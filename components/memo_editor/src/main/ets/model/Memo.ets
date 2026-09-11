import image from '@ohos.multimedia.image';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

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

/** 内置图片名称：圆环（circle.svg） */
export const BUILTIN_IMAGE_CIRCLE = 'circle';

/**
 * 内置图片表：名称 → 资源。新增内置图时在此登记。
 * 备忘里存的是**名称**而不是资源 id —— id 由构建期分配，会随资源增删而变
 */
const BUILTIN_IMAGES: Map<string, Resource> = new Map<string, Resource>([
  [BUILTIN_IMAGE_CIRCLE, $r('app.media.circle')],
]);

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

  rebuildContent(controller: RichEditorController, uiContext: UIContext) {
    for (const block of this.memoBlockArr) {
      // 单块重建失败不影响其余内容：跳过该块，继续重建后续内容
      try {
        if (block.type === 'text') {
          const options = this.mapBlock2TextSpan(block);
          controller.addTextSpan(block.value, options);
        } else if (block.type === 'image') {
          console.info(`Image Block 1: ${JSON.stringify(block)}`);
          const options = this.mapBlock2ImageSpan(block);
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

  private parseResourceIdFromUri(uri: string): number | undefined {
    const match = uri.match(/resource:\/\/\/(\d+)/);
    return match ? Number(match[1]) : undefined;
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
        ? this.parseResourceIdFromUri(resourceStr)
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

  private fontWeightResult2Value(result: number): FontWeight | number {
    switch (result) {
      case 9:
        return FontWeight.Bold;
      case 10:
        return FontWeight.Normal;
      case 11:
        return FontWeight.Bolder;
      case 12:
        return FontWeight.Lighter;
      case 13:
        return FontWeight.Medium;
      case 14:
        return FontWeight.Regular;
      default:
        return (result + 1) * 100; // 0~8 对应 100~900
    }
  }

  private mapTextSpan2Block(textSpan: RichEditorTextSpanResult): MemoBlock {
    return {
      type: 'text',
      value: textSpan.value,
      offset: textSpan.spanPosition.spanRange[0],
      textStyle: {
        fontSize: textSpan.textStyle.fontSize,
        fontStyle: textSpan.textStyle.fontStyle,
        fontFamily: textSpan.textStyle.fontFamily,
        lineHeight: textSpan.textStyle.lineHeight,
        decoration: textSpan.textStyle.decoration ?
          {
            type: textSpan.textStyle.decoration.type,
            color: textSpan.textStyle.decoration.color,
          } : undefined,
        fontColor: this.normalizeColor(textSpan.textStyle.fontColor),
        fontWeight: this.fontWeightResult2Value(textSpan.textStyle.fontWeight),
      },
      paragraphStyle: textSpan.paragraphStyle,
    };
  }

  private mapBlock2TextSpan(block: MemoBlock): RichEditorTextSpanOptions {
    return {
      style: block.textStyle,
      paragraphStyle: block.paragraphStyle,
    };
  }

  private mapBlock2ImageSpan(block: MemoBlock): RichEditorImageSpanOptions {
    return { imageStyle: block.imageStyle };
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