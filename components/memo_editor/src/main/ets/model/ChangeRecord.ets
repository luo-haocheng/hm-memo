import { image } from '@kit.ImageKit';

/**
 * 一个 span 的轻量快照（已经裁剪到变更区间内）
 *
 * 文本块用 value 存内容；图片块用 image* 字段。
 * P1 阶段不产生图片快照（遇到含图的变更会清空历史），字段先留着供 P3 使用。
 */
export interface SpanSnapshot {
  kind: 'text' | 'image';
  /** 文本内容；图片块为空 */
  value: string;
  /** 占用的坐标单位数（spanRange[1] - spanRange[0]），插入时用它推进游标 */
  length: number;
  textStyle?: RichEditorTextStyle;
  paragraphStyle?: RichEditorParagraphStyle;
  /** 图片：文件图（相册照片） */
  imagePixelMap?: image.PixelMap;
  /** 图片：内置 / 资源图 */
  imageResource?: ResourceStr;
}

/**
 * 一条变更记录 —— 撤销 / 重做的历史单元
 *
 * 采用增量式：不存"文档长什么样"，只存"这次改了什么、怎么撤销它"。
 *
 * 两侧都存**完整的 span**（不做区间裁剪）：
 *   - 变更前：`getSpans()` 在变更位置拿到的整 span（实测空区间也能拿到所在 span）
 *   - 变更后：`onWillChange` 的 `replacedSpans` / `replacedImageSpans`
 *
 * 撤销 = 删掉「变更后」那侧的整个范围 + 把「变更前」那侧插回去；重做反之。
 * 代价是重写粒度较粗（撤销一个字符可能重写整个 span），换来的是不需要 `onDidChange`
 * 的 rangeAfter，捕获可以全部在一个回调里完成。
 *
 * 纯数据类，**不要加 @ObservedV2** —— 避免大对象被 V2 观察机制包裹。
 */
/**
 * 记录类型：
 * - `content`   内容增删，撤销 = 删掉对侧范围 + 插回本侧内容
 * - `textStyle` 字符样式（粗体 / 斜体 / 下划线 / 字号 / 颜色），撤销 = 把逐段旧样式应用回原范围
 * - `paragraph` 段落对齐，撤销 = 把逐段旧对齐应用回原范围
 *
 * 后两者**不碰内容** —— 段落样式是段落级属性，用"删了重插"会拆开 / 合并段落。
 * 框架不会通知程序化的样式变更（实测 `updateSpanStyle` / `updateParagraphStyle` 不触发内容回调），
 * 所以这两类必须在 `updateTextStyle` / `updateParagraphStyle` 里显式记录。
 */
export type ChangeKind = 'content' | 'textStyle' | 'paragraph';

export class ChangeRecord {
  /** 记录类型，默认是内容增删 */
  kind: ChangeKind = 'content';
  /** 变更发生的位置：撤销后光标落在这里 */
  changeStart: number = 0;
  /** 变更前的那一侧：起点 + 完整内容（可能跨越多个 span） */
  beforeStart: number = 0;
  beforeSpans: Array<SpanSnapshot> = [];
  /** 变更后的那一侧：起点 + 完整内容 */
  afterStart: number = 0;
  afterSpans: Array<SpanSnapshot> = [];
  /** 重做后光标落点（估算为变更结束处） */
  caretAfter: number = 0;

  // ==== 样式类记录专用 ====
  // 应用范围 = [beforeStart, beforeStart + beforeSpans 的总长度)，与内容类复用同一组起点字段；
  // beforeSpans 里逐段带着各自的 textStyle / paragraphStyle，那就是"旧样式"

  /** `textStyle` 类：重做时要重新应用的样式（就是 updateTextStyle 收到的那个） */
  afterTextStyle?: RichEditorTextStyle;
  /** `paragraph` 类：重做时要重新应用的对齐方式 */
  afterAlign?: TextAlign;
}
