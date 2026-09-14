import { AlignmentInfo } from '../model/AlignmentInfo';
import { builtinImageResource, builtinImageStyle, calcDesiredSize } from '../model/Memo';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { ChangeRecord, SpanSnapshot } from '../model/ChangeRecord';
import { clipSpans, spansTotalLength, textStyleResult2Style, toSnapshots } from '../model/SpanMapping';
import { display } from '@kit.ArkUI';
import { COLOR_LIST, DEFAULT_FONT_SIZE } from '../common/Constants';
// ==== 撤销/重做探针：临时引用，验证完删除 ====
import { probeProgrammatic } from '../common/UndoProbe';

// 相册照片的固定样式参数（插入与撤销/重做共用，改这里两边一起生效）
const FILE_IMAGE_BORDER_RADIUS = 12;
const FILE_IMAGE_VERTICAL_MARGIN = 12;

// 连续同类编辑动作合并成一条历史的时间窗（毫秒）。超过则视为两次独立操作
const MERGE_WINDOW_MS = 500;
// 历史上限：超出后从最早的记录开始丢弃
const MAX_HISTORY_RECORDS = 100;

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
    const imageSpan = span as RichEditorImageSpanResult;
    if (imageSpan.imageStyle === undefined) {
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
  // 当前文本颜色
  @Trace colorIdx: number = 0;
  // 当前文本是否加粗
  @Trace isBold: boolean = false;
  // 当前文本是否斜体
  @Trace isItalics: boolean = false;
  // 当前文本是否下划线
  @Trace isUnderline: boolean = false;
  // 当前字体大小
  @Trace fontSize: number = DEFAULT_FONT_SIZE;
  // 当前段落对齐样式
  @Trace alignStyle: TextAlign = TextAlign.Start;
  // 显示的扩展工具栏索引号 0-关闭扩展工具栏 1-显示调色板 2-显示段落样式选项栏
  @Trace showToolBarIndex: number = 0;
  // 指向当前生效的历史记录下标。0 是"初始基线"，不可撤销回去
  @Trace currRecordIdx: number = -1;
  // 历史长度：单独暴露给 UI，驱动重做按钮的灰显
  @Trace historyLength: number = 0;
  // 用户操作记录历史。非 @Trace —— 避免大对象被 V2 观察机制包裹，UI 只看下标与长度
  private historyRecords: Array<ChangeRecord> = [];
  // 正在执行撤销 / 重做：程序化调用会【同步】触发内容变更回调，期间必须忽略它们
  private isRestoring: boolean = false;
  // 原子区间嵌套深度：大于 0 时，期间捕获的多条记录会合并成一条
  private atomicDepth: number = 0;
  // 本原子区间第一条记录会落在的下标。原子合并只能发生在本次区间产生的记录之间 ——
  // 否则"插入图片"的原子块会把图片并进之前那条打字记录里，撤销时文字和图片一起消失
  private atomicStartIdx: number = 0;
  // 上一条记录产生的时间，用于判断是否落在合并时间窗内（0 表示没有可合并的上一条）
  private lastRecordTime: number = 0;
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
  }

  /** 开始一段不记录历史的操作（重建编辑器内容会触发大量变更回调，必须抑制） */
  suspendHistory() {
    this.isRestoring = true;
  }

  /** 结束不记录历史的状态，并重建基线 */
  resumeHistoryAndReset() {
    this.isRestoring = false;
    this.resetHistory();
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
    const rangeStart = value.rangeBefore.start ?? 0;
    const rangeEnd = value.rangeBefore.end ?? 0;

    // 新侧：框架给的就是「变更后的整 span」，无需裁剪
    const afterRaw: Array<RichEditorSpan> = [];
    for (const span of value.replacedSpans) {
      afterRaw.push(span);
    }
    for (const span of value.replacedImageSpans) {
      afterRaw.push(span);
    }
    afterRaw.sort((a, b) => a.spanPosition.spanRange[0] - b.spanPosition.spanRange[0]);

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
      const afterSpans: Array<SpanSnapshot> = rawAfterStart > record.beforeStart
        ? clipSpans(beforeRaw, record.beforeStart, rawAfterStart)
        : [];
      // 新内容的样式沿用变更点处的样式，不用 replacedSpans 自带的（原因见 styleAt 的注释）
      const inheritedStyle = styleAt(beforeRaw, rangeStart);
      // ==== 诊断日志（P5 清理） ====
      console.info(`[undo] 继承样式: ${inheritedStyle !== undefined
        ? `fontSize=${inheritedStyle.fontSize} lineHeight=${inheritedStyle.lineHeight}`
        : '(未找到 → 会沿用 replacedSpans 的原始样式)'} `
        + `; 变更点附近 span 数=${beforeRaw.length}`);
      for (const span of toSnapshots(afterRaw)) {
        if (span.kind === 'text' && inheritedStyle !== undefined) {
          span.textStyle = inheritedStyle;
        }
        afterSpans.push(span);
      }
      record.afterStart = record.beforeStart;
      record.afterSpans = afterSpans;
    }

    // 重做后的光标：变更结束处（估算）。插入时 = 变更起点 + 净增长度；删除时 = 变更起点
    const delta = spansTotalLength(record.afterSpans) - spansTotalLength(record.beforeSpans);
    record.caretAfter = rangeStart + (delta > 0 ? delta : 0);

    // ==== 诊断日志（P5 清理）：本条记录捕获到什么 ====
    let headInfo = '(空)';
    if (record.afterSpans.length > 0) {
      const head = record.afterSpans[0];
      headInfo = `kind=${head.kind} fontSize=${head.textStyle?.fontSize} len=${head.length}`;
    }
    console.info(`[undo] 捕获: changeStart=${rangeStart} 分支=${afterRaw.length === 0 ? '纯删除' : '插入'} `
      + `旧侧起点=${record.beforeStart} 旧侧长=${spansTotalLength(record.beforeSpans)} `
      + `新侧起点=${record.afterStart} 新侧长=${spansTotalLength(record.afterSpans)} 新侧首段(${headInfo})`);

    this.pushRecord(record);
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
      // ==== 诊断日志（P5 清理） ====
      console.info(`[undo] ${useBefore ? '撤销' : '重做'}字符样式: 范围 `
        + `[${record.beforeStart}, ${record.beforeStart + rangeLength}) 共 ${record.beforeSpans.length} 段`);
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
      // ==== 诊断日志（P5 清理） ====
      console.info(`[undo] ${useBefore ? '撤销' : '重做'}段落对齐: 范围 `
        + `[${record.beforeStart}, ${record.beforeStart + rangeLength}) 共 ${record.beforeSpans.length} 段`);
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

    // ==== 诊断日志（P5 清理）：把实际执行的删除区间与插入内容打出来 ====
    console.info(`[undo] ${useBefore ? '撤销' : '重做'}: 删除 [${removeStart}, ${removeStart + removeLength}) `
      + `→ 在 ${insertStart} 插入 ${spans.length} 段，光标 ${caret}`);
    for (let i = 0; i < spans.length; i++) {
      const span = spans[i];
      const raw = span.value;
      const shown = raw.length > 24 ? `${raw.substring(0, 24)}...` : raw;
      console.info(`[undo]   span[${i}] kind=${span.kind} len=${span.length} `
        + `fontSize=${span.textStyle?.fontSize} lineHeight=${span.textStyle?.lineHeight} `
        + `hasPixelMap=${span.imagePixelMap !== undefined} hasResource=${span.imageResource !== undefined} `
        + `value="${shown.replace(/\n/g, '\\n')}"`);
    }

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
   * 设置文本样式
   */
  updateTextStyle(textStyle: RichEditorTextStyle) {
    probeProgrammatic('updateTextStyle (含 setTypingStyle + updateSpanStyle)'); // 探针
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
    probeProgrammatic('updateParagraphStyle'); // 探针
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
   * 插入内置图片（行内小图标，不独占段落）
   */
  insertBuiltinImage(name: string, uiContext: UIContext) {
    const resource = builtinImageResource(name);
    if (!resource) {
      console.error(`Unknown builtin image: ${name}`);
      return;
    }
    try {
      const caretOffset = this.contentController.getCaretOffset();
      probeProgrammatic('insertBuiltinImage/addImageSpan'); // 探针
      this.contentController.addImageSpan(resource, {
        offset: caretOffset,
        imageStyle: builtinImageStyle(),
      });
    } catch (error) {
      console.error(`Failed to insert builtin image ${name}. Cause: ${JSON.stringify(error)}`);
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
    this.showToolBarIndex = 0;
    this.alignStyle = TextAlign.Start;
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

  private addImage(pixelMap: image.PixelMap, uiContext: UIContext) {
    // "插入图片" 与 "插入换行" 是同一次用户操作，用原子区间合成一条历史记录，
    // 否则撤销一次只会退掉其中一步（先删换行、再撤才删图片）
    this.beginAtomic();
    try {
      // 获取当前光标位置
      const caretOffset = this.contentController.getCaretOffset();
      // 添加图片（样式与撤销/重做共用同一个函数）
      probeProgrammatic('addImage/addImageSpan + addTextSpan'); // 探针
      this.contentController.addImageSpan(pixelMap, {
        offset: caretOffset,
        imageStyle: this.imageStyleForFile(pixelMap, uiContext),
      });
      // 在图片后插入一行（图片独占一个段落）。
      // 必须显式给样式并做字体缩放换算，否则这个换行 span 会带上"未缩放"的字号，
      // 既让它自己的行高与正文不一致，也会被撤销/重做的"继承变更点样式"逻辑取走并传播出去
      this.contentController.addTextSpan('\n', {
        offset: caretOffset + 1,
        style: this.effectiveTypingStyle(uiContext),
      });
      // 这两步都会被 onWillChange 自动捕获并合并成一条记录
    } catch (error) {
      console.error(`Failed to add image to styled string. Cause: ${JSON.stringify(error)}`);
    } finally {
      this.endAtomic();
    }
  }
}