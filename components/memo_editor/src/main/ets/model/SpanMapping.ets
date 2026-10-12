/**
 * 编辑器 span 的映射与裁剪工具（纯函数）
 *
 * 这里放"编辑器结果类型 → 输入类型"的反向映射，以及把 getSpans() 的返回裁剪到指定区间的逻辑。
 * 撤销 / 重做与持久化两条链路共用这里的函数，避免换算口径分裂。
 */
import { image } from '@kit.ImageKit';
import { SpanSnapshot } from './ChangeRecord';

/**
 * 这个 span 是不是「文本类」—— 有可读的 value，且带 textStyle。
 *
 * 【为什么需要这道判据】类型声明保证 getSpans() 只返回文本 / 图片两种，但**运行时不保证**。
 * 一旦漏出第三种 span（BuilderSpan 是最可能的候选），下面这些地方会立刻炸：
 *   - `textStyleResult2Style` 第一行就读 `result.fontSize`（传 undefined 直接抛）
 *   - 各处的 `(span as RichEditorTextSpanResult).value.xxx`（value 为 undefined）
 * 而 `neighborAt` 是**每次按键**都会走到的路径，`toSnapshot` / `hasSpanBreakingContent`
 * 是任何一次变更捕获都会走到的路径 —— 崩在这里等于编辑器不可用。
 *
 * 判据用「value 是字符串 && textStyle 有值」：图片 span 两者都不满足，正好被排除；
 * 这也与 `Memo.updateContent` 用 `textStyle !== undefined` 判定文本 span 的口径一致。
 * 认不出来的一律当「未知的原子单元」处理 —— 宁可少一次判定，不能崩。
 */
export function isTextLikeSpan(span: RichEditorSpan): boolean {
  const textSpan = span as RichEditorTextSpanResult;
  return typeof textSpan.value === 'string' && textSpan.textStyle !== undefined;
}

/** 从 "resource:///<id>" 形式的 URI 里取出资源 id */
export function parseResourceIdFromUri(uri: string): number | undefined {
  const match = uri.match(/resource:\/\/\/(\d+)/);
  return match ? Number(match[1]) : undefined;
}

/**
 * 这个 span 是不是**文件附件 chip**（builder span）。
 *
 * 【为什么需要】真机实测（见 FILE_ATTACHMENT_REVIEW.md §一）：框架**会**把 builder span
 * 经由 `getSpans()` 返回，但把它伪装成 image span 的形状 —— `imageStyle` 有值、占 1 个坐标单位，
 * 而 `valueResourceStr` 只是个**占位空格**，既不是 `resource:///<id>`，也没有 pixelMap。
 *
 * 所以判据是「排他」的：真实图片必然要么有 pixelMap（相册图）、要么能解析出资源 id（内置图），
 * 两者都不具备的 image 形状 span 就是 builder span。
 *
 * ⚠️ 这与 SDK 声明矛盾 —— `getSpans()` 的返回类型是
 * `Array<RichEditorImageSpanResult | RichEditorTextSpanResult>`，其中并不含 builder。
 * 但运行时确实把它塞进了前者的形状里；真机做了对照测试（附件 vs 待办勾选框）才确认下来。
 *
 * 【为什么放在本文件】快照层必须能把它和真图片区分开 —— 否则 chip 会被抓成 image 快照，
 * 重放时走 `addImageSpan(占位空格)` 把正文弄坏（见 FILE_ATTACHMENT_REVIEW.md §六）。
 * 原定义在 `Memo.ets`，下移到这里是因为本文件不能反向依赖 `Memo`（会成环）。
 */
export function isBuilderSpan(span: RichEditorSpan): boolean {
  const imageSpan = span as RichEditorImageSpanResult;
  if (imageSpan.imageStyle === undefined) {
    return false; // 文本 span
  }
  if (imageSpan.valuePixelMap !== undefined) {
    return false; // 相册图
  }
  const resourceStr = imageSpan.valueResourceStr;
  if (resourceStr === undefined) {
    return true; // 无图源的 image 形状 —— 不是真图片
  }
  if (typeof resourceStr !== 'string') {
    return false; // Resource 对象 = 内置图
  }
  return parseResourceIdFromUri(resourceStr) === undefined;
}

/**
 * 把编辑器返回的数字字体权重转回 FontWeight 枚举。
 * 0~8 对应 100~900；9~14 对应具名枚举
 */
