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

// 调色盘选项
export const COLOR_LIST: ResourceColor[] =
  [$r('sys.color.font_primary'), '#FFFFF200', '#FFFF7F27', '#FFED1C24', '#FFA349A4', '#FF00A2E8', '#FF22B14C'];
