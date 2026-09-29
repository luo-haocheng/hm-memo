import { AlignmentInfo } from '../model/AlignmentInfo';
import { FileChipInfo } from '../model/FileChipInfo';
import {
  ATTACHMENT_DIR_NAME,
  builtinImageNameOf,
  builtinImageResource,
  builtinImageStyle,
  calcDesiredSize,
  doneTextColor,
  isBuilderSpan,
  MemoBlock,
  mimeOfFileName,
  TODO_MARK_DONE,
  TODO_MARK_OPEN,
  toggledTodoMark
} from '../model/Memo';
import { util } from '@kit.ArkTS';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { ChangeRecord, SpanSnapshot } from '../model/ChangeRecord';
import { clipSpans, isTextLikeSpan, spansTotalLength, textStyleResult2Style, toSnapshots } from '../model/SpanMapping';
import { display } from '@kit.ArkUI';
import { COLOR_LIST, DEFAULT_FONT_SIZE } from '../common/Constants';
import { HandwriteController } from '@kit.Penkit';

// 相册照片的固定样式参数（插入与撤销/重做共用，改这里两边一起生效）
const FILE_IMAGE_BORDER_RADIUS = 12;
const FILE_IMAGE_VERTICAL_MARGIN = 12;

// 连续同类编辑动作合并成一条历史的时间窗（毫秒）。超过则视为两次独立操作
const MERGE_WINDOW_MS = 500;
// 历史上限：超出后从最早的记录开始丢弃
const MAX_HISTORY_RECORDS = 100;

// 点击待办勾选框后，等光标落定的超时兜底时长（毫秒）。
// 实测落定事件在点击回调之后约 1ms 就到，200ms 是给慢设备留的余量；
// 这个值只在"框架根本不会发落定事件"时才用得上，宁长勿短
const TODO_TAP_SETTLE_MS = 200;

/**
 * 插入类记录：框架给了"变更后"的新内容。
 *
 * 注意**不能**用 "beforeSpans 为空" 来判定纯插入 —— 我们的记录存的是「变更位置所在的整个 span」，
 * 所以连续输入时第二条记录的 beforeSpans 里是上一条的内容（输入 b 时 before=["a"]），并不为空。
 * `afterSpans` 是否为空恰好对应捕获时的两个分支，用它更准确。
 */
function isInsertRecord(record: ChangeRecord): boolean {
  return record.afterSpans.length > 0;
}

/** 删除类记录：纯删除分支 —— 框架不给新侧，所以 after 为空 */
function isDeleteRecord(record: ChangeRecord): boolean {
  return record.afterSpans.length === 0 && record.beforeSpans.length > 0;
}

/** 两侧都只含文本（不含图片）—— 含图的记录不参与合并 */
function isTextOnly(record: ChangeRecord): boolean {
  return record.beforeSpans.every((span) => span.kind === 'text')
    && record.afterSpans.every((span) => span.kind === 'text');
}

/**
 * 取「变更点处」生效的文本样式。
 *
 * 为什么不能直接用 `replacedSpans` 自带的样式：实测它对同一段文字报的 `fontSize` 与
 * `getSpans()` 不一致（16 vs 14，差的是系统字体缩放）。`getSpans()` 报的是**实际生效**的值，
 * 而 `replacedSpans` 报的是写入前的原始值 —— 直接拿来插入会把文字放大。
 *
 * 新输入 / 粘贴的文字本来用的就是变更点处的输入样式，所以这里取旧 span 的样式即可。
 */
function styleAt(spans: Array<RichEditorSpan>, position: number): RichEditorTextStyle | undefined {
  let style: RichEditorTextStyle | undefined = undefined;
  for (const span of spans) {
    if (span.spanPosition.spanRange[0] > position) {
      continue;
    }
    // 图片与未知类型都不带文本样式，跳过（见 isTextLikeSpan）
    if (isTextLikeSpan(span)) {
      style = textStyleResult2Style((span as RichEditorTextSpanResult).textStyle);
    }
  }
  return style;
}

/** 一批 span 里最小的起点 */
function minSpanStart(spans: Array<RichEditorSpan>): number {
  let min = spans[0].spanPosition.spanRange[0];
  for (const span of spans) {
    const spanStart = span.spanPosition.spanRange[0];
    if (spanStart < min) {
      min = spanStart;
    }
  }
  return min;
}

/**
 * 取快照列表的前 length 个坐标单位（必要时在 span 中间切开）。
 * 用于原子操作合并时保留栈顶记录的前导部分。
 */
function takePrefix(spans: Array<SpanSnapshot>, length: number): Array<SpanSnapshot> {
  const result: Array<SpanSnapshot> = [];
  let remaining = length;
  for (const span of spans) {
    if (remaining <= 0) {
      break;
    }
    if (span.length <= remaining) {
      result.push(span);
      remaining -= span.length;
    } else {
      // 中途截断：只可能是文本（图片是 1 个单位的原子块）
      result.push({
        kind: 'text',
        value: span.value.substring(0, remaining),
        length: remaining,
        textStyle: span.textStyle,
        paragraphStyle: span.paragraphStyle,
      });
      remaining = 0;
    }
  }
  return result;
}

/**
 * neighborAt 的返回值 —— 编辑器坐标某处的单元类型
 * - `'newline'`  换行符
 * - `'other'`    其它内容（普通字符，或图片这类原子单元）
 * - `'boundary'` 文档边界之外
 */
type NeighborKind = 'newline' | 'other' | 'boundary';

/**
 * 判定编辑器坐标 pos 处是什么单元。
 *
 * 必须拿 spanRange（**编辑器坐标**）反查，不能拿 toStyledString 的纯文本下标去比 ——
 * 图片在纯文本里占几个字符没有定义，文档里一旦有图片，两套坐标就错位。
 *
 * `'boundary'` 这一态不能省：文档为空、或光标在文末时，"该位置什么都没有"与
 * "该位置是图片"是两回事，混作一谈会平白多补一个换行。
 */
function neighborAt(spans: Array<RichEditorSpan>, pos: number): NeighborKind {
  if (pos < 0) {
    return 'boundary';
  }
  for (const span of spans) {
    const range = span.spanPosition.spanRange;
    if (pos < range[0] || pos >= range[1]) {
      continue;
    }
    if ((span as RichEditorImageSpanResult).imageStyle !== undefined) {
      return 'other'; // 图片是原子单元，永远不是换行
    }
    if (!isTextLikeSpan(span)) {
      return 'other'; // 未知类型同样按原子单元处理（见 isTextLikeSpan）；此处每次按键都会走到，不能崩
    }
    // 用 charAt 而不是下标取值：越界时返回空串，与 '\n' 比较自然是 'other'，无需额外判界
    return (span as RichEditorTextSpanResult).value.charAt(pos - range[0]) === '\n' ? 'newline' : 'other';
  }
  return 'boundary'; // 没有 span 覆盖 → 文档边界之外
}

/** 取覆盖编辑器坐标 pos 的文本 span；该位置是图片或越界时返回 undefined */
function textSpanAt(spans: Array<RichEditorSpan>, pos: number): RichEditorTextSpanResult | undefined {
  if (pos < 0) {
    return undefined;
  }
  for (const span of spans) {
    const range = span.spanPosition.spanRange;
    if (pos < range[0] || pos >= range[1]) {
      continue;
    }
    if (!isTextLikeSpan(span)) {
      return undefined; // 图片与未知类型都不是文本 span（见 isTextLikeSpan）
    }
    return span as RichEditorTextSpanResult;
  }
  return undefined;
}

/**
 * 是不是「相册图片」—— 与 mapImageSpan2Block 同一口径：
 * 内置图走 valueResourceStr，相册图走 valuePixelMap。
 *
 * ⚠️ 剪贴板粘贴进来的图片同样是 pixelMap，在编辑器里与相册图**区分不开**，
 * 所以它也会被一并纳入「单独成段」的维护范围。
 */
function isAlbumPhoto(span: RichEditorSpan): boolean {
  const imageSpan = span as RichEditorImageSpanResult;
  return imageSpan.imageStyle !== undefined
    && !imageSpan.valueResourceStr
    && imageSpan.valuePixelMap !== undefined;
}

/**
 * 一处待补的段落分隔：在 offset 处插一个换行，让相册图片重新独占一段。
 * 样式取自紧邻的文本 span（见 buildParagraphFix）
 */
interface ParagraphFix {
  offset: number;
  style: RichEditorTextStyle;
  paragraphStyle?: RichEditorParagraphStyle;
}

/** 命中的待办勾选框：位置 + 当前名称（名称决定切换成哪一张图） */
interface TodoMarkHit {
  offset: number;
  name: string;
}

/**
 * 附件侧表的一项：文档中的一个 chip。
 *
 * 【为什么必须自己维护】实测（见 FILE_ATTACHMENT_REVIEW.md §一）：框架**会**把 builder span
 * 经由 `getSpans()` 返回（伪装成 image span），所以**位置**能直接读出来；
 * 但它的 `valueResourceStr` 只是个占位空格，**没有任何文件名信息** ——
 * 「这一格是哪个文件」只能由这张侧表记住。
 */
interface AttachmentEntry {
  /** 编辑器坐标。增量维护（见 trackAttachmentDelete / trackAttachmentShift），保存前还会重新对齐 */
  offset: number;

  /** 相对 memo_files 的路径 `<uuid>/<原文件名>` —— 持久化进 MemoBlock.value 的就是它 */
  relativePath: string;
}

/**
 * 这批新内容是不是"恰好一个换行" —— 也就是用户按了回车。
 *
 * 换行在编辑器里**永远单独成 span**（见 SPAN_EDITOR_REVIEW §二），所以这里能精确认出来。
 * 靠这个判定把它和"粘贴整段文本"区分开：粘贴是多 span，不会被当成回车。
 */
function isSingleNewline(spans: Array<RichEditorSpan>): boolean {
  if (spans.length !== 1) {
    return false;
  }
  const textSpan = spans[0] as RichEditorTextSpanResult;
  return textSpan.textStyle !== undefined && textSpan.value === '\n';
}

/**
 * 新内容里是否含换行符或图片。
 *
 * 这两类在框架里永远**单独成 span**（实测："换行会切开 span"；图片占 1 个坐标单位、与文本无缝拼接），
 * 所以它们出现在 onWillChange 的新侧时，变更点右侧那段没动过的文字一定没被带进来 ——
 * 而普通文字输入会并进所在的 span，返回的是完整的整段。
 * 这个差别是判断"要不要补尾部"的依据之一（见 onWillChange 里尾部对齐那段）。
 */
function hasSpanBreakingContent(spans: Array<RichEditorSpan>): boolean {
  for (const span of spans) {
    if ((span as RichEditorImageSpanResult).imageStyle !== undefined) {
      return true;
    }
    if (!isTextLikeSpan(span)) {
      return true; // 未知类型一律视为"会切开 span"——它必然是原子单元、不与文本合并，与图片同理
    }
    if ((span as RichEditorTextSpanResult).value.indexOf('\n') >= 0) {
      return true;
    }
  }
  return false;
}

// MIME 的本地表与 mimeOfFileName 已移到 model/Memo.ets —— 插入与重建两条路径都要用
//（重建时由存下来的相对路径重新推导 MIME，所以不需要单独持久化它）

