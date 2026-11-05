import {
  type ArborBlockId,
  type ArborDocumentSnapshot,
  type ArborEditResult,
  type ArborMoveDestination,
  type ArborVisibleRow,
  ArborOutlineStore,
} from "../lib/arbor/index.ts";

export type ArborCompletionKind = "page" | "block" | "tag" | "command";

export interface ArborCompletionTrigger {
  readonly kind: ArborCompletionKind;
  readonly start: number;
  readonly end: number;
  readonly query: string;
}

export interface ArborCompletionItem {
  readonly id: string;
  readonly label: string;
  readonly detail: string;
  readonly insertText: string;
}

export interface ArborCompletionProvider {
  candidates(
    trigger: ArborCompletionTrigger,
    snapshot: ArborDocumentSnapshot,
  ): readonly ArborCompletionItem[];
}

export function workspacePageCompletionItems(
  suggestions: readonly { label: string; insertText: string; detail?: string }[],
): ArborCompletionItem[] {
  return suggestions.slice(0, 8).map((item) => ({
    id: item.insertText,
    label: item.label,
    detail: item.detail ?? "Document",
    insertText: `[[${item.insertText}]]`,
  }));
}

export function completionPosition(
  caretLeft: number,
  caretBottom: number,
  viewportWidth: number,
  viewportHeight: number,
): { left: number; top: number } {
  const width = Math.min(320, viewportWidth - 24);
  return {
    left: Math.max(12, Math.min(caretLeft, viewportWidth - width - 12)),
    top: Math.max(12, Math.min(caretBottom + 4, viewportHeight - 260)),
  };
}

export function pastedBlockTexts(
  currentText: string,
  start: number,
  end: number,
  clipboardText: string,
): string[] {
  const selectionStart = Math.max(0, Math.min(start, end, currentText.length));
  const selectionEnd = Math.max(selectionStart, Math.min(Math.max(start, end), currentText.length));
  const lines = clipboardText.replace(/\r\n?/g, "\n").split("\n");
  if (lines.length > 1 && lines.at(-1) === "") lines.pop();
  if (lines.length === 0) lines.push("");
  return lines.map((line, index) => (
    `${index === 0 ? currentText.slice(0, selectionStart) : ""}${line}${
      index === lines.length - 1 ? currentText.slice(selectionEnd) : ""
    }`
  ));
}

export interface ArborDelimitedSelectionEdit {
  readonly text: string;
  readonly start: number;
  readonly end: number;
}

export function toggleDelimitedSelection(
  text: string,
  start: number,
  end: number,
  open: string,
  close: string,
): ArborDelimitedSelectionEdit | null {
  const selectionStart = Math.max(0, Math.min(start, end, text.length));
  const selectionEnd = Math.max(selectionStart, Math.min(Math.max(start, end), text.length));
  if (selectionStart === selectionEnd) return null;

  const isWrapped = selectionStart >= open.length
    && selectionEnd + close.length <= text.length
    && text.slice(selectionStart - open.length, selectionStart) === open
    && text.slice(selectionEnd, selectionEnd + close.length) === close;

  if (isWrapped) {
    return {
      text: text.slice(0, selectionStart - open.length)
        + text.slice(selectionStart, selectionEnd)
        + text.slice(selectionEnd + close.length),
      start: selectionStart - open.length,
      end: selectionEnd - open.length,
    };
  }

  return {
    text: text.slice(0, selectionStart)
      + open
      + text.slice(selectionStart, selectionEnd)
      + close
      + text.slice(selectionEnd),
    start: selectionStart + open.length,
    end: selectionEnd + open.length,
  };
}

const slashCommands: readonly ArborCompletionItem[] = [
  { id: "todo", label: "TODO", detail: "Task marker", insertText: "{{[[TODO]]}}" },
  { id: "heading", label: "Heading", detail: "Markdown heading", insertText: "# " },
  { id: "divider", label: "Divider", detail: "Markdown divider", insertText: "---" },
];

