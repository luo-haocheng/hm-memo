/**
 * 列表标记与「编辑器坐标字符表」工具（纯函数）。
 *
 * 【为什么列表要用文本前缀模拟】RichEditor **没有原生列表 API** —— 段落样式只有
 * `textAlign` / `leadingMargin` / `wordBreak`（真机探针也确认了这一点）。所以列表标记
 * 只能是**真实文本**。好处是：内容变更 ⇒ `onWillChange` 自动进历史、`updateContent`
 * 自动落盘，撤销与持久化都不用额外做。
 *
 * 【为什么要有"坐标字符表"】编辑器坐标把图片 / chip 各算 **1 格**，而 `toStyledString()`
 * 得到的纯文本里它们不占字符 —— 一旦正文含图，直接拿字符串下标当编辑器坐标就会错位。
 * 所以统一建一张"坐标 → 字符"表，非文本 span 一律用哨兵占位，之后全是纯字符串操作。
 * 前提与前人一致：文本 span 内「编辑器偏移 − spanRange[0]」就是字符串下标（见 SpanMapping.clipSpans）。
 */
import { isTextLikeSpan } from './SpanMapping';

/** 四种列表 */
export type ListKind = 'ordered-number' | 'ordered-letter' | 'unordered-bullet' | 'unordered-square';

/** 无序列表的两种记号（都是单 BMP 单元，在坐标表里恰好占 1 格） */
export const LIST_BULLET = '●';   // ●
export const LIST_SQUARE = '■';   // ■

/**
 * 两类列表前缀两侧的空白。**两类的结构是刻意对齐的**：
 * 都是「一个前导空格 + 记号 + 若干尾随空格」，于是记号与正文各占一列，两排看起来对齐。
 *
 * 【为什么带前导空格】待办勾选框是 image span（宽 `BUILTIN_IMAGE_SIZE` + 右边距），
 * 占掉的横向空间远大于一个字符。加前导空格把记号往右推一点，
 * 让列表与待办列表的**正文起点接近同一列**。
 *
 * 【为什么带尾随空格】记号之后让出一段距离，正文才不至于贴住记号。
 *
 * ⚠️ **这是近似而非精确对齐**：空格是**比例宽度**，而且整段前缀属于
 * `UNORDERED_MARKER_FONT_SIZE` / `ORDERED_MARKER_FONT_SIZE` 那个 span，宽度随字体度量而变。
 * 真机上若对不齐，调这几个常量即可，**别改判定逻辑**。
 *
 * ⚠️ **空白是判定的一部分**：`markerOf` 精确匹配这串前缀，
 * 用户在记号前后多打 / 少打一个空格，这一段就不再被认作列表。
 */
const UNORDERED_LEADING_SPACE = ' ';
const UNORDERED_TRAILING_SPACES = '    ';
const ORDERED_LEADING_SPACE = ' ';
const ORDERED_TRAILING_SPACES = '   ';

/**
 * 非文本 span 在坐标表里的哨兵，占 1 格。
 *
 * 用 U+FFFC（OBJECT REPLACEMENT CHARACTER）是惯例：它本身就是"这里有个对象"的语义，
 * 且永远不可能出现在用户正文里，不会与真实字符混淆。
 */
export const NON_TEXT_SENTINEL = '￼';

/** 命中一条列表标记的结果 */
export interface ListMarkerHit {
  kind: ListKind;
  /** 标记的完整文本（含尾随空格） */
  text: string;
  /** 有序列表的序号；无序列表为 undefined */
  ordinal?: number;
}

const BULLET_PREFIX = `${UNORDERED_LEADING_SPACE}${LIST_BULLET}${UNORDERED_TRAILING_SPACES}`;
const SQUARE_PREFIX = `${UNORDERED_LEADING_SPACE}${LIST_SQUARE}${UNORDERED_TRAILING_SPACES}`;

/**
 * 旧版有序列表前缀：`"1. "` —— **不带前导空格、只有一个尾随空格**。
 *
 * 改成带空白的对齐格式之前插进正文的记号就是它。保留这一条是为了
 * **已经存下来的备忘不突然变成普通文本** —— 判定认两种，但**插入只写新格式**。
 * 等旧数据都清掉之后，这里连同 `markerOf` 里的兜底分支可以一起删。
 */
const LEGACY_ORDERED_NUMBER_RE = /^(\d+)\. /;
const LEGACY_ORDERED_LETTER_RE = /^([a-z]+)\. /;