/** 拿不到原文件名时给附件的兜底名（不能为空 —— 它会当作沙箱路径的末段） */
const DEFAULT_ATTACHMENT_NAME = 'attachment';

@ObservedV2
export class MemoEditorController {
  private static _instance: MemoEditorController;

  public static get instance() {
    if (!MemoEditorController._instance) {
      MemoEditorController._instance = new MemoEditorController();
    }
    return MemoEditorController._instance;
  }

  titleController: TextInputController = new TextInputController();
  contentController: RichEditorController = new RichEditorController();
  handwriteController: HandwriteController = new HandwriteController();
  // 当前文本颜色
  @Trace colorIdx: number = 0;
  // 当前文本是否加粗
  @Trace isBold: boolean = false;
  // 当前文本是否斜体
  @Trace isItalics: boolean = false;
  // 当前文本是否下划线
  @Trace isUnderline: boolean = false;
  // 是否手写输入
  @Trace isHandWrite: boolean = false;
  // 当前字体大小
  @Trace fontSize: number = DEFAULT_FONT_SIZE;
  // 当前段落对齐样式
  @Trace alignStyle: TextAlign = TextAlign.Start;
  // 指向当前生效的历史记录下标。0 是"初始基线"，不可撤销回去
  @Trace currRecordIdx: number = -1;
  // 历史长度：单独暴露给 UI，驱动重做按钮的灰显
  @Trace historyLength: number = 0;
  // 用户操作记录历史。非 @Trace —— 避免大对象被 V2 观察机制包裹，UI 只看下标与长度
  private historyRecords: Array<ChangeRecord> = [];
  // 正在执行撤销 / 重做：程序化调用会【同步】触发内容变更回调，期间必须忽略它们
  private isRestoring: boolean = false;
  // 正在补「图片单独成段」的换行：补换行本身会同步触发一轮 willChange / didChange，用它防递归
  private isRepairing: boolean = false;
  // 勾选框被点中、但光标还没落定：等落定信号再判（见 onTodoMarkTap）
  private pendingTodoTap: boolean = false;
  // 点击勾选框那一刻的光标位置，供超时兜底判断"光标到底动没动"
  private pendingTapCaret: number = -1;
  // 本次变更是不是"回车新建了一段"（值为换行的插入点）；-1 表示不是。
  // 在 onWillChange 里判定、onDidChange 里消费，用完即清
  private pendingEnterOffset: number = -1;
  // 原子区间嵌套深度：大于 0 时，期间捕获的多条记录会合并成一条
  private atomicDepth: number = 0;
  // 本原子区间第一条记录会落在的下标。原子合并只能发生在本次区间产生的记录之间 ——
  // 否则"插入图片"的原子块会把图片并进之前那条打字记录里，撤销时文字和图片一起消失
  private atomicStartIdx: number = 0;
  // 上一条记录产生的时间，用于判断是否落在合并时间窗内（0 表示没有可合并的上一条）
  private lastRecordTime: number = 0;
  // 正在重建编辑器内容。重建期间不跟踪附件 —— 那时还不知道每个 chip 对应哪个文件，
  // 由 resetAttachments 在重建完成后统一建立侧表
  private isRebuilding: boolean = false;
  // 附件侧表，按文档顺序排列。
  // ⚠️ 只放纯数据：绝不能放 CustomBuilder / buildChip —— 本类是单例，
  //    那会把组件实例一起吊住（见 insertFile 的告警）
  private attachments: Array<AttachmentEntry> = [];
  // 段落对齐样式及其点击回调
  alignInfoArr: AlignmentInfo[] = [
    {
      icon: $r('app.media.text_alignleft'),
      value: TextAlign.Start,
    },
    {
      icon: $r('app.media.text_aligncenter'),
      value: TextAlign.Center,
    },
    {
      icon: $r('app.media.text_alignright'),
      value: TextAlign.End,
    },
  ];

  // ==================== 撤销 / 重做 ====================

  /**
   * 建立历史基线。必须在编辑器内容重建【之后】调用。
   * 第 0 条是"初始状态"的占位记录、永不应用 —— 这样 currRecordIdx === 0 天然表示"没有可撤销的步骤"
   */
  resetHistory() {
    this.historyRecords = [new ChangeRecord()];
    this.historyLength = 1;
    this.currRecordIdx = 0;
    this.lastRecordTime = 0;
    // 附件侧表一并清空。两个调用点（进编辑页、重建完成）都是"会话重新开始"的时刻，
    // 而本控制器是**单例**、字段跨页面存活 —— 不清就有可能把上一篇备忘的附件
    // 带进这一篇（第 0 条历史是基线，语义上同样代表"从这里重新开始"）。
    // 重建那条路径紧接着会调 resetAttachments 重新建立侧表
    this.attachments = [];
  }

  /** 开始一段不记录历史的操作（重建编辑器内容会触发大量变更回调，必须抑制） */
  suspendHistory() {
    this.isRestoring = true;
    // 只由 onReady 调用，所以这里同时就是"重建开始"的信号
    this.isRebuilding = true;
  }

  /** 结束不记录历史的状态，并重建基线 */
  resumeHistoryAndReset() {
    this.isRestoring = false;
    this.isRebuilding = false;
    this.resetHistory();
  }

  // ==================== 附件侧表 ====================

  /**
   * 变更【前】跟踪附件删除。
   *
   * 规则：offset 落在 [start, end) 内的附件被这次变更删掉了。
   * 实测依据（E1 / E2）：单独删掉 chip 报 `rangeBefore=[0,1)`、删 `a[chip]b` 报 `[0,3)` ——
   * 区间**恰好覆盖** chip 占的那一格，所以这条判据成立。
   *
   * ⚠️ 这是唯一能得知"哪个附件被删了"的时机，绝不能漏。
   */
  private trackAttachmentDelete(rangeBefore: TextRange): void {
    if (this.isRebuilding || this.attachments.length === 0) {
      return;
    }
    const start = rangeBefore.start ?? 0;
    const end = rangeBefore.end ?? 0;
    if (end <= start) {
      return; // 纯插入（空区间）：没有东西被删
    }
    const kept: Array<AttachmentEntry> = [];
    for (const entry of this.attachments) {
      if (entry.offset >= start && entry.offset < end) {
        continue; // 落在被删区间内
      }
      kept.push(entry);
    }
    if (kept.length !== this.attachments.length) {
      this.attachments = kept;
    }
  }

  /**
   * 变更【后】跟踪附件位移。
   *
   * 规则：`offset >= rangeBefore.end` 的附件整体平移 `delta`。
   * 实测依据（B / C）：在 chip 后面打字（`[1,1)`→`[1,2)`）chip 不动；
   * 在它前面打字（`[0,0)`→`[0,1)`）chip 右移一格 —— 两条都符合。
   *
   * ⚠️ **刻意不受 `isRestoring` / `isRepairing` 影响**：
   *   - 补段落换行（isRepairing）是**真实的内容变更**，不跟踪就会永久偏移
   *   - 撤销/重做同理，跟踪它侧表才和文档保持一致
   * 只有重建期间例外（那时侧表还没建立，见 isRebuilding）。
   */
  private trackAttachmentShift(rangeBefore: TextRange, rangeAfter: TextRange): void {
    if (this.isRebuilding || this.attachments.length === 0) {
      return;
    }
    const beforeLen = (rangeBefore.end ?? 0) - (rangeBefore.start ?? 0);
    const afterLen = (rangeAfter.end ?? 0) - (rangeAfter.start ?? 0);
    const delta = afterLen - beforeLen;
    if (delta === 0) {
      return;
    }
    const boundary = rangeBefore.end ?? 0;
    for (const entry of this.attachments) {
      if (entry.offset >= boundary) {
        entry.offset += delta;
      }
    }
  }

  /**
   * 重建完成后建立附件侧表。
   *
   * 顺序依据：`rebuildContent` 是**顺序重放**的，所以编辑器里第 k 个 chip span
   * 必然对应 `memoBlockArr` 里第 k 个 builder 块。因此这里只需按顺序两两配对即可，
   * 不需要任何 offset 推算 —— 位置直接来自 `getSpans()`。
   *
   * @param blocks 备忘的块序列（重建所依据的那份）
   */
  resetAttachments(blocks: Array<MemoBlock>): void {
    const paths: Array<string> = [];
    for (const block of blocks) {
      if (block.type === 'builder') {
        paths.push(block.value);
      }
    }
    const offsets = this.builderSpanOffsets();
    this.attachments = [];
    const paired = Math.min(offsets.length, paths.length);
    for (let i = 0; i < paired; i++) {
      this.attachments.push({ offset: offsets[i], relativePath: paths[i] });
    }
    if (offsets.length !== paths.length) {
      // 数量对不上说明重建时有块被跳过（多半是附件副本缺失），此后的对齐会整体错位
      console.error(`[file] 附件侧表建立时数量不一致: 编辑器里 ${offsets.length} 个 chip，`
        + `存档里 ${paths.length} 个附件块`);
    }
  }

  /** 读当前编辑器里所有 chip 的坐标，按文档顺序 */
  private builderSpanOffsets(): Array<number> {
    const offsets: Array<number> = [];
    try {
      for (const span of this.contentController.getSpans()) {
        if (isBuilderSpan(span)) {
          offsets.push(span.spanPosition.spanRange[0]);
        }
      }
    } catch (error) {
      console.error(`[file] 读取 chip 坐标失败: ${JSON.stringify(error)}`);
    }
    offsets.sort((a, b) => a - b);
    return offsets;
  }

  /**
   * 保存前用编辑器里的真实状态重新对齐侧表。
   *
   * 这是**自校正**：增量跟踪万一漂移（漏掉某次变更、或遇到没预料到的框架行为），
   * 这一步能把 offset 拉回真实值。chip 既然能在 `getSpans()` 里读到，就不必盲信累加结果。
   *
   * 顺序不变式：**附件之间永远不会互相换位**（不能拖动），所以"第 k 个 chip span
   * ↔ 第 k 条侧表项"成立。数量对不上时只对上前 min(n, m) 个并记日志。
   */
  private syncAttachmentOffsets(): void {
    if (this.attachments.length === 0) {
      return;
    }
    const offsets = this.builderSpanOffsets();
    if (offsets.length !== this.attachments.length) {
      console.error(`[file] 附件侧表与编辑器不一致: 编辑器 ${offsets.length} 个 chip，`
        + `侧表 ${this.attachments.length} 项。将按顺序对齐前 ${Math.min(offsets.length, this.attachments.length)} 个`);
    }
    const paired = Math.min(offsets.length, this.attachments.length);
    for (let i = 0; i < paired; i++) {
      if (this.attachments[i].offset !== offsets[i]) {
        console.info(`[file] 附件 ${i} 的 offset 由 ${this.attachments[i].offset} 校正为 ${offsets[i]}`);
        this.attachments[i].offset = offsets[i];
      }
    }
  }

