/**
 * 撤销/重做的实现前探针 —— 【临时文件，验证完整个删除】
 *
 * 只打日志，不改任何行为。目的是确认 RichEditor 内容变更回调的真实语义：
 * 触发时机、rangeBefore / rangeAfter 的含义、程序化调用是否会回声、IME 与粘贴的路径等。
 *
 * 日志统一以 [undo-probe] 开头，便于过滤。
 */

// 用于核对 onWillChange / onDidChange 是否严格 1:1 配对
let willCount = 0;
let didCount = 0;
let selectionCount = 0;

/** 把换行转义，避免一条日志被拆成多行 */
function escapeText(text: string): string {
  return text.replace(/\n/g, '\\n');
}

/** 截断过长文本，保持日志可读 */
function short(text: string, max: number = 24): string {
  return text.length <= max ? text : `${text.substring(0, max)}...(${text.length})`;
}

function rangeText(start: number | undefined, end: number | undefined): string {
  return `[${start ?? 0}, ${end ?? 0})`;
}

/** 单条 span 的摘要：区间、长度、文本长度、内容 */
export function describeSpan(span: RichEditorSpan): string {
  const spanRange = span.spanPosition.spanRange;
  const len = spanRange[1] - spanRange[0];
  const imageSpan = span as RichEditorImageSpanResult;
  if (imageSpan.imageStyle !== undefined) {
    const size = imageSpan.imageStyle.size;
    return `image range=${rangeText(spanRange[0], spanRange[1])} len=${len} `
      + `hasPixelMap=${imageSpan.valuePixelMap !== undefined} `
      + `resource=${imageSpan.valueResourceStr !== undefined} size=[${size[0]}, ${size[1]}]`;
  }
  const textSpan = span as RichEditorTextSpanResult;
  return `text  range=${rangeText(spanRange[0], spanRange[1])} len=${len} `
    + `valueLen=${textSpan.value.length} value="${escapeText(short(textSpan.value))}"`;
}

/**
 * 读一次全文并拼成可读字符串（图片记为 [图]）。
 * 关键在于同一个函数在 onWillChange 和 onDidChange 里各调一次 ——
 * 对比两行的内容，就能判断 onWillChange 触发时框架的内部模型有没有更新：
 *   willSnapshot 是旧内容 → 我们能在 onWillChange 抓到撤销所需的旧内容
 *   willSnapshot 已是新内容 → 抓不到，得换路子
 */
function docSnapshot(controller: RichEditorController): string {
  const spans = controller.getSpans({ start: 0, end: 100000 });
  let text = '';
  for (const span of spans) {
    const imageSpan = span as RichEditorImageSpanResult;
    if (imageSpan.imageStyle !== undefined) {
      text += '[图]';
    } else {
      text += (span as RichEditorTextSpanResult).value;
    }
  }
  return `spans=${spans.length} 全文="${escapeText(short(text, 40))}"`;
}

/** 查一次区间并打印结果 */
function logRangeQuery(controller: RichEditorController, label: string, start: number, end: number): void {
  try {
    const spans = controller.getSpans({ start: start, end: end });
    let desc = '';
    for (const span of spans) {
      desc += ` | ${describeSpan(span)}`;
    }
    console.info(`[undo-probe]     ${label} [${start}, ${end}) → ${spans.length} 个${desc}`);
  } catch (error) {
    console.error(`[undo-probe]     ${label} [${start}, ${end}) → 查询失败: ${JSON.stringify(error)}`);
  }
}

/**
 * 【方向 A 探针】围绕插入点查询三个区间，看能否稳定拿到「插入点所在的旧 span」。
 *
 * 若能拿到，就意味着插入场景也能在 onWillChange 里拿到旧侧的确切范围，
 * 记录逻辑就不必依赖 onDidChange 的 rangeAfter，pendingChange 也就能去掉。
 */
function probeNeighborhood(controller: RichEditorController, caret: number): void {
  console.info(`[undo-probe]   neighborhood of caret=${caret}:`);
  logRangeQuery(controller, '空区间    ', caret, caret);
  logRangeQuery(controller, '右侧一格  ', caret, caret + 1);
  logRangeQuery(controller, '跨插入点  ', Math.max(0, caret - 1), caret + 1);
}

/**
 * 程序化调用的标记。用于判断 addTextSpan / addImageSpan / updateSpanStyle /
 * updateParagraphStyle / deleteSpans 这些我们自己发起的调用会不会触发内容变更回调。
 */
export function probeProgrammatic(action: string): void {
  console.info(`[undo-probe] >>> programmatic: ${action}  (will=${willCount}, did=${didCount})`);
}

/**
 * onWillChange —— 变更【前】触发
 */
