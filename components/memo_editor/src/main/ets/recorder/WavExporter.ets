import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EXPORT_CHUNK_BYTES, RECORD_BYTES_PER_FRAME, RECORD_SAMPLE_RATE } from '../common/Constants';

/** 标准 WAV 头长度：RIFF(12) + fmt (24) + data 头(8) */
const WAV_HEADER_BYTES = 44;

/**
 * RIFF 的 size 字段是 **uint32**，能表达的最大字节数。
 * 32KB/s 下要约 37 小时才撞得到，但 `DataView.setUint32` 超了会**静默截断**，
 * 所以宁可拒绝也不要产出坏文件。
 */
const RIFF_SIZE_LIMIT = 0xFFFFFFFF;

/**
 * 把沙箱里的**裸 PCM**（16k / 单声道 / S16LE）导出成标准 **WAV** 写到用户选定的位置。
 *
 * 【为什么必须自己包头】`.pcm` 没有任何文件头，不给它加上 RIFF 头的话，
 * 导出的文件没有任何播放器认得。
 *
 * 【两条硬约束】
 * 1. **源文件大小只 stat 一次并冻结**，之后严格只拷这么多字节、绝不再 stat ——
 *    录音停止后约 1s 内 `AudioRecorder` 的循环仍可能追加，边拷边量会让头里写的
 *    `dataSize` 与实际落盘字节数对不上，那是比"截断"更隐蔽的坏文件
 * 2. **全程用异步 `fileIo.read/write` 分块拷贝**，不能图省事用同步 API ——
 *    115MB 的同步拷贝会把 UI 线程锁死，菜单和对话框都关不掉
 */
export async function exportPcmAsWav(srcPath: string, destUri: string): Promise<void> {
  let size = 0;
  try {
    size = fileIo.statSync(srcPath).size;
  } catch (error) {
    throw new Error(`读取录音文件大小失败: ${codeOf(error)}`);
  }
  // 帧对齐：半帧（进程被杀留下的）会让解码器爆音甚至拒收
  const dataSize = size - (size % RECORD_BYTES_PER_FRAME);
  if (dataSize <= 0) {
    throw new Error('录音文件为空，无法导出');
  }
  if (dataSize > RIFF_SIZE_LIMIT - 36) {
    throw new Error('录音过大，超出 WAV 格式的 4GB 上限');
  }

  let srcFd = -1;
  try {
    srcFd = fileIo.openSync(srcPath, fileIo.OpenMode.READ_ONLY).fd;
  } catch (error) {
    throw new Error(`打开录音文件失败: ${codeOf(error)}`);
  }

  let destFd = -1;
  try {
    destFd = openDest(destUri);
  } catch (error) {
    closeQuietly(srcFd);
    throw new Error(`打开目标文件失败: ${codeOf(error)}`);
  }

  try {
    await writeAll(destFd, buildWavHeader(dataSize));
    await copyExact(srcFd, destFd, dataSize);
  } catch (error) {
    // 【失败要回滚】不回滚的话会留下一个"头声称的长度 > 实际字节"的半截文件，
    // 它看起来完全正常、播到一半才断 —— 静默产出坏文件是最坏的结果
    try {
      fileIo.truncateSync(destFd, 0);
    } catch (truncError) {
      console.error(`[export] 回滚目标文件失败: ${codeOf(truncError)}`);
    }
    throw error as Error;
  } finally {
    closeQuietly(destFd);
    closeQuietly(srcFd);
  }
}

/**
 * 44 字节的标准 RIFF/WAVE 头（全部小端）。
 *
 * `ChunkSize = 36 + dataSize`（36 = 头里 data 之前的部分加 data 头本身）。
 */
