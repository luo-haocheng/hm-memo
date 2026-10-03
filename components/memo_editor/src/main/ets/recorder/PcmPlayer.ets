import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  AUDIO_BYTES_PER_MS,
  PLAYBACK_DRAIN_TIMEOUT_MS,
  PLAYBACK_STOP_JOIN_TIMEOUT_MS,
  PLAYBACK_TICK_MS,
  RECORD_BYTES_PER_FRAME,
  RECORD_SAMPLE_RATE
} from '../common/Constants';

/** 16k × 2 字节 ÷ 1000 = 32 字节/毫秒（定义在 Constants，与录音侧共用） */
const BYTES_PER_MS = AUDIO_BYTES_PER_MS;

/** 一次播放进度上报 */
export interface PlaybackTick {
  positionMs: number;
  durationMs: number;
}

/**
 * PCM 播放引擎：读 `memo_audio/<uuid>.pcm`（**裸 PCM、无文件头**）喂给 `AudioRenderer`。
 *
 * 【为什么不用 AVPlayer】文件没有容器头，AVPlayer 解析不了。只能走裸流派的 AudioRenderer。
 *
 * 【为什么用 push 模型（`await renderer.write`）而不是官方的 `on('writeData')`】
 * 真机探针实测（P2）：`write()` 在 API 24 上返回值完整（无短写）、且有**真背压** ——
 * 写 4000ms 音频耗时 3936ms（比值 0.98）。虽然它自 API 11 起标了 `@deprecated`、
 * 官方指向 `writeData`，但既然实测工作正常，push 模型的心智负担最小：
 * 与已验证的 `AudioRecorder` 读循环结构完全对称，seek 只是改文件读偏移。
 * （`on('writeData')` 也实测可用 —— 1 秒回调 13 次 —— 万一将来 push 出问题有退路。）
 *
 * 【进度的口径】用「已喂入字节数 ÷ 32」而不是 `getAudioTimestampInfoSync().framePos`：
 * 后者虽然实测也是 16k 口径（rate≈14683/s），但①声明会在某些状态抛 `6800103`
 * ②它量的是**已渲染**帧、落后已喂入约 250ms，而且 ③**flush 不会重置它的计数**，
 * seek 后还得自己维护 base。已喂入字节简单、永远可用，那 ~250ms 的领先对进度条不可见。
 */
export class PcmPlayer {
  private renderer: audio.AudioRenderer | undefined = undefined;
  private fd: number = -1;
  /** 有活跃的播放会话（含暂停）。`stop()` 里**同步**翻掉 */
  private isRunning = false;
  /** 用户在暂停中：循环不喂数据，但 renderer 与 fd 都留着 */
  private isPaused = false;
  /** 会话令牌：start / stop 都会自增，在途的 `play()` 据此判断被取消 */
  private sessionId = 0;
  private loopDone: Promise<void> = Promise.resolve();
  private stopPromise: Promise<void> = Promise.resolve();

  /** 本次播放冻结的时长（开播时 stat 一次）—— 播放期间文件若被追加也不改变 */
  private durationMs = 0;
  /** 本会话已喂入的字节数（相对整个文件） */
  private fedBytes = 0;
  /** UI 请求的 seek 目标字节；由循环下一拍消费。-1 表示没有待处理的 seek */
  private seekTargetByte = -1;
  /**
   * seek 世代号。在途的 `write()` **不取消**（取消不了），
   * 它回来后用世代号判断"这一拍是否已被 seek 作废"，作废就丢弃、不计入进度。
   */
  private seekEpoch = 0;
  private windowMs = 0;

  /** 本会话的播放时长（毫秒）。`play()` 成功后才有意义 */
  getDurationMs(): number {
    return this.durationMs;
  }

  /** 当前是否暂停中（用于 UI 的播放/暂停按钮） */
  isPausedState(): boolean {
    return this.isPaused;
  }

  isActive(): boolean {
    return this.isRunning;
  }

  /**
   * 把记住的播放位置归零。
   *
   * 【只在「播完」时调】自然播放到末尾意味着"这一轮听完了"，下次应当从头开始；
   * 而 `stop()`（切后台 / 切手写 / 离开页面）**不**调它 —— 那些场景要保留断点。
   */
  resetPosition(): void {
    this.fedBytes = 0;
  }

