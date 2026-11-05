import { describe, expect, it } from "bun:test";
import { arborBlockId, arborPageId } from "./ids.ts";
import { ArborOutlineStore } from "./store.ts";
import type { ArborDocumentSnapshot } from "./types.ts";
import { ArborVisibleIndex } from "./visibleIndex.ts";
import { ArborVirtualizer } from "./virtualizer.ts";

const pageId = arborPageId("page");
const snapshot: ArborDocumentSnapshot = {
  version: 1,
  pages: [{ id: pageId, title: "Page", children: [arborBlockId("a"), arborBlockId("b")] }],
  blocks: [
    { id: arborBlockId("a"), pageId, parentId: null, children: [arborBlockId("a1")], text: "A" },
    { id: arborBlockId("a1"), pageId, parentId: arborBlockId("a"), children: [], text: "A1" },
    { id: arborBlockId("b"), pageId, parentId: null, children: [], text: "B" },
  ],
};

describe("ArborVisibleIndex", () => {
  it("flattens only visible rows and supports block zoom", () => {
    const store = ArborOutlineStore.fromSnapshot(snapshot);
    const index = new ArborVisibleIndex(store);
    expect(index.rows(pageId).map((row) => [row.id, row.depth])).toEqual([
      [arborBlockId("a"), 0],
      [arborBlockId("a1"), 1],
      [arborBlockId("b"), 0],
    ]);

    store.setCollapsed(arborBlockId("a"), true);
    expect(index.rows(pageId).map((row) => row.id)).toEqual([
      arborBlockId("a"),
      arborBlockId("b"),
    ]);
    store.setCollapsed(arborBlockId("a"), false);
    expect(index.rows(pageId, arborBlockId("a")).map((row) => [row.id, row.depth])).toEqual([
      [arborBlockId("a"), 0],
      [arborBlockId("a1"), 1],
    ]);
  });

  it("does not rebuild visible order for text-only changes", () => {
    const store = ArborOutlineStore.fromSnapshot(snapshot);
    const index = new ArborVisibleIndex(store);
    const before = index.rows(pageId);
    store.setBlockText(arborBlockId("a1"), "Changed");
    expect(index.rows(pageId)).toBe(before);
  });
});

describe("ArborVirtualizer", () => {
  it("returns a bounded window and updates measured heights in logarithmic time", () => {
    const store = ArborOutlineStore.fromSnapshot(snapshot);
    const rows = new ArborVisibleIndex(store).rows(pageId);
    const virtualizer = new ArborVirtualizer({ estimatedRowHeight: 20, overscanPixels: 0 });
    virtualizer.setRows(rows);
    expect(virtualizer.windowForViewport(20, 20).rows.map((row) => row.id)).toEqual([
      arborBlockId("a1"),
      arborBlockId("b"),
    ]);

    expect(virtualizer.measure(arborBlockId("a"), 40)).toBe(true);
    expect(virtualizer.offsetForIndex(1)).toBe(40);
    expect(virtualizer.indexAtOffset(39)).toBe(0);
    expect(virtualizer.indexAtOffset(40)).toBe(1);
    const measured = virtualizer.windowForViewport(40, 20);
    expect(measured.paddingTop).toBe(40);
    expect(measured.totalHeight).toBe(80);
  });
});
