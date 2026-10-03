import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 一次录音会话的 PCM 落盘写入器：**追加**写，每个 buffer 一次 write 并立即 await。
 *
 * 【为什么由录音引擎持有，而不是控制器】
 * 曾经打算让控制器持有 fd、把 `close()` 挂在 `stop()` 的 resolve 上 —— 那是个致命洞：
 * 写盘变慢时读循环会挂在 `await append` 上，而 `stop()` 那边的 1200ms 超时先到、
 * 照常 resolve，于是**控制器把还在写的 fd 关掉了**，后续 write 全部 EBADF。
 * 而那恰恰是"磁盘出问题"时最需要它不出错的路径。
 * 所有权放进引擎后，`close()` 落在读循环的 `finally` 里，
 * 天然满足"所有 append 都已 resolve 才 close"这个顺序要求。
 *
 * 【绝不做用户态缓冲】每个 buffer 一次 write。进程被杀时内核会关掉 fd，
 * 已经 write 出去的内容留在 page cache 里不会丢；一旦攒批再 flush，被杀就会丢掉一整批。
 */
export class PcmFileWriter {
  private file: fileIo.File | undefined = undefined;
  private path: string = '';
  /** `open()` 那一刻的既有大小 —— 本次会话写入的字节都排在它后面 */
  private baseSize = 0;
  /** 本次会话累计写入的字节数 */
  private written = 0;
  /** 首写自检做过没有（每次 open 复位） */
  private verified = false;
  /** close 必须**幂等**：收尾链在异常路径下可能被调两次 */
  private closed = false;

  /** 本次会话已写入的字节数 */
  getWritten(): number {
    return this.written;
  }

  /**
   * 打开（不存在则创建）并定位到文件末尾。
   *
   * ⚠️ **必须先建目录**：`openSync` 不会替我们创建 `memo_audio/`。
   *    图片（`Memo.savePixelMapToFile`）和笔迹（`MemoEditorController.saveInk`）都踩过这个坑。
   */
  open(path: string): boolean {
    const dir = path.substring(0, path.lastIndexOf('/'));
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
    } catch (error) {
      console.error(`[pcm] 创建录音目录失败: ${dir}. Cause: ${this.codeOf(error)}`);
      return false;
    }

    try {
      this.file = fileIo.openSync(path,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
    } catch (error) {
      console.error(`[pcm] 打开录音文件失败: ${path}. Cause: ${this.codeOf(error)}`);
      return false;
    }

    this.path = path;
    this.written = 0;
    this.verified = false;
    this.closed = false;
    try {
      this.baseSize = fileIo.statSync(path).size;
    } catch (error) {
      // 取不到既有大小不影响追加（O_APPEND 由内核定位），但自检就没基准了
      console.error(`[pcm] 取录音文件大小失败: ${path}. Cause: ${this.codeOf(error)}`);
      this.baseSize = -1;
    }
    console.info(`[pcm] 打开录音文件: ${path} (既有 ${this.baseSize} bytes)`);
    return true;
  }

  /**
   * 追加一个 buffer。失败时**抛异常** —— 由读循环按"致命"处理并停止本次录音。
   *
   * 【不传 `WriteOptions.offset`】SDK 写明它的语义是"**当前 filePointer 加** offset"，
   * 传了可能盖掉别处；不传 + O_APPEND 才是纯粹的追加。
   */
  async append(buffer: ArrayBuffer): Promise<void> {
    const file = this.file;
    if (file === undefined || this.closed) {
      throw new Error('PCM writer 未打开或已关闭');
    }
    const written = await fileIo.write(file.fd, buffer);
    this.written += written;
    if (!this.verified) {
      this.verified = true;
      this.verifyAppend();
    }
  }

  /**
   * 首写自检 —— 本轮**替代探针**的机制。
   *
   * SDK 注释说 `OpenMode.APPEND` 会把新数据加到文件末尾，但本工程被
   * "声明与运行时不一致"坑过两次，而这里猜错的后果是**第二次录音静默覆盖第一次**。
   * 所以第一次写完立刻对一次账，把它变成响亮可见的报错。
   *
   * 附带好处：万一两个 writer 同时写同一个文件，第二个会因 `actual > expected` 触发。
   */
  private verifyAppend(): void {
    if (this.baseSize < 0) {
      return; // 没有基准，自检做不了（open 时 stat 就失败了）
    }
    const expected = this.baseSize + this.written;
    let actual = this.readSize();
    if (actual === expected) {
      console.info(`[pcm] 追加自检通过: ${this.path} (base=${this.baseSize} + ${this.written} = ${actual})`);
      return;
    }
    // 再 stat 一次，排除"stat 早于落盘"的时序误报
    actual = this.readSize();
    if (actual === expected) {
      console.info(`[pcm] 追加自检通过（第二次）: ${this.path} (${actual} bytes)`);
      return;
    }
    console.error(`[pcm] APPEND 校验失败！path=${this.path} `
      + `base=${this.baseSize} written=${this.written} actual=${actual} expected=${expected}`);
    throw new Error(`PCM 追加校验失败（期望 ${expected}，实际 ${actual}）`);
  }

  private readSize(): number {
    try {
      return fileIo.statSync(this.path).size;
    } catch (error) {
      console.error(`[pcm] 自检 stat 失败: ${this.path}. Cause: ${this.codeOf(error)}`);
      return -2; // 与 expected 不可能相等的哨兵值
    }
  }

  /** 幂等关闭。调用点可能来自正常收尾，也可能来自异常路径 */
  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    const file = this.file;
    this.file = undefined;
    if (file === undefined) {
      return;
    }
    try {
      fileIo.closeSync(file);
      if (this.written > 0) {
        console.info(`[pcm] 关闭录音文件: ${this.path} (本次写入 ${this.written} bytes)`);
      }
    } catch (error) {
      console.error(`[pcm] 关闭录音文件失败: ${this.path}. Cause: ${this.codeOf(error)}`);
    }
  }

  private codeOf(error: Object): string {
    const e = error as BusinessError;
    return e === undefined || e === null ? 'unknown' : `code=${e.code} msg=${e.message}`;
  }
}
