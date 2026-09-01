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
  @Trace fontSize: number = 16;
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
    // todo
    // this.contentController.setStyledString(this.historyRecords[--this.currRecordIdx].styledString);
  }

  /**
   * 重做
   */
  reDo() {
    if (this.currRecordIdx >= this.historyRecords.length - 1) {
      return;
    }
    // todo
    // this.contentController.setStyledString(this.historyRecords[++this.currRecordIdx].styledString);
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
    // const styledString = this.contentController.getStyledString();
    // 添加操作记录历史
    // this.addHistoryRecord(styledString);
    // todo
  }

  /**
   * 设置文本样式
   */
  updateTextStyle(textStyle: RichEditorTextStyle) {
    // 获取选中内容的范围
    const selection = this.contentController.getSelection();
    const start = selection.selection[0] ?? 0;
    const end = selection.selection[1] ?? 0;
    if (start < 0 || end <= start) {
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
   * 获取段落移动范围
   */
  getParagraphRange(start: number, end: number): RichEditorRange {
    // 当前显示文本内容
    try {
      const content = this.contentController.toStyledString({}).getString();

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
    } catch (error) {
      console.error(`Failed to invoke toStyledString. Cause: ${JSON.stringify(error)}`);
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
    // try {
    //   // 获取图片信息
    //   const info = pixelMap.getImageInfoSync();
    //   let width = info.size.width;
    //   let height = info.size.height;
    //   // 宽度超过最大尺寸时，等比例缩放
    //   const displayWidth = uiContext.px2vp(display.getDefaultDisplaySync().width) * 0.9;
    //   if (width > displayWidth) {
    //     width = displayWidth;
    //     height = width / info.size.width * height;
    //   }
    //   // 创建图片富文本对象
    //   const imageStyledString = new MutableStyledString(new ImageAttachment({
    //     value: pixelMap,
    //     objectFit: ImageFit.Auto,
    //     size: { width: width, height: height },
    //     layoutStyle: { borderRadius: LengthMetrics.vp(12), margin: { top: 12, bottom: 12 } },
    //   }));
    //   // 获取当前的富文本内容
    //   const styledString = this.contentController.getStyledString();
    //   // 获取当前光标位置
    //   const caretOffset = this.contentController.getCaretOffset();
    //   // 在当前位置插入图片
    //   styledString.insertStyledString(caretOffset, imageStyledString);
    //   // 添加图片后自动向下插入一行
    //   styledString.insertString(caretOffset + 1, '\n');
    //   // 将修改后的属性字符串设置到组件上显示
    //   this.contentController.setStyledString(styledString);
    //   // 移动光标到图片后
    //   this.contentController.setCaretOffset(caretOffset + 2);
    //   // 添加操作记录历史
    //   this.addHistoryRecord(styledString);
    // } catch (error) {
    //   console.error(`Failed to add image to styled string. Cause: ${JSON.stringify(error)}`);
    // }
    // todo
  }
}