import {
  COLOR_LIST,
  HANDWRITE_CLIP_MARGIN,
  HANDWRITE_TOOLBAR_HEIGHT,
  RECORD_BAR_COUNT,
  RECORD_BAR_MAX_HEIGHT,
  RECORD_BAR_MIN_HEIGHT
} from '../common/Constants';
import { MemoEditorController } from '../controller/MemoEditorController';
import { AlignmentInfo } from '../model/AlignmentInfo';
import { FileChipInfo } from '../model/FileChipInfo';
import { Memo, resolveInkPath } from '../model/Memo';
import { FileChip } from './FileChip';
import { HandwriteComponent, PenType } from '@kit.Penkit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * 滚动同步的收敛容差（vp）。
 *
 * 画布的 `scrollTo` 会把偏移**取整**（实测：编辑器 5.333 → 画布 5），
 * 所以两边永远差着零点几 vp。防回环**不能用"相等才忽略"**，否则会来回震荡；
 * 用差值判断才能收敛 —— 差值落进容差内，谁也不再驱动谁
 */
const SCROLL_SYNC_TOLERANCE = 1;

/**
 * 波形柱的**下标序列**。
 *
 * 【为什么用下标而不是直接遍历 `recordWaveform`】`ForEach` 按 key 做差量：柱子的数量
 * 从头到尾不变，若直接遍历波形数组、key 取下标，那么"值变了但 key 没变"→ 不重建 →
 * **柱子高度永远不会刷新**（V2 下 ForEach 的老坑）。
 * 改成遍历这个**恒定不变**的序列、让每根柱子的 `.height()` 去读 `recordWaveform[i]`，
 * V2 的细粒度绑定才会就地重算表达式。
 */
const WAVEFORM_BAR_INDICES: number[] = buildBarIndices();

function buildBarIndices(): number[] {
  const indices: number[] = [];
  for (let i = 0; i < RECORD_BAR_COUNT; i++) {
    indices.push(i);
  }
  return indices;
}

/** 录制时长 → `mm:ss` */
function formatRecordDuration(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  const mm = minutes < 10 ? `0${minutes}` : `${minutes}`;
  const ss = seconds < 10 ? `0${seconds}` : `${seconds}`;
  const hh = hours < 10 ? `0${hours}` : `${hours}`;
  return `${hh}:${mm}:${ss}`;
}

@ComponentV2
export struct MemoEditorArea {
  @Local isEditing: boolean = false;
  // 编辑层 Scroll 的**内容高度**。用来决定画布的长画布上限 ——
  // 画布必须至少能滚到和正文一样远，否则正文滚到底时笔迹跟不上
  @Local scrollContentHeight: number = 0;
  // 编辑区**当前**可用高度（vp）。会随软键盘变化，只用来给裁剪窗口封顶
  @Local editorAreaHeight: number = 0;
  // 画布基准高度：`editorAreaHeight` 见过的**最大值**。
  //
  // 【为什么要单独留一个"只增不减"的值】`MemoEditView` 设了
  // `KeyboardAvoidMode.RESIZE_WITH_CARET`，软键盘拉起时整个页面被压矮。若画布跟着变，
  // 组件会被重新量尺、笔迹被整体缩放（真机表现："输入法拉起时笔迹会缩小"）。
  // 键盘只会让可用区**变小**、不会变大，所以取最大值即等于忽略它的影响。
  //
  // ⚠️ 已知代价：屏幕旋转 / 折叠屏展开若让可用高度变小，这里不会跟着更新。手机端暂不处理
  @Local canvasBaseHeight: number = 0;
  @Param @Require isMemoSaved: boolean;
  @Param @Once @Require memoTitle: string;
  @Param @Once @Require editingMemo: Memo;
  @Event titleChange: (title: string) => void = () => {
  };
  @Event saveStatusChange: (isSaved: boolean) => void = () => {
  };
  private controller: MemoEditorController = MemoEditorController.instance;
  private styleDialogId = -1;
  // 编辑层 Scroll 的控制器。滚动同步要靠它读绝对偏移（onDidScroll 只给增量）
  private editorScroller: Scroller = new Scroller();
  // 防回环：本端驱动对端时，对端的回调不能再反过来驱动本端。
  // 与项目里 isRestoring / isRepairing 同一套路数
  private isSyncingScroll: boolean = false;

