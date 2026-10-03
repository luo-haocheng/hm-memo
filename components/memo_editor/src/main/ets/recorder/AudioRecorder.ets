import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  RECORD_BYTES_PER_FRAME,
  RECORD_LEVEL_FLOOR_DB,
  RECORD_LEVEL_WINDOW_MS,
  RECORD_SAMPLE_RATE,
  RECORD_STOP_JOIN_TIMEOUT_MS
} from '../common/Constants';
import { PcmFileWriter } from './PcmFileWriter';

/**
 * 一次音量/计时上报。
 */
export interface RecorderTick {
  /** 归一化到 0~1 的音量 */
  level: number;

  /** 已录时长（毫秒） */
  elapsedMs: number;
}

/**
 * 录音引擎：管 AudioCapturer 的建/启/停/释放、**PCM 落盘**，把「音量 + 已录时长」按窗上报。
 *
 * 【为什么是一个纯类】它不碰任何 ArkUI 东西 —— 没有装饰器、没有 UIContext、没有 builder。
 * 可观察状态留在 `MemoEditorController` 的 `@Trace` 字段上（UI 统一读 `this.controller.xxx`），
 * 这里只负责把回调打出去。**回调由控制器在 `start()` 时传进来**，本类不持有任何外部对象 ——
 * 控制器是进程级单例，往它身上挂组件作用域的东西会吊住组件实例。
 *
 * 【为什么不用 setInterval 驱动 UI 刷新】阻塞式 `read()` 由硬件节奏驱动（实测每 buffer 约 20ms），
 * **读循环本身就是天然的定时器**。工程里目前一个 setInterval 都没有，保持这个现状。
 *
 * 【为什么 writer 归它管】见 `PcmFileWriter` 顶部 —— 把 `close()` 挂在控制器的
 * `stop()` resolve 上会在"写盘变慢 + 超时"那条路上关掉正在写的 fd。
 * 所有权放这里，`close()` 就落在读循环的 `finally`，顺序天然正确。
 */
export class AudioRecorder {
  private capturer: audio.AudioCapturer | undefined = undefined;
  /** 读循环的开关。`stop()` 里**同步**翻成 false，所以点停止的同一拍循环就已决定不再累积 */
  private isRunning = false;
  /**
   * 会话令牌：每次 start / stop 都会自增。读循环靠它自杀，
   * **在途的 `start()` 也靠它判断"启动期间被取消了"**。
   *
   * ⚠️ `stop()` 里是**无条件**自增的（哪怕当前没在录）—— 这是"点录音后立刻按返回"
   *    那条路上唯一的取消信号，详见 `stop()` 的注释。
   */
  private sessionId = 0;
  /** 当前会话读循环的完成信号，`stop()` 要等它 */
  private loopDone: Promise<void> = Promise.resolve();
  /**
   * 上一次 `stop()` 的完成信号。
   *
   * 【为什么要它】实测：`stop()` 后那个挂起的阻塞 read 要约 1000ms 才收敛，
   * 而 `release()` 我们只在它收敛之后才调。所以"停止"这个动作在后台还要持续约 1s ——
   * 这段时间里用户完全可能再点一次录音。`start()` 必须等它，否则会同时存在两个 capturer。
   */
  private stopPromise: Promise<void> = Promise.resolve();
  /** abort 通知的一次性闸门（每个会话复位） */
  private abortNotified = false;

  // ---- 每个上报窗口的累加量 ----
  private sumSquares = 0;
  private windowFrames = 0;
  private windowMs = 0;
  /** 本次会话累计读到的帧数 —— 计时口径：帧数 ÷ 采样率 */
  private framesRead = 0;

