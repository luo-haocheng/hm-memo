import { COLOR_LIST } from '../common/Constants';
import { MemoEditorController } from '../controller/MemoEditorController';
import { AlignmentInfo } from '../model/AlignmentInfo';
import { FileChipInfo } from '../model/FileChipInfo';
import { Memo } from '../model/Memo';

@ComponentV2
export struct MemoEditorArea {
  @Local isEditing: boolean = false;
  @Param @Require isMemoSaved: boolean;
  @Param @Once @Require memoTitle: string;
  @Param @Once @Require editingMemo: Memo;
  @Event titleChange: (title: string) => void = () => {
  };
  @Event saveStatusChange: (isSaved: boolean) => void = () => {
  };
  private controller: MemoEditorController = MemoEditorController.instance;

  @Builder
  fontStyleBar() {
    Column() {
      Row() {
        Text('A')
          .fontSize(10)
          .fontColor($r('sys.color.font_secondary'));

        Blank();

        Row() {
          Slider({
            value: this.controller.fontSize,
            min: 10, // 滑动最小值
            max: 24, // 滑动最大值
            step: 2,
            style: SliderStyle.InSet,
          })
            .showSteps(true)
            .trackThickness(20)
            .trackColor($r('sys.color.comp_background_secondary'))
            .selectedColor($r('sys.color.comp_background_emphasize'))
            .blockSize({ width: 12, height: 12 })
            .blockStyle({ type: SliderBlockType.IMAGE, image: $r('app.media.font_setting') })
            .onChange((value: number) => {
              this.controller.fontSize = value;
              this.controller.updateTextStyle({
                fontSize: this.controller.fontSize,
                lineHeight: this.controller.fontSize * 1.5,
              });
            });
        }
        .width('90%');

        Blank();

        Text('A')
          .fontSize(16)
          .fontColor($r('sys.color.font_secondary'));
      }
      .height(50)
      .width('100%')
      .padding({ left: '4%', right: '4%' });

      Flex({
        justifyContent: FlexAlign.SpaceAround,
        alignItems: ItemAlign.Center,
      }) {
        ForEach(
          COLOR_LIST,
          (color: ResourceColor, index: number) => {
            Stack() {
              Circle({ width: 16, height: 16 })
                .fill(color);

              Circle({ width: 24, height: 24 })
                .fillOpacity(0)
                .borderWidth(2)
                .borderRadius(12)
                .borderColor(this.controller.colorIdx === index ? Color.Red : Color.Black);
            }
            .onClick(() => {
              this.controller.colorIdx = index;
              this.controller.updateTextStyle({
                fontColor: COLOR_LIST[this.controller.colorIdx]
              });
            });
          },
          (color: ResourceColor) => JSON.stringify(color),
        );
      }
      .height(50)
      .width('100%');
    }
    .height(100)
    .width('100%');
  }

  @Builder
  paragraphAlignBar() {
    Flex({
      justifyContent: FlexAlign.SpaceAround,
      alignItems: ItemAlign.Center,
    }) {
      ForEach(
        this.controller.alignInfoArr,
        (item: AlignmentInfo) => {
          Image(item.icon)
            .width(24)
            .fillColor($r('sys.color.font_primary'))
            .onClick(() => {
              this.controller.alignStyle = item.value;
              this.controller.updateParagraphStyle({ textAlign: this.controller.alignStyle });
            });
        },
        (item: AlignmentInfo) => JSON.stringify(item)
      );
    }
    .height(56)
    .width('100%');
  }

  @Builder
  editorToolBar() {
    Flex({
      justifyContent: FlexAlign.SpaceBetween,
      alignItems: ItemAlign.Center,
    }) {
      // 字体样式
      Image($r('app.media.font_color_size'))
        .width(20)
        .fillColor(COLOR_LIST[this.controller.colorIdx])
        .onClick(() => {
          if (this.controller.showToolBarIndex !== 1) {
            this.controller.showToolBarIndex = 1;
          } else {
            this.controller.showToolBarIndex = 0;
          }
        });

      // 加粗
      Image($r('app.media.ic_bold'))
        .width(20)
        .fillColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.controller.isBold = !this.controller.isBold;
          this.controller.updateTextStyle({
            fontWeight: this.controller.isBold ? FontWeight.Bold : FontWeight.Normal
          });
        });