export function completionTrigger(text: string, caret: number): ArborCompletionTrigger | null {
  const prefix = text.slice(0, Math.max(0, Math.min(caret, text.length)));
  const lineStart = prefix.lastIndexOf("\n") + 1;
  const line = prefix.slice(lineStart);
  const candidates: ArborCompletionTrigger[] = [];

  const pageStart = line.lastIndexOf("[[");
  if (pageStart >= 0 && !line.slice(pageStart + 2).includes("]]")) {
    candidates.push({
      kind: "page",
      start: lineStart + pageStart,
      end: prefix.length,
      query: line.slice(pageStart + 2),
    });
  }

  const blockStart = line.lastIndexOf("((");
  if (blockStart >= 0 && !line.slice(blockStart + 2).includes("))")) {
    candidates.push({
      kind: "block",
      start: lineStart + blockStart,
      end: prefix.length,
      query: line.slice(blockStart + 2),
    });
  }

  const token = /(^|\s)([#/])([^\s#/]*)$/.exec(line);
  if (token) {
    const marker = token[2]!;
    const start = lineStart + line.length - token[0].length + token[1]!.length;
    candidates.push({
      kind: marker === "#" ? "tag" : "command",
      start,
      end: prefix.length,
      query: token[3]!,
    });
  }

  return candidates.sort((left, right) => right.start - left.start)[0] ?? null;
}

function normalizedText(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

export const localCompletionProvider: ArborCompletionProvider = {
  candidates(trigger, snapshot) {
    let items: ArborCompletionItem[];
    if (trigger.kind === "page") {
      items = snapshot.pages.map((page) => ({
        id: page.id,
        label: page.title,
        detail: "Page",
        insertText: `[[${page.title}]]`,
      }));
    } else if (trigger.kind === "block") {
      items = snapshot.blocks.map((block) => ({
        id: block.id,
        label: normalizedText(block.text) || "Empty block",
        detail: block.id,
        insertText: `((${block.id}))`,
      }));
    } else if (trigger.kind === "tag") {
      const tags = new Set<string>();
      for (const block of snapshot.blocks) {
        for (const match of block.text.matchAll(/(?:^|\s)#([\p{L}\p{N}_/-]+)/gu)) tags.add(match[1]!);
      }
      items = [...tags].map((tag) => ({
        id: tag.toLocaleLowerCase(),
        label: tag,
        detail: "Tag",
        insertText: `#${tag}`,
      }));
    } else {
      items = [...slashCommands];
    }

    const query = trigger.query.toLocaleLowerCase();
    return items
      .filter((item) => item.label.toLocaleLowerCase().includes(query))
      .slice(0, 8);
  },
};

export function rangeSelection(
  rows: readonly ArborVisibleRow[],
  anchor: ArborBlockId,
  target: ArborBlockId,
): Set<ArborBlockId> {
  const anchorIndex = rows.findIndex((row) => row.id === anchor);
  const targetIndex = rows.findIndex((row) => row.id === target);
  if (anchorIndex < 0 || targetIndex < 0) return new Set([target]);
  const start = Math.min(anchorIndex, targetIndex);
  const end = Math.max(anchorIndex, targetIndex);
  return new Set(rows.slice(start, end + 1).map((row) => row.id));
}

export interface ArborRangeExtension {
  readonly extentId: ArborBlockId;
  readonly selectedIds: ReadonlySet<ArborBlockId>;
}

export function extendRangeSelection(
  rows: readonly ArborVisibleRow[],
  anchorId: ArborBlockId,
  extentId: ArborBlockId,
  direction: "up" | "down",
): ArborRangeExtension | null {
  const extentIndex = rows.findIndex((row) => row.id === extentId);
  if (extentIndex < 0) return null;
  const target = rows[extentIndex + (direction === "up" ? -1 : 1)];
  return target
    ? { extentId: target.id, selectedIds: rangeSelection(rows, anchorId, target.id) }
    : null;
}

export interface ArborPointerRange {
  readonly dragged: boolean;
  readonly extentId: ArborBlockId;
  readonly selectedIds: ReadonlySet<ArborBlockId>;
}

export function pointerRangeSelection(
  rows: readonly ArborVisibleRow[],
  anchorId: ArborBlockId,
  extentId: ArborBlockId,
  wasDragged: boolean,
): ArborPointerRange {
  return {
    dragged: wasDragged || extentId !== anchorId,
    extentId,
    selectedIds: rangeSelection(rows, anchorId, extentId),
  };
}

export function shouldExtendBlockSelection(
  direction: "up" | "down",
  caret: number,
  textLength: number,
  selectionCollapsed: boolean,
  hasBlockSelection: boolean,
): boolean {
  if (!selectionCollapsed) return false;
  if (hasBlockSelection) return true;
  return direction === "up" ? caret === 0 : caret === textLength;
}

export function shouldMergeBlockOnBackspace(
  caret: number,
  selectionCollapsed: boolean,
): boolean {
  return selectionCollapsed && caret === 0;
}

export function selectionRoots(
  store: ArborOutlineStore,
  orderedIds: readonly ArborBlockId[],
): ArborBlockId[] {
  const selected = new Set(orderedIds);
  return orderedIds.filter((id) => {
    let parentId = store.getBlock(id)?.parentId ?? null;
    while (parentId) {
      if (selected.has(parentId)) return false;
      parentId = store.getBlock(parentId)?.parentId ?? null;
    }
    return true;
  });
}

export function selectedOutlineText(
  store: ArborOutlineStore,
  roots: readonly ArborBlockId[],
): string {
  const lines: string[] = [];
  const append = (id: ArborBlockId, depth: number) => {
    const block = store.getBlock(id);
    if (!block) return;
    lines.push(`${"  ".repeat(depth)}- ${block.text}`);
    for (const childId of store.childIds(block.pageId, block.id)) append(childId, depth + 1);
  };
  for (const root of roots) append(root, 0);
  return lines.join("\n");
}

export function selectedRowsOutlineText(
  store: ArborOutlineStore,
  orderedIds: readonly ArborBlockId[],
): string {
  const selected = new Set(orderedIds);
  return orderedIds.flatMap((id) => {
    const block = store.getBlock(id);
    if (!block) return [];
    let depth = 0;
    let parentId = block.parentId;
    while (parentId) {
      if (selected.has(parentId)) depth += 1;
      parentId = store.getBlock(parentId)?.parentId ?? null;
    }
    return `${"  ".repeat(depth)}- ${block.text}`;
  }).join("\n");
}

export type ArborDropPlacement = "before" | "after" | "first-child" | "last-child";

export interface ArborDropTarget {
  readonly blockId: ArborBlockId;
  readonly placement: ArborDropPlacement;
}

export function dropTargetAtPointer(
  blockId: ArborBlockId,
  clientY: number,
  top: number,
  height: number,
): ArborDropTarget {
  const position = height > 0 ? (clientY - top) / height : 0;
  const placement: ArborDropPlacement = position < 0.25
    ? "before"
    : position > 0.75
      ? "after"
      : position < 0.5
        ? "first-child"
        : "last-child";
  return { blockId, placement };
}

export function dropDestination(
  store: ArborOutlineStore,
  target: ArborDropTarget,
): ArborMoveDestination | null {
  const block = store.getBlock(target.blockId);
  if (!block) return null;
  if (target.placement === "before") {
    return {
      pageId: block.pageId,
      parentId: block.parentId,
      afterId: block.previousSiblingId,
    };
  }
  if (target.placement === "after") {
    return { pageId: block.pageId, parentId: block.parentId, afterId: block.id };
  }
  return {
    pageId: block.pageId,
    parentId: block.id,
    afterId: target.placement === "first-child" ? null : block.lastChildId,
  };
}

function hasAncestor(
  store: ArborOutlineStore,
  blockId: ArborBlockId | null,
  possibleAncestorIds: ReadonlySet<ArborBlockId>,
): boolean {
  let cursor = blockId;
  while (cursor) {
    if (possibleAncestorIds.has(cursor)) return true;
    cursor = store.getBlock(cursor)?.parentId ?? null;
  }
  return false;
}

export function canDropBlocks(
  store: ArborOutlineStore,
  roots: readonly ArborBlockId[],
  target: ArborDropTarget,
): boolean {
  const destination = dropDestination(store, target);
  if (!destination || roots.length === 0) return false;
  const sourceIds = new Set(roots);
  if (hasAncestor(store, target.blockId, sourceIds)) return false;
  if (destination.afterId && sourceIds.has(destination.afterId)) return false;
  return !hasAncestor(store, destination.parentId, sourceIds);
}

export function moveBlocksToTarget(
  store: ArborOutlineStore,
  roots: readonly ArborBlockId[],
  target: ArborDropTarget,
): ArborEditResult {
  const destination = dropDestination(store, target);
  if (!destination || !canDropBlocks(store, roots, target)) {
    return { changed: false, focus: null };
  }

  let afterId = destination.afterId;
  return store.transaction("Move blocks", () => {
    for (const blockId of roots) {
      store.moveBlock(blockId, { ...destination, afterId });
      afterId = blockId;
    }
  });
}

export function outdentBlocks(
  store: ArborOutlineStore,
  roots: readonly ArborBlockId[],
): ArborEditResult {
  return store.transaction("Outdent blocks", () => {
    for (const blockId of [...roots].reverse()) store.outdentBlock(blockId);
  });
}

export function keyboardDropTarget(
  store: ArborOutlineStore,
  roots: readonly ArborBlockId[],
  direction: "up" | "down",
): ArborDropTarget | null {
  const blocks = roots.map((id) => store.getBlock(id));
  if (blocks.length === 0 || blocks.some((block) => !block)) return null;
  const first = blocks[0]!;
  if (blocks.some((block) => block!.pageId !== first.pageId || block!.parentId !== first.parentId)) {
    return null;
  }
  for (let index = 1; index < blocks.length; index += 1) {
    if (blocks[index - 1]!.nextSiblingId !== blocks[index]!.id) return null;
  }
  if (direction === "up") {
    return first.previousSiblingId
      ? { blockId: first.previousSiblingId, placement: "before" }
      : null;
  }
  const last = blocks.at(-1)!;
  return last.nextSiblingId
    ? { blockId: last.nextSiblingId, placement: "after" }
    : null;
}
