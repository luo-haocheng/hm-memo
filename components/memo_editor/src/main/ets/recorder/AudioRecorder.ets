import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  RECORD_BYTES_PER_FRAME,
  RECORD_LEVEL_FLOOR_DB,
  RECORD_LEVEL_WINDOW_MS,
  RECORD_SAMPLE_RATE,
  RECORD_STOP_JOIN_TIMEOUT_MS
} from '../common/Constants';

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
 * 录音引擎：管 AudioCapturer 的建/启/停/释放，把「音量 + 已录时长」按窗上报。
 *
 * 【为什么是一个纯类】它不碰任何 ArkUI 东西 —— 没有装饰器、没有 UIContext、没有 builder。
 * 可观察状态留在 `MemoEditorController` 的 `@Trace` 字段上（UI 统一读 `this.controller.xxx`），
 * 这里只负责把回调打出去。**回调由控制器在 `start()` 时传进来**，本类不持有任何外部对象 ——
 * 控制器是进程级单例，往它身上挂组件作用域的东西会吊住组件实例。
 *
 * 【为什么不用 setInterval 驱动 UI 刷新】阻塞式 `read()` 由硬件节奏驱动（实测每 buffer 约 20ms），
 * **读循环本身就是天然的定时器**。工程里目前一个 setInterval 都没有，保持这个现状。
 */
export class AudioRecorder {
  private capturer: audio.AudioCapturer | undefined = undefined;
  /** 读循环的开关。`stop()` 里**同步**翻成 false，所以点停止的同一拍循环就已决定不再累积 */
  private isRunning = false;
  /**
   * 会话令牌：每次 start 自增。旧循环靠它自杀 ——
   * 与 `isRunning` 是**双保险**：`isRunning` 管当前会话，令牌管"万一有旧循环还活着"
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
  // ---- 每个上报窗口的累加量 ----
  private sumSquares = 0;
  private windowFrames = 0;
  private windowMs = 0;
  /** 本次会话累计读到的帧数 —— 计时口径：帧数 ÷ 采样率 */
  private framesRead = 0;

  /**
   * 开始录音。失败时**抛异常**，由调用方决定怎么提示。
   *
   * @param onTick 每 `RECORD_LEVEL_WINDOW_MS` 回调一次
   * @param onInterrupt 系统打断（来电、被其他应用抢占麦克风等）时回调，调用方应停止录音
   */
  async start(onTick: (tick: RecorderTick) => void, onInterrupt: () => void): Promise<void> {
    if (this.isRunning) {
      return;
    }
    // 等上一次 stop 彻底收尾（见 stopPromise 的注释），避免两个 capturer 并存
    await this.stopPromise;

    const capturer = await audio.createAudioCapturer(this.buildOptions());
    this.sessionId++;
    const mySession = this.sessionId;
    this.isRunning = true;
    this.capturer = capturer;
    this.framesRead = 0;
    this.sumSquares = 0;
    this.windowFrames = 0;
    this.windowMs = 0;

    try {
      // 来电等系统打断：本轮不做"暂停后自动续录"，直接交给调用方停掉即可
      capturer.on('audioInterrupt', () => {
        onInterrupt();
      });
      await capturer.start();
    } catch (error) {
      // 启动失败要把 capturer 收拾干净，否则麦克风一直占着
      this.isRunning = false;
      this.capturer = undefined;
      await this.releaseQuietly(capturer);
      throw error as Error;
    }

    const bufferSize = capturer.getBufferSizeSync();
    if (bufferSize <= 0) {
      this.isRunning = false;
      this.capturer = undefined;
      await this.stopAndRelease(capturer);
      throw new Error(`capturer 报出的 bufferSize 非法: ${bufferSize}`);
    }

    this.loopDone = this.readLoop(capturer, mySession, bufferSize, onTick);
  }

  /**
   * 停止录音并释放麦克风。
   *
   * 幂等；**同步**先把状态翻掉，所以调用方（UI）不必等它 —— 录音条应当立刻消失。
   */
  async stop(): Promise<void> {
    if (!this.isRunning) {
      // 可能上一次 stop 还在后台收尾，把它交给后来者等
      await this.stopPromise;
      return;
    }
    // ① 同步翻牌：下一拍循环必退。UI 的"立刻消失"靠的就是这一步的同步性
    this.isRunning = false;
    // ② 令牌失效：双保险
    this.sessionId++;

    const capturer = this.capturer;
    this.capturer = undefined;
    if (capturer === undefined) {
      return;
    }
    this.stopPromise = this.stopAndRelease(capturer);
    await this.stopPromise;
  }

  /** 真正去停：stop → 等读循环收敛 → release */
  private async stopAndRelease(capturer: audio.AudioCapturer): Promise<void> {
    try {
      await capturer.stop();
    } catch (error) {
      // 已经被打断 / 已经停了都会走到这里，不是错误路径
      console.info(`[record] stop 时捕获到异常（通常是已停/被打断）: ${this.codeOf(error)}`);
    }

    // 挂起的阻塞 read 实测要约 1s 才以 6800301 收敛。等它自然退出再 release ——
    // 「release 时仍有 read 未收敛」这条路**没有实测过**，所以只在超时兜底时才走
    await Promise.race([
      this.loopDone,
      this.delay(RECORD_STOP_JOIN_TIMEOUT_MS),
    ]);

    await this.releaseQuietly(capturer);
  }

  /**
   * 阻塞式读取循环。
   *
   * 每一步都重新判一次"是否还是本次会话" —— `stop()` 会打断挂起的 `read()`，
   * 那一刻循环必须**安静退出**，不能把 6800301 当错误报上去、更不能把缓冲继续累加。
   */
  private async readLoop(capturer: audio.AudioCapturer, mySession: number,
    bufferSize: number, onTick: (tick: RecorderTick) => void): Promise<void> {
    while (this.isRunning && mySession === this.sessionId) {
      let buffer: ArrayBuffer;
      try {
        buffer = await capturer.read(bufferSize, true);
      } catch (error) {
        if (!this.isRunning || mySession !== this.sessionId) {
          return; // stop() 打断挂起的 read —— 正常路径
        }
        console.error(`[record] 读取音频失败: ${this.codeOf(error)}`);
        return;
      }

      // stop 之后可能还会回一个已排队的 buffer，这里再判一次直接丢掉，
      // 保证"点停止后立刻不再累积"，也保证时长不会多跳一帧
      if (!this.isRunning || mySession !== this.sessionId) {
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