      // 斜体
      Image($r('app.media.ic_italics'))
        .width(20)
        .fillColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.controller.isItalics = !this.controller.isItalics;
          this.controller.updateTextStyle({
            fontStyle: this.controller.isItalics ? FontStyle.Italic : FontStyle.Normal
          });
        });

      // 下划线
      Image($r('app.media.ic_underline'))
        .width(20)
        .fillColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.controller.isUnderline = !this.controller.isUnderline;
          let decoration = this.controller.isUnderline ? TextDecorationType.Underline : TextDecorationType.None;
          this.controller.updateTextStyle({
            decoration: { type: decoration, }
          });
        });

      // 段落对齐
      Image(this.controller.alignInfoArr[this.controller.alignStyle].icon)
        .width(20)
        .fillColor($r('sys.color.font_primary'))
        .onClick(() => {
          if (this.controller.showToolBarIndex !== 2) {
            this.controller.showToolBarIndex = 2;
          } else {
            this.controller.showToolBarIndex = 0;
          }
        });

      // 插入图片
      SymbolGlyph($r('sys.symbol.picture_fill'))
        .fontSize(20)
        .fontColor([$r('sys.color.font_primary')])
        .onClick(() => {
          this.controller.insertImage(this.getUIContext());
        });

      // 插入文件附件（行内 chip）
      Image($r('app.media.ic_attach'))
        .width(20)
        .height(20)
        .fillColor($r('sys.color.font_primary'))
        .onClick(() => {
          // 外层箭头是"工厂"（请求时调一次、带数据），内层箭头才是 CustomBuilder
          //（零参，框架稍后调）。addBuilderSpan 只收零参 builder，数据只能这样捕获进去
          this.controller.insertFile(this.getUIContext(), (info: FileChipInfo) => {
            return (): void => {
              this.fileChip(info);
            };
          });
        });

      // 插入待办勾选框（插到当前段落开头）
      Image($r('app.media.circle'))
        .width(20)
        .height(20)
        .fillColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.controller.insertTodoMark();
        });
    }
    .padding(12)
    .width('80%')
    .borderRadius('50%')
    .backgroundColor($r('sys.color.background_tertiary'));
  }

  /**
   * 文件附件 chip。**行内**原子单元，随文字流动，不单独成段。
   *
   * 参数用**单个对象**而非多个散参：这是 `@Builder` 支持"按引用传递"的前提形态
   *（调用处写对象字面量才算按引用）。这里调用时传的是变量，**实际按值传递** ——
   * 本场景数据是静态的（插入时定好就不再变），按值就够；
   * 保持单对象形态是为了将来给 chip 加"选中 / 删除"等交互态时不必改调用约定。
   *
   * 点击必须挂在 chip 自己的内容上：`RichEditorBuilderSpanOptions` 里**没有** gesture
   * 字段（只有 offset 与 accessibilitySpanOptions），不像 `addImageSpan` 那样能在插入时挂手势。
   */
  @Builder
  fileChip(info: FileChipInfo) {
    Row({ space: 4 }) {
      Image($r('app.media.ic_attach'))
        .width(14)
        .height(14)
        .fillColor($r('sys.color.font_primary'))
        .draggable(false);

      Text(info.name)
        .fontSize(this.controller.fontSize)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    // 必须有上界，否则一个长文件名会把整行撑开；给 Row 定死 maxWidth 才能让
    // 子 Text 的省略号真正生效。注意**不能**写 width('100%') —— 那会让 chip 独占一行
    .constraintSize({ maxWidth: 220 })
    .padding({
      left: 6,
      right: 6,
      top: 2,
      bottom: 2
    })
    .margin({ left: 2, right: 2 })
    .borderRadius(6)
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    .onClick(() => {
      this.controller.openFile(info, this.getUIContext());
    });
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll() {
        Column() {
          TextInput({
            placeholder: '标题',
            text: this.memoTitle,
            controller: this.controller.titleController,
          })
            .height(40)
            .width('100%')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .placeholderColor($r('sys.color.font_secondary'))
            .placeholderFont({ size: 20, weight: FontWeight.Bold })
            .borderRadius(0)
            .margin({ top: 12 })
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.saveStatusChange(false);
            })
            .onChange((value) => {
              this.memoTitle = value;
              this.titleChange(value);
            });

          RichEditor({ controller: this.controller.contentController })
            .width('100%')
            .barState(BarState.Off)
            .placeholder('开始书写你的笔记', { fontColor: $r('sys.color.font_tertiary') })
            .onReady(() => {
              // 重建内容期间会触发大量内容变更回调，必须先屏蔽历史记录
              this.controller.suspendHistory();
              // 预设文本输入样式（与工具栏状态保持一致）
              this.controller.applyTypingStyle();
              // 重建备忘内容。待办勾选框要能点击切换，而 gesture 只能在插入时挂上，
              // 所以把回调一路传进去 —— 否则从存档恢复出来的勾选框是"死"的
              this.editingMemo.rebuildContent(this.controller.contentController, this.getUIContext(),
                () => {
                  this.controller.onTodoMarkTap();
                });
              // 内容就位后建立历史基线（第 0 条 = 初始状态，不可撤销回去）
              this.controller.resumeHistoryAndReset();
            })
            .onEditingChange((editStatus) => {
              this.isEditing = editStatus;
              this.saveStatusChange(false);
              if (!editStatus) {
                this.controller.showToolBarIndex = 0;
              }
            })
            // 撤销/重做的捕获入口：变更【前】在此把两侧内容一次取齐（详见 onWillChange 的注释）
            .onWillChange((value: RichEditorChangeValue) => {
              this.controller.onWillChange(value);
              return true;
            })
            // 维持「相册图片单独成段」：变更【后】检查紧邻的图片，前后缺换行就补上
            //（详见 onDidChange 的注释；这里只用到 rangeAfter）
            .onDidChange((_rangeBefore: TextRange, rangeAfter: TextRange) => {
              this.controller.onDidChange(rangeAfter, this.getUIContext());
            })
            // 待办勾选框被点中后，等光标落定再判定点的是哪一张（见 onTodoMarkTap 的注释）
            .onSelectionChange((range: RichEditorRange) => {
              this.controller.onSelectionChange(range);
            });
        }
        .width('100%');
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .padding({ bottom: AppStorage.get('BottomRectHeight') as number });

      Column() {
        if (!this.isMemoSaved) {
          if (this.controller.showToolBarIndex === 1) {
            this.fontStyleBar();
          } else if (this.controller.showToolBarIndex === 2) {
            this.paragraphAlignBar();
          }
          this.editorToolBar();
        }
      }
      .margin({ bottom: this.isEditing ? 8 : AppStorage.get('BottomRectHeight') as number });
    }
    .width('100%')
    .height('100%');
  }
}