export function probeWillChange(value: RichEditorChangeValue, controller: RichEditorController): void {
  willCount++;
  const replaced = value.replacedSpans;
  const replacedImages = value.replacedImageSpans;
  const replacedSymbols = value.replacedSymbolSpans;
  console.info(`[undo-probe] onWillChange #${willCount} rangeBefore=${rangeText(value.rangeBefore.start, value.rangeBefore.end)} `
    + `texts=${replaced.length} images=${replacedImages.length} symbols=${replacedSymbols.length} (did=${didCount})`);
  // 【关键】此刻读到的是旧内容还是新内容？
  try {
    console.info(`[undo-probe]   willSnapshot: ${docSnapshot(controller)}`);
  } catch (error) {
    console.error(`[undo-probe]   willSnapshot 读取失败: ${JSON.stringify(error)}`);
  }
  // 【方向 A 探针】rangeBefore 为空 = 纯插入，正是拿不到长度的那个场景
  const beforeStart = value.rangeBefore.start ?? 0;
  const beforeEnd = value.rangeBefore.end ?? 0;
  if (beforeEnd === beforeStart) {
    probeNeighborhood(controller, beforeStart);
  }
  for (let i = 0; i < replaced.length; i++) {
    console.info(`[undo-probe]   will.text[${i}] ${describeSpan(replaced[i])}`);
  }
  for (let i = 0; i < replacedImages.length; i++) {
    console.info(`[undo-probe]   will.image[${i}] ${describeSpan(replacedImages[i])}`);
  }
  for (let i = 0; i < replacedSymbols.length; i++) {
    console.info(`[undo-probe]   will.symbol[${i}] ${describeSpan(replacedSymbols[i])}`);
  }
}

/**
 * onDidChange —— 变更【后】触发，只给区间不给内容，所以这里主动读回 rangeAfter 内的 span。
 * 重点看：能否同步读回、读回的是不是刚变更的那段、spans 长度之和是否等于区间长度（Q4 / Q6）
 */
export function probeDidChange(rangeBefore: TextRange, rangeAfter: TextRange,
  controller: RichEditorController): void {
  didCount++;
  const beforeStart = rangeBefore.start ?? 0;
  const beforeEnd = rangeBefore.end ?? 0;
  const afterStart = rangeAfter.start ?? 0;
  const afterEnd = rangeAfter.end ?? 0;
  console.info(`[undo-probe] onDidChange #${didCount} rangeBefore=[${beforeStart}, ${beforeEnd}) `
    + `rangeAfter=[${afterStart}, ${afterEnd}) (will=${willCount})`);
  // 变更【后】的全文，用来和上面的 willSnapshot 对比
  try {
    console.info(`[undo-probe]   didSnapshot:  ${docSnapshot(controller)}`);
  } catch (error) {
    console.error(`[undo-probe]   didSnapshot 读取失败: ${JSON.stringify(error)}`);
  }

  if (afterEnd <= afterStart) {
    console.info(`[undo-probe]   afterSpans: (rangeAfter 为空，跳过读取)`);
    return;
  }
  try {
    const spans = controller.getSpans({ start: afterStart, end: afterEnd });
    let totalLen = 0;
    for (const span of spans) {
      const spanRange = span.spanPosition.spanRange;
      totalLen += spanRange[1] - spanRange[0];
    }
    console.info(`[undo-probe]   afterSpans=${spans.length} sumLen=${totalLen} `
      + `rangeLen=${afterEnd - afterStart} ${totalLen === afterEnd - afterStart ? '(严丝合缝)' : '(不相等!)'}`);
    for (let i = 0; i < spans.length; i++) {
      console.info(`[undo-probe]   did.span[${i}] ${describeSpan(spans[i])}`);
    }
  } catch (error) {
    console.error(`[undo-probe]   afterSpans 读取失败: ${JSON.stringify(error)}`);
  }
}

/** onSelectionChange —— 观察 IME 组合输入期间是否高频触发（会打断"连续输入合并"） */
export function probeSelection(range: RichEditorRange): void {
  selectionCount++;
  console.info(`[undo-probe] onSelectionChange #${selectionCount} ${rangeText(range.start, range.end)}`);
}

/** 其它事件只记"发生了"，用于确认走哪条回调路径 */
export function probeEvent(name: string): void {
  console.info(`[undo-probe] event: ${name}`);
}

/** IME 输入开始（插入前） */
export function probeIMEInput(value: RichEditorInsertValue): void {
  console.info(`[undo-probe] aboutToIMEInput offset=${value.insertOffset} `
    + `value="${escapeText(short(value.insertValue))}"`);
}

/** IME 输入完成，给出上屏后的 span */
export function probeIMEComplete(span: RichEditorTextSpanResult): void {
  console.info(`[undo-probe] onIMEInputComplete ${describeSpan(span)}`);
}