export function buildWavHeader(dataSize: number): ArrayBuffer {
  const header = new ArrayBuffer(WAV_HEADER_BYTES);
  const view = new DataView(header);
  const channels = 1;
  const bitsPerSample = 16;
  const blockAlign = channels * bitsPerSample / 8; // = RECORD_BYTES_PER_FRAME

  putAscii(view, 0, 'RIFF');
  view.setUint32(4, 36 + dataSize, true);
  putAscii(view, 8, 'WAVE');
  putAscii(view, 12, 'fmt ');
  view.setUint32(16, 16, true);                                     // fmt 块长度
  view.setUint16(20, 1, true);                                      // 编码：1 = PCM
  view.setUint16(22, channels, true);
  view.setUint32(24, RECORD_SAMPLE_RATE, true);
  view.setUint32(28, RECORD_SAMPLE_RATE * blockAlign, true);        // byteRate
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, bitsPerSample, true);
  putAscii(view, 36, 'data');
  view.setUint32(40, dataSize, true);
  return header;
}

/**
 * 导出时预填的文件名：`录音_20261004_013715.wav`。
 *
 * 【为什么要精确到秒】只到分钟的话，同一分钟内导出两次会撞名，
 * 撞名后是覆盖还是自动改名取决于文件提供方，不可控。
 *
 * 【为什么手工拼而不是 `toISOString()`】后者是 **UTC**，临近午夜会差一天。
 *
 * ⚠️ 这只是**预填**给 picker 的建议名，用户可以在系统界面里改；
 *    系统也可能自行改名，所以**不要**从返回的 URI 反推文件名。
 */
export function timestampWavName(): string {
  const now = new Date();
  const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  const date = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}`;
  const time = `${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  return `录音_${date}_${time}.wav`;
}

// ==================== 内部 ====================

/**
 * 打开目标位置。
 *
 * `DocumentViewPicker.save()` 默认会先把空文件建出来，所以不需要 `CREATE`；
 * `TRUNC` 只防"用户选了一个已存在的文件、确认覆盖"。
 * 万一某些设备没预建文件，回退带 `CREATE` 再试一次。
 */
function openDest(destUri: string): number {
  try {
    return fileIo.openSync(destUri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC).fd;
  } catch (error) {
    console.info(`[export] 直接打开目标失败，回退带 CREATE 重试: ${codeOf(error)}`);
    return fileIo.openSync(destUri,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC).fd;
  }
}

/** 写满整个 buffer（`write` 可能短写） */
async function writeAll(fd: number, data: ArrayBuffer): Promise<void> {
  let offset = 0;
  while (offset < data.byteLength) {
    const part = offset === 0 ? data : data.slice(offset);
    const written = await fileIo.write(fd, part);
    if (written <= 0) {
      throw new Error('写入目标文件时返回 0 字节');
    }
    offset += written;
  }
}

/** 严格拷贝 `totalBytes` 字节 —— 不多读也不少读，读到尾就报错（说明源文件被截短了） */
async function copyExact(srcFd: number, destFd: number, totalBytes: number): Promise<void> {
  const chunkBytes = Math.min(EXPORT_CHUNK_BYTES, totalBytes);
  const buffer = new ArrayBuffer(chunkBytes);
  let remaining = totalBytes;
  while (remaining > 0) {
    const want = Math.min(chunkBytes, remaining);
    const read = await fileIo.read(srcFd, buffer, { length: want });
    if (read <= 0) {
      throw new Error(`读取录音文件提前结束，还差 ${remaining} 字节`);
    }
    await writeAll(destFd, read === buffer.byteLength ? buffer : buffer.slice(0, read));
    remaining -= read;
  }
}

function putAscii(view: DataView, offset: number, text: string): void {
  for (let i = 0; i < text.length; i++) {
    view.setUint8(offset + i, text.charCodeAt(i));
  }
}

function closeQuietly(fd: number): void {
  if (fd < 0) {
    return;
  }
  try {
    fileIo.closeSync(fd);
  } catch (error) {
    console.error(`[export] 关闭文件失败: ${codeOf(error)}`);
  }
}

function codeOf(error: Object): string {
  const e = error as BusinessError;
  return e === undefined || e === null ? 'unknown' : `code=${e.code} msg=${e.message}`;
}
