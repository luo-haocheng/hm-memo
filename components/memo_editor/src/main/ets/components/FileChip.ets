import { FileChipInfo } from '../model/FileChipInfo';

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
  /**
   * 字号。编辑区传工具栏当前值，预览传固定值。
   *
   * ⚠️ 拖动字号滑块**不会**改变已经插好的 chip —— builder span 的内容只创建一次、
   * 之后由框架缓存。这是预期行为，不是 bug（见 FILE_ATTACHMENT_REVIEW.md）。
   */
  @Param fontSize: number = 14;
  @Event onOpen: (info: FileChipInfo) => void = () => {
  };

  build() {
    Row({ space: 4 }) {
      Image($r('app.media.ic_attach'))
        .width(14)
        .height(14)
        .fillColor($r('sys.color.font_primary'))
        .draggable(false);

      Text(this.info.name)
        .fontSize(this.fontSize)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    // 必须有上界，否则一个长文件名会把整行撑开；给 Row 定死 maxWidth 才能让
    // 子 Text 的省略号真正生效。注意**不能**写 width('100%') —— 那会让 chip 独占一行
    .constraintSize({ maxWidth: 220 })
    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
    .margin({ left: 2, right: 2 })
    .borderRadius(6)
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    .onClick(() => {
      this.onOpen(this.info);
    });
  }
}
