import image from '@ohos.multimedia.image';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
// 字体权重的反向映射搬到 SpanMapping，与撤销/重做链路共用同一份，避免两份拷贝漂移
import { fontWeightResult2Value } from './SpanMapping';
// 调色板：用来判断一个色值是"用户选的自定义色"还是"主题色"（见 isPaletteColor）
import { COLOR_LIST } from '../common/Constants';

const PIXELMAP_IMG_VERTICAL_MARGIN = 12;

// 图片文件存放的子目录名（相对于 filesDir）
export const IMAGE_DIR_NAME = 'memo_images';

// 图片最长边上限（px）。解码时按此降采样，同时降低编码耗时、文件体积与内存占用。
// 编辑区显示宽度约 1134px（手机），2000px 足够清晰。
// 注意：显示尺寸以解码后的像素尺寸为基准计算，所以上限必须高于所有目标机型的屏幕像素宽度，
// 否则大图会显示得比预期小。手机屏幕宽 ≤ 1440px，2000px 余量充足；若将来支持平板需重新评估。
export const MAX_IMAGE_SIDE = 2000;

// JPEG 编码质量。100 几乎不压缩；85 对照片而言肉眼与 100 基本无差别，体积约为其 1/2~1/3。
// 权衡画质与体积时在此调整（一般 75~90 之间）
const JPEG_QUALITY = 85;

// 内置图片的显示尺寸（vp）
export const BUILTIN_IMAGE_SIZE = 20;

// 内置图片的右边距（vp）
const BUILTIN_IMAGE_RIGHT_MARGIN = 4;

/** 内置图片名称：圆环（circle.svg）—— 待办勾选框的「未完成」态 */
export const BUILTIN_IMAGE_CIRCLE = 'circle';

/** 内置图片名称：勾（checkmark.svg）—— 待办勾选框的「已完成」态 */
export const BUILTIN_IMAGE_CHECKMARK = 'checkmark';

/**
 * 内置图片表：名称 → 资源。新增内置图时在此登记。
 * 备忘里存的是**名称**而不是资源 id —— id 由构建期分配，会随资源增删而变
 */
const BUILTIN_IMAGES: Map<string, Resource> = new Map<string, Resource>([
  [BUILTIN_IMAGE_CIRCLE, $r('app.media.circle')],
  [BUILTIN_IMAGE_CHECKMARK, $r('app.media.checkmark')],
]);

/**
 * 待办勾选框的两种内置图。
 *
 * 勾选状态**就存在这两张图本身里** —— 备忘存的是内置图的名称，
 * 所以不需要给 Memo 加任何字段，勾选状态天然跟着存档走。
 *
 * ⚠️ `'circle'` 这个值不能改：历史备忘里存的就是它，
 * 改名会让那些图在重建时被当成未知资源而丢弃
 */
export const TODO_MARK_OPEN = BUILTIN_IMAGE_CIRCLE;
export const TODO_MARK_DONE = BUILTIN_IMAGE_CHECKMARK;

// 已完成待办正文的文字透明度（0x80 = 128 ≈ 50%）
const DONE_TEXT_ALPHA = '80';

/** ResourceColor → '#AARRGGBB'；主题色（Resource）取不到色值，返回 undefined */
function toArgbHex(color: ResourceColor): string | undefined {
  let hex: string;
  if (typeof color === 'string') {
    hex = color.startsWith('#') ? color.substring(1) : color;
  } else if (typeof color === 'number') {
    hex = color.toString(16).toUpperCase();
  } else {
    return undefined;
  }
  if (hex.length === 6) {
    return `#FF${hex}`;
  }
  return hex.length === 8 ? `#${hex}` : undefined;
}

/**
 * 这个色值是不是调色板里的固定色（`COLOR_LIST` 里除第 0 项以外的那些）。
 *
 * 【为什么不能用"解析主题色再比对"来判断默认色】踩过两次坑，这条路走不通：
 *
 *   ① `getSpans()` 回报的 `fontColor` **永远是已解析的具体色值，不会是 Resource**
 *      —— 按 `typeof color === 'object'` 判断主题色，那条分支从来没被走到过
 *   ② 改用 `resourceManager.getColorSync()` 解析主题色再比 —— **值会随模式漂移**：
 *      解析出来的是**当前模式**下的值，而编辑器里的 span 存的是**它建立时那个模式**下的值。
 *      实测：浅色下建备忘、切到深色再保存 → 两者对不上 → 判定失败 → 颜色被当成自定义色写死
 *
 * 所以改成白名单：只有调色板里那些**固定色值**才算自定义色，其余一律当主题色处理
 *（涵盖默认文字色、以及已完成待办盖上的 `font_tertiary`）。这个判断与深浅色模式无关。
 *
 * ⚠️ 将来若新增了调色板之外的取色来源，记得同步这里，否则那个颜色会被当成主题色丢掉。
 */
