import { describe, expect, it } from "bun:test";
import {
  ArborOutlineStore,
  ArborVisibleIndex,
  arborBlockId,
  arborPageId,
  type ArborDocumentSnapshot,
} from "../lib/arbor/index.ts";
import {
  canDropBlocks,
  completionPosition,
  completionTrigger,
  dropDestination,
  extendRangeSelection,
  keyboardDropTarget,
  localCompletionProvider,
  moveBlocksToTarget,
  outdentBlocks,
  pastedBlockTexts,
  pointerRangeSelection,
  rangeSelection,
  selectedOutlineText,
  selectedRowsOutlineText,
  selectionRoots,
  shouldExtendBlockSelection,
  shouldMergeBlockOnBackspace,
  toggleDelimitedSelection,
  workspacePageCompletionItems,
} from "./interactions.ts";

const pageId = arborPageId("page");
const snapshot: ArborDocumentSnapshot = {
  version: 1,
  pages: [
    { id: pageId, title: "Project Notes", children: [arborBlockId("a"), arborBlockId("b"), arborBlockId("c")] },
  ],
  blocks: [
    { id: arborBlockId("a"), pageId, parentId: null, children: [arborBlockId("a1")], text: "Alpha #work" },
    { id: arborBlockId("a1"), pageId, parentId: arborBlockId("a"), children: [], text: "Alpha child" },
    { id: arborBlockId("b"), pageId, parentId: null, children: [], text: "Beta #later" },
    { id: arborBlockId("c"), pageId, parentId: null, children: [], text: "Gamma" },
  ],
};

function fixture() {
  return ArborOutlineStore.fromSnapshot(snapshot);
}