  /**
   * 开始（或从暂停中继续）播放。
   *
   * @param pcmPath 要播放的 PCM 文件绝对路径（只在**首次开始**时用得上；续播时沿用已打开的文件）
   * @returns `true` = 正在播放；`false` = **启动期间被 `stop()` 取消**，调用方什么都不用做。
   *          真正的失败（打不开文件、建不了 renderer）走**抛异常**
   */
  async play(pcmPath: string,
    onTick: (tick: PlaybackTick) => void,
    onEnded: () => void,
    onAbort: (reason: string) => void): Promise<boolean> {
    // 已经在播 / 已暂停 → 这是"继续"
    if (this.isRunning) {
      if (this.isPaused) {
        await this.resume(onTick, onEnded, onAbort);
      }
      return true;
    }

    const mySession = ++this.sessionId;
    await this.stopPromise;
    if (mySession !== this.sessionId) {
      return false;
    }

    // 开播时 stat 一次并**冻结**时长：录音循环在 stop 之后还可能追加约 1s，
    // 播放中途文件变长不该让进度条跟着跳
    let size = 0;
    try {
      size = fileIo.statSync(pcmPath).size;
    } catch (error) {
      throw new Error(`读取录音文件大小失败: ${codeOf(error)}`);
    }
    const playable = size - (size % RECORD_BYTES_PER_FRAME);
    if (playable <= 0) {
      throw new Error('录音文件为空，无法播放');
    }
    this.durationMs = Math.floor(playable / BYTES_PER_MS);

    let fd = -1;
    try {
      fd = fileIo.openSync(pcmPath, fileIo.OpenMode.READ_ONLY).fd;
    } catch (error) {
      throw new Error(`打开录音文件失败: ${codeOf(error)}`);
    }

    // 【续播】保留上一轮的播放位置。`stop()`（切后台 / 切手写 / 离开页面）只释放资源、
    // **不动 fedBytes**，所以重新打开文件后要先 lseek 回去，否则会从头开始。
    // 「播完」那条路是自然结束，控制器会先调 `resetPosition()` 把它归零。
    let resumeByte = Math.max(0, this.fedBytes);
    if (resumeByte >= playable) {
      resumeByte = playable - RECORD_BYTES_PER_FRAME; // 别一开就撞到 EOF
    }
    try {
      fileIo.lseek(fd, resumeByte, fileIo.WhenceType.SEEK_SET);
    } catch (error) {
      console.error(`[play] 续播定位失败，从头开始: ${codeOf(error)}`);
      resumeByte = 0;
    }

    let renderer: audio.AudioRenderer;
    try {
      renderer = await audio.createAudioRenderer(buildRendererOptions());
    } catch (error) {
      closeQuietly(fd);
      throw error as Error;
    }
    if (mySession !== this.sessionId) {
      closeQuietly(fd);
      await this.releaseQuietly(renderer);
      return false;
    }

    try {
      await renderer.start();
    } catch (error) {
      closeQuietly(fd);
      await this.releaseQuietly(renderer);
      throw error as Error;
    }
    if (mySession !== this.sessionId) {
      await this.teardown(renderer, fd);
      return false;
    }

    this.renderer = renderer;
    this.fd = fd;
    this.isRunning = true;
    this.isPaused = false;
    this.fedBytes = resumeByte; // 从断点续播（首次播放时它是 0）
    this.windowMs = 0;
    this.seekTargetByte = -1;
    this.seekEpoch++;
    this.loopDone = this.loop(mySession, onTick, onEnded, onAbort);
    return true;
  }

  /** 从暂停中继续：重新拉起 renderer 并开一个新循环（fd 位置就是暂停处） */
  private async resume(onTick: (tick: PlaybackTick) => void,
    onEnded: () => void,
    onAbort: (reason: string) => void): Promise<void> {
    const renderer = this.renderer;
    if (renderer === undefined) {
      return;
    }
    this.isPaused = false;
    try {
      await renderer.start();
    } catch (error) {
      console.error(`[play] 恢复播放失败: ${codeOf(error)}`);
      onAbort('恢复播放失败');
      return;
    }
    this.windowMs = 0;
    this.loopDone = this.loop(this.sessionId, onTick, onEnded, onAbort);
  }

