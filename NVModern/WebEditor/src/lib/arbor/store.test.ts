import { describe, expect, it } from "bun:test";
import { arborBlockId, arborPageId, createSequentialArborIdFactory } from "./ids.ts";
import { ArborOutlineStore } from "./store.ts";
import type { ArborDocumentSnapshot } from "./types.ts";

function fixture(): { store: ArborOutlineStore; pageId: ReturnType<typeof arborPageId> } {
  const pageId = arborPageId("page");
  const snapshot: ArborDocumentSnapshot = {
    version: 1,
    pages: [{
      id: pageId,
      title: "Test",
      children: [arborBlockId("a"), arborBlockId("b")],
    }],
    blocks: [
      {
        id: arborBlockId("a"),
        pageId,
        parentId: null,
        children: [arborBlockId("a1")],
        text: "Alpha",
      },
      {
        id: arborBlockId("a1"),
        pageId,
        parentId: arborBlockId("a"),
        children: [],
        text: "Alpha child",
      },
      {
        id: arborBlockId("b"),
        pageId,
        parentId: null,
        children: [],
        text: "Beta",
      },
    ],
  };
  return {
    store: ArborOutlineStore.fromSnapshot(snapshot, {
      idFactory: createSequentialArborIdFactory("new"),
    }),
    pageId,
  };
}