export function fontWeightResult2Value(result: number): FontWeight | number {
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

/**
 * RichEditorTextStyleResult → RichEditorTextStyle
 *
 * 注意：颜色字段**原样透传，不做归一化**。
 * 历史记录只活在内存里、不需要可序列化，而持久化链路的 normalizeColor 会把 Resource 类型
 * 丢弃（返回 undefined），用在这里会导致"撤销回默认色（$r('sys.color.font_primary')）"失效。
 */
export function textStyleResult2Style(result: RichEditorTextStyleResult): RichEditorTextStyle {
  return {
    fontSize: result.fontSize,
    fontStyle: result.fontStyle,
    fontFamily: result.fontFamily,
    fontWeight: fontWeightResult2Value(result.fontWeight),
    fontColor: result.fontColor,
    lineHeight: result.lineHeight,
    letterSpacing: result.letterSpacing,
    decoration: result.decoration ? {
      type: result.decoration.type,
      color: result.decoration.color,
      style: result.decoration.style,
    } : undefined,
  };
}

/** 快照列表占用的总坐标长度 */
export function spansTotalLength(spans: Array<SpanSnapshot>): number {
  let total = 0;
  for (const span of spans) {
    total += span.length;
  }
  return total;
}

/**
 * 把一个 span 原样转成快照（不裁剪）。
 *
 * 不认识 span 类型（既非图片也非文本，见 isTextLikeSpan）时返回 undefined，由调用方跳过。
 * 快照列表是编辑器内容的**真子集**是安全方向 —— 反过来造出一个 value 为 undefined 的
 * "文本快照"，会在后面 clipSpans 的 substring 或 insertSpans 的 addTextSpan 处才炸。
 */
export function toSnapshot(span: RichEditorSpan): SpanSnapshot | undefined {
  const imageSpan = span as RichEditorImageSpanResult;
  if (imageSpan.imageStyle !== undefined) {
    // ⚠️ **builder 必须先于图片判**：它在形状上就是个 image span，顺序反了就会被抓成
    // "imageResource 是占位空格" 的图片快照，重做时走 addImageSpan(占位空格) 损坏正文
    return isBuilderSpan(span) ? snapshotOfBuilder(imageSpan) : snapshotOfImage(imageSpan);
  }
  if (!isTextLikeSpan(span)) {
    console.error(`[undo] 未知类型的 span（既非文本也非图片），已跳过快照`);
    return undefined;
  }
  const textSpan = span as RichEditorTextSpanResult;
  return {
    kind: 'text',
    value: textSpan.value,
    length: textSpan.spanPosition.spanRange[1] - textSpan.spanPosition.spanRange[0],
    textStyle: textStyleResult2Style(textSpan.textStyle),
    paragraphStyle: textSpan.paragraphStyle,
  };
}

/** 一批 span 原样转成快照，按起点排序后返回 */
export function toSnapshots(spans: Array<RichEditorSpan>): Array<SpanSnapshot> {
  const ordered: Array<RichEditorSpan> = spans.slice();
  ordered.sort((a, b) => a.spanPosition.spanRange[0] - b.spanPosition.spanRange[0]);
  const result: Array<SpanSnapshot> = [];
  for (const span of ordered) {
    const snapshot = toSnapshot(span);
    if (snapshot !== undefined) {
      result.push(snapshot);
    }
  }
  return result;
}

function snapshotOfImage(imageSpan: RichEditorImageSpanResult): SpanSnapshot {
  const spanRange = imageSpan.spanPosition.spanRange;
  return {
    kind: 'image',
    value: '',
    length: spanRange[1] - spanRange[0],
    imagePixelMap: imageSpan.valuePixelMap,
    imageResource: imageSpan.valueResourceStr,
  };
}

/**
 * 附件 chip → 快照。
 *
 * **`value` 留空是刻意的**：span 里没有任何文件名信息（`valueResourceStr` 只是个占位空格），
 * 身份只有附件侧表有。所以这里只记下 `offset`，由控制器在捕获结束时拿它反查补上
 * （见 `MemoEditorController.fillBuilderPaths`）。**绝不能**把 `valueResourceStr` 当资源存 ——
 * 那正是重做时 `addImageSpan(" ")` 损坏正文的来源。
 */
function snapshotOfBuilder(imageSpan: RichEditorImageSpanResult): SpanSnapshot {
  const spanRange = imageSpan.spanPosition.spanRange;
  return {
    kind: 'builder',
    value: '',
    length: spanRange[1] - spanRange[0],
    offset: spanRange[0],
  };
}

/**
 * 把 getSpans() 返回的「整个 span」裁剪到 [start, end)，产出按顺序排列的快照。
 *
 * getSpans(range) 返回的是与区间**有交叠的完整 span**（不裁剪），所以必须自己做这一步。
 * 依赖两个已真机验证的前提：
 *   - 文本 span 内「编辑器偏移 − spanRange[0]」就是字符串下标
 *   - 编辑器坐标等于 UTF-16 码元数（emoji 代理对、中文均已实测一致）
 */
export function clipSpans(spans: Array<RichEditorSpan>, start: number, end: number): Array<SpanSnapshot> {
  const result: Array<SpanSnapshot> = [];
  for (const span of spans) {
    const spanRange = span.spanPosition.spanRange;
    const spanStart = spanRange[0];
    const spanEnd = spanRange[1];
    // 与目标区间无交集
    if (spanEnd <= start || spanStart >= end) {
      continue;
    }

    const imageSpan = span as RichEditorImageSpanResult;
    if (imageSpan.imageStyle !== undefined) {
      // 图片与附件 chip 都是原子单位，只接受完整落在区间内的；被区间切开视为异常
      if (spanStart >= start && spanEnd <= end) {
        result.push(isBuilderSpan(span) ? snapshotOfBuilder(imageSpan) : snapshotOfImage(imageSpan));
      } else {
        console.error(`[undo] 图片 / 附件 span [${spanStart}, ${spanEnd}) 被区间 [${start}, ${end}) 切开，已跳过`);
      }
      continue;
    }

    if (!isTextLikeSpan(span)) {
      console.error(`[undo] 未知类型的 span [${spanStart}, ${spanEnd})，已跳过`);
      continue;
    }
    const textSpan = span as RichEditorTextSpanResult;
    const from = Math.max(start, spanStart) - spanStart;
    const to = Math.min(end, spanEnd) - spanStart;
    if (to <= from) {
      continue;
    }
    result.push({
      kind: 'text',
      value: textSpan.value.substring(from, to),
      length: to - from,
      textStyle: textStyleResult2Style(textSpan.textStyle),
      paragraphStyle: textSpan.paragraphStyle,
    });
  }
  return result;
}