describe("Arbor renderer interactions", () => {
  it("detects the nearest open completion trigger", () => {
    expect(completionTrigger("See [[Proj", 10)).toEqual({
      kind: "page",
      start: 4,
      end: 10,
      query: "Proj",
    });
    expect(completionTrigger("Run /to", 7)?.kind).toBe("command");
    expect(completionTrigger("Closed [[Page]]", 15)).toBeNull();
  });

  it("keeps the caret menu inside the viewport", () => {
    expect(completionPosition(900, 700, 1000, 800)).toEqual({ left: 668, top: 540 });
    expect(completionPosition(-10, -10, 1000, 800)).toEqual({ left: 12, top: 12 });
  });

  it("turns pasted lines into sibling block text and keeps the surrounding text", () => {
    expect(pastedBlockTexts("BeforeAfter", 6, 6, "One\r\nTwo\nThree")).toEqual([
      "BeforeOne",
      "Two",
      "ThreeAfter",
    ]);
    expect(pastedBlockTexts("Replace me", 0, 10, "First\nSecond\n")).toEqual([
      "First",
      "Second",
    ]);
  });

  it("toggles bold and italic delimiters around a text selection", () => {
    expect(toggleDelimitedSelection("hello world", 6, 11, "**", "**")).toEqual({
      text: "hello **world**",
      start: 8,
      end: 13,
    });
    expect(toggleDelimitedSelection("hello **world**", 8, 13, "**", "**")).toEqual({
      text: "hello world",
      start: 6,
      end: 11,
    });
    expect(toggleDelimitedSelection("alpha beta", 0, 5, "*", "*")).toEqual({
      text: "*alpha* beta",
      start: 1,
      end: 6,
    });
  });

  it("does not add formatting delimiters without a selection", () => {
    expect(toggleDelimitedSelection("hello", 2, 2, "**", "**")).toBeNull();
  });

  it("builds local page, block, tag, and slash candidates", () => {
    expect(localCompletionProvider.candidates(
      { kind: "page", start: 0, end: 4, query: "proj" },
      snapshot,
    )[0]?.insertText).toBe("[[Project Notes]]");
    expect(localCompletionProvider.candidates(
      { kind: "block", start: 0, end: 2, query: "alpha" },
      snapshot,
    ).map((item) => item.id)).toEqual(["a", "a1"]);
    expect(localCompletionProvider.candidates(
      { kind: "tag", start: 0, end: 1, query: "lat" },
      snapshot,
    )[0]?.insertText).toBe("#later");
    expect(localCompletionProvider.candidates(
      { kind: "command", start: 0, end: 1, query: "to" },
      snapshot,
    )[0]?.label).toBe("TODO");
  });

  it("turns workspace documents into page links without changing local block completion", () => {
    expect(workspacePageCompletionItems([{
      label: "Projects/Roadmap.outline",
      insertText: "Projects/Roadmap.outline",
      detail: "Projects/Roadmap.outline",
    }])).toEqual([{
      id: "Projects/Roadmap.outline",
      label: "Projects/Roadmap.outline",
      detail: "Projects/Roadmap.outline",
      insertText: "[[Projects/Roadmap.outline]]",
    }]);
    expect(localCompletionProvider.candidates(
      { kind: "block", start: 0, end: 2, query: "beta" },
      snapshot,
    ).map((item) => item.id)).toEqual(["b"]);
  });

  it("keeps range selection stable and removes selected descendants", () => {
    const store = fixture();
    const rows = new ArborVisibleIndex(store).rows(pageId);
    const selected = rangeSelection(rows, arborBlockId("a"), arborBlockId("b"));

    expect([...selected]).toEqual([arborBlockId("a"), arborBlockId("a1"), arborBlockId("b")]);
    const roots = selectionRoots(store, rows.filter((row) => selected.has(row.id)).map((row) => row.id));
    expect(roots).toEqual([arborBlockId("a"), arborBlockId("b")]);
    expect(selectedOutlineText(store, roots)).toBe(
      "- Alpha #work\n  - Alpha child\n- Beta #later",
    );
  });

  it("copies only explicitly selected rows while preserving selected ancestry", () => {
    const store = fixture();

    expect(selectedRowsOutlineText(store, [
      arborBlockId("a"),
      arborBlockId("a1"),
      arborBlockId("c"),
    ])).toBe(
      "- Alpha #work\n  - Alpha child\n- Gamma",
    );
  });

  it("extends, shrinks, and reverses a structural Shift range around its anchor", () => {
    const rows = new ArborVisibleIndex(fixture()).rows(pageId);
    const down = extendRangeSelection(
      rows,
      arborBlockId("a1"),
      arborBlockId("a1"),
      "down",
    )!;
    expect(down.extentId).toBe(arborBlockId("b"));
    expect([...down.selectedIds]).toEqual([arborBlockId("a1"), arborBlockId("b")]);

    const shrunk = extendRangeSelection(rows, arborBlockId("a1"), down.extentId, "up")!;
    expect(shrunk.extentId).toBe(arborBlockId("a1"));
    expect([...shrunk.selectedIds]).toEqual([arborBlockId("a1")]);

    const reversed = extendRangeSelection(rows, arborBlockId("a1"), shrunk.extentId, "up")!;
    expect(reversed.extentId).toBe(arborBlockId("a"));
    expect([...reversed.selectedIds]).toEqual([arborBlockId("a"), arborBlockId("a1")]);
  });

  it("keeps pointer ranges contiguous and shrinks them back to the anchor", () => {
    const rows = new ArborVisibleIndex(fixture()).rows(pageId);
    const crossed = pointerRangeSelection(
      rows,
      arborBlockId("a"),
      arborBlockId("b"),
      false,
    );
    expect(crossed.dragged).toBe(true);
    expect([...crossed.selectedIds]).toEqual([
      arborBlockId("a"),
      arborBlockId("a1"),
      arborBlockId("b"),
    ]);

    const returned = pointerRangeSelection(
      rows,
      arborBlockId("a"),
      arborBlockId("a"),
      crossed.dragged,
    );
    expect(returned.dragged).toBe(true);
    expect([...returned.selectedIds]).toEqual([arborBlockId("a")]);
  });

  it("does not turn an ordinary same-row mouse gesture into block selection", () => {
    const rows = new ArborVisibleIndex(fixture()).rows(pageId);
    const stationary = pointerRangeSelection(
      rows,
      arborBlockId("b"),
      arborBlockId("b"),
      false,
    );
    expect(stationary.dragged).toBe(false);
    expect([...stationary.selectedIds]).toEqual([arborBlockId("b")]);
  });

  it("preserves native text selection away from block boundaries", () => {
    expect(shouldExtendBlockSelection("up", 0, 5, true, false)).toBe(true);
    expect(shouldExtendBlockSelection("up", 2, 5, true, false)).toBe(false);
    expect(shouldExtendBlockSelection("down", 5, 5, true, false)).toBe(true);
    expect(shouldExtendBlockSelection("up", 0, 5, false, false)).toBe(false);
    expect(shouldExtendBlockSelection("up", 2, 5, false, true)).toBe(false);
    expect(shouldExtendBlockSelection("up", 2, 5, true, true)).toBe(true);
  });

  it("merges on Backspace only from a collapsed caret at the block start", () => {
    expect(shouldMergeBlockOnBackspace(0, true)).toBe(true);
    expect(shouldMergeBlockOnBackspace(0, false)).toBe(false);
    expect(shouldMergeBlockOnBackspace(4, true)).toBe(false);
  });

  it("uses one destination model for keyboard and pointer moves", () => {
    const store = fixture();
    const target = keyboardDropTarget(store, [arborBlockId("b")], "down")!;

    expect(target).toEqual({ blockId: arborBlockId("c"), placement: "after" });
    expect(dropDestination(store, target)).toEqual({
      pageId,
      parentId: null,
      afterId: arborBlockId("c"),
    });
    expect(moveBlocksToTarget(store, [arborBlockId("b")], target).changed).toBe(true);
    expect(store.childIds(pageId, null)).toEqual([
      arborBlockId("a"),
      arborBlockId("c"),
      arborBlockId("b"),
    ]);
    expect(store.history.undoDepth).toBe(1);
  });

  it("moves past complete subtrees and preserves multi-root order", () => {
    const store = fixture();

    expect(keyboardDropTarget(store, [arborBlockId("a")], "down")).toEqual({
      blockId: arborBlockId("b"),
      placement: "after",
    });
    moveBlocksToTarget(store, [arborBlockId("b"), arborBlockId("c")], {
      blockId: arborBlockId("a"),
      placement: "before",
    });
    expect(store.childIds(pageId, null)).toEqual([
      arborBlockId("b"),
      arborBlockId("c"),
      arborBlockId("a"),
    ]);

    store.undo();
    moveBlocksToTarget(store, [arborBlockId("a"), arborBlockId("b")], {
      blockId: arborBlockId("c"),
      placement: "after",
    });
    expect(store.childIds(pageId, null)).toEqual([
      arborBlockId("c"),
      arborBlockId("a"),
      arborBlockId("b"),
    ]);
  });

  it("moves up across a sibling subtree without reparenting", () => {
    const store = fixture();
    const target = keyboardDropTarget(store, [arborBlockId("b")], "up")!;

    expect(target).toEqual({ blockId: arborBlockId("a"), placement: "before" });
    moveBlocksToTarget(store, [arborBlockId("b")], target);
    expect(store.childIds(pageId, null)).toEqual([
      arborBlockId("b"),
      arborBlockId("a"),
      arborBlockId("c"),
    ]);
    expect(store.getBlock(arborBlockId("b"))?.parentId).toBeNull();
  });

  it("does not keyboard-move mixed-parent selections", () => {
    const store = fixture();
    expect(keyboardDropTarget(
      store,
      [arborBlockId("a1"), arborBlockId("b")],
      "down",
    )).toBeNull();
  });

  it("rejects a destination inside the dragged subtree", () => {
    const store = fixture();
    expect(canDropBlocks(store, [arborBlockId("a")], {
      blockId: arborBlockId("a1"),
      placement: "last-child",
    })).toBe(false);
  });

  it("preserves selected sibling order while outdenting", () => {
    const store = fixture();
    store.moveBlock(arborBlockId("b"), {
      parentId: arborBlockId("a"),
      afterId: arborBlockId("a1"),
    });
    store.moveBlock(arborBlockId("c"), {
      parentId: arborBlockId("a"),
      afterId: arborBlockId("b"),
    });
    store.clearHistory();

    outdentBlocks(store, [arborBlockId("b"), arborBlockId("c")]);
    expect(store.childIds(pageId, null)).toEqual([
      arborBlockId("a"),
      arborBlockId("b"),
      arborBlockId("c"),
    ]);
    expect(store.history.undoDepth).toBe(1);
  });
});