  /**
   * 按文档顺序返回附件的相对路径，供保存链路写入 `MemoBlock.value`。
   *
   * 会先做一次 `syncAttachmentOffsets()` —— 保存是"落盘"的关口，值得多花一次
   * `getSpans()` 把位置校正到真实值。
   */
  attachmentPathsInOrder(): Array<string> {
    this.syncAttachmentOffsets();
    const paths: Array<string> = [];
    for (const entry of this.attachments) {
      paths.push(entry.relativePath);
    }
    return paths;
  }

  /**
   * onWillChange —— 内容变更【前】触发。撤销/重做需要的信息在这里一次取齐。
   *
   * 【为什么只需要这一个回调】
   * 两侧内容都能拿到，不需要 onDidChange 的 rangeAfter：
   *   - 旧侧：实测框架在回调触发时尚未更新内部模型，`getSpans()` 读到的是**变更前**的内容；
   *     而且区间为空（纯插入）时也能拿到「插入点所在的 span」。
   *   - 新侧：`replacedSpans` / `replacedImageSpans` 直接给出「变更后覆盖该区域的 span」。
   *
   * 代价是两侧都是**完整的 span**（含未改动的邻居），所以撤销/重做时会整段重写。
   * 对备忘录这种没有超长段落的场景，换来的是"无待配对状态、可单点调试"。
   */
  onWillChange(value: RichEditorChangeValue) {
    if (this.isRestoring) {
      return;
    }
    // 附件删除跟踪：必须放在下面所有早返回【之前】—— 删掉附件是全链路里
    // 唯一能得知"哪个附件没了"的时机（插附件不触发任何回调，删附件才触发）
    this.trackAttachmentDelete(value.rangeBefore);

    const rangeStart = value.rangeBefore.start ?? 0;
    const rangeEnd = value.rangeBefore.end ?? 0;

    // 新侧：框架给的是「变更后覆盖变更区域的 span」。两种形态都有 ——
    // 普通文字输入返回所在整段，换行 / 图片只返回新内容本身（判别见下面"尾部对齐"那段）
    const afterRaw: Array<RichEditorSpan> = [];
    for (const span of value.replacedSpans) {
      afterRaw.push(span);
    }
    for (const span of value.replacedImageSpans) {
      afterRaw.push(span);
    }
    afterRaw.sort((a, b) => a.spanPosition.spanRange[0] - b.spanPosition.spanRange[0]);

    // 这次是不是"回车新建了一段"？判定见 isSingleNewline 的注释。
    // 放在这里是为了只判一次 —— 下面记录怎么建、是不是纯删除，都不影响这个判定
    this.pendingEnterOffset = (rangeStart === rangeEnd && isSingleNewline(afterRaw)) ? rangeStart : -1;

    const record = new ChangeRecord();
    record.changeStart = rangeStart;
    // onWillChange 触发时编辑器还没更新选区，这里读到的是变更【前】的光标位置
    record.caretBefore = this.contentController.getSelection().selection[0] ?? rangeStart;

    if (afterRaw.length === 0) {
      // ---- 纯删除：框架不给新侧，用 rangeBefore 精确表达 ----
      if (rangeEnd <= rangeStart) {
        return; // 既没有新内容、也没有被删内容，没什么可记的
      }
      record.beforeStart = rangeStart;
      record.beforeSpans = clipSpans(
        this.contentController.getSpans({ start: rangeStart, end: rangeEnd }), rangeStart, rangeEnd);
      record.afterStart = rangeStart;
      record.afterSpans = [];
    } else {
      // ---- 插入 / 替换：旧侧取「变更位置所在的整 span」，与新侧的整 span 配对 ----
      const beforeRaw = this.contentController.getSpans({ start: rangeStart, end: rangeEnd });
      record.beforeSpans = toSnapshots(beforeRaw);
      record.beforeStart = beforeRaw.length > 0 ? minSpanStart(beforeRaw) : rangeStart;

      // 新侧的起点可能落在旧内容之后 —— 例如在段首粘贴时，新 span 不会与前一段合并，
      // 于是新侧从粘贴点开始，而旧侧覆盖着变更点之前那一整段。
      // 必须把「变更点之前那截未改动的内容」补到新侧前面，让两侧从同一起点开始；
      // 否则撤销时按新侧范围删除会漏掉那截内容，再把旧侧插回去就成了重复内容。
      const rawAfterStart = afterRaw[0].spanPosition.spanRange[0];
      // 框架返回的第一段起点落在变更点之后 → 它给的是「从变更点开始的新 span」，
      // 而不是「变更位置所在的整个 span」，右侧那段没被动过的文字也就没被带上
      const afterStartsAtChange = rawAfterStart > record.beforeStart;
      const afterSpans: Array<SpanSnapshot> = afterStartsAtChange
        ? clipSpans(beforeRaw, record.beforeStart, rawAfterStart)
        : [];
      // 新内容的样式沿用变更点处的样式，不用 replacedSpans 自带的（原因见 styleAt 的注释）
      const inheritedStyle = styleAt(beforeRaw, rangeStart);
      for (const span of toSnapshots(afterRaw)) {
        if (span.kind === 'text' && inheritedStyle !== undefined) {
          span.textStyle = inheritedStyle;
        }
        afterSpans.push(span);
      }

      // 尾部对齐 —— 与上面那截前导是同一问题的【镜像】。
      // 旧侧取的是「变更位置所在的整 span」，新侧却可能只有框架给的「变更区域」，
      // 于是变更点【右侧】那段没被动过的文字不在新侧里，两侧的覆盖范围对不上：
      // 撤销时按新侧范围删除删不到那截，再把旧侧插回去就成了重复内容。
      //（abc → 光标移到开头插图 → 撤销 → abcabc；abc → 在 b 后插图 → 撤销 → abcc）
      //
      // ⚠️ 不能拿"长度"当"覆盖范围"的代理：插入的字符数会把长度差填平。
      //    abc 的 b 后插换行时，旧侧 3 个字、新侧（前导 ab + 换行）也是 3 个字，
      //    长度相等，但右侧那个 c 照样没被覆盖 —— 长度比较会漏判。
      //
      // 难点是框架有两种返回形态，而 onWillChange 里拿不到区分它们的信息
      //（能区分的是 rangeAfter，只在 onDidChange 上）：
      //    普通文字输入 → 并进所在 span，返回的是**整段**，尾部已经在里面
      //    换行 / 图片   → 永远单独成 span，只返回新内容，尾部不在里面
      // 所以只在**能确定尾部不在里面**时才补，下面三条满足其一即补：
      //    ① 前导非空：框架返回的是「从变更点开始的新 span」而非所在整段，右侧同理没带上
      //    ② 纯插入且新侧没盖过旧侧末尾：净增长 ≥ 1 时返回整段必然盖过旧侧末尾，
      //       盖不过就一定是「只有新内容」这一形态
      //    ③ 新内容含换行或图片：这两类永远单独成 span，从不与右侧文字合并
      // 已知盲区：纯插入 + 变更点恰在 span 开头 + 插入的是不含换行的多字符文本且长于右侧剩余
      //（例如在 3 个字的段落开头粘贴 10 个字）—— 它与「同位置普通打字」的签名完全相同，
      //  不引入 rangeAfter 无解。真遇到再走 onDidChange 方案
      const beforeEnd = record.beforeStart + spansTotalLength(record.beforeSpans);
      const afterEnd = record.beforeStart + spansTotalLength(afterSpans);
      const tailLength = beforeEnd - rangeEnd;
      if (tailLength > 0 && (afterStartsAtChange
        || (rangeStart === rangeEnd && (afterEnd <= beforeEnd || hasSpanBreakingContent(afterRaw))))) {
        for (const span of clipSpans(beforeRaw, rangeEnd, beforeEnd)) {
          afterSpans.push(span);
        }
      }

      record.afterStart = record.beforeStart;
      record.afterSpans = afterSpans;
    }

    // 重做后的光标：变更结束处（估算）。插入时 = 变更起点 + 净增长度；删除时 = 变更起点
    const delta = spansTotalLength(record.afterSpans) - spansTotalLength(record.beforeSpans);
    record.caretAfter = rangeStart + (delta > 0 ? delta : 0);

    this.pushRecord(record);
  }

  /**
   * onDidChange —— 变更【后】触发，用来维护两类「内容各自成段」的原则：
   *
   *   - 相册照片与文件附件 chip 必须**独占一段**：前后两侧都得是换行
   *   - 待办勾选框必须待在**段落开头**：前一格得是换行（或文档开头）
   *
   * 【为什么放在变更后】修复依据的是变更【后】的真实内容，只有这里读得到
   *（onWillChange 里 getSpans() 拿到的还是旧内容）。而且这里能拿到精确的 rangeAfter，
   * onWillChange 没有这个字段 —— 用它圈出扫描窗口，不必每次按键都全量扫全文。
   *
   * 【为什么是"放行 + 事后修复"，而不是在 onWillChange 里拦截、改写用户操作】
   * 越界操作不止"删换行"一种：图片前后打字、粘贴、跨段选区删除都会破坏。
   * 要拦截就得重放用户的输入，而重放要从 replacedSpans 还原"用户敲了什么" ——
   * 它的语义是把没改动的旧内容和新内容合并成同一个 span、样式还报写入前的原始值
   *（见 UNDO_REDO_PLAN §二），还原不了。放行 + 事后修复是"看结果说话"，对入口不敏感。
   *
   * 【只管行内图片】两条原则都只针对图片单元；普通文字不受任何约束。
   * 两类图片的约束不同（照片前后都要换行，勾选框只管前侧），所以判定分开写在循环里。
   */
  onDidChange(rangeBefore: TextRange, rangeAfter: TextRange, uiContext: UIContext) {
    // 附件位移跟踪：**刻意放在所有守卫之前**。
    // 它必须看到每一次真实的内容变更，包括补段落换行（isRepairing）与撤销/重做（isRestoring）
    // 产生的那些 —— 那些都是实实在在的文字增删，跳过跟踪侧表就会永久偏移。
    // （重建期间由 trackAttachmentShift 内部按 isRebuilding 自行跳过）
    this.trackAttachmentShift(rangeBefore, rangeAfter);

    // 先把回车标记消费掉：下面几个分支都可能提前 return，留着会污染下一次变更
    const enterOffset = this.pendingEnterOffset;
    this.pendingEnterOffset = -1;
    // 重建内容 / 撤销重做期间不插手：那些变更不来自用户编辑。
    // isRepairing 是防递归 —— 下面补换行会同步触发一轮 willChange / didChange
    if (this.isRestoring || this.isRepairing) {
      return;
    }
    // 回车新建的一段，上一段是待办的话把它也变成待办。
    // 放在下面的段落维护【之前】：它会插一张图，而那段维护是按"当时的坐标"扫描的，
    // 先插再扫，坐标才对得上
    if (enterOffset >= 0) {
      this.continueTodoParagraph(enterOffset);
    }
    const rangeStart = rangeAfter.start ?? 0;
    const rangeEnd = rangeAfter.end ?? 0;
    // 只有紧挨变更点的图片才可能被破坏：变更点左边一格、右边一格。
    // 多取一格是必要的 —— 纯删除时 rangeAfter 是空区间，图片正好落在它两侧
    const from = Math.max(0, Math.min(rangeStart, rangeEnd) - 1);
    const to = Math.max(rangeStart, rangeEnd) + 1;

    let spans: Array<RichEditorSpan>;
    try {
      spans = this.contentController.getSpans({ start: from, end: to });
    } catch (error) {
      console.error(`[image] 读取变更周边内容失败: ${JSON.stringify(error)}`);
      return;
    }

    // 用 Map 按插入位置去重：两张相邻图片时，前一张的"后侧"和后一张的"前侧"
    // 指向同一个插入位置，各插一个会凭空多出空段落
    const fixes: Map<number, ParagraphFix> = new Map<number, ParagraphFix>();
    for (const span of spans) {
      const range = span.spanPosition.spanRange;
      // 相册照片与文件附件 chip 是**同一类**约束：都必须独占一段，前后都得是换行。
      // chip 早期是按行内内容做的；能改成独占一段的依据见 FILE_ATTACHMENT_REVIEW.md
      if (isAlbumPhoto(span) || isBuilderSpan(span)) {
        // 前侧：左边是普通字符或另一个原子单元 → 已经和它挤在同一段了
        if (neighborAt(spans, range[0] - 1) === 'other') {
          fixes.set(range[0], this.buildParagraphFix(range[0], range[0] - 1, spans, uiContext));
        }
        // 后侧同理
        if (neighborAt(spans, range[1]) === 'other') {
          fixes.set(range[1], this.buildParagraphFix(range[1], range[1], spans, uiContext));
        }
        continue;
      }
      // 待办勾选框只能待在【段落开头】—— 图标前一格不是换行（也不是文档开头）就补一个。
      // 这一条同时管住两种越界，它们是同一个条件：
      //   在图标前打字   prev\nX[图标]  → prev\nX\n[图标]   打的字被挡回上一段
      //   删掉图标前的换行 prev[图标]   → prev\n[图标]      两个待办不会被并成一行
      const markName = builtinImageNameOf(span);
      if (markName !== undefined && toggledTodoMark(markName) !== undefined
        && neighborAt(spans, range[0] - 1) === 'other') {
        fixes.set(range[0], this.buildParagraphFix(range[0], range[0] - 1, spans, uiContext));
      }
    }
    if (fixes.size === 0) {
      return;
    }
    const pending: Array<ParagraphFix> = [];
    for (const fix of fixes.values()) {
      pending.push(fix);
    }
    this.applyParagraphFixes(pending);
  }