/**
 * 解析**新版**有序列表记号：`" 12.   "` / `" ab.   "`。
 *
 * 【为什么用字符串切分而不是正则】空白数量来自上面几个常量；
 * 把数量写死在正则字面量里，改常量时正则不会跟着变，**判定与插入就会脱节**。
 */
function orderedMarkerOf(line: string): ListMarkerHit | undefined {
  if (!line.startsWith(ORDERED_LEADING_SPACE)) {
    return undefined;
  }
  const body = line.substring(ORDERED_LEADING_SPACE.length);
  const tail = `.${ORDERED_TRAILING_SPACES}`;
  // 取**第一个** tail —— 记号永远在行首，所以它就是记号自己的那个
  const dotIndex = body.indexOf(tail);
  if (dotIndex <= 0) {
    return undefined;
  }
  const core = body.substring(0, dotIndex);
  const text = line.substring(0, ORDERED_LEADING_SPACE.length + dotIndex + tail.length);
  if (/^\d+$/.test(core)) {
    return { kind: 'ordered-number', text: text, ordinal: Number(core) };
  }
  if (/^[a-z]+$/.test(core)) {
    return { kind: 'ordered-letter', text: text, ordinal: lettersToNum(core) };
  }
  return undefined;
}

/**
 * 行首是不是一条列表标记。
 *
 * ⚠️ **不做"?跳过段首图片"的兜底**：调用方（`applyList` / `continueListParagraph`）在段落
 * 首格是图片时一律提前返回 —— 段首标记槽是**单占**的（待办优先），所以走到这里时
 * 行首必定是文本。若将来取消那道守卫，这里必须跟着改，否则会读出错误的标记位置。
 */
export function markerOf(line: string): ListMarkerHit | undefined {
  if (line.startsWith(BULLET_PREFIX)) {
    return { kind: 'unordered-bullet', text: BULLET_PREFIX };
  }
  if (line.startsWith(SQUARE_PREFIX)) {
    return { kind: 'unordered-square', text: SQUARE_PREFIX };
  }
  const ordered = orderedMarkerOf(line);
  if (ordered !== undefined) {
    return ordered;
  }
  // 旧格式兜底（见 LEGACY_ORDERED_NUMBER_RE 的注释，旧数据清完可删）
  const legacyNumber = line.match(LEGACY_ORDERED_NUMBER_RE);
  if (legacyNumber !== null) {
    return { kind: 'ordered-number', text: legacyNumber[0], ordinal: Number(legacyNumber[1]) };
  }
  const legacyLetter = line.match(LEGACY_ORDERED_LETTER_RE);
  if (legacyLetter !== null) {
    return { kind: 'ordered-letter', text: legacyLetter[0], ordinal: lettersToNum(legacyLetter[1]) };
  }
  return undefined;
}

/** 这个种类是不是有序列表 */
export function isOrdered(kind: ListKind): boolean {
  return kind === 'ordered-number' || kind === 'ordered-letter';
}

/**
 * 生成第 n 项（n 从 1 开始）的标记文本。
 *
 * 无序列表忽略 n —— 两种记号本身不带序号。
 * 有序列表两侧的空白与无序列表**结构一致**（前导 1 空格 + 尾随若干空格），
 * 这样两排的记号与正文各占一列。
 */
export function markerText(kind: ListKind, n: number): string {
  switch (kind) {
    case 'ordered-number':
      return `${ORDERED_LEADING_SPACE}${n}.${ORDERED_TRAILING_SPACES}`;
    case 'ordered-letter':
      return `${ORDERED_LEADING_SPACE}${numToLetters(n)}.${ORDERED_TRAILING_SPACES}`;
    case 'unordered-bullet':
      return BULLET_PREFIX;
    case 'unordered-square':
      return SQUARE_PREFIX;
    default:
      return BULLET_PREFIX;
  }
}

/**
 * 字母序号 → 数字：a=1, z=26, aa=27, ab=28 …
 *
 * bijective base-26（每一位是 1..26 而不是 0..25），与 Excel 列名同一套。
 */
export function lettersToNum(letters: string): number {
  let value = 0;
  for (let i = 0; i < letters.length; i++) {
    value = value * 26 + (letters.charCodeAt(i) - 96);
  }
  return value;
}

/** 数字 → 字母序号，`lettersToNum` 的逆；n < 1 时返回 'a' 兜底 */
export function numToLetters(n: number): string {
  let value = Math.floor(n);
  if (value < 1) {
    return 'a';
  }
  let result = '';
  while (value > 0) {
    const remainder = (value - 1) % 26;
    result = String.fromCharCode(97 + remainder) + result;
    value = Math.floor((value - 1) / 26);
  }
  return result;
}

