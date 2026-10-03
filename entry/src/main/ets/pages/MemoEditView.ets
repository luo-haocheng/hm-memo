import { Memo, MemoEditorArea, MemoEditorController, resolveInkPath } from 'memo_editor';
import { KVStore, MemoService, SystemCategory, UserCategory } from 'data_source';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';

@Builder
export function MemoEditBuilder() {
  MemoEditView();
}

@ComponentV2
struct MemoEditView {
  @Local memoTitle: string = '';
  @Local isEditMemo: boolean = false;
  @Local isMemoSaved: boolean = true;
  @Local currentMemo: Memo = new Memo();
  @Consumer() kvStore: KVStore | undefined = undefined;
  uiContext: UIContext = this.getUIContext() as UIContext;
  private memoService: MemoService = MemoService.instance;
  private editorController: MemoEditorController = MemoEditorController.instance;

  aboutToAppear(): void {
    // 启用压缩模式避让软键盘
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE_WITH_CARET);
    // 清空编辑器操作记录并恢复初始化状态。
    // 真正的历史基线在编辑器 onReady（内容重建完成）之后才建立
    this.editorController.resetHistory();
    this.editorController.initState();
  }

  @Builder
  toolBar() {
    if (!this.isMemoSaved) {
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
            this.editorController.unDo(this.uiContext);
          });

        Image($r('app.media.redo'))
          .width(40)
          .height(40)
          .padding(8)
          .borderRadius('50%')
          .fillColor($r('sys.color.font_primary'))
          .backgroundColor($r('sys.color.background_secondary'))
          .opacity(this.editorController.currRecordIdx >= this.editorController.historyLength - 1 ? 0.3 : 1)
          .onClick(() => {
            this.editorController.reDo(this.uiContext);
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
              // 修改保存状态
              this.isMemoSaved = true;
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
  }

  /**
   * 保存笔记
   */
  async saveMemo(): Promise<boolean> {
    let styledString = this.editorController.contentController.toStyledString({});
    let contentStr = styledString.getString();
    // 若新增笔记，内容和标题为空，不保存
    // 修改笔记，内容和标题为空，按返回无响应
    if (contentStr === '' && this.memoTitle === '') {
      return this.isEditMemo ? false : true;
    }

    const spanResult = this.editorController.contentController.getSpans();
    // 附件按文档顺序的相对路径。chip 的 span 里没有文件名，只能由控制器的侧表提供；
    // 这一步同时会把侧表的 offset 与编辑器真实状态对齐（见 attachmentPathsInOrder）
    await this.currentMemo.updateContent(spanResult, this.uiContext,
      this.editorController.attachmentPathsInOrder());
    this.currentMemo.description = contentStr;
    this.currentMemo.title = this.memoTitle;
    // 手写笔迹与正文分开存一个文件，文件名记在 Memo.inkFile 上。
    // 必须放在持久化之前 —— inkFile 是这次要写进 KV 的一部分
    await this.saveInk();

    if (this.isEditMemo) {
      this.memoService.updateMemo(this.currentMemo, this.kvStore, this.uiContext);
    } else {
      this.memoService.addMemo(this.currentMemo, this.kvStore, this.uiContext);
      this.isEditMemo = true;
    }

    return true;
  }

  /**
   * 保存手写笔迹。
   *
   * 【为什么文件名要复用】`save()` 是**覆盖写**，复用同一个文件名就不会像图片那样
   * 每次保存都堆一份新文件。只有第一次（还没有文件名时）才生成一个。
   *
   * 【空画布】`saveInk` 返回 false 时**不保留文件名**。这同时覆盖了两种情况：
   *   - 从来没画过 → `inkFile` 保持空，不留空文件
   *   - 原本有笔迹、这次被擦光了 → `inkFile` 清空，旧文件变成孤儿，下次启动回收掉
   */
  private async saveInk(): Promise<void> {
    const name = this.currentMemo.inkFile || `${util.generateRandomUUID()}.ink`;
    const path = resolveInkPath(this.uiContext, name);
    if (path === '') {
      return;
    }
    const saved = await this.editorController.saveInk(path);
    this.currentMemo.inkFile = saved ? name : '';
  }

  build() {
    NavDestination() {
      Column() {
        MemoEditorArea({
          isMemoSaved: this.isMemoSaved,
          editingMemo: this.currentMemo,
          memoTitle: this.currentMemo.title,
          titleChange: (title: string) => {
            this.memoTitle = title;
          },
          saveStatusChange: (isSave: boolean) => {
            this.isMemoSaved = isSave;
          }
        });
      }
      .width('100%')
      .height('100%');
    }
    .menus(this.toolBar())
    .padding({ top: AppStorage.get('TopRectHeight') as number })
    .onReady((ctx: NavDestinationContext) => {
      const params = ctx.pathInfo.param as Record<string, Object>;
      const memoId = params.memoId as string;
      const sysCategory = params.systemCategory as string;
      const userCategory = params.userCategory as UserCategory;
      if (memoId === '') {
        this.isEditMemo = false;
        if (sysCategory) {
          this.currentMemo.categoryId = '-1';
          if (sysCategory === SystemCategory.FAVORITE_MEMO) {
            this.currentMemo.isFavorite = true;
          }
        } else {
          this.currentMemo.categoryId = userCategory.id;
        }
      } else {
        this.isEditMemo = true;
        let currentMemo: Memo | undefined = undefined;
        if (sysCategory === SystemCategory.DELETED_MEMO) {
          currentMemo = this.memoService.getDeletedMemoById(memoId);
        } else {
          currentMemo = this.memoService.getMemoById(memoId);
        }
        if (currentMemo) {
          this.currentMemo = currentMemo;
        }
      }
    })
    .onBackPressed(() => {
      // 还原默认上抬模式
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);

      return false;
    })
    // 离开编辑页：录音必须停。
    //
    // 【为什么放在这里】控制器是进程级单例，录音状态与 AudioCapturer 都挂在它身上，
    // 会**跨页面存活**。不在这里停的话，返回首页后麦克风还占着、`isRecording` 还亮着，
    // 下次进编辑页就是"一进来就在录音"。实测 `onWillDisappear` 在返回时确实触发。
    //
    // 切后台是另一条路：见 `EntryAbility.onBackground`（实测切后台后应用会被系统杀掉）
    .onWillDisappear(() => {
      this.editorController.stopRecord();
    });
  }
}