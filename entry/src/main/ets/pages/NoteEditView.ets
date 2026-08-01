import { RichEditorArea, RichEditorController } from 'rich_editor';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { CHECK_MARK_UTF8, RING_UTF8 } from 'rich_editor/src/main/ets/common/Constants';

@Builder
export function NoteEditBuilder() {
  NoteEditView();
}

@ComponentV2
struct NoteEditView {
  @Local noteTitle: string = '';
  @Local noteContent: MutableStyledString = new MutableStyledString(`${RING_UTF8}\n${CHECK_MARK_UTF8}`);
  private noteEditorController: RichEditorController = RichEditorController.instance;

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
      Image(this.noteEditorController.currRecordIdx < 1 ?
        $r('app.media.undo_expire') :
        $r('app.media.undo_effect')
      )
        .width(40)
        .height(40)
        .onClick(() => {
          this.noteEditorController.unDo();
        });

      Image(this.noteEditorController.currRecordIdx >= this.noteEditorController.historyRecords.length - 1 ?
        $r('app.media.redo_expire') :
        $r('app.media.redo_effect')
      )
        .width(40)
        .height(40)
        .onClick(() => {
          this.noteEditorController.reDo();
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
      RichEditorArea({
        noteTitle: this.noteTitle,
        noteContent: this.noteContent,
      });
    }
    .menus(this.toolBar());
  }
}