function isPaletteColor(argb: string): boolean {
  // ⚠️ **只比 RGB，不比 alpha**：已完成待办的文字色是"调色板色 + 50% 透明度"（形如 '#4D774342'），
  // 连 alpha 一起比就认不出来，会被当成主题色在存档时抹掉（实测踩过：勾选后保存重开，自定义色变默认色）。
  //
  // alpha 也不能完全不管：万一某个主题色的 RGB 正好撞上调色板里的一项，光比 RGB 就会误判。
  // 所以限定它只能是"没动过"(FF) 或"我们勾选时盖上去的"(DONE_TEXT_ALPHA) —— 这两种之外的一律不算。
  const alpha = argb.substring(1, 3);
  if (alpha !== 'FF' && alpha !== DONE_TEXT_ALPHA) {
    return false;
  }
  const rgb = argb.substring(3);
  for (const color of COLOR_LIST) {
    // 第 0 项是 $r('sys.color.font_primary')，是主题色而非固定色值，会被这一句滤掉
    if (typeof color === 'string') {
      const paletteArgb = toArgbHex(color);
      if (paletteArgb !== undefined && paletteArgb.substring(3) === rgb) {
        return true;
      }
    }
  }
  return false;
}

/**
 * 待办正文的文字颜色：`done` 为真时变灰，为假时还原。
 *
 * 【为什么不用一个固定的灰】那样会把用户自己设的颜色冲掉 —— 勾选再取消就丢色了。
 * 这里分两种处理，**两种都能精确还原**：
 *
 *   - 主题色（默认文字色，或已完成时盖上的那个灰）→ 换用主题色 `font_tertiary` / `font_primary`；
 *     用主题色而不是具体色值，深/浅色模式才会自动跟随
 *   - 具体色值（调色板选的自定义色，形如 '#FFED1C24'）→ 保留色相、只把 alpha 降到 50%；
 *     取消勾选时把 alpha 升回 FF 即还原成原色
 */
export function doneTextColor(color: ResourceColor, done: boolean): ResourceColor {
  const argb = toArgbHex(color);
  if (argb === undefined || !isPaletteColor(argb)) {
    // 主题色（默认文字色 / 已完成时盖上的那个灰）→ 用主题色换，深浅色模式才会自动跟随
    return done ? $r('sys.color.font_tertiary') : $r('sys.color.font_primary');
  }
  // 自定义色 → 保留色相、只把 alpha 降到 50%；取消勾选时升回 FF 即还原
  return done ? `#${DONE_TEXT_ALPHA}${argb.substring(3)}` : `#FF${argb.substring(3)}`;
}

/** 待办勾选框名 → 切换后的另一个；不是勾选框时返回 undefined */
export function toggledTodoMark(name: string): string | undefined {
  if (name === TODO_MARK_OPEN) {
    return TODO_MARK_DONE;
  }
  if (name === TODO_MARK_DONE) {
    return TODO_MARK_OPEN;
  }
  return undefined;
}

/**
 * 名称 → 内置图片资源；未登记的名称返回 undefined
 */
export function builtinImageResource(name: string): Resource | undefined {
  return BUILTIN_IMAGES.get(name);
}

/**
 * 内置图片的固定样式，插入与重建共用同一份定义。
 * 内置图的尺寸和边距都是已知常量，刻意不走 getSpans() 的往返 ——
 * "边距是否计入返回尺寸"的口径一旦与保存时的换算不一致，每次保存/重开图片都会漂移
 */
export function builtinImageStyle(): RichEditorImageSpanStyle {
  return {
    size: [BUILTIN_IMAGE_SIZE, BUILTIN_IMAGE_SIZE],
    verticalAlign: ImageSpanAlignment.CENTER,
    objectFit: ImageFit.Auto,
    layoutStyle: {
      margin: { right: BUILTIN_IMAGE_RIGHT_MARGIN },
    },
  };
}

/**
 * 资源 id → 内置图片名称；未登记的资源返回 undefined
 */