describe("ArborOutlineStore", () => {
  it("inserts and relinks blocks without changing stable ids", () => {
    const { store, pageId } = fixture();
    const result = store.insertBlock({
      pageId,
      afterId: arborBlockId("a"),
      text: "Inserted",
    });

    expect(result.focus).toEqual({ blockId: arborBlockId("new_b1"), offset: 8 });
    expect(store.childIds(pageId, null)).toEqual([
      arborBlockId("a"),
      arborBlockId("new_b1"),
      arborBlockId("b"),
    ]);
    expect(store.getBlock(arborBlockId("a"))?.nextSiblingId).toBe(arborBlockId("new_b1"));
    expect(store.getBlock(arborBlockId("b"))?.previousSiblingId).toBe(arborBlockId("new_b1"));
  });

  it("renames a block id and preserves every structural and computation link", () => {
    const { store, pageId } = fixture();
    const resultId = store.insertBlock({
      pageId,
      afterId: arborBlockId("b"),
      text: "Derived",
      computation: {
        version: 2,
        state: "live",
        producerId: arborBlockId("a"),
        resultKey: "scalar",
        generation: 1,
        inputHash: "a".repeat(40),
        originBlockId: arborBlockId("a"),
        updatePolicy: "detach",
      },
    }).focus!.blockId;
    store.clearHistory();
    const beforeRename = store.toSnapshot();

    expect(store.renameBlock(arborBlockId("a"), arborBlockId("renamed")).focus).toEqual({
      blockId: arborBlockId("renamed"),
      offset: 5,
    });
    expect(store.hasBlock(arborBlockId("a"))).toBe(false);
    expect(store.childIds(pageId, null)).toEqual([
      arborBlockId("renamed"),
      arborBlockId("b"),
      resultId,
    ]);
    expect(store.getBlock(arborBlockId("a1"))?.parentId).toBe(arborBlockId("renamed"));
    expect(store.getBlock(resultId)?.computation).toMatchObject({
      producerId: arborBlockId("renamed"),
      originBlockId: arborBlockId("renamed"),
    });

    store.undo();
    expect(store.toSnapshot()).toEqual(beforeRename);
    expect(store.hasBlock(arborBlockId("a"))).toBe(true);
    expect(store.getBlock(resultId)?.computation?.producerId).toBe(arborBlockId("a"));
    store.redo();
    expect(store.hasBlock(arborBlockId("renamed"))).toBe(true);
  });

  it("splits, indents, outdents, and moves subtrees", () => {
    const { store, pageId } = fixture();
    const split = store.splitBlock(arborBlockId("b"), 2);
    const newId = split.focus!.blockId;
    expect(store.getBlock(arborBlockId("b"))?.text).toBe("Be");
    expect(store.getBlock(newId)?.text).toBe("ta");

    store.indentBlock(newId);
    expect(store.getBlock(newId)?.parentId).toBe(arborBlockId("b"));
    expect(store.childIds(pageId, arborBlockId("b"))).toEqual([newId]);

    store.outdentBlock(newId);
    expect(store.getBlock(newId)?.parentId).toBeNull();
    store.moveBlockUp(newId);
    expect(store.childIds(pageId, null)).toEqual([
      arborBlockId("a"),
      newId,
      arborBlockId("b"),
    ]);
    store.moveBlockDown(newId);
    expect(store.childIds(pageId, null)).toEqual([
      arborBlockId("a"),
      arborBlockId("b"),
      newId,
    ]);
  });

  it("inserts an empty sibling before a parent split at its start", () => {
    const { store, pageId } = fixture();
    const result = store.splitBlock(arborBlockId("a"), 0);
    const newId = result.focus!.blockId;

    expect(result.focus).toEqual({ blockId: newId, offset: 0 });
    expect(store.childIds(pageId, null)).toEqual([
      newId,
      arborBlockId("a"),
      arborBlockId("b"),
    ]);
    expect(store.getBlock(newId)?.text).toBe("");
    expect(store.getBlock(arborBlockId("a"))?.text).toBe("Alpha");
    expect(store.childIds(pageId, arborBlockId("a"))).toEqual([arborBlockId("a1")]);
    expect(store.getBlock(arborBlockId("a1"))?.parentId).toBe(arborBlockId("a"));
  });

  it("merges into the previous visible block and keeps children", () => {
    const { store, pageId } = fixture();
    const inserted = store.insertBlock({
      pageId,
      afterId: arborBlockId("a"),
      text: "Tail",
    }).focus!.blockId;
    const child = store.insertBlock({
      pageId,
      parentId: inserted,
      afterId: null,
      text: "Kept child",
    }).focus!.blockId;

    const merged = store.mergeWithPrevious(inserted);
    expect(merged.focus).toEqual({ blockId: arborBlockId("a1"), offset: 11 });
    expect(store.hasBlock(inserted)).toBe(false);
    expect(store.getBlock(arborBlockId("a1"))?.text).toBe("Alpha childTail");
    expect(store.getBlock(child)?.parentId).toBe(arborBlockId("a1"));
  });

  it("deletes and restores a complete subtree", () => {
    const { store, pageId } = fixture();

    const result = store.deleteBlock(arborBlockId("a"));

    expect(result.focus).toEqual({ blockId: arborBlockId("b"), offset: 4 });
    expect(store.childIds(pageId, null)).toEqual([arborBlockId("b")]);
    expect(store.hasBlock(arborBlockId("a"))).toBe(false);
    expect(store.hasBlock(arborBlockId("a1"))).toBe(false);

    store.undo();
    expect(store.childIds(pageId, null)).toEqual([arborBlockId("a"), arborBlockId("b")]);
    expect(store.getBlock(arborBlockId("a1"))?.parentId).toBe(arborBlockId("a"));
  });

  it("undoes and redoes structural edits exactly", () => {
    const { store, pageId } = fixture();
    const before = store.toSnapshot();
    const newId = store.splitBlock(arborBlockId("b"), 1).focus!.blockId;
    store.indentBlock(newId);

    expect(store.undo().changed).toBe(true);
    expect(store.getBlock(newId)?.parentId).toBeNull();
    expect(store.undo().changed).toBe(true);
    expect(store.toSnapshot()).toEqual(before);
    expect(store.redo().changed).toBe(true);
    expect(store.getBlock(newId)?.text).toBe("eta");
    expect(store.redo().changed).toBe(true);
    expect(store.getBlock(newId)?.parentId).toBe(arborBlockId("b"));
  });

  it("coalesces consecutive contenteditable input into one history entry", () => {
    const { store } = fixture();
    store.setBlockText(arborBlockId("b"), "Beta!", { historyGroup: "typing:b" });
    store.setBlockText(arborBlockId("b"), "Beta!!", { historyGroup: "typing:b" });
    store.setBlockText(arborBlockId("b"), "Beta!!!", { historyGroup: "typing:b" });
    expect(store.history.undoDepth).toBe(1);

    store.undo();
    expect(store.getBlock(arborBlockId("b"))?.text).toBe("Beta");
    store.redo();
    expect(store.getBlock(arborBlockId("b"))?.text).toBe("Beta!!!");
  });

  it("detaches a managed result on its first text or structural mutation", () => {
    const { store, pageId } = fixture();
    const metadata = {
      version: 1 as const,
      state: "live" as const,
      producerId: arborBlockId("a"),
      resultKey: "scalar",
      generation: 1,
      inputHash: "a".repeat(40),
    };
    const result = store.insertBlock({
      pageId,
      parentId: arborBlockId("a"),
      afterId: arborBlockId("a1"),
      text: "42",
      computation: metadata,
    }).focus!.blockId;

    store.setBlockText(result, "forty two");
    expect(store.getBlock(result)?.computation?.state).toBe("detached");
    store.undo();
    expect(store.getBlock(result)?.computation?.state).toBe("live");
    store.moveBlock(result, { pageId, parentId: null, afterId: arborBlockId("b") });
    expect(store.getBlock(result)?.computation?.state).toBe("detached");
  });

  it("commits a bulk transaction as one undo step", () => {
    const { store, pageId } = fixture();
    let changes = 0;
    store.subscribe(() => changes += 1);

    store.transaction("Indent blocks", () => {
      store.indentBlock(arborBlockId("b"));
      store.setBlockText(arborBlockId("a1"), "Changed");
    });

    expect(store.history.undoDepth).toBe(1);
    expect(changes).toBe(1);
    expect(store.getBlock(arborBlockId("b"))?.parentId).toBe(arborBlockId("a"));
    expect(store.getBlock(arborBlockId("a1"))?.text).toBe("Changed");

    store.undo();
    expect(store.childIds(pageId, null)).toEqual([arborBlockId("a"), arborBlockId("b")]);
    expect(store.getBlock(arborBlockId("a1"))?.text).toBe("Alpha child");
  });

  it("rolls back a failed bulk transaction", () => {
    const { store } = fixture();
    const before = store.toSnapshot();

    expect(() => store.transaction("Invalid move", () => {
      store.deleteBlock(arborBlockId("b"));
      store.moveBlock(arborBlockId("a"), {
        parentId: arborBlockId("a1"),
        afterId: null,
      });
    })).toThrow("own subtree");

    expect(store.toSnapshot()).toEqual(before);
    expect(store.history.undoDepth).toBe(0);
  });

  it("keeps an empty-page replacement in the delete transaction", () => {
    const { store, pageId } = fixture();

    store.transaction("Delete all blocks", () => {
      store.deleteBlock(arborBlockId("a"));
      store.deleteBlock(arborBlockId("b"));
      store.insertBlock({ pageId, id: arborBlockId("replacement") });
    });

    expect(store.history.undoDepth).toBe(1);
    expect(store.childIds(pageId, null)).toEqual([arborBlockId("replacement")]);
    store.undo();
    expect(store.childIds(pageId, null)).toEqual([arborBlockId("a"), arborBlockId("b")]);
  });

  it("keeps view-only collapse state outside the edit undo log", () => {
    const { store, pageId } = fixture();
    store.insertBlock({ pageId, afterId: arborBlockId("a"), text: "Inserted" });
    store.setCollapsed(arborBlockId("a"), true);
    store.undo();
    expect(store.getBlock(arborBlockId("a"))?.collapsed).toBe(true);
  });

  it("installs an authoritative snapshot as one undoable edit", () => {
    const { store, pageId } = fixture();
    store.setCollapsed(arborBlockId("a"), true);
    const before = store.toSnapshot();
    const replacement = ArborOutlineStore.fromSnapshot(before);
    replacement.setBlockText(arborBlockId("a"), "Changed by the kernel");
    replacement.deleteBlock(arborBlockId("b"));

    store.replaceSnapshot(replacement.toSnapshot());

    expect(store.getBlock(arborBlockId("a"))?.text).toBe("Changed by the kernel");
    expect(store.getBlock(arborBlockId("a"))?.collapsed).toBe(true);
    expect(store.childIds(pageId, null)).toEqual([arborBlockId("a")]);
    expect(store.history.undoDepth).toBe(1);
    store.undo();
    expect(store.toSnapshot()).toEqual(before);
  });

  it("moves a subtree between pages and restores it with undo", () => {
    const { store, pageId } = fixture();
    const otherPage = store.createPage("Other", arborPageId("other"));
    store.moveBlock(arborBlockId("a"), {
      pageId: otherPage,
      parentId: null,
      afterId: null,
    });
    expect(store.getBlock(arborBlockId("a"))?.pageId).toBe(otherPage);
    expect(store.getBlock(arborBlockId("a1"))?.pageId).toBe(otherPage);
    expect(store.childIds(pageId, null)).toEqual([arborBlockId("b")]);

    store.undo();
    expect(store.getBlock(arborBlockId("a"))?.pageId).toBe(pageId);
    expect(store.getBlock(arborBlockId("a1"))?.pageId).toBe(pageId);
  });

  it("rejects cycles", () => {
    const { store, pageId } = fixture();
    expect(() => store.moveBlock(arborBlockId("a"), {
      pageId,
      parentId: arborBlockId("a1"),
      afterId: null,
    })).toThrow("own subtree");
  });

  it("rejects orphaned snapshot blocks", () => {
    const pageId = arborPageId("orphan-page");
    expect(() => ArborOutlineStore.fromSnapshot({
      version: 1,
      pages: [{ id: pageId, title: "Orphans", children: [] }],
      blocks: [{
        id: arborBlockId("orphan"),
        pageId,
        parentId: null,
        children: [],
        text: "Lost",
      }],
    })).toThrow("Unplaced Arbor block");
  });

  it("rejects cyclic snapshot ancestry", () => {
    const pageId = arborPageId("cycle-page");
    expect(() => ArborOutlineStore.fromSnapshot({
      version: 1,
      pages: [{ id: pageId, title: "Cycle", children: [] }],
      blocks: [
        {
          id: arborBlockId("left"),
          pageId,
          parentId: arborBlockId("right"),
          children: [arborBlockId("right")],
          text: "Left",
        },
        {
          id: arborBlockId("right"),
          pageId,
          parentId: arborBlockId("left"),
          children: [arborBlockId("left")],
          text: "Right",
        },
      ],
    })).toThrow("Cyclic Arbor block ancestry");
  });
});