  @Builder
  styleDialog() {
    Column() {
      Row() {
        Text('样式')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'));

        Image($r('app.media.xmark'))
          .width(32)
          .height(32)
          .padding(8)
          .borderRadius('50%')
          .fillColor($r('sys.color.font_primary'))
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .onClick(() => {
            try {
              this.getUIContext().getPromptAction().closeCustomDialog(this.styleDialogId);
            } catch (error) {
              console.error(`Failed to closeCustomeDialog. Cause: ${JSON.stringify(error)}`);
            }
          });
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.SpaceBetween);

      Row() {
        // 加粗
        Image($r('app.media.ic_bold'))
          .width(24)
          .fillColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.controller.isBold = !this.controller.isBold;
            this.controller.updateTextStyle({
              fontWeight: this.controller.isBold ? FontWeight.Bold : FontWeight.Normal
            });
          });

        // 斜体
        Image($r('app.media.ic_italics'))
          .width(24)
          .fillColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.controller.isItalics = !this.controller.isItalics;
            this.controller.updateTextStyle({
              fontStyle: this.controller.isItalics ? FontStyle.Italic : FontStyle.Normal
            });
          });

        // 下划线
        Image($r('app.media.ic_underline'))
          .width(24)
          .fillColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.controller.isUnderline = !this.controller.isUnderline;
            let decoration = this.controller.isUnderline ? TextDecorationType.Underline : TextDecorationType.None;
            this.controller.updateTextStyle({
              decoration: { type: decoration, }
            });
          });

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
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.SpaceBetween);

      Divider()
        .width('100%')
        .strokeWidth(1)
        .color($r('sys.color.ohos_id_color_button_divider'));

      Row() {
        ForEach(
          COLOR_LIST,
          (color: ResourceColor, index: number) => {
            Stack() {
              Circle({ width: 16, height: 16 })
                .fill(color);

              if (this.controller.colorIdx === index) {
                Circle({ width: 24, height: 24 })
                  .fillOpacity(0)
                  .borderWidth(2)
                  .borderRadius(12)
                  .borderColor(Color.Red);
              }
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
      .width('100%')
      .padding({ top: 16, bottom: 16 })
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.SpaceBetween);

      Divider()
        .width('100%')
        .strokeWidth(1)
        .color($r('sys.color.ohos_id_color_button_divider'));

      Row() {
        Text('Aa')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'));

        Row() {
          Slider({
            value: this.controller.fontSize,
            min: 10, // 滑动最小值
            max: 24, // 滑动最大值
            step: 2,
            style: SliderStyle.InSet,
          })
            .trackThickness(18)
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

        Text('Aa')
          .fontSize(16)
          .fontColor($r('sys.color.font_secondary'));
      }
      .width('100%')
      .padding({ top: 16, bottom: 16 })
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.SpaceBetween);
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: AppStorage.get('BottomRectHeight') as number });
  }

  @Builder
  editorToolBar() {
    Flex({
      // 手写模式下只剩一个按钮，居中对齐；文本模式下才是两端排开
      justifyContent: this.controller.isHandWrite ? FlexAlign.Center : FlexAlign.SpaceBetween,
      alignItems: ItemAlign.Center,
    }) {
      // 手写模式下把文本工具整排收起来：它们对手写画布不生效。
      // 而且 Penkit 的画布自带一条手写工具栏（本 SDK 版本藏不掉，见
      // HANDWRITE_TOOLBAR_HEIGHT 的注释），两排并排会打架
      if (!this.controller.isHandWrite) {
        // 字体样式
        Image($r('app.media.text_style'))
          .width(20)
          .fillColor(COLOR_LIST[this.controller.colorIdx])
          .onClick(() => {
            this.getUIContext()
              .getPromptAction()
              .openCustomDialog({
                width: '100%',
                builder: () => {
                  this.styleDialog();
                },
                alignment: DialogAlignment.Bottom,
                transition: TransitionEffect.SLIDE,
                keyboardAvoidMode: KeyboardAvoidMode.NONE,
                offset: { dx: 0, dy: AppStorage.get('BottomRectHeight') as number },
              })
              .then((dialogId: number) => {
                this.styleDialogId = dialogId;
              })
              .catch((error: BusinessError) => {
                console.error(`Failed to openCustomDialog. Cause: ${JSON.stringify(error)}`);
              });
          });

        // 插入待办勾选框（插到当前段落开头）
        Image($r('app.media.checkmark_circle'))
          .width(22)
          .fillColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.controller.insertTodoMark();
          });

        // 插入图片
        Image($r('app.media.picture'))
          .width(22)
          .fillColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.controller.insertImage(this.getUIContext());
          });

        // 插入文件附件（行内 chip）
        Image($r('app.media.ic_attach'))
          .width(22)
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

        // 音频录制。录音中变灰且不可点（需求 2）——
        // `enabled(false)` 是"只关交互、不动渲染"的开关，与手写画布那边同一个用法
        Image($r('app.media.record_circle'))
          .width(22)
          .fillColor(this.controller.isRecording
            ? $r('sys.color.font_tertiary')
            : $r('sys.color.font_primary'))
          .opacity(this.controller.isRecording ? 0.4 : 1)
          .enabled(!this.controller.isRecording)
          .onClick(() => {
            // 与 enabled 双保险：权限申请是异步的，置位之前还能被点到
            if (this.controller.isRecording) {
              return;
            }
            // 把备忘传进去：录音文件的名字要落到它的 audioFile 上（一备忘一文件）
            this.controller.startRecord(this.getUIContext(), this.editingMemo)
              .catch((error: BusinessError) => {
                console.error(`[record] 启动录音时未捕获的异常: ${JSON.stringify(error)}`);
              });
          });
      }

      // 手写 / 键盘切换。**刻意放在 if 之外** —— 它是切回键盘的**唯一入口**，
      // 收进 else 里就再也出不来手写模式了
      Image(this.controller.isHandWrite ? $r('app.media.keyboard') : $r('app.media.square_and_pencil'))
        .width(22)
        .fillColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.getUIContext().animateTo(
            {
              duration: 300,
              curve: Curve.Ease,
              playMode: PlayMode.Normal,
            },
            () => {
              this.controller.toggleHandWrite();
            });
        });
    }
    .padding(12)
    .borderRadius('50%')
    // 手写模式下只剩一个按钮，窄胶囊；文本模式下是排开的一整排
    .width(this.controller.isHandWrite ? '56vp' : '80%')
    .backgroundColor($r('sys.color.background_tertiary'));
  }

  /**
   * 附件 chip 的构建入口。
   *
   * 外观定义在 `FileChip` 组件里（首页长按预览复用同一份，避免两处外观漂移），
   * 这里只负责把它接上「点击用系统应用打开」。
   */
  /**
   * 把本条备忘的笔迹交给控制器去加载。
   *
   * 放在 RichEditor 的 `onReady` 里、紧挨着 `rebuildContent` —— 那里能确定
   * `editingMemo` 已经是对的那一条（正文重建本来就依赖它）。
   * 画布是否已就绪由控制器内部兜着，见 `requestInkLoad` 的注释。
   */
  private requestInkLoad() {
    const fileName = this.editingMemo.inkFile;
    if (!fileName) {
      return; // 没有笔迹，正常
    }
    const path = resolveInkPath(this.getUIContext(), fileName);
    if (path === '') {
      return;
    }
    try {
      if (!fileIo.accessSync(path)) {
        // 副本可能已被孤儿回收删掉。跳过即可，不要报错刷屏
        console.error(`[ink] 笔迹文件不存在，跳过加载: ${fileName}`);
        return;
      }
    } catch (error) {
      console.error(`[ink] 检查笔迹文件失败: ${fileName}. Cause: ${JSON.stringify(error)}`);
      return;
    }
    this.controller.requestInkLoad(path);
  }

  /**
   * 录音条。从左到右三段：**停止按钮 / 音量波形 / 录制时间**。
   *
   * 出现在**标题与正文之间**（插入点在 build 里 TextInput 与 RichEditor 之间）。
   */
  @Builder
  recordBar() {
    Row({ space: 8 }) {
      // 停止按钮：用形状原语画"圆底 + 红色圆角方块"，省掉为一个按钮新增 SVG 资源（也避开构建期资源索引的风险）
      Stack() {
        Circle({ width: 28, height: 28 })
          .fill($r('sys.color.comp_background_secondary'));

        Rect({ width: 12, height: 12 })
          .radius(3)
          .fill($r('sys.color.warning'));
      }
      .onClick(() => {
        this.controller.stopRecord();
      });

      //  波形：居中对称柱 —— 每根柱子的**容器固定高、内容居中**，里面的柱子因此天然以中线为轴上下对称生长
      Row({ space: 3 }) {
        ForEach(WAVEFORM_BAR_INDICES, (index: number) => {
          Column() {
            Column()
              .width(2)
              .height(RECORD_BAR_MIN_HEIGHT
                + (this.controller.recordWaveform[index] ?? 0) * RECORD_BAR_MAX_HEIGHT)
              .borderRadius(1.5)
              .backgroundColor($r('sys.color.gray_04'));
          }
          .height(RECORD_BAR_MIN_HEIGHT + RECORD_BAR_MAX_HEIGHT)
          .justifyContent(FlexAlign.Center);
        }, (index: number) => index.toString());
      }
      .clip(true)
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center);

      // 计时
      Text(formatRecordDuration(this.controller.recordElapsedMs) + '/' + '02:00:00')
        .fontSize(8)
        .fontColor($r('sys.color.font_secondary'));
    }
    .padding(12)
    .margin({ left: 12, right: 12 })
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('sys.color.background_secondary'));
  }

  @Builder
  fileChip(info: FileChipInfo) {
    FileChip({
      info: info,
      onOpen: (target: FileChipInfo) => {
        this.controller.openFile(target, this.getUIContext());
      },
    });
  }

  /**
   * 手写画布的长画布上限（vp）。
   *
   * 取**正文内容高度**：画布必须至少能滚到和正文一样远，否则正文滚到底时笔迹跟不上、
   * 两者在底部错位。正文比视口矮时取视口高，等于不滚。
   *
   * ⚠️ 可以放心让它随内容变化：真机实测过**画布的坐标空间与 `maxCanvasHeight` 无关** ——
   *    在 `maxCanvasHeight` 引入之前画的笔迹，带着新值打开时尺寸完全正常。
   */
  private handwriteMaxCanvasHeight(): number {
    const viewport = this.canvasBaseHeight > 0 ? this.canvasBaseHeight : 1000;
    return Math.max(this.scrollContentHeight, viewport);
  }

  /**
   * 画布自己滚动时，把编辑器拉过来对齐。
   *
   * 【为什么要反向】手写模式下画布在上层，滚动手势落在**画布**上，编辑器不会自己动 ——
   * 不反向同步的话，笔迹滚了、正文没动，两者立刻错位。
   *
   * 【防回环靠的是"按模式收口"，不是容差】
   * 两个模式**互斥**，每种模式里驱动方只有一个，所以把两个回调各自按模式闸住就没有回路：
   *   - 键盘模式：画布 `.enabled(false)`，用户滚不动它 → 只有编辑器能驱动
   *   - 手写模式：画布盖住编辑器 → 手势落不到编辑器上 → 只有画布能驱动
   *（调用点在 build 里，两边各有一道 `isHandWrite` 判断）
   *
   * ⚠️ **曾经想用"差值容差"兜底，真机上快速滚动会抖动**：编辑器已经滚到 12、
   * 画布的回调这时才报上一帧的 10，|10-12|=2 超过容差 → 被判定成"画布自己动了" →
   * 把编辑器拽回 10。下一帧又往前，来回抖。差的是**一帧的时间差**，容差挡不住。
   * 所以容差现在只用来避免重复调用，不再承担防回环的职责。
   */
  private syncEditorToInk(inkOffset: number) {
    const editorOffset = this.editorScroller.currentOffset().yOffset;
    if (Math.abs(inkOffset - editorOffset) <= SCROLL_SYNC_TOLERANCE) {
      return; // 已对齐，不再驱动，避免震荡
    }
    this.editorScroller.scrollTo({ xOffset: 0, yOffset: inkOffset });
  }

  /**
   * 手写画布**裁剪容器**的高度。
   *
   * 键盘模式下比编辑区矮一个 `HANDWRITE_TOOLBAR_HEIGHT` —— 画布组件本身仍按整屏高布局，
   * 底部溢出的那一段（就是它自带的工具栏）被 `clip(true)` 裁掉，于是画布照常显示、工具栏不见。
   * 手写模式下容器是整屏高，工具栏正常露出来。
   *
   * 还没量到高度时（首帧）回落 `'100%'`：此时两种模式都还没有笔迹，看不出差别。
   */
  private handwriteLayerHeight(): number | string {
    if (this.canvasBaseHeight <= 0) {
      return '100%';
    }
    if (this.controller.isHandWrite) {
      // 手写模式：窗口全开，自带工具栏正常露出
      return this.editorAreaHeight > 0
        ? Math.min(this.canvasBaseHeight, this.editorAreaHeight)
        : this.canvasBaseHeight;
    }
    // 键盘模式：砍掉自带工具栏那一段，**外加它投影向上溢出的部分** ——
    // 只裁到工具栏顶边的话，投影的上半截会留在画布区里，成一条突兀的灰色渐变带。
    //（实测数据见 HANDWRITE_CLIP_MARGIN 的注释）
    // 再用**当前**可用高度封顶：软键盘压矮页面时画布会溢出到可视区外，
    // 封顶只是多裁一点，不会把工具栏露出来
    const clipped = this.canvasBaseHeight - HANDWRITE_TOOLBAR_HEIGHT - HANDWRITE_CLIP_MARGIN;
    return this.editorAreaHeight > 0 ? Math.min(clipped, this.editorAreaHeight) : clipped;
  }

  /**
   * 画布组件自身的高度 —— **恒为基准高度**，两种模式、软键盘抬起与否都不变。
   *
   * 这是整个方案的关键不变量：只要组件尺寸不变，它就不会重新量尺，
   * 笔迹既不会被缩放、也不会被重排。裁剪交给外层窗口的高度去做（见 build 里的结构）
   */
  private handwriteCanvasHeight(): number | string {
    return this.canvasBaseHeight > 0 ? this.canvasBaseHeight : '100%';
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll(this.editorScroller) {
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
            .focusable(!this.controller.isHandWrite)
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

          // 录音条：标题与正文之间（需求 3）。只在录音期间存在
          if (this.controller.isRecording) {
            this.recordBar();
          }

          RichEditor({ controller: this.controller.contentController })
            .width('100%')
            .barState(BarState.Off)
            .focusable(!this.controller.isHandWrite)
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
                },
                (info: FileChipInfo) => {
                  return (): void => {
                    this.fileChip(info);
                  };
                });
              // 内容就位后建立历史基线（第 0 条 = 初始状态，不可撤销回去）
              this.controller.resumeHistoryAndReset();
              // 附件 chip 的 span 里**没有文件名**（valueResourceStr 只是个占位空格），
              // 所以重建完必须把「第 k 个 chip ↔ 第 k 个附件块」的对应关系交给控制器，
              // 否则保存时无从知道每一格是哪个文件
              this.controller.resetAttachments(this.editingMemo.memoBlockArr);
              // 恢复手写笔迹。放在这里是因为此刻 editingMemo 一定是对的那一条
              this.requestInkLoad();
            })
            .onEditingChange((editStatus) => {
              this.isEditing = editStatus;
              this.saveStatusChange(false);
            })
            // 撤销/重做的捕获入口：变更【前】在此把两侧内容一次取齐（详见 onWillChange 的注释）
            .onWillChange((value: RichEditorChangeValue) => {
              this.controller.onWillChange(value);
              return true;
            })
            // 维持「相册图片单独成段」：变更【后】检查紧邻的图片，前后缺换行就补上
            //（详见 onDidChange 的注释）
            .onDidChange((rangeBefore: TextRange, rangeAfter: TextRange) => {
              this.controller.onDidChange(rangeBefore, rangeAfter, this.getUIContext());
            })
            // 待办勾选框被点中后，等光标落定再判定点的是哪一张（见 onTodoMarkTap 的注释）
            .onSelectionChange((range: RichEditorRange) => {
              this.controller.onSelectionChange(range);
            });
        }
        .width('100%')
        // 量出正文内容高度，供画布的长画布上限使用（见 handwriteMaxCanvasHeight）
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const height = newArea.height as number;
          if (height > 0) {
            this.scrollContentHeight = height;
          }
        });
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .padding({ bottom: AppStorage.get('BottomRectHeight') as number })
      // 这里刻意**不设底色**：这行原是"画布压在编辑层下面时用来挡住它"的，
      // 现在画布永远在上层，它已无作用 —— 反而可能在原生 surface 旁露出来、
      // 与页面底色对不上而显出一条色带
      .zIndex(0)
      // 正文滚动 → 画布跟着滚。
      // 用 currentOffset() 而不是回调参数 —— onDidScroll 给的是**增量**，不是绝对位置
      .onDidScroll(() => {
        // ⚠️ **只在键盘模式下驱动画布**。手写模式下画布盖住了这一层，用户滚不到编辑器，
        // 这里的事件只可能是我们同步过去产生的**回声** —— 再拿它去驱动画布就会来回打架。
        // 两个模式互斥（见 syncEditorToInk 的注释），所以这一道闸就是回路的断点
        if (this.controller.isHandWrite) {
          return;
        }
        this.controller.scrollInkTo(this.editorScroller.currentOffset().yOffset);
      });

      // 手写画布层：**永远浮在编辑层之上**，两种模式都显示笔迹 ——
      // 键盘模式下就是"批注盖在正文上"的效果（画布除笔迹外是透明的，正文透得出来）。
      //
      // 【为什么不切显隐】真机实测：用 `Visibility.Hidden` 藏起来再切回来，**笔迹会丢**，
      // 说明笔迹存在**组件侧**、不在 HandwriteController 里 —— 藏起来这一步把 surface 销毁了。
      // 所以组件必须始终在渲染树里、始终被绘制。
      //
      // 【工具栏怎么办】官方 FAQ 明确「画布和工具栏配套提供，不支持单独使用」，且
      // `hiddenTools` 要 API 26（本机只有 24）—— 也就是说**没有任何 API 能把工具栏摘掉**。
      // 这里改用几何办法：组件始终按**整屏高**布局，键盘模式下把外层容器砍矮一个
      // `HANDWRITE_TOOLBAR_HEIGHT` 并 `clip(true)`，底部溢出的那一段正好就是自带工具栏，
      // 被裁出可视区 —— 画布本体一点不少（见 handwriteLayerHeight 的注释）。
      //
      // ⚠️ `enabled` 是必需的：键盘模式下画布浮在上层但不能编辑，且编辑层在它下面，
      // 若不禁用，触摸会被画布截住 —— 文字选不了、滚不动。
      // 结构分三层，各司其职 —— 关键是把"会变的东西"和"会动的东西"隔开：
      //
      //   外层 Column  恒 100%×100%，永远铺满 Stack → Stack 的 Bottom 对齐对它没有影响，
      //                它的顶边恒在 y=0
      //     └ 裁剪窗口 Column  高度随模式变（键盘模式矮一个工具栏），但它是 Column 的
      //                第一个子节点，Column 从顶部排 → **顶边恒在 y=0**，高度变化只往下吃
      //       └ HandwriteComponent  高度恒为基准高度，两种模式完全一致
      //
      // 上一版把「裁剪窗口」直接当 Stack 的子节点，它的顶边就跟着 Bottom 对齐漂了；
      // 加了 .align(Alignment.Top) 也没解决（真机实测仍在跳），所以改成靠**嵌套结构**
      // 保证顶边不动 —— 不依赖任何对齐属性。
      Column() {
        Column() {
          HandwriteComponent({
            handwriteController: this.controller.handwriteController,
            defaultPenType: PenType.BALLPOINT_PEN,
            scaleDisabled: true,
            // 画布初始化完成的信号。`load` 必须等这一刻（官方要求），
            // 所以笔迹恢复由这里的置位去触发，见 controller.requestInkLoad
            onInit: () => {
              this.controller.onInkCanvasReady();
            },
            // 长画布上限：至少要有正文那么长，否则正文滚到底时画布跟不上
            maxCanvasHeight: this.handwriteMaxCanvasHeight(),
            // 画布自己滚动 → 把编辑器拉过来对齐。
            // 同样按模式收口：键盘模式下画布被禁用、不可能被用户滚，报回来的只可能是回声
            onDidScroll: (yOffset: number) => {
              if (!this.controller.isHandWrite) {
                return;
              }
              this.syncEditorToInk(yOffset);
            },
          })
            .width('100%')
            // ⚠️ 必须是**基准高度**，不能写 '100%' ——
            // 它的父节点是「裁剪窗口」，高度会随模式变；写成 100% 就等于让组件跟着变高变矮，
            // 组件会被重新量尺、笔迹被缩放（不变量 ① 被破坏）。
            // 恒定的组件高度 + 可变的裁剪窗口，这个分工是整套方案的关键
            .height(this.handwriteCanvasHeight());
        }
        .width('100%')
        .height(this.handwriteLayerHeight())
        .clip(true);
      }
      .width('100%')
      .height('100%')
      .zIndex(2)
      .enabled(this.controller.isHandWrite);

      // 这里**刻意不放遮挡条**。它听起来很合理（盖住投影、顺手统一两种模式的可绘制区），
      // 试过、又删了。两个理由：
      //
      //   ① **层级对不上**：栈里从下到上是 `编辑层(z0) → 画布(z2) → 遮挡条(z3) → 工具栏(z4)`，
      //      不透明的遮挡条会**连编辑层的正文一起盖住**（键盘模式下底部约 22vp 的正文被切掉）。
      //      这和"整体改用覆盖"方案踩的是同一个坑，只是小一号
      //   ② **键盘模式下它本来就是多余的**：裁剪线落在 T+M=148vp 处，投影在 126~147vp，
      //      整条都在裁剪线以下、已经被裁干净了
      //
      // 它唯一的作用是挡住手写模式下用户画进 [126, 148] 那一条（那段在键盘模式下会被裁掉）。
      // 权衡：盖住 22vp 正文的代价 > 少挡 22vp 绘制的收益，所以不做 ——
      // 那片本来就压在工具栏投影里、很昏暗，不容易刻意画进去。
      //
      // ⚠️ 若将来真想解决那 22vp，正确的做法是**只在手写模式下放一条透明的挡触摸条**，
      //    而不是不透明遮挡条。前提是要先验证透明组件在 ArkUI 里拦不拦得住触摸。

      Column({ space: 12 }) {
        if (!this.isMemoSaved) {
          this.editorToolBar();
        }
      }
      // 最上层：要压过画布（zIndex 2）
      .zIndex(3)
      .margin({
        // 手写模式下要抬到画布自带工具栏的上面，否则两排工具叠在一起
        //（HANDWRITE_TOOLBAR_HEIGHT 的注释里有说明）
        bottom: this.controller.isHandWrite
          ? (AppStorage.get('BottomRectHeight') as number) + HANDWRITE_TOOLBAR_HEIGHT
          : (this.isEditing ? 8 : AppStorage.get('BottomRectHeight') as number)
      });
    }
    .width('100%')
    .height('100%')
    // 量出编辑区可用高度，供手写画布的容器高度换算（见 handwriteLayerHeight）
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const height = newArea.height as number;
      if (height > 0) {
        this.editorAreaHeight = height;
        // 只增不减：软键盘把页面压矮时不能让画布跟着缩，理由见 canvasBaseHeight 的注释
        if (height > this.canvasBaseHeight) {
          this.canvasBaseHeight = height;
        }
      }
    });
  }
}