/**
 * 建"坐标 → 字符"表：`chars[i]` 是编辑器坐标 i 处的单个字符；
 * 非文本 span（图片 / chip / 认不出的 span）一律填哨兵，各占 1 格。
 *
 * 一次 O(文档长) 的 `getSpans()`，列表操作（回车续接、判定标记）调用方各自建一次即可。
 */
export function buildCharMap(spans: Array<RichEditorSpan>): string[] {
  const chars: string[] = [];
  for (const span of spans) {
    const range = span.spanPosition.spanRange;
    if (!isTextLikeSpan(span)) {
      // 图片 / chip / 未知 span：占 1 格哨兵
      chars[range[0]] = NON_TEXT_SENTINEL;
      continue;
    }
    const textSpan = span as RichEditorTextSpanResult;
    const value = textSpan.value;
    for (let k = 0; k < value.length; k++) {
      chars[range[0] + k] = value[k];
    }
  }
  return chars;
}

/**
 * 只读 [start, end) 这一段的文本（`buildCharMap` 的有界版本）。
 *
 * 【为什么要这个】`buildCharMap` 需要一次**全量** `getSpans()`，而"回车续接列表"是
 * **每次回车**都会走的路径 —— 在那条热路径上读整篇文档代价太大。调用方只要本段落的文本时用这个。
 *
 * 返回串与 [start, end) 的坐标**一一对应**：非文本 span 占一个哨兵格，
 * span 之间若有空隙（理论上不该有）也补哨兵，保证下标不漂移。
 */
export function textInRange(spans: Array<RichEditorSpan>, start: number, end: number): string {
  const ordered: Array<RichEditorSpan> = spans.slice();
  ordered.sort((a, b) => a.spanPosition.spanRange[0] - b.spanPosition.spanRange[0]);
  let text = '';
  for (const span of ordered) {
    const range = span.spanPosition.spanRange;
    const from = Math.max(start, range[0]);
    const to = Math.min(end, range[1]);
    if (to <= from) {
      continue;
    }
    // 补齐区间内、位于 from 之前还没产出过的坐标（非文本 span 只占 1 格时靠这里对齐）
    while (start + text.length < from) {
      text += NON_TEXT_SENTINEL;
    }
    if (!isTextLikeSpan(span)) {
      text += NON_TEXT_SENTINEL;
      continue;
    }
    const value = (span as RichEditorTextSpanResult).value;
    text += value.substring(from - range[0], to - range[0]);
  }
  return text;
}

/**
 * 从 `start` 起、到下一个换行（不含）为止的行文本。
 *
 * 换行符本身会被停下 —— 列表标记是**段落级**的，跨段落没有意义。
 */
export function lineTextAt(chars: string[], start: number): string {
  let text = '';
  for (let i = start; i < chars.length; i++) {
    const char = chars[i];
    if (char === undefined || char === '\n') {
      break;
    }
    text += char;
  }
  return text;
}

/**
 * `start` 所在行的**起点**坐标（即它前面那个换行之后的位置）。
 *
 * 段首位置在正文里就是"\n 之后"，但段落以行内图开头时 `getParagraphs()` 报的段首
 * 会落在图片【之后】（见 `paragraphStartAt` 的注释）—— 所以本函数只用于"顺坐标表往回找行首"
 * 这种纯文本场景，不替代 `paragraphStartAt`。
 */
export function lineStartOf(chars: string[], position: number): number {
  let i = position - 1;
  while (i >= 0) {
    const char = chars[i];
    if (char === undefined || char === '\n') {
      return i + 1;
    }
    i--;
  }
  return 0;
}

/**
 * `start` 上一行的文本；`start` 就是文档开头（没有上一行）时返回 undefined。
 *
 * 约定 `start` 是**行首**（它前一格是换行，或它是文档开头）—— 调用方传的都是段落起点。
 * 上一行以 `start - 1` 结尾，所以从 `start - 1` 往回找它的行首。
 *
 * ⚠️ **不要写成 `start - 2`**：那样在上一行是**空行**时会跳过它、读到再上面一行，
 * 与 `continueListParagraph`（看紧邻上一段）对不上 —— 同一个位置，"点工具栏"与"按回车"
 * 会给出不同的编号。
 */
export function previousLineText(chars: string[], start: number): string | undefined {
  if (start <= 0) {
    return undefined;
  }
  return lineTextAt(chars, lineStartOf(chars, start - 1));
}