function builtinImageNameById(resourceId: number): string | undefined {
  for (const name of BUILTIN_IMAGES.keys()) {
    const resource = BUILTIN_IMAGES.get(name);
    if (resource && resource.id === resourceId) {
      return name;
    }
  }
  return undefined;
}

/** 从 "resource:///<id>" 形式的 URI 里取出资源 id */
function parseResourceIdFromUri(uri: string): number | undefined {
  const match = uri.match(/resource:\/\/\/(\d+)/);
  return match ? Number(match[1]) : undefined;
}

/**
 * 编辑器返回的图片 span → 内置图名称；相册图或未登记的资源返回 undefined。
 *
 * 解析口径与 mapImageSpan2Block 完全一致（valueResourceStr 可能是 "resource:///<id>" 字符串，
 * 也可能直接是 Resource 对象，两种都兼容），供「这张图是不是待办勾选框」这类判断使用。
 */
export function builtinImageNameOf(span: RichEditorSpan): string | undefined {
  const imageSpan = span as RichEditorImageSpanResult;
  if (imageSpan.imageStyle === undefined) {
    return undefined;
  }
  const resourceStr = imageSpan.valueResourceStr;
  if (!resourceStr) {
    return undefined; // 相册图走 valuePixelMap，没有 resourceStr
  }
  const resourceId = typeof resourceStr === 'string'
    ? parseResourceIdFromUri(resourceStr)
    : resourceStr.id;
  return resourceId === undefined ? undefined : builtinImageNameById(resourceId);
}

/**
 * 按最长边上限计算解码目标尺寸。
 * 未超过上限时返回 undefined，表示按原始尺寸解码
 */
export function calcDesiredSize(width: number, height: number): image.Size | undefined {
  const maxSide = Math.max(width, height);
  if (maxSide <= MAX_IMAGE_SIDE) {
    return undefined;
  }
  const ratio = MAX_IMAGE_SIDE / maxSide;
  return { width: Math.round(width * ratio), height: Math.round(height * ratio) };
}

export interface MemoBlock {
  /**
   * 文本块：文本内容
   * 图片块：memo_images 下的文件名（不含目录，绝对路径在读取时拼装）
   */
  value: string;
  offset: number;
  type: 'text' | 'image' | 'builder';
  imgSource?: 'file' | 'resource';
  textStyle?: RichEditorTextStyle;
  imageStyle?: RichEditorImageSpanStyle;
  paragraphStyle?: RichEditorParagraphStyle;
}

@ObservedV2
export class Memo {
  @Trace title: string = '';
  @Trace description: string = '';
  @Trace pinTime: string = '-1';
  @Trace isLocked: boolean = false;
  @Trace isFavorite: boolean = false;
  @Trace isSelected: boolean = false;
  id: string = '';
  createTime: string = '';
  updateTime: string = '';
  categoryId: string = '-1';
  memoBlockArr: Array<MemoBlock> = [];

  constructor(title?: string, categoryId?: string) {
    this.title = title || '';
    this.categoryId = categoryId || '';
    this.id = new Date().getTime().toString();
    this.createTime = new Date().getTime().toString();
    this.updateTime = this.createTime;
  }

  async updateContent(spanResult: Array<RichEditorSpan>, uiContext: UIContext) {
    const memoBlockArr: Array<MemoBlock> = [];
    for (const span of spanResult) {
      // 图片Span信息
      const imageSpan = span as RichEditorImageSpanResult;
      if (imageSpan.imageStyle !== undefined) {
        const imageSpan = span as RichEditorImageSpanResult;
        if (imageSpan.imageStyle !== undefined) {
          const imageBlock = await this.mapImageSpan2Block(imageSpan, uiContext);
          if (imageBlock) {
            memoBlockArr.push(imageBlock);
          }
        }
        continue;
      }
      // 文本Span信息
      const textSpan = span as RichEditorTextSpanResult;
      if (textSpan.textStyle !== undefined) {
        const textBlock = this.mapTextSpan2Block(textSpan);
        memoBlockArr.push(textBlock);
        continue;
      }
    }

    this.memoBlockArr = memoBlockArr;
    this.updateTime = new Date().getTime().toString();
  }

