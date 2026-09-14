import { AlignmentInfo } from '../model/AlignmentInfo';
import { builtinImageResource, builtinImageStyle, calcDesiredSize } from '../model/Memo';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { ChangeRecord, SpanSnapshot } from '../model/ChangeRecord';
import { clipSpans, spansTotalLength, textStyleResult2Style, toSnapshots } from '../model/SpanMapping';
import { display } from '@kit.ArkUI';
import { COLOR_LIST, DEFAULT_FONT_SIZE } from '../common/Constants';
// ==== 撤销/重做探针：临时引用，验证完删除 ====
import { probeProgrammatic } from '../common/UndoProbe';

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

    // P1 不支持图片：含图则清空历史。
    // 图片会改变后续记录的坐标，跳过不记会导致撤销落到错误的位置 —— 宁可历史从头开始，也不能出错
    if (record.hasImage()) {
      console.info('[undo] 变更涉及图片，P1 阶段清空历史');
      this.resetHistory();
      return;
    }
    this.pushRecord(record);
  }

  /** 撤销 */
  unDo() {
    if (this.isRestoring || this.currRecordIdx < 1) {
      return;
    }
    const record = this.historyRecords[this.currRecordIdx];
    this.isRestoring = true;
    try {
      this.applyRecord(record, true);
      this.currRecordIdx -= 1;
    } catch (error) {
      console.error(`[undo] 撤销失败: ${JSON.stringify(error)}`);
    } finally {
      this.isRestoring = false;
    }
  }

  /** 重做 */
  reDo() {
    if (this.isRestoring || this.currRecordIdx >= this.historyLength - 1) {
      return;
    }
    const record = this.historyRecords[this.currRecordIdx + 1];
    this.isRestoring = true;
    try {
      this.applyRecord(record, false);
      this.currRecordIdx += 1;
    } catch (error) {
      console.error(`[undo] 重做失败: ${JSON.stringify(error)}`);
    } finally {
      this.isRestoring = false;
    }
  }

  /** 记录入栈，并截断"未来"（撤销后再编辑会让重做栈失效） */
  private pushRecord(record: ChangeRecord) {
    if (this.currRecordIdx < this.historyRecords.length - 1) {
      this.historyRecords.splice(this.currRecordIdx + 1);
    }
    this.historyRecords.push(record);
    this.historyLength = this.historyRecords.length;
    this.currRecordIdx = this.historyRecords.length - 1;
  }

  /**
   * 把记录的一侧应用到编辑器。
   *
   * 顺序必须是"先删后插"：先删掉对侧占用的整个范围，再把本侧内容插到本侧起点；
   * 反过来先插会把后面的坐标整体右移。
   */
  private applyRecord(record: ChangeRecord, useBefore: boolean) {
    const removeStart = useBefore ? record.afterStart : record.beforeStart;
    const removeLength = spansTotalLength(useBefore ? record.afterSpans : record.beforeSpans);
    const insertStart = useBefore ? record.beforeStart : record.afterStart;
    const spans = useBefore ? record.beforeSpans : record.afterSpans;
    const caret = useBefore ? record.changeStart : record.caretAfter;

    // ==== 诊断日志（P5 清理）：把实际执行的删除区间与插入内容打出来 ====
    console.info(`[undo] ${useBefore ? '撤销' : '重做'}: 删除 [${removeStart}, ${removeStart + removeLength}) `
      + `→ 在 ${insertStart} 插入 ${spans.length} 段，光标 ${caret}`);
    for (let i = 0; i < spans.length; i++) {
      const span = spans[i];
      const raw = span.value;
      const shown = raw.length > 24 ? `${raw.substring(0, 24)}...` : raw;
      console.info(`[undo]   span[${i}] len=${span.length} `
        + `fontSize=${span.textStyle?.fontSize} fontWeight=${span.textStyle?.fontWeight} `
        + `lineHeight=${span.textStyle?.lineHeight} para=${JSON.stringify(span.paragraphStyle)} `
        + `value="${shown.replace(/\n/g, '\\n')}"`);
    }

    if (removeLength > 0) {
      this.contentController.deleteSpans({ start: removeStart, end: removeStart + removeLength });
    }
    this.insertSpans(spans, insertStart);
    this.contentController.setCaretOffset(caret);
  }

  /** 按顺序把一组快照插回编辑器。游标用快照自带的 length 推进，不依赖 span 之间无缝衔接 */
  private insertSpans(spans: Array<SpanSnapshot>, start: number) {
    let cursor = start;
    for (const span of spans) {
      if (span.kind === 'text') {
        this.contentController.addTextSpan(span.value, {
          offset: cursor,
          style: span.textStyle,
          paragraphStyle: span.paragraphStyle,
        });
      } else {
        // P1 不产生图片快照；含图的记录在入栈前就被拦掉了
        console.error('[undo] 遇到图片快照，P1 阶段不支持');
      }
      cursor += span.length;
    }
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
    probeProgrammatic('updateTextStyle (含 setTypingStyle + updateSpanStyle)');   // 探针
    // 获取选中内容的范围
    const selection = this.contentController.getSelection();
    const start = selection.selection[0] ?? 0;
    const end = selection.selection[1] ?? 0;
    // 无论有无选区，都让"后续输入样式"跟随工具栏状态
    this.applyTypingStyle();
    if (start < 0 || end <= start) {
      // 无选区：样式作用于此后输入的内容，已有内容不变
      return;
    }
    // 更新文本样式
    this.contentController.updateSpanStyle({
      textStyle: textStyle,
      start: start,
      end: end,
    });
    // 样式变更不记录历史：它不改变文本长度，跳过不影响后续记录的坐标，是安全的。
    // 若实测发现 updateSpanStyle 也会触发 onWillChange/onDidChange，撤销链路会自动覆盖它（P4 验证）
  }

  /**
   * 设置段落对齐方式
   */
  updateParagraphStyle(paragraphStyle: RichEditorParagraphStyle) {
    probeProgrammatic('updateParagraphStyle');   // 探针
    // 获取选中内容的范围
    const selection = this.contentController.getSelection();
    // 当未选中内容时，计算当前段落起始范围
    const pRange = this.getParagraphRange(selection.selection[0] ?? 0, selection.selection[1] ?? 0);
    // 获取指定范围的段落信息
    this.contentController.updateParagraphStyle({
      style: paragraphStyle,
      start: pRange.start,
      end: pRange.end,
    });
    // 段落对齐属于 P4 范围：它的恢复必须走 updateParagraphStyle，
    // 用"删了重插"会拆开/合并段落
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
      probeProgrammatic('insertBuiltinImage/addImageSpan');   // 探针
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
    try {
      // 获取图片信息
      const info = pixelMap.getImageInfoSync();
      let width = uiContext.px2vp(info.size.width);
      let height = uiContext.px2vp(info.size.height);
      // 宽度超过最大尺寸时，等比例缩放
      const displayWidth = uiContext.px2vp(display.getDefaultDisplaySync().width) * 0.9;
      if (width > displayWidth) {
        height = height * (displayWidth / width);
        width = displayWidth;
      }
      // 获取当前光标位置
      const caretOffset = this.contentController.getCaretOffset();
      // 图片选项
      const imageSpanOptions: RichEditorImageSpanOptions = {
        offset: caretOffset,
        imageStyle: {
          size: [width, height],
          objectFit: ImageFit.Auto,
          layoutStyle: { borderRadius: 12, margin: { top: 12, bottom: 12 } },
        }
      };
      // 添加图片
      probeProgrammatic('addImage/addImageSpan + addTextSpan');   // 探针
      this.contentController.addImageSpan(pixelMap, imageSpanOptions);
      // 在图片后插入一行（图片独占一个段落）
      this.contentController.addTextSpan('\n', { offset: caretOffset + 1 });
      // 这里的两步都会被 onWillChange/onDidChange 自动捕获，无需手动记录。
      // 注意：它们会产生【两条】独立记录，撤销一次只退一步 —— P3 需要把这类多步操作合成一条
    } catch (error) {
      console.error(`Failed to add image to styled string. Cause: ${JSON.stringify(error)}`);
    }
  }
}