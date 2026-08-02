// 圆环
export const RING_UTF8 = '\u25EF';

// 勾号
export const CHECK_MARK_UTF8 = '\u2713';

// 默认行高
export const DEFAULT_LINE_HEIGHT = 24;

// 原色滤镜
export const ORIGIN_COLOR_FILTER: ColorFilter = [
  1, 0, 0, 0, 0,
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 1, 0
];

// 高亮颜色滤镜
export const HIGHLIGHT_COLOR_FILTER: ColorFilter = [
  0, 0, 0, 0, 1,
  0, 0, 0, 0, 0.5,
  0, 0, 0, 0, 0,
  0, 0, 0, 1, 0
];

// 调色盘选项
export const COLOR_LIST: ResourceColor[] =
  ['#E5000000', '#FF774342', '#FFFFF200', '#FFFF7F27', '#FFED1C24',
    '#FFEF88BE', '#FFA349A4', '#FF00A2E8', '#FF22B14C', '#FF888888'];