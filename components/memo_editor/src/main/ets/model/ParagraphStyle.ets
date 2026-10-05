/**
 * 段落样式（`RichEditorParagraphStyle`）的读写工具（纯函数）。
 *
 * ==================== 真机实测的三条关键事实（2026-10-05 探针） ====================
 *
 * **① `updateParagraphStyle` 是「整体替换」而非「部分更新」**
 *    写好 `leadingMargin=24` 之后，只要再调一次 `updateParagraphStyle({style:{textAlign}})`，
 *    `leadingMargin` 就变回 `["0.00px","0.00px"]` —— 没传的字段被重置，不是保留。
 *    ⇒ **任何一次写入都必须把要保留的字段一并带上**（本文件 `mergeParagraphStyle` 的职责）。
 *
 * **② `addTextSpan` 的 `paragraphStyle` 不生效**
 *    段首插入一个带 `paragraphStyle:{textAlign:Center, leadingMargin:24}` 的文本 span，
 *    插完段落读回来仍是 `textAlign=0 / leadingMargin=0`。
 *    ⇒ 段落样式**只能**经 `updateParagraphStyle` 改；列表标记那种"插前缀文本"不会扰动所在段落的样式。
 *
 * **③ 回读形态：`getParagraphs()` 有尺寸，`getSpans()` 没有**
 *    `getParagraphs()[i].style.leadingMargin` = `placeholder(size=["24.00vp","0.00vp"])`
 *    `getSpans()[i].paragraphStyle.leadingMargin` = `placeholder(size=undefined)`
 *    ⇒ **读"当前生效的段落样式"必须走 `getParagraphs()`**；span 快照（撤销记录用）里的
 *      `leadingMargin` 是**丢尺寸**的，不能当缩进的来源。
 *
 * 另：从未设置过时回读是 `placeholder(size=["0.00px","0.00px"])` —— 注意单位是 **px**，
 * 而设置过之后回显 **vp**。下面的 `dimensionToVp` 对非 0 的 px 值会拒绝，宁可不动也不能乱改。
 */
import { INDENT_MAX_LEVEL, INDENT_STEP_VP } from '../common/Constants';

/**
 * 归一化后的段落样式 —— **可 JSON 序列化**。
 *
 * 存在的理由：框架回读的 `leadingMargin` 是 `LeadingMarginPlaceholder`（可能含 PixelMap），
 * 直接塞进 KV 有 `JSON.stringify` 抛异常导致整次保存静默失败的风险（见 `Memo.mapTextSpan2Block` 的原注释）。
 * 所以进出持久化 / 历史记录一律用这个"只有两个字段、且都是原始值"的形态。
 */
export interface NormalizedParagraphStyle {
  textAlign?: TextAlign;
  /** 缩进量（vp）。0 表示无缩进，此时**不会**出现该字段 */
  leadingMargin?: number;
}

/**
 * 一段的样式快照（范围 + 样式）—— 撤销/重做与持久化共用。
 *
 * 连范围一起存：样式操作**不改内容**，所以这些范围在整个历史里都保持有效，
 * 还原时不必再去问框架"这些段落现在在哪"。
 */
export interface ParagraphStyleSnapshot {
  start: number;
  end: number;
  style: NormalizedParagraphStyle;
}

/**
 * `position` 落在哪个段落里。
 *
 * 口径与 `getParagraphRange` 一致（**端点归后一段**）：取 `range[0] <= position` 的**最后**一个。
 * 注意段落以行内图片开头时 `getParagraphs()` 报的段首会落在图片【之后】，
 * 但那不影响这个判定 —— 图片之后的文本位置依然满足 `range[0] <= position`。
 */
export function paragraphContaining(
  paragraphs: Array<RichEditorParagraphResult>, position: number): RichEditorParagraphResult | undefined {
  let found: RichEditorParagraphResult | undefined = undefined;
  for (const paragraph of paragraphs) {
    if (paragraph.range[0] <= position) {
      found = paragraph;
    }
  }
  return found;
}

/** `Dimension` → vp 数值。非 0 的 px 值一律拒绝（口径不符，宁可不动） */
function dimensionToVp(value: Dimension | undefined): number | undefined {
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value !== 'string') {
    return undefined;
  }
  const match = value.match(/^(-?\d+(?:\.\d+)?)(px|vp|fp|lpx)?$/);
  if (match === null) {
    return undefined;
  }
  const amount = Number(match[1]);
  if (match[2] === 'px' && amount !== 0) {
    // 未设置时框架报的是 "0.00px"，所以 0 是正常的；出现**非 0 的 px** 说明口径变了
    console.error(`[indent] leadingMargin 回读单位是 px 且非 0（${value}），口径不符，已忽略`);
    return undefined;
  }
  return amount;
}