  /**
   * 开始录音，并把 PCM **追加**写入 `pcmPath`。
   *
   * 【返回值】`true` = 已经在录了；`false` = **启动期间被 `stop()` 取消**，
   * 此时本类已经把建出来的 capturer / writer 全部收拾干净，调用方什么都不用做。
   * 真正的失败（打不开文件、创建 capturer 失败、bufferSize 非法）走**抛异常**。
   *
   * 【契约】无论成功 / 失败 / 取消，`start()` settle 时**文件一定已关闭**。
   * 控制器因此完全不用管 fd 的生命周期。
   *
   * @param onTick 每 `RECORD_LEVEL_WINDOW_MS` 回调一次
   * @param onAbort 需要中止本次录音时回调一次（系统打断 / 读取失败 / 写盘失败）。
   *                调用方只需翻 UI 状态；引擎自己会把麦克风与文件收干净
   * @param pcmPath 追加写入的目标文件绝对路径（目录不存在会创建）
   */
  async start(onTick: (tick: RecorderTick) => void,
    onAbort: (reason: string) => void,
    pcmPath: string): Promise<boolean> {
    if (this.isRunning) {
      return false;
    }
    // 会话令牌必须在**任何 await 之前**自增 —— 见 stop() 的注释
    const mySession = ++this.sessionId;
    this.abortNotified = false;

    // 等上一次 stop 彻底收尾。**writer 也要等到这之后才创建** ——
    // 否则上一次的读循环可能还在写同一个文件，两个 fd 交叠
    await this.stopPromise;
    if (mySession !== this.sessionId) {
      return false; // 等待期间被取消
    }

    const writer = new PcmFileWriter();
    if (!writer.open(pcmPath)) {
      throw new Error(`无法打开录音文件: ${pcmPath}`);
    }

    let capturer: audio.AudioCapturer;
    try {
      capturer = await audio.createAudioCapturer(this.buildOptions());
    } catch (error) {
      writer.close();
      throw error as Error;
    }
    if (mySession !== this.sessionId) {
      writer.close();
      await this.abortStart(capturer);
      return false;
    }

    this.framesRead = 0;
    this.sumSquares = 0;
    this.windowFrames = 0;
    this.windowMs = 0;

    try {
      // 来电等系统打断：本轮不做"暂停后自动续录"，交给调用方停掉即可
      capturer.on('audioInterrupt', () => {
        this.notifyAbort(onAbort, '系统打断（来电 / 被其他应用抢占麦克风）');
      });
      await capturer.start();
    } catch (error) {
      writer.close();
      await this.releaseQuietly(capturer);
      throw error as Error;
    }
    if (mySession !== this.sessionId) {
      writer.close();
      await this.abortStart(capturer);
      return false;
    }

    const bufferSize = capturer.getBufferSizeSync();
    if (bufferSize <= 0) {
      writer.close();
      await this.abortStart(capturer);
      throw new Error(`capturer 报出的 bufferSize 非法: ${bufferSize}`);
    }

    this.isRunning = true;
    this.capturer = capturer;
    this.loopDone = this.readLoop(capturer, mySession, bufferSize, writer, onTick, onAbort);
    return true;
  }

  /**
   * 停止录音并释放麦克风。
   *
   * 幂等；**同步**先把状态翻掉，所以调用方（UI）不必等它 —— 录音条应当立刻消失。
   *
   * 【为什么无条件自增 `sessionId`】哪怕当前没在录，也要让**在途的 `start()`** 失效。
   * `MemoEditorController` 侧 `isRecording` 是 `start()` resolve 之后才置位的，
   * 所以"点录音后立刻按返回"这条路上控制器拦不住 —— 这里才是唯一的取消点。
   * 不这么做的话，录音会照样起来、麦克风留在开着。
   */
  async stop(): Promise<void> {
    // ① 无条件翻牌：在途的 start 会据此自我取消
    this.sessionId++;

    if (!this.isRunning) {
      // 可能上一次 stop 还在后台收尾，把它交给后来者等
      await this.stopPromise;
      return;
    }
    this.isRunning = false;

    const capturer = this.capturer;
    this.capturer = undefined;
    if (capturer === undefined) {
      return;
    }
    this.stopPromise = this.stopAndRelease(capturer);
    await this.stopPromise;
  }

  /**
   * 阻塞式读取循环：每读到一个 buffer 就**追加写盘**、累加音量。
   *
   * 每一步都重新判一次"是否还是本次会话" —— `stop()` 会打断挂起的 `read()`，
   * 那一刻循环必须**安静退出**，不能把 6800301 当错误报上去、更不能把缓冲继续累加。
   */
  private async readLoop(capturer: audio.AudioCapturer, mySession: number, bufferSize: number,
    writer: PcmFileWriter, onTick: (tick: RecorderTick) => void,
    onAbort: (reason: string) => void): Promise<void> {
    try {
      while (this.isRunning && mySession === this.sessionId) {
        let buffer: ArrayBuffer;
        try {
          buffer = await capturer.read(bufferSize, true);
        } catch (error) {
          if (!this.isRunning || mySession !== this.sessionId) {
            return; // stop() 打断挂起的 read —— 正常路径
          }
          console.error(`[record] 读取音频失败，停止本次录音: ${this.codeOf(error)}`);
          this.notifyAbort(onAbort, '读取音频失败');
          return;
        }

        // stop 之后可能还会回一个已排队的 buffer，这里再判一次直接丢掉，
        // 保证"点停止后立刻不再累积"，也保证时长不会多跳一帧
        if (!this.isRunning || mySession !== this.sessionId) {
          return;
        }

        // 【写盘失败就地吃掉，绝不让 rejection 逃出循环】
        // 逃出去会让 loopDone reject → Promise.race reject → releaseQuietly 被跳过
        // → capturer 泄漏 → 麦克风一直占着，下次录音就有两个 capturer 并存
        try {
          await writer.append(buffer);
        } catch (error) {
          console.error(`[record] 写入 PCM 失败，停止本次录音: ${this.codeOf(error)}`);
          this.notifyAbort(onAbort, '写入录音文件失败');
          return;
        }

        const frames = buffer.byteLength / RECORD_BYTES_PER_FRAME;
        this.framesRead += frames;
        this.accumulate(buffer);
        this.windowMs += frames / RECORD_SAMPLE_RATE * 1000;

        if (this.windowMs >= RECORD_LEVEL_WINDOW_MS) {
          this.windowMs = 0;
          onTick({
            level: this.finishLevel(),
            elapsedMs: this.framesRead / RECORD_SAMPLE_RATE * 1000,
          });
        }
      }
    } finally {
      // 契约：writer 的所有权在本类，**循环真退出时**才关 ——
      // 此刻所有 `await writer.append` 都已 resolve，不可能有关到正在写的 fd 的情况
      writer.close();

      // 因"写盘失败 / 读取失败"退出时，用户并没有喊停（`isRunning` 仍为 true）
      // —— 这里要自己把麦克风收掉，否则下次录音就会有两个 capturer
      if (mySession === this.sessionId && this.isRunning) {
        this.stopPromise = this.selfStop(capturer);
        await this.stopPromise;
      }
    }
  }