  /**
   * 组装一处待补的换行。
   *
   * 样式取紧邻那个【文本】span 的：补出来的换行会并进它所在的那一段，
   * 样式不同就可能把段落拆成两个、对齐方式跟着漂移（与 addImage 里前置换行同一个理由）。
   * refPosition 处是图片（两张图挨着）或取不到文本时，回落输入样式。
   */
  private buildParagraphFix(offset: number, refPosition: number,
    spans: Array<RichEditorSpan>, uiContext: UIContext): ParagraphFix {
    const refSpan = textSpanAt(spans, refPosition);
    const refParagraph = refSpan ? refSpan.paragraphStyle : undefined;
    return {
      offset: offset,
      style: refSpan ? textStyleResult2Style(refSpan.textStyle) : this.effectiveTypingStyle(uiContext),
      paragraphStyle: refParagraph ? { textAlign: refParagraph.textAlign } : undefined,
    };
  }

  /**
   * 逐处补上换行。
   *
   * 【从右往左插】先动手的必须是靠后的位置，否则前面几处的坐标会被推移。
   *
   * 【光标校正】只把插在光标【之前】的换行计入位移，**恰好插在光标位置上的不推**。
   * 这条决定了图片前后打字的手感，以"图片前打一个 x"为例：
   *   abc\n[img] → 打完 x 变成 abc\nx[img]，补一个换行到 x 后面
   *   不推光标 → 光标留在 x 之后，再打 y 得到 abc\nxy\n[img]，天然就不破坏了
   *   若改成右推 → 光标落到图片段首，打 y 又破坏、又补一行，每打一个字就多一行
   * 对"删掉换行"则表现为把删除换成了"向前移动光标"：内容回到原样，光标停在换行之前。
   */
  private applyParagraphFixes(fixes: Array<ParagraphFix>) {
    fixes.sort((a, b) => b.offset - a.offset);
    const caret = this.contentController.getCaretOffset();
    let shift = 0;
    this.isRepairing = true;
    try {
      for (const fix of fixes) {
        this.contentController.addTextSpan('\n', {
          offset: fix.offset,
          style: fix.style,
          paragraphStyle: fix.paragraphStyle,
        });
        if (caret >= 0 && fix.offset < caret) {
          shift += 1;
        }
      }
      // 必须【无条件】设置，不能只在 shift > 0 时设置：
      // 插入点恰好等于光标位置时，框架会把光标右推到插入内容之后（0 位移也要覆盖掉），
      // 否则退格会表现为"按了没反应"—— 光标停在图片段首不动，下次退格删掉刚补的换行，来回循环
      if (caret >= 0) {
        this.contentController.setCaretOffset(caret + shift);
      }
    } catch (error) {
      console.error(`[image] 补图片段落换行失败: ${JSON.stringify(error)}`);
    } finally {
      this.isRepairing = false;
    }
  }

  /**
   * 撤销。需要 uiContext 是因为图片快照的样式要在恢复时重算（用得到 px2vp）
   */
  unDo(uiContext: UIContext) {
    if (this.isRestoring || this.currRecordIdx < 1) {
      return;
    }
    const record = this.historyRecords[this.currRecordIdx];
    this.isRestoring = true;
    try {
      this.applyRecord(record, true, uiContext);
      this.currRecordIdx -= 1;
    } catch (error) {
      console.error(`[undo] 撤销失败: ${JSON.stringify(error)}`);
    } finally {
      this.isRestoring = false;
    }
  }

  /** 重做 */
  reDo(uiContext: UIContext) {
    if (this.isRestoring || this.currRecordIdx >= this.historyLength - 1) {
      return;
    }
    const record = this.historyRecords[this.currRecordIdx + 1];
    this.isRestoring = true;
    try {
      this.applyRecord(record, false, uiContext);
      this.currRecordIdx += 1;
    } catch (error) {
      console.error(`[undo] 重做失败: ${JSON.stringify(error)}`);
    } finally {
      this.isRestoring = false;
    }
  }

  // ==================== 原子操作 ====================

  /**
   * 开始一个原子区间：期间捕获到的多条记录会合并成一条。
   * 用途：像"插入图片 + 插入换行"这种一次用户操作产生多条底层变更的场景，
   * 否则撤销一次只会退掉其中一步。
   */
  beginAtomic() {
    if (this.atomicDepth === 0) {
      this.atomicStartIdx = this.currRecordIdx + 1;
    }
    this.atomicDepth += 1;
  }

  /** 结束原子区间 */
  endAtomic() {
    if (this.atomicDepth > 0) {
      this.atomicDepth -= 1;
    }
  }

  /**
   * 记录入栈。
   * 优先尝试合并（原子操作 > 连续同类编辑）；否则截断"未来"（撤销后再编辑会让重做栈失效）后入栈，
   * 并在超出上限时淘汰最早的记录。
   */
  private pushRecord(record: ChangeRecord) {
    // 原子合并：只并进"本次原子区间已经产生的记录"，不能并进进入区间之前就有的记录
    if (this.atomicDepth > 0 && this.currRecordIdx >= this.atomicStartIdx
      && this.mergeIntoTop(record)) {
      this.lastRecordTime = new Date().getTime();
      return;
    }
    if (this.mergeByWindow(record)) {
      this.lastRecordTime = new Date().getTime();
      return;
    }
    if (this.currRecordIdx < this.historyRecords.length - 1) {
      this.historyRecords.splice(this.currRecordIdx + 1);
    }
    this.historyRecords.push(record);
    this.currRecordIdx = this.historyRecords.length - 1;
    this.lastRecordTime = new Date().getTime();
    this.evictIfNeeded();
  }

  /** 超出条数上限时从最早的记录开始丢弃（基线也会被丢掉，之后最早那条就撤不动了） */
  private evictIfNeeded() {
    const overflow = this.historyRecords.length - MAX_HISTORY_RECORDS;
    if (overflow <= 0) {
      this.historyLength = this.historyRecords.length;
      return;
    }
    this.historyRecords.splice(0, overflow);
    this.currRecordIdx = Math.max(0, this.currRecordIdx - overflow);
    this.historyLength = this.historyRecords.length;
    console.info(`[undo] 历史超限，淘汰最早的 ${overflow} 条记录`);
  }

  /**
   * 连续同类编辑的合并（打字 / 连续删除）。
   *
   * 判据是**白名单**：只放明确安全的进来 —— 漏掉一个打断条件的后果是"一次撤销吃掉一大段"，
   * 比"该合并的没合并"严重得多。因此要求：
   *   - 只在历史末端合并（撤销过再编辑属于分叉，不能并进旧记录）
   *   - 两类都必须是 content、纯插入或纯删除、且只含文本
   *   - 位置连续（输入看光标衔接，删除看区间相邻或同位置）
   *   - 落在合并时间窗内
   */
  private mergeByWindow(record: ChangeRecord): boolean {
    // 原子区间内不做时间窗合并：区间里"第一条"记录不能并进之前那条操作。
    // 反例：打个字 → 立刻插图，补出来的前置换行是纯文本插入，位置又恰好衔接打字记录的光标，
    // 不拦的话会被并进打字记录里，撤销一次连刚打的字一起退掉。
    // （区间内后续几条仍由 mergeIntoTop 合并，不受影响）
    if (this.atomicDepth > 0) {
      return false;
    }
    if (this.currRecordIdx < 1 || this.currRecordIdx !== this.historyRecords.length - 1) {
      return false;
    }
    if (this.lastRecordTime === 0) {
      return false;
    }
    if (new Date().getTime() - this.lastRecordTime > MERGE_WINDOW_MS) {
      return false;
    }
    const top = this.historyRecords[this.currRecordIdx];
    if (top.kind !== 'content' || record.kind !== 'content') {
      return false;
    }
    if (!isTextOnly(top) || !isTextOnly(record)) {
      return false;
    }

    if (isInsertRecord(top) && isInsertRecord(record)) {
      return this.mergeInsertIntoTop(top, record);
    }
    if (isDeleteRecord(top) && isDeleteRecord(record)) {
      return this.mergeDeleteIntoTop(top, record);
    }
    return false;
  }

  /**
   * 连续输入：记录是"层层覆盖"的关系（after 越来越大），
   * 所以保留最早的 before，after 用最新的覆盖即可。
   */
  private mergeInsertIntoTop(top: ChangeRecord, record: ChangeRecord): boolean {
    // 位置连续：这次输入接在上次输入结束处
    if (record.changeStart !== top.caretAfter || record.afterStart < top.afterStart) {
      return false;
    }
    const merged: Array<SpanSnapshot> = [];
    const headLength = record.afterStart - top.afterStart;
    if (headLength > 0) {
      for (const span of takePrefix(top.afterSpans, headLength)) {
        merged.push(span);
      }
    }
    for (const span of record.afterSpans) {
      merged.push(span);
    }
    top.afterSpans = merged;
    top.caretAfter = record.caretAfter;
    return true;
  }

