import { COLOR_LIST, DEFAULT_FONT_SIZE, HIGHLIGHT_COLOR_FILTER, ORIGIN_COLOR_FILTER, } from '../common/Constants';
import { MemoEditorController } from '../controller/MemoEditorController';
import { AlignmentInfo } from '../model/AlignmentInfo';
import { LengthMetrics } from '@kit.ArkUI';

@ComponentV2
export struct MemoEditorArea {
  @Local isEditing: boolean = false;
  @Param @Once @Require memoTitle: string;
  @Param @Once @Require memoContent: MutableStyledString;
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
            value: this.controller.fontSize.value,
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
              this.controller.fontSize = LengthMetrics.vp(value);
              this.updateFontStyle();
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
              this.updateFontStyle();
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
            .colorFilter(this.controller.alignStyle === item.value ? HIGHLIGHT_COLOR_FILTER : ORIGIN_COLOR_FILTER)
            .onClick(() => {
              this.controller.alignStyle = item.value;
              this.controller.setParagraphStyle(new ParagraphStyle({ textAlign: this.controller.alignStyle }));
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
      justifyContent: FlexAlign.SpaceAround,
      alignItems: ItemAlign.Center,
    }) {
      // 字体样式
      Image($r('app.media.font_color_size'))
        .width(24)
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
        .width(24)
        .colorFilter(this.controller.isBold ? HIGHLIGHT_COLOR_FILTER : ORIGIN_COLOR_FILTER)
        .onClick(() => {
          this.controller.isBold = !this.controller.isBold;
          this.updateFontStyle();
        });

      // 斜体
      Image($r('app.media.ic_italics'))
        .width(24)
        .colorFilter(this.controller.isItalics ? HIGHLIGHT_COLOR_FILTER : ORIGIN_COLOR_FILTER)
        .onClick(() => {
          this.controller.isItalics = !this.controller.isItalics;
          this.updateFontStyle();
        });

      // 下划线
      Image($r('app.media.ic_underline'))
        .width(24)
        .colorFilter(this.controller.isUnderline ? HIGHLIGHT_COLOR_FILTER : ORIGIN_COLOR_FILTER)
        .onClick(() => {
          this.controller.isUnderline = !this.controller.isUnderline;
          let decoration = this.controller.isUnderline ? TextDecorationType.Underline : TextDecorationType.None;
          this.controller.setTextStyle(StyledStringKey.DECORATION, new DecorationStyle({ type: decoration }));
        });

      // 段落对齐
      Image(this.controller.alignInfoArr[this.controller.alignStyle].icon)
        .width(24)
        .onClick(() => {
          if (this.controller.showToolBarIndex !== 2) {
            this.controller.showToolBarIndex = 2;
          } else {
            this.controller.showToolBarIndex = 0;
          }
        });

      // 插入图片
      SymbolGlyph($r('sys.symbol.picture_fill'))
        .fontSize(24)
        .onClick(() => {
          this.controller.insertImage(this.getUIContext());
        });
    }
    .height(60)
    .width('100%')
    .backgroundColor('#EDEFF5')
    .padding({ left: 16, right: 16 });
  }

  private updateFontStyle() {
    this.controller.setTextStyle(StyledStringKey.FONT, new TextStyle({
      fontStyle: this.controller.isItalics ? FontStyle.Italic : FontStyle.Normal,
      fontWeight: this.controller.isBold ? FontWeight.Bold : FontWeight.Normal,
      fontColor: COLOR_LIST[this.controller.colorIdx],
      fontSize: this.controller.fontSize,
    }));
    this.controller.setTextStyle(StyledStringKey.LINE_HEIGHT,
      new LineHeightStyle(LengthMetrics.vp(this.controller.fontSize.value * 1.5)));
  }

  build() {
    Column() {
      Column() {
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
              .backgroundColor(Color.Transparent);

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
                // 注册编辑区内容改变回调
                this.controller.contentController.onContentChanged({
                  onDidChange: () => {
                    this.controller.onContentChanged();
                  }
                });
                // 设置备忘内容，并添加到操作记录。
                this.controller.contentController.setStyledString(this.memoContent);
                this.controller.addHistoryRecord(this.memoContent);
              })
              .onEditingChange((editStatus) => {
                this.isEditing = editStatus;
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
        .scrollBar(BarState.Off);
      }
      .layoutWeight(1);

      if (this.isEditing) {
        if (this.controller.showToolBarIndex === 1) {
          this.fontStyleBar();
        } else if (this.controller.showToolBarIndex === 2) {
          this.paragraphAlignBar();
        }
        this.editorToolBar();
      }
    }
    .width('100%')
    .height('100%');
  }
}