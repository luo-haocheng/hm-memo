// 圆环
export const RING_UTF8 = '\u25EF';

// 勾号
export const CHECK_MARK_UTF8 = '\u2713';

// 默认字体大小
export const DEFAULT_FONT_SIZE = 14;

/**
 * 手写画布自带工具栏的高度（vp）。
 */
export const HANDWRITE_TOOLBAR_HEIGHT = 108;

/**
 * 工具栏**投影**向上溢出到画布区的高度（vp）。
 * 键盘模式裁剪时，要在工具栏高度之外**再往上让出这么多**，否则投影的上半截会留在画布区里。
 */
export const HANDWRITE_CLIP_MARGIN = 24;

/**
 * 录音采样率（Hz）。
 * 16k 对人声足够，buffer 更小 —— 音量只要能量、不需要宽频。
 */
export const RECORD_SAMPLE_RATE = 16000;

/** 单声道 S16LE → 每帧 2 字节 */
export const RECORD_BYTES_PER_FRAME = 2;

/**
 * 音量计算与上报的最小间隔（毫秒）。
 * 单个 buffer（实测 640 字节 = 20ms）的 RMS 抖动大，攒够一个窗口再算才不闪。
 */
export const RECORD_LEVEL_WINDOW_MS = 100;

/**
 * 音量归一化的下限（dB）：低于它视为静音。
 * 人声的 RMS 线性值通常只有 0.02~0.2，直接当 0~1 会"永远贴地"，所以走 dB 映射。
 */
export const RECORD_LEVEL_FLOOR_DB = 50;

/** 显示衰减系数：下降沿每拍乘它，上升沿瞬时跟随（峰值保持） */
export const RECORD_LEVEL_DECAY = 0.75;

/**
 * `stop()` 后等待读循环收敛的上限（毫秒）。
 *
 * 【为什么是 1200】真机实测：`stop()` 本身 39ms 就返回，但**挂在 native 上的那个阻塞
 * read 要约 1000ms 才以 `6800301` reject**。所以要等它自然退出再 release，
 * 留 1200ms 让正常路径走完；只有它真卡住时才落到超时兜底。
 */
export const RECORD_STOP_JOIN_TIMEOUT_MS = 1200;

/** 波形柱子数量。与 RECORD_LEVEL_WINDOW_MS 一起决定历史窗口长度（32 × 100ms ≈ 3.2s） */
export const RECORD_BAR_COUNT = 50;

/** 波形柱的最小高度（vp）—— 静音时也留一条细线，不然看起来像坏了 */
export const RECORD_BAR_MIN_HEIGHT = 2;

/** 波形柱的最大高度（vp）。柱子**以中线为轴对称**，所以这是总高的一半 */
export const RECORD_BAR_MAX_HEIGHT = 20;

// 调色盘选项
export const COLOR_LIST: ResourceColor[] =
  [$r('sys.color.font_primary'), '#FFFFF200', '#FFFF7F27', '#FFED1C24', '#FFA349A4', '#FF00A2E8', '#FF22B14C'];