  /**
   * 连续删除：关系与输入相反，是"各自向前推进"，
   * 所以要在 before 侧按文档顺序把两次删掉的内容拼起来，after 保持为空。
   */
  private mergeDeleteIntoTop(top: ChangeRecord, record: ChangeRecord): boolean {
    const topStart = top.beforeStart;
    const topEnd = topStart + spansTotalLength(top.beforeSpans);
    const newStart = record.beforeStart;
    const newEnd = newStart + spansTotalLength(record.beforeSpans);

    const merged: Array<SpanSnapshot> = [];
    if (newEnd === topStart) {
      // 退格：这次删的在栈顶那条的紧前面 → [新的][栈顶的]
      for (const span of record.beforeSpans) {
        merged.push(span);
      }
      for (const span of top.beforeSpans) {
        merged.push(span);
      }
      top.beforeStart = newStart;
    } else if (newStart === topStart) {
      // 前向删除（Delete 键）：同一位置反复删 → [栈顶的][新的]
      for (const span of top.beforeSpans) {
        merged.push(span);
      }
      for (const span of record.beforeSpans) {
        merged.push(span);
      }
    } else {
      return false; // 两次删除不相邻，不合并
    }
    top.beforeSpans = merged;
    top.afterStart = top.beforeStart;
    // 撤销后的光标由 caretBefore 决定，它保留的是【最早那条】的值 ——
    // 也就是连续删除开始前光标所在的位置，正是撤销后应该回到的地方
    return true;
  }

  /**
   * 把新记录并入栈顶（原子操作的多步合成一条）。
   *
   * 规则：保留栈顶的 before 侧；after 侧取「栈顶 after 中位于新记录起点之前的部分 + 新记录的 after」。
   * 那截前导必须保留 —— 两条记录覆盖的区域起点可能不同：例如插入照片时，
   * 第一条记录覆盖 [0,4)，第二条只覆盖 [3,5)，直接替换 after 会把 [0,3) 的内容丢掉。
   */
  private mergeIntoTop(record: ChangeRecord): boolean {
    if (this.currRecordIdx < 1) {
      return false; // 栈顶是基线，不能并进去
    }
    const top = this.historyRecords[this.currRecordIdx];
    if (top.kind !== 'content' || record.kind !== 'content') {
      return false; // 样式类记录不参与原子合并
    }
    if (record.afterStart < top.afterStart) {
      return false; // 起点回退，超出预期，保守起见不合并
    }
    const merged: Array<SpanSnapshot> = [];
    const headLength = record.afterStart - top.afterStart;
    if (headLength > 0) {
      for (const span of takePrefix(top.afterSpans, headLength)) {
        merged.push(span);
      }
    }
    for (const span of record.afterSpans) {
      merged.push(span);
    }
    top.afterSpans = merged;
    top.caretAfter = record.caretAfter;
    return true;
  }

  /**
   * 把记录的一侧应用到编辑器。
   *
   * 顺序必须是"先删后插"：先删掉对侧占用的整个范围，再把本侧内容插到本侧起点；
   * 反过来先插会把后面的坐标整体右移。
   */
  private applyRecord(record: ChangeRecord, useBefore: boolean, uiContext: UIContext) {
    // 样式类记录不碰内容：段落样式是段落级属性，删了重插会把段落拆开 / 合并
    if (record.kind === 'textStyle') {
      const rangeLength = spansTotalLength(record.beforeSpans);
      if (useBefore) {
        this.applySpanStyles(record.beforeSpans, record.beforeStart);
      } else {
        this.contentController.updateSpanStyle({
          textStyle: record.afterTextStyle,
          start: record.beforeStart,
          end: record.beforeStart + rangeLength,
        });
      }
      return;
    }
    if (record.kind === 'paragraph') {
      const rangeLength = spansTotalLength(record.beforeSpans);
      if (useBefore) {
        this.applyParagraphAligns(record.beforeSpans, record.beforeStart);
      } else {
        this.contentController.updateParagraphStyle({
          style: { textAlign: record.afterAlign ?? TextAlign.Start },
          start: record.beforeStart,
          end: record.beforeStart + rangeLength,
        });
      }
      return;
    }

    const removeStart = useBefore ? record.afterStart : record.beforeStart;
    const removeLength = spansTotalLength(useBefore ? record.afterSpans : record.beforeSpans);
    const insertStart = useBefore ? record.beforeStart : record.afterStart;
    const spans = useBefore ? record.beforeSpans : record.afterSpans;
    const caret = useBefore ? record.caretBefore : record.caretAfter;

    if (removeLength > 0) {
      this.contentController.deleteSpans({ start: removeStart, end: removeStart + removeLength });
    }
    this.insertSpans(spans, insertStart, uiContext);
    this.contentController.setCaretOffset(caret);
  }

  /** 逐段把快照里的旧样式应用回去（样式类记录的撤销） */
  private applySpanStyles(spans: Array<SpanSnapshot>, start: number) {
    let cursor = start;
    for (const span of spans) {
      if (span.kind === 'text' && span.textStyle !== undefined) {
        this.contentController.updateSpanStyle({
          textStyle: span.textStyle,
          start: cursor,
          end: cursor + span.length,
        });
      }
      cursor += span.length;
    }
  }

  /** 逐段把快照里的旧对齐应用回去 */
  private applyParagraphAligns(spans: Array<SpanSnapshot>, start: number) {
    let cursor = start;
    for (const span of spans) {
      const align = span.paragraphStyle?.textAlign;
      if (span.kind === 'text' && align !== undefined) {
        this.contentController.updateParagraphStyle({
          style: { textAlign: align },
          start: cursor,
          end: cursor + span.length,
        });
      }
      cursor += span.length;
    }
  }

  /**
   * 构造一条样式类记录：把 [start, end) 区间内**逐段**的现有样式抓下来作为"旧样式"。
   *
   * 必须逐段抓 —— 比如选中的一半是粗体一半是正常体，撤销要还原成"混合"状态，
   * 统一的样式表达不了。
   */
  private buildStyleRecord(kind: 'textStyle' | 'paragraph', start: number, end: number): ChangeRecord {
    const record = new ChangeRecord();
    record.kind = kind;
    record.beforeStart = start;
    record.beforeSpans = clipSpans(this.contentController.getSpans({ start: start, end: end }), start, end);
    return record;
  }

  /** 按顺序把一组快照插回编辑器。游标用快照自带的 length 推进，不依赖 span 之间无缝衔接 */
  private insertSpans(spans: Array<SpanSnapshot>, start: number, uiContext: UIContext) {
    let cursor = start;
    for (const span of spans) {
      if (span.kind === 'text') {
        this.contentController.addTextSpan(span.value, {
          offset: cursor,
          style: span.textStyle,
          paragraphStyle: span.paragraphStyle,
        });
      } else {
        this.insertImageSpan(span, cursor, uiContext);
      }
      cursor += span.length;
    }
  }

  /**
   * 插入一个图片快照。
   *
   * 样式在这里**重算**，不用快照里存的结果值 —— 图片样式本来就由我们插入时决定，
   * 重算既能保证与原始插入完全一致，又不依赖框架对图片尺寸的报值
   * （实测 getSpans 在变更后立即读是 [0,0]、replacedSpans 的单位口径也和它不一致）。
   */
  private insertImageSpan(span: SpanSnapshot, offset: number, uiContext: UIContext) {
    const resource = span.imageResource;
    if (resource !== undefined) {
      // 内置图：样式是固定常量
      this.contentController.addImageSpan(resource, { offset: offset, imageStyle: builtinImageStyle() });
      return;
    }
    const pixelMap = span.imagePixelMap;
    if (pixelMap === undefined) {
      console.error('[undo] 图片快照既无资源也无 PixelMap，跳过该图');
      return;
    }
    this.contentController.addImageSpan(pixelMap, {
      offset: offset,
      imageStyle: this.imageStyleForFile(pixelMap, uiContext),
    });
  }

  /**
   * 相册照片的显示样式。
   * 插入（addImage）与撤销/重做共用这一个函数，保证重做出来的图
   * 在尺寸、圆角、边距上与原始插入完全一致。
   */
  private imageStyleForFile(pixelMap: image.PixelMap, uiContext: UIContext): RichEditorImageSpanStyle {
    const info = pixelMap.getImageInfoSync();
    let width = uiContext.px2vp(info.size.width);
    let height = uiContext.px2vp(info.size.height);
    // 宽度超过最大尺寸时，等比例缩放
    const displayWidth = uiContext.px2vp(display.getDefaultDisplaySync().width) * 0.9;
    if (width > displayWidth) {
      height = height * (displayWidth / width);
      width = displayWidth;
    }
    return {
      size: [width, height],
      objectFit: ImageFit.Auto,
      layoutStyle: {
        borderRadius: FILE_IMAGE_BORDER_RADIUS,
        margin: { top: FILE_IMAGE_VERTICAL_MARGIN, bottom: FILE_IMAGE_VERTICAL_MARGIN },
      },
    };
  }

  /**
   * 把输入样式换算成"实际生效"的数值，供 addTextSpan 显式指定样式时使用。
   *
   * 为什么需要换算：`setTypingStyle` 设的是**原始值**，渲染时会乘上系统字体缩放；
   * 而 `addTextSpan` 写入的值**不缩放**。实测输入样式 fontSize=16 时，
   * 手打文字实际渲染为 14（缩放系数 0.875），而不带样式插入的 span 渲染为 16。
   * 所以把原始值直接交给 addTextSpan，这段文字的渲染字号会比用户手打的文字大。
   */
  private effectiveTypingStyle(uiContext: UIContext): RichEditorTextStyle {
    const raw = this.buildTypingStyle();
    let scale = 1;
    const fontScale = (uiContext.getHostContext() as common.UIAbilityContext).config.fontSizeScale;
    if (fontScale !== undefined) {
      scale = fontScale;
    }
    return {
      fontSize: typeof raw.fontSize === 'number' ? raw.fontSize * scale : raw.fontSize,
      lineHeight: typeof raw.lineHeight === 'number' ? raw.lineHeight * scale : raw.lineHeight,
      fontStyle: raw.fontStyle,
      fontWeight: raw.fontWeight,
      fontFamily: raw.fontFamily,
      fontColor: raw.fontColor,
      decoration: raw.decoration,
      letterSpacing: typeof raw.letterSpacing === 'number' ? raw.letterSpacing * scale : raw.letterSpacing,
    };
  }

  /**
   * 由当前工具栏状态组装"后续输入样式"
   */
  private buildTypingStyle(): RichEditorTextStyle {
    return {
      fontSize: this.fontSize,
      lineHeight: this.fontSize * 1.5,
      fontColor: COLOR_LIST[this.colorIdx],
      fontWeight: this.isBold ? FontWeight.Bold : FontWeight.Normal,
      fontStyle: this.isItalics ? FontStyle.Italic : FontStyle.Normal,
      decoration: {
        type: this.isUnderline ? TextDecorationType.Underline : TextDecorationType.None,
      },
    };
  }

  /**
   * 让"后续输入样式"与工具栏状态保持一致
   */
  applyTypingStyle() {
    this.contentController.setTypingStyle(this.buildTypingStyle());
  }

