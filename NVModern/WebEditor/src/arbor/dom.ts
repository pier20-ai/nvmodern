export function plainText(element: HTMLElement): string {
  return element.innerText.replace(/\r\n?/g, "\n");
}

export function caretOffset(element: HTMLElement): number {
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) return 0;

  const range = selection.getRangeAt(0);
  if (!element.contains(range.startContainer)) return 0;

  const prefix = range.cloneRange();
  prefix.selectNodeContents(element);
  prefix.setEnd(range.startContainer, range.startOffset);
  return prefix.toString().length;
}

export function selectionOffsets(
  element: HTMLElement,
): { start: number; end: number } | null {
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) return null;
  const range = selection.getRangeAt(0);
  if (!element.contains(range.commonAncestorContainer)) return null;

  const offset = (node: Node, nodeOffset: number) => {
    const prefix = range.cloneRange();
    prefix.selectNodeContents(element);
    prefix.setEnd(node, nodeOffset);
    return prefix.toString().length;
  };
  const start = offset(range.startContainer, range.startOffset);
  const end = offset(range.endContainer, range.endOffset);
  return { start: Math.min(start, end), end: Math.max(start, end) };
}

export interface VerticalBox {
  readonly top: number;
  readonly bottom: number;
}

export function isCaretOnVisualLineBoundary(
  direction: "up" | "down",
  caret: VerticalBox,
  fragments: readonly VerticalBox[],
): boolean {
  const fragmentCenters = fragments
    .filter((fragment) => fragment.bottom > fragment.top)
    .map((fragment) => (fragment.top + fragment.bottom) / 2)
    .sort((left, right) => left - right);
  const lineCenters: number[] = [];
  for (const center of fragmentCenters) {
    const previous = lineCenters.at(-1);
    if (previous === undefined || center - previous > 2) lineCenters.push(center);
  }
  if (lineCenters.length === 0) return true;

  const caretCenter = (caret.top + caret.bottom) / 2;
  let nearestIndex = 0;
  for (let index = 1; index < lineCenters.length; index += 1) {
    if (Math.abs(lineCenters[index]! - caretCenter)
      < Math.abs(lineCenters[nearestIndex]! - caretCenter)) nearestIndex = index;
  }
  return direction === "up"
    ? nearestIndex === 0
    : nearestIndex === lineCenters.length - 1;
}

function firstVisibleRect(range: Range): DOMRect | null {
  return Array.from(range.getClientRects()).find((rect) => rect.height > 0) ?? null;
}

function caretRect(range: Range): DOMRect | null {
  const direct = firstVisibleRect(range);
  if (direct) return direct;

  const node = range.startContainer;
  const length = node.nodeType === Node.TEXT_NODE ? node.textContent?.length ?? 0 : 0;
  if (length === 0) return null;

  const probe = document.createRange();
  if (range.startOffset < length) {
    probe.setStart(node, range.startOffset);
    probe.setEnd(node, range.startOffset + 1);
  } else {
    probe.setStart(node, range.startOffset - 1);
    probe.setEnd(node, range.startOffset);
  }
  return firstVisibleRect(probe);
}

export function scrollDeltaToReveal(
  caret: VerticalBox,
  viewport: VerticalBox,
  requestedMargin = 8,
): number {
  const margin = Math.max(
    0,
    Math.min(requestedMargin, Math.max(0, (viewport.bottom - viewport.top) / 2)),
  );
  const visibleTop = viewport.top + margin;
  const visibleBottom = viewport.bottom - margin;
  if (caret.top < visibleTop) return caret.top - visibleTop;
  if (caret.bottom > visibleBottom) return caret.bottom - visibleBottom;
  return 0;
}

export function scrollCaretIntoView(
  element: HTMLElement,
  scroller: HTMLElement,
  margin = 8,
): void {
  const selection = window.getSelection();
  if (!selection?.isCollapsed || selection.rangeCount === 0) return;
  const range = selection.getRangeAt(0);
  if (!element.contains(range.startContainer)) return;
  const caret = caretRect(range) ?? element.getBoundingClientRect();
  const delta = scrollDeltaToReveal(caret, scroller.getBoundingClientRect(), margin);
  if (delta !== 0) scroller.scrollTop += delta;
}

export function caretIsOnVisualLineBoundary(
  element: HTMLElement,
  direction: "up" | "down",
): boolean {
  const selection = window.getSelection();
  if (!selection?.isCollapsed || selection.rangeCount === 0) return false;
  const range = selection.getRangeAt(0);
  if (!element.contains(range.startContainer)) return false;

  const caret = caretRect(range);
  const contents = document.createRange();
  contents.selectNodeContents(element);
  const fragments = Array.from(contents.getClientRects());
  return caret ? isCaretOnVisualLineBoundary(direction, caret, fragments) : true;
}

function textPointAtOffset(
  element: HTMLElement,
  requestedOffset: number,
): { node: Node; offset: number } {
  const targetOffset = Math.max(0, requestedOffset);
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let remaining = targetOffset;
  let node = walker.nextNode();

  while (node) {
    const length = node.textContent?.length ?? 0;
    if (remaining <= length) {
      return { node, offset: remaining };
    }
    remaining -= length;
    node = walker.nextNode();
  }

  return { node: element, offset: element.childNodes.length };
}

export function placeSelection(
  element: HTMLElement,
  requestedStart: number,
  requestedEnd: number,
): void {
  const start = textPointAtOffset(element, Math.min(requestedStart, requestedEnd));
  const end = textPointAtOffset(element, Math.max(requestedStart, requestedEnd));
  const range = document.createRange();
  range.setStart(start.node, start.offset);
  range.setEnd(end.node, end.offset);
  const selection = window.getSelection();
  selection?.removeAllRanges();
  selection?.addRange(range);
}

export function placeCaret(element: HTMLElement, requestedOffset: number): void {
  placeSelection(element, requestedOffset, requestedOffset);
}

export function focusEditor(element: HTMLElement, offset: number): void {
  element.focus({ preventScroll: true });
  placeCaret(element, offset);
}

export function focusEditorSelection(
  element: HTMLElement,
  start: number,
  end: number,
): void {
  element.focus({ preventScroll: true });
  placeSelection(element, start, end);
}

export function insertTextAtSelection(element: HTMLElement, text: string): void {
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) return;
  const range = selection.getRangeAt(0);
  if (!element.contains(range.commonAncestorContainer)) return;

  range.deleteContents();
  const node = document.createTextNode(text);
  range.insertNode(node);
  range.setStartAfter(node);
  range.collapse(true);
  selection.removeAllRanges();
  selection.addRange(range);
  element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
}
