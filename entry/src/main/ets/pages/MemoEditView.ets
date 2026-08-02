import { Memo, MemoEditorArea, MemoEditorController } from 'memo_editor';
import { MemoService } from 'data_source';
import { KVStore } from 'serializer';
import { KeyboardAvoidMode } from '@kit.ArkUI';

@Builder
export function MemoEditBuilder() {
  MemoEditView();
}

@ComponentV2
struct MemoEditView {
  @Local memoTitle: string = '';
  @Local isEditMemo: boolean = false;
  @Local currentMemo: Memo = new Memo(new MutableStyledString(''));
  @Consumer() kvStore: KVStore | undefined = undefined;
  uiContext: UIContext = this.getUIContext() as UIContext;
  private memoService: MemoService = MemoService.instance;
  private editorController: MemoEditorController = MemoEditorController.instance;

  aboutToAppear(): void {
    // 启用压缩模式避让软键盘
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE_WITH_CARET);
  }

  aboutToDisappear(): void {
    // 还原默认上抬模式
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
  }

  @Builder
  toolBar() {
    Row({ space: 12 }) {
      Image($r('app.media.undo'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor($r('sys.color.font_primary'))
        .backgroundColor($r('sys.color.background_secondary'))
        .opacity(this.editorController.currRecordIdx <= 0 ? 0.3 : 1)
        .onClick(() => {
          this.editorController.unDo();
        });

      Image($r('app.media.redo'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor($r('sys.color.font_primary'))
        .backgroundColor($r('sys.color.background_secondary'))
        .opacity(this.editorController.currRecordIdx >= this.editorController.historyRecords.length - 1 ? 0.3 : 1)
        .onClick(() => {
          this.editorController.reDo();
        });

      Image($r('app.media.checkmark'))
        .width(40)
        .height(40)
        .padding(8)
        .borderRadius('50%')
        .fillColor($r('sys.color.font_primary'))
        .backgroundColor($r('sys.color.background_secondary'))
        .onClick(async () => {
          let isSucc = await this.saveMemo();
          if (isSucc) {
            console.info(`save memo success`);
            // 点击保存后退出选中状态
            this.editorController.contentController.setSelection(0, 0);
            // 退出编辑状态
            this.editorController.titleController.stopEditing();
            this.editorController.contentController.stopEditing();
          } else {
            console.error(`save memo failed`);
          }
        });
    }
    .width(150)
    .height('100%')
    .margin({ right: 16 })
    .justifyContent(FlexAlign.Center);
  }

  /**
   * 保存笔记
   */
  async saveMemo(): Promise<boolean> {
    let styledString: MutableStyledString = this.editorController.contentController.getStyledString();
    let content = styledString.getString();
    if (content === '' && this.memoTitle === '') {
      return this.isEditMemo ? false : true;
    }

    if (!this.isEditMemo) {
      this.currentMemo.title = this.memoTitle;
      this.currentMemo.styledString = this.editorController.contentController.getStyledString();
      this.currentMemo.description = this.currentMemo.styledString.getString();
      this.memoService.addMemo(this.currentMemo, this.kvStore, this.uiContext);
      this.isEditMemo = true;
    }

    return true;
  }

  build() {
    NavDestination() {
      Column() {
        MemoEditorArea({
          memoTitle: this.currentMemo.title,
          memoContent: this.currentMemo.styledString,
          titleChange: (title: string) => {
            this.memoTitle = title;
          }
        });
      }
      .width('100%')
      .height('100%');
    }
    .menus(this.toolBar());
  }
}