  /**
   * 切换「手写画布 / 键盘输入」。
   *
   * 【切进手写前必须 stopEditing】只把输入框的 `focusable` 置 false **不会**让
   * 已经获焦的输入框失焦 —— 软键盘会继续停在屏幕上盖住画布，得显式收起来。
   * 反过来切回键盘时**不主动唤起**输入法：让用户自己点，免得平白弹一次键盘。
   *
   * 笔迹本身不在这里管：它由 handwriteController 持有，两个模式切来切去不会丢
   *（画布组件常驻，只切显隐）。⚠️ 但**退出编辑页就没了** —— 目前没有持久化。
   */
  toggleHandWrite() {
    if (!this.isHandWrite) {
      try {
        this.titleController.stopEditing();
        this.contentController.stopEditing();
      } catch (error) {
        // 收起输入法失败不该拦住模式切换，记日志继续
        console.error(`Failed to stop editing when switching to handwrite. Cause: ${JSON.stringify(error)}`);
      }
    }
    this.isHandWrite = !this.isHandWrite;
  }

  /**
   * 设置文本样式
   */
  updateTextStyle(textStyle: RichEditorTextStyle) {
    // 获取选中内容的范围
    const selection = this.contentController.getSelection();
    const start = selection.selection[0] ?? 0;
    const end = selection.selection[1] ?? 0;
    // 无论有无选区，都让"后续输入样式"跟随工具栏状态
    this.applyTypingStyle();
    if (start < 0 || end <= start) {
      // 无选区：样式只作用于此后输入的内容，已有内容没变 —— 不产生历史记录
      return;
    }
    // 框架不会通知程序化的样式变更（实测 updateSpanStyle 不触发内容回调），必须手动记录。
    // 先把本区间的逐段旧样式抓下来，再应用新样式
    const record = this.buildStyleRecord('textStyle', start, end);
    record.afterTextStyle = textStyle;
    this.contentController.updateSpanStyle({
      textStyle: textStyle,
      start: start,
      end: end,
    });
    this.pushRecord(record);
  }

  /**
   * 设置段落对齐方式
   */
  updateParagraphStyle(paragraphStyle: RichEditorParagraphStyle) {
    // 获取选中内容的范围
    const selection = this.contentController.getSelection();
    // 当未选中内容时，计算当前段落起始范围
    const pRange = this.getParagraphRange(selection.selection[0] ?? 0, selection.selection[1] ?? 0);
    const pStart = pRange.start ?? 0;
    const pEnd = pRange.end ?? 0;
    // 同 updateTextStyle：框架不通知，手动记录被改段落原有的对齐方式
    const record = this.buildStyleRecord('paragraph', pStart, pEnd);
    record.afterAlign = paragraphStyle.textAlign;
    // 获取指定范围的段落信息
    this.contentController.updateParagraphStyle({
      style: paragraphStyle,
      start: pStart,
      end: pEnd,
    });
    this.pushRecord(record);
  }

  /**
   * 获取段落范围（编辑器坐标）
   *
   * 用 getParagraphs 而不是解析 toStyledString 的纯文本：
   * 段落边界由框架给出，不依赖"图片 / SymbolSpan / BuilderSpan 在纯文本里占几个字符"这类
   * 文档未定义的假设 —— 那些假设一旦不成立，算出的下标就会和编辑器坐标错位。
   *
   * 选中多个字符时，返回覆盖整个选区所跨段落的范围
   */
  getParagraphRange(start: number, end: number): RichEditorRange {
    try {
      // 必须传参（空对象即可）：不传会返回 undefined。
      // 签名上参数是可选，但实测如此，且与 getSpans() 的行为不一致，勿删
      const paragraphs = this.contentController.getParagraphs({});
      // 光标 / 选区端点落在段落边界上时归属后一段，
      // 这与"光标在段首"的直觉一致，也避开了 range 是否含换行的歧义
      let first: RichEditorParagraphResult | undefined = undefined;
      let last: RichEditorParagraphResult | undefined = undefined;
      for (const paragraph of paragraphs) {
        if (paragraph.range[0] <= start) {
          first = paragraph;
        }
        if (paragraph.range[0] <= end) {
          last = paragraph;
        }
      }
      if (first && last) {
        return { start: first.range[0], end: last.range[1] };
      }
    } catch (error) {
      console.error(`Failed to invoke getParagraphs. Cause: ${JSON.stringify(error)}`);
    }

    // 兜底：拿不到段落信息时按原范围处理，不抛异常
    return { start: start, end: end };
  }

  /**
   * 插入图片
   */
  insertImage(uiContext: UIContext) {
    this.selectPhoto()
      .then((photoUris) => {
        if (!photoUris || photoUris.length < 1) {
          return;
        }

        let pixelMap: image.PixelMap | undefined;
        try {
          const photoUri = photoUris[0];
          pixelMap = this.loadImage(photoUri);
          this.addImage(pixelMap, uiContext);
        } finally {
          if (pixelMap) {
            pixelMap.release();
          }
        }
      });
  }

  /**
   * position 所在段落的真正起点。
   *
   * 不能直接用 `getParagraphRange().start` 了事 —— 段落以行内图片开头时，
   * `getParagraphs()` 报的段首会落在图片【之后】（实测：勾选框占 `[0,1)`、光标在 1 处时，
   * 报的段首是 1 而不是 0，见 SPAN_EDITOR_REVIEW §五），
   * 拿它去判"段首有没有勾选框"必然落空。所以还得往回看一格。
   */
  private paragraphStartAt(position: number): number {
    const range = this.getParagraphRange(position, position);
    const start = range.start ?? position;
    if (start > 0 && this.todoMarkAt(start - 1) !== undefined) {
      return start - 1;
    }
    return start;
  }

