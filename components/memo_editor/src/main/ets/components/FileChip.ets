import { FileChipInfo } from '../model/FileChipInfo';
import { MIME_ICON } from '../model/Memo';

/**
 * 文件附件 chip 的显示。**行内**原子单元，随文字流动，不单独成段。
 *
 * 【为什么抽成独立组件】两处都要渲染它：
 *   - 编辑区（`MemoEditorArea`），点击用系统应用打开
 *   - 首页长按预览（`Index.memoPreview`），只读
 * 两边外观必须一致，所以只留一份定义。而 `addBuilderSpan` 的 `CustomBuilder`
 * 本来就只是"给个能构造节点树的零参函数"，组件比 `@Builder` 方法更好复用。
 *
 * 点击必须挂在 chip 自己的内容上：`RichEditorBuilderSpanOptions` 里**没有** gesture
 * 字段（只有 offset 与 accessibilitySpanOptions），不像 `addImageSpan` 那样能在插入时挂手势。
 */
@ComponentV2
export struct FileChip {
  @Param @Require info: FileChipInfo;
  @Event onOpen: (info: FileChipInfo) => void = () => {
  };

  build() {
    Row() {
      Row({ space: 4 }) {
        if (MIME_ICON.has(this.info.mimeType)) {
          Image(MIME_ICON.get(this.info.mimeType))
            .height('100%')
            .aspectRatio(1)
            .layoutWeight(0)
            .draggable(false);
        } else {
          Image($r('app.media.mime_unknow'))
            .height('100%')
            .aspectRatio(1)
            .layoutWeight(0)
            .draggable(false);
        }

        Text(this.info.name)
          .maxLines(1)
          .fontSize(12)
          .layoutWeight(1)
          .fontColor($r('sys.color.font_primary'))
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .height(80)
      .margin(12)
      .padding(12)
      .borderRadius(16)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .onClick(() => {
        this.onOpen(this.info);
      });
    }
    .width('100%')
    .justifyContent(FlexAlign.Center);
  }
}
