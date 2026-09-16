/**
 * 文件附件 chip 的显示与打开所需信息。
 *
 * 【为什么单独一个文件】控制器管"选文件 / 插入 / 打开"，组件管"渲染 chip"，
 * 两边都要引用这个类型。放 model 层是为了避免组件反向 import 控制器而形成循环。
 */
export interface FileChipInfo {
  /**
   * **沙箱副本**的 URI（`file://<bundleName>/...`），用系统应用打开时传的就是它。
   *
   * ⚠️ 不是 picker 返回的那个 URI —— 那个只有临时授权、转授不出去，
   * 直接拿去 startAbility 会让目标应用被拉起来了却打不开。
   * 详见 FILE_ATTACHMENT_REVIEW.md §二
   */
  uri: string;

  /** 显示名（含后缀）。取自 FileUri.name，取不到时回落到 URI 末段 */
  name: string;

  /** 打开时用的 MIME。插入时就定好，避免点击时再算一次 */
  mimeType: string;
}