/**
 * `leadingMargin` → vp 数值。
 *
 * 三种形态都要认：
 *   - `number`（我们自己写进去的）
 *   - `string`（`"24vp"`）
 *   - `LeadingMarginPlaceholder`（**框架回读的形态**；`getSpans()` 那份 `size` 为 undefined ⇒ 返回 undefined）
 *
 * 带 `pixelMap` 的 placeholder 直接拒绝 —— 那是图片占位，不是缩进，且不可序列化。
 */
export function leadingMarginOf(value: Dimension | LeadingMarginPlaceholder | undefined): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value === 'number' || typeof value === 'string') {
    return dimensionToVp(value);
  }
  const placeholder = value as LeadingMarginPlaceholder;
  if (placeholder.pixelMap !== undefined) {
    return undefined;
  }
  if (placeholder.size === undefined) {
    // getSpans() 报的就是这种：尺寸丢失，拿不到缩进量
    return undefined;
  }
  return dimensionToVp(placeholder.size[0]);
}

/**
 * 这一段的对齐是不是 `Start`。
 *
 * 【为什么需要】产品要求：**只有对齐为 Start 的段落才允许调整缩进** ——
 * 居中 / 右对齐下再叠加左缩进，视觉上像是排版坏了。反过来，改对齐时会清掉缩进
 *（见控制器的 `setParagraphAlign`），两者共同保证"一段要么居左带缩进、要么居中/右对齐不带缩进"。
 *
 * 框架回读的 `textAlign` 实测总是有值（Start 报 0）；缺省时按默认值 Start 处理。
 */
export function isStartAligned(style: RichEditorParagraphStyle | undefined): boolean {
  return style?.textAlign === undefined || style.textAlign === TextAlign.Start;
}

/** 段落样式的缩进级数（0 = 无缩进），已按 `INDENT_MAX_LEVEL` 封顶 */
export function indentLevelOf(style: RichEditorParagraphStyle | undefined): number {
  const leadingMargin = leadingMarginOf(style?.leadingMargin);
  if (leadingMargin === undefined || leadingMargin <= 0) {
    return 0;
  }
  return Math.min(INDENT_MAX_LEVEL, Math.round(leadingMargin / INDENT_STEP_VP));
}

/** 缩进级数 → vp 数值 */
export function indentMarginFor(level: number): number {
  return Math.max(0, Math.min(INDENT_MAX_LEVEL, level)) * INDENT_STEP_VP;
}

/**
 * 把「当前样式」与「本次要改的字段」合并成一份**完整**样式。
 *
 * 【为什么必须有这一步】见文件头事实①：整体替换语义下，漏传的字段会被重置。
 * 于是"点对齐按钮"会抹掉缩进、"点缩进"会抹掉对齐 —— 两个按钮互相拆台。
 *
 * ⚠️ **只搬 `textAlign` 与 `leadingMargin` 两个字段，绝不整体展开 `current`**：
 * `current` 是框架回读的对象，可能带着含 PixelMap 的 `LeadingMarginPlaceholder`；
 * 原样回写既无意义（我们从不改它），又有把不可序列化对象带上链路的危险。
 */
export function mergeParagraphStyle(
  current: RichEditorParagraphStyle | undefined,
  input: RichEditorParagraphStyle
): RichEditorParagraphStyle {
  const merged: RichEditorParagraphStyle = {};
  const textAlign = input.textAlign ?? current?.textAlign;
  if (textAlign !== undefined) {
    merged.textAlign = textAlign;
  }
  const leadingMargin = leadingMarginOf(input.leadingMargin) ?? leadingMarginOf(current?.leadingMargin);
  if (leadingMargin !== undefined) {
    merged.leadingMargin = leadingMargin;
  }
  return merged;
}

/** 段落样式 → 可序列化的归一化形态（0 缩进不产出字段） */
export function normalizeParagraphStyle(
  style: RichEditorParagraphStyle | undefined
): NormalizedParagraphStyle {
  const result: NormalizedParagraphStyle = {};
  if (style === undefined) {
    return result;
  }
  if (style.textAlign !== undefined) {
    result.textAlign = style.textAlign;
  }
  const leadingMargin = leadingMarginOf(style.leadingMargin);
  if (leadingMargin !== undefined && leadingMargin !== 0) {
    result.leadingMargin = leadingMargin;
  }
  return result;
}
