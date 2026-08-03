import { display, LengthMetrics } from '@kit.ArkUI';
import { AlignmentInfo } from '../model/AlignmentInfo';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { ChangeRecord } from '../model/ChangeRecord';

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
  contentController: RichEditorStyledStringController = new RichEditorStyledStringController();
  // 当前文本颜色
  @Trace colorIdx: number = 0;
  // 当前文本是否加粗
  @Trace isBold: boolean = false;
  // 当前文本是否斜体
  @Trace isItalics: boolean = false;
  // 当前文本是否下划线
  @Trace isUnderline: boolean = false;
  // 当前字体大小
  @Trace fontSize: LengthMetrics = LengthMetrics.vp(16);
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
      icon: $r('app.media.ic_alignment_left'),
      value: TextAlign.Start,
    },
    {
      icon: $r('app.media.ic_alignment_center'),
      value: TextAlign.Center,
    },
    {
      icon: $r('app.media.ic_alignment_right'),
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
    this.contentController.setStyledString(this.historyRecords[--this.currRecordIdx].styledString);
  }

  /**
   * 重做
   */
  reDo() {
    if (this.currRecordIdx >= this.historyRecords.length - 1) {
      return;
    }
    this.contentController.setStyledString(this.historyRecords[++this.currRecordIdx].styledString);
  }

  /**
   * 增加操作记录
   */
  addHistoryRecord(styledString: MutableStyledString) {
    this.historyRecords = this.historyRecords.slice(0, ++this.currRecordIdx);
    this.historyRecords.push(new ChangeRecord(styledString));
  }

  /**
   * 当内容发生改变是，记录用户操作。
   */
  onContentChanged() {
    // 获得当前显示属性字符串
    const styledString = this.contentController.getStyledString();
    // 添加操作记录历史
    this.addHistoryRecord(styledString);
  }

  /**
   * 设置文本样式
   */
  setTextStyle(styledKey: StyledStringKey, styledValue: StyledStringValue) {
    const selection = this.contentController.getSelection();
    const start = selection.start ?? 0;
    const end = selection.end ?? 0;
    if (start < 0 || end <= start) {
      return;
    }

    // 获取当前显示的属性字符串
    const styledString = this.contentController.getStyledString();
    // 修改属性字符串样式
    try {
      styledString.setStyle({
        start: start,
        length: end - start,
        styledKey: styledKey,
        styledValue: styledValue,
      });
    } catch (error) {
      console.error(`Failed to invoke setStyle for styled string. Cause: ${JSON.stringify(error)}`);
      return;
    }
    // 将修改过后的属性字符串设置给富文本编辑组件显示
    this.contentController.setStyledString(styledString);
    // 重新设置选中状态
    this.contentController.setSelection(start, end);
    // 添加操作记录历史
    this.addHistoryRecord(styledString);
  }

  /**
   * 设置段落对齐方式
   */
  setParagraphStyle(paragraphStyle: ParagraphStyle) {
    // 获取当前显示的属性字符串
    const styledString = this.contentController.getStyledString();
    // 光标选中范围
    const selection = this.contentController.getSelection();
    // 段落移动范围
    const paragraphRange = this.getParagraphRange(selection.start ?? 0, selection.end ?? 0);
    // 修改属性字符串选中段落的对齐样式
    try {
      styledString.setStyle({
        start: paragraphRange.start,
        length: (paragraphRange.end ?? 0) - (paragraphRange.start ?? 0),
        styledKey: StyledStringKey.PARAGRAPH_STYLE,
        styledValue: paragraphStyle
      });
    } catch (error) {
      console.info(`Failed to invoke setStyle for paragraph style. Cause: ${JSON.stringify(error)}`);
      return;
    }
    // 将修改过的属性字符串设置给富文本编辑组件显示
    this.contentController.setStyledString(styledString);
    // 设置光标位置
    this.contentController.setCaretOffset(selection.start);
    // 设置选中范围
    this.contentController.setSelection(selection.start, selection.end);
    // 添加操作记录历史
    this.addHistoryRecord(styledString);
  }

  /**
   * 获取段落移动范围
   */
  getParagraphRange(start: number, end: number): RichEditorRange {
    // 当前显示文本内容
    const content = this.contentController.getStyledString().getString();

    if (start === end) {
      // 中间独占一行
      if (content.charAt(start - 1) === '\n' && content.charAt(end) === '\n') {
        return { start: start, end: start + 1 };
      }
      // 末尾独占一行
      if (content.charAt(start - 1) === '\n' && end === content.length) {
        return { start: start - 1, end: start };
      }
    }
    // 定位到段落开头
    while (content.charAt(start - 1) !== '\n' && start !== 0) {
      start--;
    }
    // 定位到段落结尾
    while (content.charAt(end) !== '\n' && end < content.length) {
      end++;
    }

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
      return imageSource.createPixelMapSync();
    } catch (error) {
      console.error(`Failed to create pixelmap when load image. Cause: ${JSON.stringify(error)}`);
      throw new Error(error);
    } finally {
      if (imageSource) {
        imageSource.release();
      }
      if (imageFile) {
        fileIo.closeSync(imageFile);
      }
    }
  }

  private addImage(pixelMap: image.PixelMap, uiContext: UIContext) {
    try {
      // 获取图片信息
      const info = pixelMap.getImageInfoSync();
      let width = info.size.width;
      let height = info.size.height;
      // 宽度超过最大尺寸时，等比例缩放
      const displayWidth = uiContext.px2vp(display.getDefaultDisplaySync().width) * 0.9;
      if (width > displayWidth) {
        width = displayWidth;
        height = width / info.size.width * height;
      }
      // 创建图片富文本对象
      const imageStyledString = new MutableStyledString(new ImageAttachment({
        value: pixelMap,
        objectFit: ImageFit.Auto,
        size: { width: width, height: height },
        layoutStyle: { borderRadius: LengthMetrics.vp(12), margin: { top: 12, bottom: 12 } },
      }));
      // 获取当前的富文本内容
      const styledString = this.contentController.getStyledString();
      // 获取当前光标位置
      const caretOffset = this.contentController.getCaretOffset();
      // 在当前位置插入图片
      styledString.insertStyledString(caretOffset, imageStyledString);
      // 添加图片后自动向下插入一行
      styledString.insertString(caretOffset + 1, '\n');
      // 将修改后的属性字符串设置到组件上显示
      this.contentController.setStyledString(styledString);
      // 移动光标到图片后
      this.contentController.setCaretOffset(caretOffset + 2);
      // 添加操作记录历史
      this.addHistoryRecord(styledString);
    } catch (error) {
      console.error(`Failed to add image to styled string. Cause: ${JSON.stringify(error)}`);
    }
  }
}