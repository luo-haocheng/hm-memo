/**
 * 文件附件 chip 的显示、打开与持久化身份。
 *
 * 【为什么单独一个文件】控制器管"选文件 / 插入 / 打开 / 持久化"，组件管"渲染 chip"，
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

  /**
   * 相对 `memo_files` 的路径，形如 `<uuid>/<原文件名>`。
   * 这就是持久化进 `MemoBlock.value` 的东西 —— 存相对路径而非绝对路径，
   * 与图片只存文件名同一个理由：沙箱绝对路径会随安装/迁移变化，写进存档就还原不了。
   *
   * 沙箱副本的真正「身份」由它承载：chip 的 span 里**没有任何文件名信息**
   *（`valueResourceStr` 只是个占位空格），所以"这格是哪个文件"只能靠这份数据。
   */
  relativePath: string;
}