  /** 用户主动停止时的收尾：stop → 等读循环收敛 → release */
  private async stopAndRelease(capturer: audio.AudioCapturer): Promise<void> {
    try {
      await capturer.stop();
    } catch (error) {
      // 已经被打断 / 已经停了都会走到这里，不是错误路径
      console.info(`[record] stop 时捕获到异常（通常是已停/被打断）: ${this.codeOf(error)}`);
    }
    try {
      // 挂起的阻塞 read 实测要约 1s 才以 6800301 收敛。等它自然退出再 release ——
      // 「release 时仍有 read 未收敛」这条路没有实测过，所以只在超时兜底时才走
      await Promise.race([
        this.loopDone,
        this.delay(RECORD_STOP_JOIN_TIMEOUT_MS),
      ]);
    } finally {
      // 任何异常路径都必须释放，否则麦克风一直占着
      await this.releaseQuietly(capturer);
    }
  }

  /**
   * 读循环**自己**退出时的收尾（写盘失败 / 读取失败）。
   *
   * ⚠️ 不能复用 `stopAndRelease` —— 它会 await `this.loopDone`，
   *    而我们此刻正站在那个 promise 的 finally 里，会**自锁**。所以这里不等循环。
   */
  private async selfStop(capturer: audio.AudioCapturer): Promise<void> {
    this.isRunning = false;
    this.sessionId++;
    this.capturer = undefined;
    try {
      await capturer.stop();
    } catch (error) {
      console.info(`[record] 自行收尾时 stop 异常（通常是已停/被打断）: ${this.codeOf(error)}`);
    }
    await this.releaseQuietly(capturer);
  }

  /** 启动被取消时收拾已经建出来的 capturer（还没进读循环，不用等 loopDone） */
  private async abortStart(capturer: audio.AudioCapturer): Promise<void> {
    try {
      await capturer.stop();
    } catch (error) {
      console.info(`[record] 取消启动时 stop 异常（通常是还没起或已停）: ${this.codeOf(error)}`);
    }
    await this.releaseQuietly(capturer);
  }

  /** abort 通知只发一次；回调本身抛异常也不能把引擎带崩 */
  private notifyAbort(onAbort: (reason: string) => void, reason: string): void {
    if (this.abortNotified) {
      return;
    }
    this.abortNotified = true;
    try {
      onAbort(reason);
    } catch (error) {
      console.error(`[record] onAbort 回调抛异常: ${JSON.stringify(error)}`);
    }
  }

  /** 采集参数：16k / 单声道 / S16LE 原始 PCM（与真机探针验证过的配置一致） */
  private buildOptions(): audio.AudioCapturerOptions {
    return {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      capturerInfo: {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0,
      },
    };
  }

  /** 逐 buffer 累加平方和。S16LE 直接当 Int16Array 读 */
  private accumulate(buffer: ArrayBuffer): void {
    const samples = new Int16Array(buffer);
    for (let i = 0; i < samples.length; i++) {
      const s = samples[i];
      this.sumSquares += s * s;
    }
    this.windowFrames += samples.length;
  }

  /**
   * 把本窗口的 RMS 归一化到 0~1。
   *
   * 【为什么要走 dB】人声的 RMS 线性值通常落在 0.02~0.2，直接当 0~1 用会"永远贴底"，
   * 波形看着像没反应。转成 dB 再线性映射，说话时才有明显的起伏。
   * 底噪被 `RECORD_LEVEL_FLOOR_DB` 截掉，安静时归零。
   */
  private finishLevel(): number {
    const rms = this.windowFrames > 0 ? Math.sqrt(this.sumSquares / this.windowFrames) : 0;
    this.sumSquares = 0;
    this.windowFrames = 0;
    // 1e-9 防 log(0)
    const db = 20 * Math.log10(rms / 32768 + 1e-9);
    const normalized = (db + RECORD_LEVEL_FLOOR_DB) / RECORD_LEVEL_FLOOR_DB;
    return Math.min(1, Math.max(0, normalized));
  }

  private async releaseQuietly(capturer: audio.AudioCapturer): Promise<void> {
    try {
      await capturer.release();
    } catch (error) {
      console.error(`[record] 释放 capturer 失败: ${this.codeOf(error)}`);
    }
  }

  private codeOf(error: Object): string {
    const e = error as BusinessError;
    return e === undefined || e === null ? 'unknown' : `code=${e.code} msg=${e.message}`;
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}