  /**
   * 回车新建的那一段，如果上一段是待办，就把它也变成待办 —— 待办列表连着写的基本手感。
   *
   * @param enterOffset 换行的插入点（= 上一段的结尾），新段落从它后一格开始
   *
   * 触发条件由 onWillChange 判定（纯插入 + 恰好一个换行），粘贴整段不会走到这里。
   */
  private continueTodoParagraph(enterOffset: number) {
    // 上一段以勾选框开头吗？注意用 paragraphStartAt 而不是直接取 getParagraphRange，
    // 理由见它的注释
    if (this.todoMarkAt(this.paragraphStartAt(enterOffset - 1)) === undefined) {
      return;
    }
    const resource = builtinImageResource(TODO_MARK_OPEN);
    if (!resource) {
      console.error(`Unknown builtin image: ${TODO_MARK_OPEN}`);
      return;
    }
    try {
      this.contentController.addImageSpan(resource, {
        offset: enterOffset + 1,
        imageStyle: builtinImageStyle(),
        gesture: {
          onClick: () => {
            this.onTodoMarkTap();
          },
        },
      });
      // 光标落到新勾选框之后，用户可以直接写这一条的内容
      this.contentController.setCaretOffset(enterOffset + 2);
    } catch (error) {
      console.error(`Failed to continue todo paragraph. Cause: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 插入待办勾选框（行内小图标，不独占段落）。
   *
   * 插到光标所在**段落开头** —— 与「待办 = 以勾选框开头的段落」这个定义自洽，
   * 也与系统备忘录一致；光标停在段落中间时不会插出一个"半截待办"。
   */
  insertTodoMark() {
    const caret = this.contentController.getCaretOffset();
    if (caret < 0) {
      return;
    }
    const paragraphStart = this.paragraphStartAt(caret);
    // 段首已经有勾选框就不重复插，免得变成「○○ 买牛奶」
    if (this.todoMarkAt(paragraphStart) !== undefined) {
      return;
    }
    const resource = builtinImageResource(TODO_MARK_OPEN);
    if (!resource) {
      console.error(`Unknown builtin image: ${TODO_MARK_OPEN}`);
      return;
    }
    try {
      this.contentController.addImageSpan(resource, {
        offset: paragraphStart,
        imageStyle: builtinImageStyle(),
        gesture: {
          onClick: () => {
            this.onTodoMarkTap();
          },
        },
      });
    } catch (error) {
      console.error(`Failed to insert todo mark. Cause: ${JSON.stringify(error)}`);
    }
  }

  // ==================== 待办勾选框 ====================

  /**
   * 勾选框被点中（挂在图片 span 的 gesture 上）。
   *
   * 【触发与定位是分开的两件事】
   *   - 触发：只有真正点在图标上才会进这个回调（点它左边/右边的文字不会），
   *     所以左半边右半边都算数，不需要额外判方向
   *   - 定位：框架会把光标移到被点那张图的旁边，**落在前还是后取决于点的是左半还是右半**
   *     （实测：点左半落 0、点右半落 1）。两种都要认 ——
   *     勾选框是段落级标记、不可能两张紧挨着，所以"紧邻光标的勾选框"唯一
   *
   * 【为什么必须等落定，不能就地判】回调里读到的光标还是点击【前】的
   *（实测：点击前在 9，回调里读到 9，落定后才是 0）。而点击前光标多半正停在
   * **上一个被点的图标**旁边 —— 直接按它判就会切错目标：
   *   两个待办 A、B：点完 A 后光标停在 A 旁；再点 B 时，B 的回调触发时光标还没更新，
   *   仍然紧邻 A，于是又切了一次 A。
   * 所以这里只挂起，等落定信号统一结算。
   */
  onTodoMarkTap() {
    this.pendingTodoTap = true;
    this.pendingTapCaret = this.contentController.getCaretOffset();
    // 超时兜底：光标本来就落在"落定位置"时，框架不会触发 onSelectionChange（实测有这种情况），
    // 这时等不到事件，按点击时的光标结算 —— 光标一直没动，说明它正是落定位置。
    // 若它已经动过，说明落定事件在路上（或已处理），交给 onSelectionChange，这里什么都不做
    setTimeout(() => {
      if (this.pendingTodoTap && this.contentController.getCaretOffset() === this.pendingTapCaret) {
        this.settleTodoTap(this.pendingTapCaret);
      }
    }, TODO_TAP_SETTLE_MS);
  }

  /** 选区 / 光标落定（组件上的 onSelectionChange） */
  onSelectionChange(range: RichEditorRange) {
    this.settleTodoTap(range.start ?? -1);
  }

  /** 结算一次点击。pendingTodoTap 保证同一次点击只结算一次 —— 先到的那个说了算 */
  private settleTodoTap(caret: number) {
    if (!this.pendingTodoTap) {
      return;
    }
    this.pendingTodoTap = false;
    const hit = this.todoMarkNearCaret(caret);
    if (hit !== undefined) {
      this.toggleTodoMark(hit);
    }
  }

  /** position 处是不是待办勾选框；是则返回它的名称 */
  private todoMarkAt(position: number): string | undefined {
    if (position < 0) {
      return undefined;
    }
    const spans = this.contentController.getSpans({ start: position, end: position + 1 });
    for (const span of spans) {
      const name = builtinImageNameOf(span);
      if (name !== undefined && toggledTodoMark(name) !== undefined
        && span.spanPosition.spanRange[0] === position) {
        return name;
      }
    }
    return undefined;
  }

  /** 找紧邻光标（前一格或后一格）的待办勾选框；两侧都认，理由见 onTodoMarkTap */
  private todoMarkNearCaret(caret: number): TodoMarkHit | undefined {
    if (caret < 0) {
      return undefined;
    }
    const spans = this.contentController.getSpans({ start: Math.max(0, caret - 1), end: caret + 1 });
    for (const span of spans) {
      const name = builtinImageNameOf(span);
      if (name === undefined || toggledTodoMark(name) === undefined) {
        continue;
      }
      const range = span.spanPosition.spanRange;
      if (range[1] === caret || range[0] === caret) {
        return { offset: range[0], name: name };
      }
    }
    return undefined;
  }

  /**
   * 切换勾选状态：换图（圆环 ↔ 勾）+ 该行文字变灰 / 复原。
   *
   * RichEditor 没有"更新图片 span"的 API，所以换图 = 删掉旧图 + 在原位置插新图。
   * 勾选框占 1 个坐标单位，删一插一，后面的内容不会移位。
   */
  private toggleTodoMark(hit: TodoMarkHit) {
    const nextName = toggledTodoMark(hit.name);
    if (nextName === undefined) {
      return;
    }
    const resource = builtinImageResource(nextName);
    if (!resource) {
      console.error(`Unknown builtin image: ${nextName}`);
      return;
    }
    try {
      this.contentController.deleteSpans({ start: hit.offset, end: hit.offset + 1 });
      this.contentController.addImageSpan(resource, {
        offset: hit.offset,
        imageStyle: builtinImageStyle(),
        gesture: {
          onClick: () => {
            this.onTodoMarkTap();
          },
        },
      });
      // 变灰作用于勾选框之后、本行末尾之前的全部文字
      const line = this.todoTextRange(hit.offset);
      const textStart = line.start ?? hit.offset + 1;
      const textEnd = line.end ?? textStart;
      if (textEnd > textStart) {
        this.applyDoneStyle(textStart, textEnd, nextName === TODO_MARK_DONE);
      }
    } catch (error) {
      console.error(`Failed to toggle todo mark. Cause: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 勾选框所在那一行剩余文字的区间：[勾选框后一格, 第一个换行符)。
   *
   * 这里**刻意不用 getParagraphRange 取末尾**，两个原因：
   *   ① 实测段落以勾选框开头时，getParagraphs() 报的段首会落在勾选框【之后】，
   *      段落边界并不能直接当"这一行的范围"用（insertTodoMark 里也踩了同一个坑）
   *   ② 待办为空行时（一行只有一个勾选框），按段尾取会把下一行的文字一并算进来
   */
  private todoTextRange(markOffset: number): RichEditorRange {
    const start = markOffset + 1;
    let end = start;
    for (const span of this.contentController.getSpans()) {
      const range = span.spanPosition.spanRange;
      if (range[1] <= start) {
        continue;
      }
      const textSpan = span as RichEditorTextSpanResult;
      if (textSpan.textStyle === undefined) {
        end = Math.max(end, range[1]); // 图片：整格跨过去
        continue;
      }
      // 找到这一行末尾的换行就收工
      const breakAt = textSpan.value.indexOf('\n', Math.max(start, range[0]) - range[0]);
      if (breakAt >= 0) {
        return { start: start, end: range[0] + breakAt };
      }
      end = Math.max(end, range[1]);
    }
    return { start: start, end: end }; // 没有换行 = 这一行一直到文档末尾
  }

  /**
   * 已完成 / 未完成的文字外观：[start, end) 内的文字变灰或复原。
   *
   * 颜色怎么算是 `doneTextColor` 的事（具体色值只改 alpha、主题色换成已知的灰，
   * 两种都能精确还原，不会把用户自己设的颜色冲掉）—— 这里只负责**逐 span 应用**。
   *
   * 逐 span 而不是整段设一个色：一行里可能混着不同颜色的 span，
   * 每个都得按它自己的原色去变灰 / 还原。
   */
  private applyDoneStyle(start: number, end: number, done: boolean) {
    const spans = this.contentController.getSpans({ start: start, end: end });
    for (const span of spans) {
      const range = span.spanPosition.spanRange;
      const textSpan = span as RichEditorTextSpanResult;
      if (textSpan.textStyle === undefined) {
        continue;
      }
      const from = Math.max(start, range[0]);
      const to = Math.min(end, range[1]);
      if (to <= from) {
        continue;
      }
      this.contentController.updateSpanStyle({
        textStyle: { fontColor: doneTextColor(textSpan.textStyle.fontColor, done) },
        start: from,
        end: to,
      });
    }
  }

  /**
   * 恢复初始状态
   */
  initState() {
    this.colorIdx = 0;
    this.isBold = false;
    this.isItalics = false;
    this.isUnderline = false;
    this.isHandWrite = false;
    this.alignStyle = TextAlign.Start;
    this.handwriteController = new HandwriteController();
  }

  private async selectPhoto(): Promise<Array<string> | undefined> {
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.isPhotoTakingSupported = true;
      options.isSearchSupported = true;
      options.isEditSupported = true;
      options.maxSelectNumber = 1;

      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const photoSelectResult = await photoPicker.select(options);
      if (photoSelectResult && photoSelectResult.photoUris && photoSelectResult.photoUris.length > 0) {
        return photoSelectResult.photoUris;
      }
      return undefined;
    } catch (error) {
      console.error(`Failed to select photo. Cause: ${JSON.stringify(error)}`);
      throw new Error(error);
    }
  }

  private loadImage(uri: string): image.PixelMap {
    let imageSource: image.ImageSource | undefined;
    let imageFile: fileIo.File | undefined;
    try {
      imageFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(imageFile.fd);
      // 按最长边上限降采样解码：编辑器从此刻起就持有小图，保存时自然编码小图
      const imageInfo = imageSource.getImageInfoSync();
      const desiredSize = calcDesiredSize(imageInfo.size.width, imageInfo.size.height);
      return imageSource.createPixelMapSync(desiredSize ? { desiredSize: desiredSize } : undefined);
    } catch (error) {
      console.error(`Failed to create pixelmap when load image. Cause: ${JSON.stringify(error)}`);
      throw new Error(error);
    } finally {
      if (imageSource) {
        imageSource.release();
      }
      if (imageFile) {
        fileIo.close(imageFile)
          .catch((err: BusinessError) => {
            console.error(`Failed to close image file ${imageFile?.path}. Cause: ${JSON.stringify(err)}`);
          });
      }
    }
  }

  /**
   * 插入相册照片。
   *
   * 照片必须**单独成段**：图片前一个单元、后一个单元都得是换行符。
   * 所以这里不是无脑补两个 '\n'，而是先看插入点左右已有的邻居，缺哪个补哪个 ——
   * 本来就有换行的地方（比如插在空行上）再补一个会多出空段落；
   * 而在段落中间只补一个，图片又会和文字挤在同一行。
   *
   * 两个判定都在【变更前】的文档上一次算完：补完前置换行后，原 caret 处的字符
   * 正好落到图片右边一格，所以"原 caret 处是不是换行"就等价于"最终图片后面是不是换行"。
   */
  private addImage(pixelMap: image.PixelMap, uiContext: UIContext) {
    // "补换行 + 插图"是同一次用户操作，用原子区间合成一条历史记录，
    // 否则撤销一次只会退掉其中一步
    this.beginAtomic();
    try {
      // 获取当前光标位置：有选区时也在光标处插入，不动选中内容（与插入内置图片一致）
      const caret = this.contentController.getCaretOffset();
      // 取全量 span：文末插入时区间 [caret-1, caret+1) 会越过文档末尾，
      // 全量调用没有越界风险；插图频率极低，多返回几个 span 无所谓
      const spans = this.contentController.getSpans();
      // 前置：左边是普通字符或图片才要补（'newline' 已经有了，'boundary' 是文档开头）
      const needLeading = neighborAt(spans, caret - 1) === 'other';
      // 后置：'newline' 说明已经有换行，'other'（文字/图片）和 'boundary'（文末）都要补，
      // 保证图片后面永远另起一行、光标有处可落
      const needTrailing = neighborAt(spans, caret) !== 'newline';

      let imageOffset = caret;
      if (needLeading) {
        const beforeSpan = textSpanAt(spans, caret - 1);
        const beforeParagraph = beforeSpan ? beforeSpan.paragraphStyle : undefined;
        this.contentController.addTextSpan('\n', {
          offset: caret,
          // 这个换行是并进【前一段】的，样式必须跟前一段一致：样式不同就不会与前一段合并，
          // 前一段有被拆成两段、对齐方式跟着漂移的风险。
          // 左边是图片（取不到文本样式）时回落输入样式
          style: beforeSpan ? textStyleResult2Style(beforeSpan.textStyle) : this.effectiveTypingStyle(uiContext),
          paragraphStyle: beforeParagraph ? { textAlign: beforeParagraph.textAlign } : undefined,
        });
        imageOffset += 1;
      }

      // 添加图片（样式与撤销/重做共用同一个函数）
      this.contentController.addImageSpan(pixelMap, {
        offset: imageOffset,
        imageStyle: this.imageStyleForFile(pixelMap, uiContext),
      });

      if (needTrailing) {
        // 后置换行开启的是图片【之后】那一段，用输入样式。
        // 必须显式给样式并做字体缩放换算，否则这个换行 span 会带上"未缩放"的字号，
        // 既让它自己的行高与正文不一致，也会被撤销/重做的"继承变更点样式"逻辑取走并传播出去
        this.contentController.addTextSpan('\n', {
          offset: imageOffset + 1,
          style: this.effectiveTypingStyle(uiContext),
        });
      }

      // 图片后面必然是一个换行（刚补的，或原本就有的），光标落到它之后 ——
      // 也就是图片下方那一行的行首，用户可以接着输入
      this.contentController.setCaretOffset(imageOffset + 2);
      // 以上几步都会被 onWillChange 自动捕获，并由原子区间合并成一条记录
    } catch (error) {
      console.error(`Failed to add image to styled string. Cause: ${JSON.stringify(error)}`);
    } finally {
      this.endAtomic();
    }
  }

  /**
   * 插入文件附件（行内 chip，不落盘）。
   *
   * 【为什么需要 buildChip 这个参数】`addBuilderSpan` 只接受零参的 `CustomBuilder`，
   * 而每个 chip 的内容（文件名）和点击回调都不一样，数据只能靠**词法捕获**带进去；
   * 又因为 builder 必须在组件作用域里构造（要闭包组件的 this、要有 UI 上下文），
   * 所以只能由组件造好一个零参闭包再交进来。控制器不构造它，只当不透明的值转交。
   *
   * @param buildChip 组件提供的工厂：给出文件信息，返回该 chip 的 CustomBuilder
   *
   * ⚠️ **绝不要把 buildChip / 造出的 CustomBuilder / FileChipInfo 存进控制器的字段。**
   *    本类是单例（`instance`），比 MemoEditorArea（每个 NavDestination 重建一次）活得久 ——
   *    存下来会把组件实例一起吊住：既泄漏，闭包里的 this 又变成已销毁的组件。
   */
  insertFile(uiContext: UIContext, buildChip: (info: FileChipInfo) => CustomBuilder): void {
    this.selectDocument(uiContext)
      .then((uris) => {
        if (!uris || uris.length < 1) {
          return;
        }
        // 先拷进沙箱：picker 的临时授权转授不出去，直接拿它打开会让目标应用读不到内容
        const info = this.copyToSandbox(uris[0], uiContext);
        if (info === undefined) {
          return; // 失败原因已在 copyToSandbox 内部打过日志
        }

        // 在真正插入的那一刻才造 builder：提前造好而中途页面被销毁的话，
        // 闭包里捕获的就是一个死组件
        this.addFileChip(buildChip(info), info.relativePath, uiContext);
      })
      .catch((error: BusinessError) => {
        // selectPhoto 那条链缺这一层 catch（既有问题，不动它）；新代码补上
        console.error(`[file] 选择文件失败: ${JSON.stringify(error)}`);
      });
  }

  /**
   * 用系统应用打开附件。
   *
   * action 用**字面量**而不是常量：stage model 的 `wantConstant` 里没有 Action 枚举，
   * 唯一的 `ACTION_VIEW_DATA` 定义在 `@ohos.ability.wantConstant`，那个已 @deprecated since 9。
   *
   * `FLAG_AUTH_READ_URI_PERMISSION` 必须带：目标应用对我们的沙箱文件没有权限，
   * 得把读权限显式转授过去。只要读权限 —— 仅查看。
   *
   * ⚠️ **只有沙箱副本转授得出去**：picker 返回的 URI 那种临时授权是不能再次转移的，
   * 直接拿它调 startAbility 会让目标应用被拉起来了却打不开（见 copyToSandbox 的注释）。
   */
  openFile(info: FileChipInfo, uiContext: UIContext): void {
    const context = uiContext.getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      console.error('[file] 取不到 host context，无法打开文件');
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: info.uri,
      type: info.mimeType,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
    };
    context.startAbility(want)
      .catch((error: BusinessError) => {
        // 常见码：16000018（不允许跳第三方）、16000019（没有能处理该类型的应用）
        console.error(`[file] 打开文件失败: ${info.name}. Cause: ${JSON.stringify(error)}`);
      });
  }

  /** 选文件。与 selectPhoto 同一套路，换成 DocumentViewPicker；不需要任何权限 */
  private async selectDocument(uiContext: UIContext): Promise<Array<string> | undefined> {
    const context = uiContext.getHostContext();
    if (context === undefined) {
      console.error('[file] 取不到 host context，无法拉起文件选择器');
      return undefined;
    }
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    // selectMode 不设：它的 syscap 是 FolderSelection（2in1 专属），手机上调不到；
    // 默认值就是 FILE，正是我们要的
    // fileSuffixFilters 不设 = 不限类型。将来要白名单在这里加
    const documentPicker = new picker.DocumentViewPicker(context);
    return await documentPicker.select(options);
  }

  /** URI → 显示名。`FileUri.name` 是 getter 且会抛（BusinessError），必须包起来 */
  private displayNameOf(uri: string): string {
    let name = '';
    try {
      name = new fileUri.FileUri(uri).name;
    } catch (error) {
      console.error(`[file] 解析文件名失败: ${uri}. Cause: ${JSON.stringify(error)}`);
    }
    if (!name) {
      // 兜底：取 URI 末段
      const slash = uri.lastIndexOf('/');
      name = slash >= 0 ? uri.substring(slash + 1) : uri;
    }
    // 这个名字会直接当作沙箱路径的末段，必须挡掉路径分隔符；
    // 再空就退一个固定名，否则会拼出 `memo_files/<uuid>/` 这种以目录结尾的路径
    name = name.replaceAll('/', '_').replaceAll('\\', '_');
    return name === '' ? DEFAULT_ATTACHMENT_NAME : name;
  }

  /**
   * 把选中的文件复制进应用沙箱，返回插入 chip 所需的信息。
   *
   * 【为什么必须复制】`DocumentViewPicker` 返回的 URI，应用只拿到**临时授权**，
   * 而这个授权**不能再次转移**给第三方应用 —— 而 `openFile` 里的
   * FLAG_AUTH_READ_URI_PERMISSION 要做的恰恰是把它转授出去。真机实测表现为：
   * 目标应用被拉起来了，但显示"预览失败"（读不到内容）。
   * 拷进沙箱后我们就是文件的所有者，转授自己的文件没有任何限制。
   *
   * 【目录形态】`memo_files/<uuid>/<原文件名>` 而不是 `memo_files/<uuid>.<后缀>`：
   * 目标应用标题栏显示的是 URI 末段的文件名，用 uuid 当文件名会让它在对方应用里
   * 显示成乱码；套一层 uuid 目录既能保住原名，又避免两个同名附件互相覆盖。
   */
  private copyToSandbox(uri: string, uiContext: UIContext): FileChipInfo | undefined {
    const name = this.displayNameOf(uri);
    const context = uiContext.getHostContext();
    if (context === undefined) {
      console.error('[file] 取不到 host context，无法复制附件');
      return undefined;
    }
    // uuid 既是目录名，也是附件的**持久化身份**（存进 MemoBlock.value），所以不能就地丢弃
    const uuid = util.generateRandomUUID();
    const dir = `${context.filesDir}/${ATTACHMENT_DIR_NAME}/${uuid}`;
    const dest = `${dir}/${name}`;
    let srcFile: fileIo.File | undefined;
    try {
      fileIo.mkdirSync(dir, true);
      srcFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      fileIo.copyFileSync(srcFile.fd, dest);
    } catch (error) {
      console.error(`[file] 复制附件失败: ${name}. Cause: ${JSON.stringify(error)}`);
      return undefined;
    } finally {
      if (srcFile) {
        try {
          fileIo.closeSync(srcFile);
        } catch (error) {
          console.error(`[file] 关闭附件源文件失败: ${name}. Cause: ${JSON.stringify(error)}`);
        }
      }
    }
    return {
      uri: fileUri.getUriFromPath(dest),
      name: name,
      mimeType: mimeOfFileName(name),
      relativePath: `${uuid}/${name}`,
    };
  }

  /**
   * 插入一个文件 chip，并保证它**独占一段**（前后都是换行）—— 与相册照片同一类约束。
   *
   * 骨架照抄 `addImage`：先看插入点两侧已有的邻居，缺哪个补哪个，而不是无脑补两个换行
   *（本来就在空行上、再补一个会多出空段落）。两边的**判定与补法完全一致**，
   * 只是插入 API 不同（`addBuilderSpan` 要显式 offset）。
   *
   * 【为什么包 beginAtomic】"补前换行 + 插 chip + 补尾换行"是一次用户操作。
   * 不合并的话，两条换行的记录会各自独立，撤销一次只退掉其中一个，chip 变成行内、
   * 下次编辑又被修复路径补回来 —— 表现为"撤销按了没反应"。
   * 这是"新功能不为撤销/重做做适配"约定的一次**有意破例**：理由是这样合并与既有
   * `addImage` 的行为一致，而不是为新功能发明新机制。
   *
   * @param relativePath 附件在 memo_files 下的相对路径，登记进侧表供持久化使用
   */
  private addFileChip(chip: CustomBuilder, relativePath: string, uiContext: UIContext) {
    this.beginAtomic();
    try {
      const caret = this.contentController.getCaretOffset();
      if (caret < 0) {
        console.error('[file] 光标位置无效，取消插入附件');
        return;
      }
      // 取全量 span：文末插入时区间 [caret-1, caret+1) 会越过文档末尾，全量调用没有越界风险
      const spans = this.contentController.getSpans();
      // 前置：左边是普通字符或图片才要补（'newline' 已经有了，'boundary' 是文档开头）
      const needLeading = neighborAt(spans, caret - 1) === 'other';
      // 后置：'newline' 说明已经有换行；'other'（文字 / 图片 / 另一个 chip）和
      // 'boundary'（文末）都要补，保证 chip 后面永远另起一行、光标有处可落
      const needTrailing = neighborAt(spans, caret) !== 'newline';

      let chipOffset = caret;
      if (needLeading) {
        const beforeSpan = textSpanAt(spans, caret - 1);
        const beforeParagraph = beforeSpan ? beforeSpan.paragraphStyle : undefined;
        this.contentController.addTextSpan('\n', {
          offset: caret,
          // 这个换行是并进【前一段】的，样式必须跟前一段一致：样式不同就不会与前一段合并，
          // 前一段有被拆成两段、对齐方式跟着漂移的风险。
          // 左边是图片 / chip（取不到文本样式）时回落输入样式
          style: beforeSpan ? textStyleResult2Style(beforeSpan.textStyle) : this.effectiveTypingStyle(uiContext),
          paragraphStyle: beforeParagraph ? { textAlign: beforeParagraph.textAlign } : undefined,
        });
        chipOffset += 1;
      }

      this.contentController.addBuilderSpan(chip, { offset: chipOffset });

      if (needTrailing) {
        // 后置换行开启的是 chip【之后】那一段，用输入样式。
        // 必须显式给样式并做字体缩放换算，否则这个换行 span 会带上"未缩放"的字号，
        // 既让它自己的行高与正文不一致，也会被撤销/重做的"继承变更点样式"逻辑取走并传播出去
        this.contentController.addTextSpan('\n', {
          offset: chipOffset + 1,
          style: this.effectiveTypingStyle(uiContext),
        });
      }

      // 光标落到 chip 下方那一行的行首，用户可以接着输入（与 addImage 一致）
      this.contentController.setCaretOffset(chipOffset + 2);

      this.registerAttachment(chipOffset, relativePath);
      // 以上几步都会被 onWillChange 自动捕获，并由原子区间合并成一条记录
    } catch (error) {
      console.error(`[file] 插入附件失败: ${JSON.stringify(error)}`);
    } finally {
      this.endAtomic();
    }
  }

  /**
   * 把新插入的 chip 登记进附件侧表。
   *
   * ⚠️ 位置**以框架实际放置的结果为准**，不靠推算：插入 chip 本身不触发内容回调（实测），
   * 落在哪一格没有直接信号，索性插完读回来。
   *
   * ⚠️ **必须插到数组的正确位置，不能 push。** 侧表的数组顺序就是文档顺序，
   * 而新 chip 可能插在已有附件的**前面** —— 那些条目还占着靠前的位置，push 会把新条目
   * 排到它们后面，于是"第 k 个 chip ↔ 第 k 条记录"整个错位，表现是两个附件保存后**对调**。
   */
  private registerAttachment(chipOffset: number, relativePath: string) {
    const observed = this.builderSpanOffsets();
    const newIndex = observed.indexOf(chipOffset);
    if (newIndex < 0) {
      console.error(`[file] 插入后没在 ${JSON.stringify(observed)} 中找到坐标 ${chipOffset}，侧表可能失准`);
    }
    let insertAt = this.attachments.length;
    if (newIndex >= 0) {
      insertAt = newIndex;
    } else {
      // 兜底：按 offset 有序插入
      for (let i = 0; i < this.attachments.length; i++) {
        if (this.attachments[i].offset >= chipOffset) {
          insertAt = i;
          break;
        }
      }
    }
    this.attachments.splice(insertAt, 0, { offset: chipOffset, relativePath: relativePath });
    // 统一按观察到的真实坐标校正一遍：同时消掉"兜底推算准不准"与
    // "补换行产生的回调有没有重复平移"两个不确定性
    this.syncAttachmentOffsets();
  }
}