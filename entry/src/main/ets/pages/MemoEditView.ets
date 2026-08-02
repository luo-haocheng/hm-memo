import { MemoEditorArea, MemoEditorController } from 'memo_editor';
import { KeyboardAvoidMode } from '@kit.ArkUI';

@Builder
export function MemoEditBuilder() {
  MemoEditView();
}

@ComponentV2
struct MemoEditView {
  @Local memoTitle: string = '';
  @Local memoContent: MutableStyledString = new MutableStyledString('');
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
      Image(this.editorController.currRecordIdx < 1 ?
        $r('app.media.undo_expire') :
        $r('app.media.undo_effect')
      )
        .width(40)
        .height(40)
        .onClick(() => {
          this.editorController.unDo();
        });

      Image(this.editorController.currRecordIdx >= this.editorController.historyRecords.length - 1 ?
        $r('app.media.redo_expire') :
        $r('app.media.redo_effect')
      )
        .width(40)
        .height(40)
        .onClick(() => {
          this.editorController.reDo();
        });

      Image($r('app.media.save'))
        .width(40)
        .height(40)
        .onClick(() => {
          // todo;
        });
    }
    .width(150)
    .height('100%')
    .margin({ right: 16 })
    .justifyContent(FlexAlign.Center);
  }

  build() {
    NavDestination() {
      MemoEditorArea({
        memoTitle: this.memoTitle,
        memoContent: this.memoContent,
      });
    }
    .menus(this.toolBar());
  }
}