  /**
   * @param onTodoMarkTap 待办勾选框被点中时的回调。
   *   gesture 只能在 addImageSpan 时挂上，重建出来的勾选框否则是"死"的 ——
   *   所以这个回调得从组件一路传进来（Memo 是模型层，拿不到控制器）
   */
  rebuildContent(controller: RichEditorController, uiContext: UIContext, onTodoMarkTap: () => void) {
    for (const block of this.memoBlockArr) {
      // 单块重建失败不影响其余内容：跳过该块，继续重建后续内容
      try {
        if (block.type === 'text') {
          const options = this.mapBlock2TextSpan(block);
          controller.addTextSpan(block.value, options);
        } else if (block.type === 'image') {
          const options = this.mapBlock2ImageSpan(block, onTodoMarkTap);
          if (block.imgSource === 'resource') {
            const resource = builtinImageResource(block.value);
            if (resource) {
              controller.addImageSpan(resource, options);
            } else {
              console.error(`Unknown builtin image: ${block.value}`);
            }
          } else if (block.imgSource === 'file') {
            const pixelMap = this.loadImage(this.resolveImagePath(uiContext, block.value));
            controller.addImageSpan(pixelMap, options);
            pixelMap.release();
          }
        }
      } catch (error) {
        console.error(`Failed to rebuild block at offset ${block.offset}. Cause: ${JSON.stringify(error)}`);
      }
    }
    // 内容全部就位后再补"已完成"的灰 —— 那时各块的坐标才稳定
    this.applyTodoDoneStyles(controller);
  }

  /**
   * 把「已完成」待办（勾选框是 checkmark）的正文补成灰色。
   *
   * 【为什么重建时要补一遍】灰色是**显示态**，没有存在数据里：
   * 默认文字色是主题色 `Resource`，而 `normalizeColor` 对 `Resource` 返回 `undefined`
   * （KV 里存不下），所以只存了默认色的待办，重开后正文就"不灰"了。
   * 具体色值那一支能存下（存的是降过 alpha 的，形如 '#80ED1C24'），补一遍也无害 —— 幂等。
   */
  private applyTodoDoneStyles(controller: RichEditorController) {
    for (let i = 0; i < this.memoBlockArr.length; i++) {
      const mark = this.memoBlockArr[i];
      if (mark.type !== 'image' || mark.imgSource !== 'resource' || mark.value !== TODO_MARK_DONE) {
        continue;
      }
      // 这一行剩下的文字：从勾选框后一格起，到第一个换行符为止
      let cursor = mark.offset + 1;
      for (let j = i + 1; j < this.memoBlockArr.length; j++) {
        const text = this.memoBlockArr[j];
        if (text.type !== 'text') {
          cursor += 1; // 图片占 1 个坐标单位，跨过去继续
          continue;
        }
        const breakAt = text.value.indexOf('\n');
        const length = breakAt >= 0 ? breakAt : text.value.length;
        if (length > 0) {
          const sourceColor = text.textStyle ? text.textStyle.fontColor : undefined;
          controller.updateSpanStyle({
            textStyle: { fontColor: doneTextColor(sourceColor, true) },
            start: cursor,
            end: cursor + length,
          });
        }
        if (breakAt >= 0) {
          break; // 到换行为止，后面的内容不属于这个待办
        }
        cursor += text.value.length;
      }
    }
  }

  /**
   * 收集本备忘引用的图片文件名（供孤儿图片回收使用）
   * 只统计确实指向文件的图片块：资源图的 value 是空的，不能当成文件名
   */
  collectImageFileNames(into: Set<string>) {
    for (const block of this.memoBlockArr) {
      if (block.type === 'image' && block.imgSource === 'file' && block.value) {
        into.add(block.value);
      }
    }
  }

  /**
   * 把图片文件名还原为绝对路径。
   * 备忘里只保存文件名，目录在读取时拼装，避免把沙箱路径写进持久化数据
   */
  private resolveImagePath(uiContext: UIContext, fileName: string): string {
    const context = uiContext.getHostContext();
    if (context === undefined) {
      console.error(`Failed to get host context when resolving image: ${fileName}`);
      return '';
    }
    return `${context.filesDir}/${IMAGE_DIR_NAME}/${fileName}`;
  }

  private getImgMargin(imgSource: 'resource' | 'file'): Margin {
    const margin: Margin = {};
    // 内置图不加边距：边距会计入 getSpans 返回的尺寸，一旦它与保存时的换算口径不一致，
    // 每次保存/重开都会让图片尺寸漂移。24vp 的小图标对边距不敏感，先留空
    if (imgSource === 'file') {
      margin.top = PIXELMAP_IMG_VERTICAL_MARGIN;
      margin.bottom = PIXELMAP_IMG_VERTICAL_MARGIN;
    }
    return margin;
  }

