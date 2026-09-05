import { COLOR_LIST, DEFAULT_FONT_SIZE } from '../common/Constants';
import { MemoEditorController } from '../controller/MemoEditorController';
import { AlignmentInfo } from '../model/AlignmentInfo';

@ComponentV2
export struct MemoEditorArea {
  @Local isEditing: boolean = false;
  @Param @Require isMemoSaved: boolean;
  @Param @Once @Require memoTitle: string;
  @Param @Once @Require memoContent: MutableStyledString;
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
            min: 14, // 滑动最小值
            max: 30, // 滑动最大值
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
              // todo
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
              // todo
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
    }
    .padding(12)
    .width('80%')
    .borderRadius('50%')
    .backgroundColor($r('sys.color.background_tertiary'));
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
              // 预设文本输入样式
              this.controller.contentController.setTypingStyle({
                fontSize: DEFAULT_FONT_SIZE,
                fontStyle: FontStyle.Normal,
                fontWeight: FontWeight.Normal,
                lineHeight: DEFAULT_FONT_SIZE * 1.5,
                fontColor: $r('sys.color.font_primary'),
              });
            })
            .onEditingChange((editStatus) => {
              this.isEditing = editStatus;
              this.saveStatusChange(false);
              if (!editStatus) {
                this.controller.showToolBarIndex = 0;
              }
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