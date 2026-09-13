import { AlignmentInfo } from '../model/AlignmentInfo';
import { builtinImageResource, builtinImageStyle, calcDesiredSize } from '../model/Memo';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { ChangeRecord } from '../model/ChangeRecord';
import { display } from '@kit.ArkUI';
import { COLOR_LIST, DEFAULT_FONT_SIZE } from '../common/Constants';

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
  // 指向当前操作记录
  @Trace currRecordIdx: number = -1;
  // 用户操作记录历史
  @Trace historyRecords: Array<ChangeRecord> = [];
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

  /**
   * 撤销
   */
  unDo() {
    if (this.currRecordIdx < 1) {
      return;
    }
    // this.contentController.setStyledString(this.historyRecords[--this.currRecordIdx].styledString);
    // todo
  }

  /**
   * 重做
   */
  reDo() {
    if (this.currRecordIdx >= this.historyRecords.length - 1) {
      return;
    }
    // this.contentController.setStyledString(this.historyRecords[++this.currRecordIdx].styledString);
    // todo
  }

  /**
   * 增加操作记录
   */
  addHistoryRecord(styledString: MutableStyledString) {
    // this.historyRecords = this.historyRecords.slice(0, ++this.currRecordIdx);
    // this.historyRecords.push(new ChangeRecord(styledString));
    // todo
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
    // 添加操作记录历史
    // this.addHistoryRecord(styledString);
    // todo
  }

  /**
   * 设置段落对齐方式
   */
  updateParagraphStyle(paragraphStyle: RichEditorParagraphStyle) {
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

    // 添加操作记录历史
    // this.addHistoryRecord(styledString);
    // todo
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
      this.contentController.addImageSpan(pixelMap, imageSpanOptions);
      // 在图片后插入一行（图片独占一个段落）
      this.contentController.addTextSpan('\n', { offset: caretOffset + 1 });
      // 添加操作记录历史
      // this.addHistoryRecord(styledString);
      // todo
    } catch (error) {
      console.error(`Failed to add image to styled string. Cause: ${JSON.stringify(error)}`);
    }
  }
}