  /**
   * 将图片编码落盘，返回文件名（不含目录）。
   * 备忘只保存文件名，绝对路径在读取时由 resolveImagePath 拼装
   */
  private async savePixelMapToFile(pixelMap: image.PixelMap, uiContext: UIContext): Promise<string | undefined> {
    const context = uiContext.getHostContext();
    if (context === undefined) {
      console.error('Failed to get host context when saving pixelmap.');
      return undefined;
    }
    const dir = `${context.filesDir}/${IMAGE_DIR_NAME}`;
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
    } catch (error) {
      console.error(`Failed to access directory: ${dir}. Cause: ${JSON.stringify(error)}`);
      return undefined;
    }

    let file: fileIo.File | undefined;
    let packer: image.ImagePacker | undefined;
    const fileName = `${util.generateRandomUUID()}.jpg`;
    const path = `${dir}/${fileName}`;
    try {
      packer = image.createImagePacker();
      file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      await packer.packToFile(pixelMap, file.fd, { format: 'image/jpeg', quality: JPEG_QUALITY });
    } catch (error) {
      console.error(`Failed to pack pixelmap to file: ${path}. Cause: ${JSON.stringify(error)}`);
      return undefined;
    } finally {
      if (packer) {
        packer.release();
      }
      if (file) {
        fileIo.close(file)
          .catch((error: BusinessError) => {
            console.error(`Failed to close file: ${path}. Cause: ${JSON.stringify(error)}`);
          });
      }
    }

