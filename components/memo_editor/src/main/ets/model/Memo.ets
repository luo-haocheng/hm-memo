import image from '@ohos.multimedia.image';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

const RESOURCE_IMG_RIGHT_MARGIN = 8;
const PIXELMAP_IMG_VERTICAL_MARGIN = 12;

// 图片文件存放的子目录名（相对于 filesDir）
export const IMAGE_DIR_NAME = 'memo_images';

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
            // todo
            // const resource = this.BUILTIN_IMAGES[block.value];
            // this.controller.addImageSpan(resource, options);
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
    if (imgSource === 'resource') {
      margin.right = RESOURCE_IMG_RIGHT_MARGIN;
    } else if (imgSource === 'file') {
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
      await packer.packToFile(pixelMap, file.fd, { format: 'image/jpeg', quality: 100 });
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
      if (typeof resourceStr === 'string' && resourceStr.startsWith('resource:///')) {
        imgSource = 'resource';
        // todo
        // imgSize[0] -= this.RESOURCE_IMG_RIGHT_MARGIN;
        // const resId = this.parseResourceIdFromUri(resourceStr);
        // if (resId) {
        //   value = this.resourceNameById.get(resId) ?? '';
        // }
      } else {
        return undefined;
      }
    } else if (pixelMap) {
      imgSource = 'file';
      imgSize[1] -= 2 * PIXELMAP_IMG_VERTICAL_MARGIN;
      const savedPath = await this.savePixelMapToFile(pixelMap, uiContext);
      if (!savedPath) {
        // 写盘失败：丢弃这张图，避免把坏路径存进 MemoBlock
        return undefined;
      }
      value = savedPath;
    } else {
      return undefined;
    }

    return {
      value: value,
      type: 'image',
      imgSource: imgSource,
      offset: imageSpan.spanPosition.spanRange[0],
      imageStyle: {
        size: imgSize,
        objectFit: imageSpan.imageStyle.objectFit,
        verticalAlign: imageSpan.imageStyle.verticalAlign,
        layoutStyle: {
          margin: this.getImgMargin(imgSource),
          borderRadius: imageSpan.imageStyle.layoutStyle?.borderRadius,
        },
      }
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
      return imageSource.createPixelMapSync();
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