  /** 暂停：停止喂数据，并把 renderer 挂起。renderer 与 fd 都留着，恢复很快 */
  async pause(): Promise<void> {
    if (!this.isRunning || this.isPaused) {
      return;
    }
    this.isPaused = true; // 同步翻牌：循环下一拍就不再喂
    const renderer = this.renderer;
    if (renderer === undefined) {
      return;
    }
    // 等循环退出再 pause，避免"循环刚 write 完、pause 又被 write 唤醒"的来回
    await Promise.race([this.loopDone, delay(PLAYBACK_STOP_JOIN_TIMEOUT_MS)]);
    try {
      await renderer.pause();
    } catch (error) {
      console.error(`[play] 暂停失败: ${codeOf(error)}`);
    }
  }

  /**
   * 停止播放并释放所有资源。
   *
   * 幂等；调用方不必等它（UI 状态由控制器同步翻）。**离开页面必须调它** ——
   * 本类是单例持有的，残留的 renderer 会一直占着音频焦点。
   */
  async stop(): Promise<void> {
    this.sessionId++; // 无条件：让在途的 play() 自我取消
    if (!this.isRunning) {
      await this.stopPromise;
      return;
    }
    this.isRunning = false;
    this.isPaused = false;

    const renderer = this.renderer;
    const fd = this.fd;
    this.renderer = undefined;
    this.fd = -1;
    if (renderer === undefined) {
      return;
    }
    this.stopPromise = this.teardown(renderer, fd);
    await this.stopPromise;
  }

  /**
   * 请求跳转到指定位置。
   *
   * 【在途的 write 不取消，也取消不了】它回来后由 `seekEpoch` 判断作废。
   * 代价是最多一个 buffer（实测 640 字节 = 20ms）的旧音频可能已经进了驱动，
   * 听感上察觉不到。
   */
  seekTo(positionMs: number, durationHintMs: number): void {
    // 没在播放时（切后台 / 切手写之后）也要能改位置 —— 只记住，下次 play() 从这儿开始
    const duration = this.isRunning && this.durationMs > 0 ? this.durationMs : durationHintMs;
    const clamped = Math.max(0, Math.min(positionMs, duration));
    let byte = Math.floor(clamped * BYTES_PER_MS);
    byte -= byte % RECORD_BYTES_PER_FRAME; // 半帧会出爆音
    if (!this.isRunning) {
      this.fedBytes = byte;
      return;
    }
    this.seekEpoch++;
    if (this.isPaused) {
      // 暂停态没有循环在跑，直接自己消费掉
      this.seekTargetByte = -1;
      this.applySeek(byte).catch((error: Object) => {
        console.error(`[play] 暂停态 seek 失败: ${codeOf(error)}`);
      });
    } else {
      this.seekTargetByte = byte; // 交给循环下一拍消费
    }
  }

  // ==================== 内部 ====================

  /**
   * 喂数据主循环。
   *
   * 退出条件有三个：用户暂停、会话被换掉、文件读到尾。三者都用**同步标志**判断，
   * 所以"点暂停"的同一拍循环就已决定不再喂。
   */
  private async loop(session: number,
    onTick: (tick: PlaybackTick) => void,
    onEnded: () => void,
    onAbort: (reason: string) => void): Promise<void> {
    const renderer = this.renderer;
    if (renderer === undefined) {
      return;
    }
    const chunkBytes = Math.max(2, renderer.getBufferSizeSync());
    try {
      while (this.isRunning && !this.isPaused && session === this.sessionId) {
        // 先消费挂起的 seek
        if (this.seekTargetByte >= 0) {
          const target = this.seekTargetByte;
          this.seekTargetByte = -1;
          await this.applySeek(target);
          continue;
        }

        const epoch = this.seekEpoch;
        const buffer = this.readChunk(chunkBytes);
        if (buffer.byteLength === 0) {
          await this.finish(renderer);
          onEnded();
          return;
        }

        // write 可能短写（探针实测 640 字节时不会，但按防御写）
        let offset = 0;
        while (offset < buffer.byteLength) {
          const part = offset === 0 ? buffer : buffer.slice(offset);
          const written = await renderer.write(part);
          if (written <= 0) {
            break;
          }
          offset += written;
          if (epoch !== this.seekEpoch) {
            break; // 这一拍已被 seek 作废，剩下的不再写
          }
        }
        if (epoch !== this.seekEpoch) {
          continue; // 不把这个作废的 buffer 计入进度
        }
        this.fedBytes += offset;
        this.windowMs += offset / BYTES_PER_MS;
        if (this.windowMs >= PLAYBACK_TICK_MS) {
          this.windowMs = 0;
          onTick({ positionMs: this.positionMs(), durationMs: this.durationMs });
        }
      }
    } catch (error) {
      if (this.isRunning && session === this.sessionId) {
        console.error(`[play] 播放循环出错: ${codeOf(error)}`);
        onAbort(`播放出错: ${codeOf(error)}`);
      }
    }
  }