    return fileName;
  }

  private async mapImageSpan2Block(imageSpan: RichEditorImageSpanResult,
    uiContext: UIContext): Promise<MemoBlock | undefined> {
    const spanSize = imageSpan.imageStyle.size;

    let value = '';
    let imgSource: 'resource' | 'file' | undefined = undefined;
    let imgSize: [number, number] = [uiContext.px2vp(spanSize[0]), uiContext.px2vp(spanSize[1])];
    const pixelMap = imageSpan.valuePixelMap;
    const resourceStr = imageSpan.valueResourceStr;
    if (resourceStr) {
      // valueResourceStr 可能是 "resource:///<id>" 字符串，也可能直接是 Resource 对象，两种都兼容
      const resourceId = typeof resourceStr === 'string'
        ? parseResourceIdFromUri(resourceStr)
        : resourceStr.id;
      const builtinName = resourceId === undefined ? undefined : builtinImageNameById(resourceId);
      if (!builtinName) {
        // 不是已登记的内置图（系统资源或其它来源）：丢弃，避免存下无法还原的引用
        console.error(`Unsupported resource image: ${JSON.stringify(resourceStr)}`);
        return undefined;
      }
      imgSource = 'resource';
      value = builtinName;
    } else if (pixelMap) {
      imgSource = 'file';
      imgSize[1] -= 2 * PIXELMAP_IMG_VERTICAL_MARGIN;
      const savedFileName = await this.savePixelMapToFile(pixelMap, uiContext);
      if (!savedFileName) {
        // 写盘失败：丢弃这张图，避免把坏路径存进 MemoBlock
        return undefined;
      }
      value = savedFileName;
    } else {
      return undefined;
    }

    // 内置图用固定的样式常量；文件图从编辑器读回，做到所见即所得
    const imageStyle: RichEditorImageSpanStyle = imgSource === 'resource'
      ? builtinImageStyle()
      : {
        size: imgSize,
        objectFit: imageSpan.imageStyle.objectFit,
        verticalAlign: imageSpan.imageStyle.verticalAlign,
        layoutStyle: {
          margin: this.getImgMargin(imgSource),
          borderRadius: imageSpan.imageStyle.layoutStyle?.borderRadius,
        },
      };

    return {
      value: value,
      type: 'image',
      imgSource: imgSource,
      offset: imageSpan.spanPosition.spanRange[0],
      imageStyle: imageStyle,
    };
  }

  private normalizeColor(color: ResourceColor): string | undefined {
    if (typeof color === 'string') {
      return color;
    }
    if (typeof color === 'number') {
      if (color > 0xFFFFFF) {
        // ARGB：保留 alpha 通道
        return `#${color.toString(16).padStart(8, '0').toUpperCase()}`;
      }
      // RGB
      return `#${color.toString(16).padStart(6, '0').toUpperCase()}`;
    }
    // object（Resource）：无法安全还原，回落默认
    return undefined;
  }

  /**
   * 文字颜色落盘前的归一化。
   *
   * ⚠️ 编辑器通过 `getSpans()` 回报的 `fontColor` **永远是已解析的具体色值**，不是 Resource
   *（见 `isPaletteColor` 的说明）。直接存下去就等于把颜色**写死**了 ——
   * 任何备忘一保存，重开后正文都不再跟随深/浅色模式。
   *
   * 所以主题文字色一律存 `undefined`：
   *   - 默认文字色 → 重建时回落默认，跟着主题走
   *   - 已完成待办盖上的 `font_tertiary` → 重建后由 `applyTodoDoneStyles` 按勾选状态重新盖上
   *
   * 取不到具体色值（真的传进来 Resource）时也走 `normalizeColor` 的老口径：丢弃、回落默认。
   */
  private normalizeFontColor(color: ResourceColor): string | undefined {
    const argb = toArgbHex(color);
    if (argb !== undefined && !isPaletteColor(argb)) {
      return undefined;
    }
    return this.normalizeColor(color);
  }

  private mapTextSpan2Block(textSpan: RichEditorTextSpanResult): MemoBlock {
    // decoration.color 走与 fontColor 相同的归一化：
    // Resource 类型无法还原（返回 undefined，回落默认装饰色），十六进制色值可安全往返
    const sourceDecoration = textSpan.textStyle.decoration;
    const decoration: DecorationStyleInterface | undefined = sourceDecoration ? {
      type: sourceDecoration.type,
      color: this.normalizeColor(sourceDecoration.color),
    } : undefined;

    // paragraphStyle 只搬运明确支持的字段，不整体拷贝：
    // 编辑器填充的其它字段（如 leadingMargin，其 LeadingMarginPlaceholder 内含 PixelMap）
    // 一旦被写进 KV 就无法还原，甚至可能让 JSON.stringify 抛异常导致整次保存静默失败
    const sourceParagraph = textSpan.paragraphStyle;
    const paragraphStyle: RichEditorParagraphStyle | undefined = sourceParagraph ? {
      textAlign: sourceParagraph.textAlign
    } : undefined;

    return {
      type: 'text',
      value: textSpan.value,
      offset: textSpan.spanPosition.spanRange[0],
      textStyle: {
        decoration: decoration,
        fontSize: textSpan.textStyle.fontSize,
        fontStyle: textSpan.textStyle.fontStyle,
        fontFamily: textSpan.textStyle.fontFamily,
        lineHeight: textSpan.textStyle.lineHeight,
        fontColor: this.normalizeFontColor(textSpan.textStyle.fontColor),
        fontWeight: fontWeightResult2Value(textSpan.textStyle.fontWeight),
      },
      paragraphStyle: paragraphStyle,
    };
  }

  private mapBlock2TextSpan(block: MemoBlock): RichEditorTextSpanOptions {
    return {
      style: block.textStyle,
      paragraphStyle: block.paragraphStyle,
    };
  }

  /**
   * 图片块 → addImageSpan 的参数。
   * 待办勾选框（圆环 / 勾）要能点击切换，所以在这里把 gesture 挂上 ——
   * 只在插入时挂是不够的，从存档重建出来的勾选框同样得能点
   */
  private mapBlock2ImageSpan(block: MemoBlock, onTodoMarkTap: () => void): RichEditorImageSpanOptions {
    const options: RichEditorImageSpanOptions = { imageStyle: block.imageStyle };
    if (block.imgSource === 'resource' && toggledTodoMark(block.value) !== undefined) {
      options.gesture = {
        onClick: () => {
          onTodoMarkTap();
        },
      };
    }
    return options;
  }

  private loadImage(uri: string): image.PixelMap {
    let imageSource: image.ImageSource | undefined;
    let imageFile: fileIo.File | undefined;
    try {
      imageFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(imageFile.fd);
      // 按最长边上限降采样解码，避免持有全分辨率位图
      const imageInfo = imageSource.getImageInfoSync();
      const desiredSize = calcDesiredSize(imageInfo.size.width, imageInfo.size.height);
      return imageSource.createPixelMapSync(desiredSize ? { desiredSize: desiredSize } : undefined);
    } catch (error) {
      console.error(`Failed to create pixelmap when load image. Cause: ${JSON.stringify(error)}`);
      throw new Error(error);
    } finally {
      if (imageSource) {
        imageSource.release();
      }
      if (imageFile) {
        fileIo.close(imageFile)
          .catch((err: BusinessError) => {
            console.error(`Failed to close image file ${imageFile?.path}. Cause: ${JSON.stringify(err)}`);
          });
      }
    }
  }
}