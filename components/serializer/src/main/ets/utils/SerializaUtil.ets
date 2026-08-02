import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { StyledStringSerializer } from '../handler/StyledStringSerializer';
import { JSON, util } from '@kit.ArkTS';
import { ImageAttachmentSerializer, SerializedImageAttachment } from '../handler/ImageAttachmentSerializer';

/**
 * 对应MutableStyledString
 */
export interface SerializedMutableStyledString {
  content: string;
  options: Array<SerializedStyleOptions>;
}


/**
 * 对应StyleOptions
 */
export interface SerializedStyleOptions {
  start: number;
  length: number;
  styledKey: StyledStringKey;
  styledValue: SerializedStyledStringValue;
}

/**
 * 对应StyledStringValue
 */
export interface SerializedStyledStringValue {}

export class SerializeUtil {
  static async serialize(styledString: MutableStyledString, uiContext: UIContext): Promise<string> {
    const content = styledString.getString();
    const styles: Array<SpanStyle> = styledString.getStyles(0, content.length);

    const options: Array<SerializedStyleOptions> = [];
    for (let style of styles) {
      if (style.styledKey === StyledStringKey.IMAGE) {
        // 图片类型
        const context = uiContext.getHostContext() as Context;
        const imageAttachment = style.styledValue as ImageAttachment;
        const sandboxPath = context.filesDir + '/' + util.generateRandomUUID() + '.png';
        await SerializeUtil.savePixelMapToSandbox(imageAttachment.value, sandboxPath);
        options.push({
          start: style.start,
          length: style.length,
          styledKey: style.styledKey,
          styledValue: ImageAttachmentSerializer.serialize(imageAttachment, sandboxPath, uiContext),
        });
      } else {
        // 其他类型
        options.push({
          start: style.start,
          length: style.length,
          styledKey: style.styledKey,
          styledValue: StyledStringSerializer.serialize(style.styledKey, style.styledValue),
        });
      }
    }

    const obj: SerializedMutableStyledString = {
      content: styledString.getString(),
      options: options,
    };
    return JSON.stringify(obj);
  }

  static async deserialize(data: string): Promise<MutableStyledString> {
    // string转obj
    const obj: SerializedMutableStyledString = JSON.parse(data) as SerializedMutableStyledString;
    const styleOptions: Array<StyleOptions> = [];
    const imageOptions: Array<StyleOptions> = [];

    for (let option of obj.options) {
      if (option.styledKey === StyledStringKey.IMAGE) {
        // 图片类型
        const serializedImageAttachment = option.styledValue as SerializedImageAttachment;
        imageOptions.push({
          start: option.start,
          length: option.length,
          styledKey: option.styledKey,
          styledValue: ImageAttachmentSerializer.deserialize(serializedImageAttachment),
        });
      } else {
        // 其他类型
        styleOptions.push({
          start: option.start,
          length: option.length,
          styledKey: option.styledKey,
          styledValue: StyledStringSerializer.deserialize(option.styledValue, option.styledKey),
        });
      }
    }

    let mss = new MutableStyledString(obj.content, styleOptions);
    // 添加图片
    for (let imageOption of imageOptions) {
      mss.insertStyledString(imageOption.start, new MutableStyledString(imageOption.styledValue as ImageAttachment));
    }
    return mss;
  }

  private static async savePixelMapToSandbox(pixelMap: image.PixelMap, path: string) {
    let fd: number | null = null;
    const imagePacker = image.createImagePacker();

    imagePacker.packToData(pixelMap, {
      format: 'image/png',
      quality: 100,
    })
      .then((data: ArrayBuffer) => {
        const mode = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE;
        try {
          fd = fileIo.openSync(path, mode).fd;
          fileIo.truncateSync(fd);
          fileIo.writeSync(fd, data);
        } catch (error) {
          console.error(`Failed to write image file to sandbox. Cause: ${JSON.stringify(error)}`);
        } finally {
          fileIo.closeSync(fd);
        }
      })
      .catch((error: BusinessError) => {
        console.error(`Failed to pack the image.code ${error.code},message is ${error.message}`);
      });
  }
}