  /** flush → lseek → 重置已喂字节。实测三种状态下 flush 都合法（P5b） */
  private async applySeek(byte: number): Promise<void> {
    const renderer = this.renderer;
    if (renderer === undefined || this.fd < 0) {
      return;
    }
    try {
      // 不清掉驱动里已排队的旧音频，跳过去之后会先听到一小段陈旧的
      await renderer.flush();
    } catch (error) {
      console.error(`[play] flush 失败（继续按 seek 处理）: ${codeOf(error)}`);
    }
    try {
      fileIo.lseek(this.fd, byte, fileIo.WhenceType.SEEK_SET);
    } catch (error) {
      console.error(`[play] lseek 失败: ${codeOf(error)}`);
    }
    this.fedBytes = byte;
    this.windowMs = 0;
  }

  /** 读到文件尾：等驱动把已排队的放完，然后走正常收尾 */
  private async finish(renderer: audio.AudioRenderer): Promise<void> {
    try {
      await Promise.race([
        renderer.drain(),
        delay(PLAYBACK_DRAIN_TIMEOUT_MS),
      ]);
    } catch (error) {
      console.error(`[play] drain 失败: ${codeOf(error)}`);
    }
  }

  /**
   * 释放 renderer 与 fd。
   *
   * ⚠️ 顺序是「等循环收敛（带超时）→ release」。**绝不能在还有在途 write 时直接 release
   * 还去 await 那个 write** —— 实测它会**永远不 settle**。这里的 `Promise.race` 是必需的超时兜底
   */
  private async teardown(renderer: audio.AudioRenderer, fd: number): Promise<void> {
    await Promise.race([this.loopDone, delay(PLAYBACK_STOP_JOIN_TIMEOUT_MS)]);
    try {
      await renderer.stop();
    } catch (error) {
      // 已停 / 未启动都会走到这里，不是错误路径
      console.info(`[play] stop 异常（通常是已停）: ${codeOf(error)}`);
    }
    await this.releaseQuietly(renderer);
    closeQuietly(fd);
  }

  private async releaseQuietly(renderer: audio.AudioRenderer): Promise<void> {
    try {
      await renderer.release();
    } catch (error) {
      console.error(`[play] 释放 renderer 失败: ${codeOf(error)}`);
    }
  }

  private positionMs(): number {
    return Math.min(this.durationMs, Math.floor(this.fedBytes / BYTES_PER_MS));
  }

  /** 读一块（偶数对齐）。读到尾返回 byteLength = 0 */
  private readChunk(bytes: number): ArrayBuffer {
    if (this.fd < 0) {
      return new ArrayBuffer(0);
    }
    const buffer = new ArrayBuffer(bytes);
    let n = 0;
    try {
      n = fileIo.readSync(this.fd, buffer);
    } catch (error) {
      console.error(`[play] 读录音文件失败: ${codeOf(error)}`);
      return new ArrayBuffer(0);
    }
    const even = n - (n % RECORD_BYTES_PER_FRAME);
    if (even <= 0) {
      return new ArrayBuffer(0);
    }
    return even === bytes ? buffer : buffer.slice(0, even);
  }
}

/** 采集参数与录音端完全一致：16k / 单声道 / S16LE / 裸流 */
function buildRendererOptions(): audio.AudioRendererOptions {
  return {
    streamInfo: {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
    },
    rendererInfo: {
      // rendererFlags 的声明原文是 "reserved, suggest setting the default value to 0"
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
      rendererFlags: 0,
    },
  };
}

function closeQuietly(fd: number): void {
  if (fd < 0) {
    return;
  }
  try {
    fileIo.closeSync(fd);
  } catch (error) {
    console.error(`[play] 关闭录音文件失败: ${codeOf(error)}`);
  }
}

function codeOf(error: Object): string {
  const e = error as BusinessError;
  return e === undefined || e === null ? 'unknown' : `code=${e.code} msg=${e.message}`;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}
