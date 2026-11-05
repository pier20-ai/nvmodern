import { defaultArborIdFactory } from "./ids.ts";
import type {
  ArborBlockId,
  ArborBlockNode,
  ArborBlockSnapshot,
  ArborCaretTarget,
  ArborComputationMetadata,
  ArborDocumentSnapshot,
  ArborEditResult,
  ArborHistoryState,
  ArborIdFactory,
  ArborInsertInput,
  ArborMoveDestination,
  ArborMoveOptions,
  ArborPageId,
  ArborPageNode,
  ArborPageSnapshot,
  ArborTextEditOptions,
} from "./types.ts";

export type ArborChangeKind = "content" | "structure" | "view";

export interface ArborStoreChange {
  readonly revision: number;
  readonly kind: ArborChangeKind;
  readonly pageIds: ReadonlySet<ArborPageId>;
}

interface EntityState {
  blocks: Map<ArborBlockId, ArborBlockNode | null>;
  pages: Map<ArborPageId, ArborPageNode | null>;
}

interface HistoryEntry {
  label: string;
  kind: Exclude<ArborChangeKind, "view">;
  before: EntityState;
  after: EntityState;
  pageIds: Set<ArborPageId>;
  focusBefore: ArborCaretTarget | null;
  focusAfter: ArborCaretTarget | null;
  mergeKey: string | null;
}

interface MutationRecorder {
  before: EntityState;
  pageIds: Set<ArborPageId>;
}

interface StoreTransaction extends MutationRecorder {
  label: string;
  kind: Exclude<ArborChangeKind, "view">;
  focusBefore: ArborCaretTarget | null;
  focusAfter: ArborCaretTarget | null;
  changed: boolean;
}

export interface ArborStoreOptions {
  idFactory?: ArborIdFactory;
  historyLimit?: number;
}

const cloneBlock = (block: ArborBlockNode): ArborBlockNode => ({
  ...block,
  ...(block.computation ? { computation: { ...block.computation } } : {}),
});
const clonePage = (page: ArborPageNode): ArborPageNode => ({ ...page });

function cloneCaret(caret: ArborCaretTarget | null): ArborCaretTarget | null {
  return caret ? { ...caret } : null;
}

/**
 * Normalized outline storage. Structural edits relink only the affected nodes;
 * they never copy the document or scan unrelated pages.
 */
export class ArborOutlineStore {
  private readonly blocks = new Map<ArborBlockId, ArborBlockNode>();
  private readonly pages = new Map<ArborPageId, ArborPageNode>();
  private readonly listeners = new Set<(change: ArborStoreChange) => void>();
  private readonly pageStructureRevisions = new Map<ArborPageId, number>();
  private readonly idFactory: ArborIdFactory;
  private readonly historyLimit: number;
  private undoStack: HistoryEntry[] = [];
  private redoStack: HistoryEntry[] = [];
  private activeTransaction: StoreTransaction | null = null;
  private revision = 0;

  constructor(snapshot?: ArborDocumentSnapshot, options: ArborStoreOptions = {}) {
    this.idFactory = options.idFactory ?? defaultArborIdFactory;
    this.historyLimit = Math.max(0, options.historyLimit ?? 500);
    if (snapshot) this.loadSnapshot(snapshot);
  }

  static fromSnapshot(
    snapshot: ArborDocumentSnapshot,
    options: ArborStoreOptions = {},
  ): ArborOutlineStore {
    return new ArborOutlineStore(snapshot, options);
  }

  getRevision(): number {
    return this.revision;
  }

  getPageStructureRevision(pageId: ArborPageId): number {
    return this.pageStructureRevisions.get(pageId) ?? 0;
  }

  subscribe(listener: (change: ArborStoreChange) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  get history(): ArborHistoryState {
    return {
      canUndo: this.undoStack.length > 0,
      canRedo: this.redoStack.length > 0,
      undoDepth: this.undoStack.length,
      redoDepth: this.redoStack.length,
    };
  }

  transaction(label: string, edit: () => void): ArborEditResult {
    if (this.activeTransaction) {
      edit();
      return { changed: false, focus: null };
    }

    const transaction: StoreTransaction = {
      label,
      kind: "content",
      before: { blocks: new Map(), pages: new Map() },
      pageIds: new Set(),
      focusBefore: null,
      focusAfter: null,
      changed: false,
    };
    this.activeTransaction = transaction;
    try {
      edit();
    } catch (error) {
      this.restoreEntityState(transaction.before);
      throw error;
    } finally {
      this.activeTransaction = null;
    }

    if (!transaction.changed) return { changed: false, focus: null };
    const entry: HistoryEntry = {
      label,
      kind: transaction.kind,
      before: transaction.before,
      after: this.captureCurrentState(transaction.before),
      pageIds: transaction.pageIds,
      focusBefore: transaction.focusBefore,
      focusAfter: transaction.focusAfter,
      mergeKey: null,
    };
    if (this.historyLimit > 0) {
      this.undoStack.push(entry);
      if (this.undoStack.length > this.historyLimit) this.undoStack.shift();
    }
    this.redoStack = [];
    this.emit(entry.kind, entry.pageIds);
    return { changed: true, focus: cloneCaret(entry.focusAfter) };
  }

  getPage(pageId: ArborPageId): Readonly<ArborPageNode> | undefined {
    return this.pages.get(pageId);
  }

  getBlock(blockId: ArborBlockId): Readonly<ArborBlockNode> | undefined {
    return this.blocks.get(blockId);
  }

  hasBlock(blockId: ArborBlockId): boolean {
    return this.blocks.has(blockId);
  }

  createPage(title: string, id = this.idFactory.pageId()): ArborPageId {
    if (this.pages.has(id)) throw new Error(`Duplicate Arbor page id: ${id}`);
    this.pages.set(id, {
      id,
      title,
      firstChildId: null,
      lastChildId: null,
      childCount: 0,
    });
    this.pageStructureRevisions.set(id, 0);
    this.emit("structure", new Set([id]));
    return id;
  }

  setPageTitle(pageId: ArborPageId, title: string): ArborEditResult {
    const page = this.requirePage(pageId);
    if (page.title === title) return { changed: false, focus: null };

    return this.recordEdit("Rename page", "content", null, null, null, (recorder) => {
      this.touchPage(recorder, pageId);
      page.title = title;
      return null;
    });
  }

  insertBlock(input: ArborInsertInput): ArborEditResult {
    const page = this.requirePage(input.pageId);
    const parentId = input.parentId ?? null;
    this.validateContainer(page.id, parentId);
    this.validateInsertionAnchor(page.id, parentId, input.afterId ?? null);

    const id = input.id ?? this.idFactory.blockId();
    if (this.blocks.has(id)) throw new Error(`Duplicate Arbor block id: ${id}`);

    return this.recordEdit("Insert block", "structure", null, null, null, (recorder) => {
      this.touchBlock(recorder, id);
      const block: ArborBlockNode = {
        id,
        pageId: page.id,
        text: input.text ?? "",
        parentId,
        firstChildId: null,
        lastChildId: null,
        previousSiblingId: null,
        nextSiblingId: null,
        childCount: 0,
        collapsed: input.collapsed ?? false,
        ...(input.computation ? { computation: { ...input.computation } } : {}),
      };
      this.blocks.set(id, block);
      this.attachNode(recorder, block, page.id, parentId, input.afterId ?? null);
      return { blockId: id, offset: block.text.length };
    });
  }

  setBlockText(
    blockId: ArborBlockId,
    text: string,
    options: ArborTextEditOptions = {},
  ): ArborEditResult {
    const block = this.requireBlock(blockId);
    if (block.text === text) {
      return { changed: false, focus: { blockId, offset: text.length } };
    }

    const focusBefore = { blockId, offset: block.text.length };
    const focusAfter = { blockId, offset: text.length };
    return this.recordEdit(
      "Edit block",
      "content",
      options.historyGroup ?? null,
      focusBefore,
      focusAfter,
      (recorder) => {
        this.touchBlock(recorder, blockId);
        if (!options.preserveComputation) this.detachComputation(block);
        block.text = text;
        return focusAfter;
      },
    );
  }

  renameBlock(blockId: ArborBlockId, newId: ArborBlockId): ArborEditResult {
    if (blockId === newId) return { changed: false, focus: null };
    if (this.blocks.has(newId)) throw new Error(`Duplicate Arbor block id: ${newId}`);
    const block = this.requireBlock(blockId);

    return this.recordEdit("Rename block id", "structure", null, null, null, (recorder) => {
      this.touchBlock(recorder, blockId);
      this.touchBlock(recorder, newId);

      if (block.previousSiblingId) {
        const previous = this.requireBlock(block.previousSiblingId);
        this.touchBlock(recorder, previous.id);
        previous.nextSiblingId = newId;
      }
      if (block.nextSiblingId) {
        const next = this.requireBlock(block.nextSiblingId);
        this.touchBlock(recorder, next.id);
        next.previousSiblingId = newId;
      }
      if (block.parentId) {
        const parent = this.requireBlock(block.parentId);
        this.touchBlock(recorder, parent.id);
        if (parent.firstChildId === blockId) parent.firstChildId = newId;
        if (parent.lastChildId === blockId) parent.lastChildId = newId;
      } else {
        const page = this.requirePage(block.pageId);
        this.touchPage(recorder, page.id);
        if (page.firstChildId === blockId) page.firstChildId = newId;
        if (page.lastChildId === blockId) page.lastChildId = newId;
      }

      let childId = block.firstChildId;
      while (childId) {
        const child = this.requireBlock(childId);
        this.touchBlock(recorder, child.id);
        child.parentId = newId;
        childId = child.nextSiblingId;
      }

      const renamed: ArborBlockNode = { ...cloneBlock(block), id: newId };
      this.blocks.delete(blockId);
      this.blocks.set(newId, renamed);

      for (const candidate of this.blocks.values()) {
        const computation = candidate.computation;
        if (!computation) continue;
        const producerChanged = computation.producerId === blockId;
        const originChanged = computation.originBlockId === blockId;
        if (!producerChanged && !originChanged) continue;
        this.touchBlock(recorder, candidate.id);
        candidate.computation = {
          ...computation,
          ...(producerChanged ? { producerId: newId } : {}),
          ...(originChanged ? { originBlockId: newId } : {}),
        };
      }
      return { blockId: newId, offset: renamed.text.length };
    });
  }

  setBlockComputation(
    blockId: ArborBlockId,
    computation: ArborComputationMetadata | undefined,
  ): ArborEditResult {
    const block = this.requireBlock(blockId);
    if (sameComputation(block.computation, computation)) {
      return { changed: false, focus: null };
    }
    return this.recordEdit("Update computation state", "content", null, null, null, (recorder) => {
      this.touchBlock(recorder, blockId);
      block.computation = computation ? { ...computation } : undefined;
      return null;
    });
  }

  splitBlock(blockId: ArborBlockId, offset: number): ArborEditResult {
    const block = this.requireBlock(blockId);
    const splitOffset = Math.max(0, Math.min(block.text.length, offset));
    const newId = this.idFactory.blockId();
    const beforeText = block.text.slice(0, splitOffset);
    const afterText = block.text.slice(splitOffset);

    return this.recordEdit(
      "Split block",
      "structure",
      null,
      { blockId, offset: splitOffset },
      { blockId: newId, offset: 0 },
      (recorder) => {
        this.touchBlock(recorder, blockId);
        this.touchBlock(recorder, newId);
        const created: ArborBlockNode = {
          id: newId,
          pageId: block.pageId,
          text: splitOffset === 0 ? "" : afterText,
          parentId: block.parentId,
          firstChildId: null,
          lastChildId: null,
          previousSiblingId: null,
          nextSiblingId: null,
          childCount: 0,
          collapsed: false,
        };
        this.blocks.set(newId, created);
        if (splitOffset === 0) {
          this.attachNode(recorder, created, block.pageId, block.parentId, block.previousSiblingId);
          return { blockId: newId, offset: 0 };
        }

        this.detachComputation(block);
        block.text = beforeText;
        this.attachNode(recorder, created, block.pageId, block.parentId, blockId);
        return { blockId: newId, offset: 0 };
      },
    );
  }

  mergeWithPrevious(blockId: ArborBlockId): ArborEditResult {
    const block = this.requireBlock(blockId);
    const target = this.previousVisibleBlock(block);
    if (!target) return { changed: false, focus: { blockId, offset: 0 } };
    const targetOffset = target.text.length;

    return this.recordEdit(
      "Merge block",
      "structure",
      null,
      { blockId, offset: 0 },
      { blockId: target.id, offset: targetOffset },
      (recorder) => {
        this.touchBlock(recorder, target.id);
        this.detachComputation(target);
        target.text += block.text;

        const originalParentId = block.parentId;
        const originalPreviousId = block.previousSiblingId;
        this.detachNode(recorder, block);

        let insertionParentId: ArborBlockId | null;
        let insertionAfterId: ArborBlockId | null;
        if (target.id === originalParentId) {
          insertionParentId = originalParentId;
          insertionAfterId = originalPreviousId;
        } else {
          insertionParentId = target.id;
          insertionAfterId = target.lastChildId;
        }

        while (block.firstChildId) {
          const child = this.requireBlock(block.firstChildId);
          this.detachNode(recorder, child);
          this.attachNode(recorder, child, target.pageId, insertionParentId, insertionAfterId);
          insertionAfterId = child.id;
        }

        this.touchBlock(recorder, block.id);
        this.blocks.delete(block.id);
        return { blockId: target.id, offset: targetOffset };
      },
    );
  }

  deleteBlock(blockId: ArborBlockId): ArborEditResult {
    const block = this.requireBlock(blockId);
    const fallbackId = block.nextSiblingId ?? block.previousSiblingId ?? block.parentId;
    const fallback = fallbackId ? this.requireBlock(fallbackId) : null;
    const subtree: ArborBlockId[] = [];
    const stack = [blockId];
    while (stack.length > 0) {
      const id = stack.pop()!;
      subtree.push(id);
      let childId = this.requireBlock(id).firstChildId;
      while (childId) {
        stack.push(childId);
        childId = this.requireBlock(childId).nextSiblingId;
      }
    }

    return this.recordEdit(
      "Delete block",
      "structure",
      null,
      { blockId, offset: block.text.length },
      fallback ? { blockId: fallback.id, offset: fallback.text.length } : null,
      (recorder) => {
        this.detachNode(recorder, block);
        for (const id of subtree) {
          this.touchBlock(recorder, id);
          this.blocks.delete(id);
        }
        return fallback ? { blockId: fallback.id, offset: fallback.text.length } : null;
      },
    );
  }

  indentBlock(blockId: ArborBlockId): ArborEditResult {
    const block = this.requireBlock(blockId);
    const previous = block.previousSiblingId
      ? this.requireBlock(block.previousSiblingId)
      : null;
    if (!previous) return { changed: false, focus: { blockId, offset: 0 } };
    return this.moveBlock(blockId, {
      pageId: block.pageId,
      parentId: previous.id,
      afterId: previous.lastChildId,
    }, "Indent block");
  }

  outdentBlock(blockId: ArborBlockId): ArborEditResult {
    const block = this.requireBlock(blockId);
    if (!block.parentId) return { changed: false, focus: { blockId, offset: 0 } };
    const parent = this.requireBlock(block.parentId);
    return this.moveBlock(blockId, {
      pageId: block.pageId,
      parentId: parent.parentId,
      afterId: parent.id,
    }, "Outdent block");
  }

  moveBlockUp(blockId: ArborBlockId): ArborEditResult {
    const block = this.requireBlock(blockId);
    if (!block.previousSiblingId) return { changed: false, focus: { blockId, offset: 0 } };
    const previous = this.requireBlock(block.previousSiblingId);
    return this.moveBlock(blockId, {
      pageId: block.pageId,
      parentId: block.parentId,
      afterId: previous.previousSiblingId,
    }, "Move block up");
  }

  moveBlockDown(blockId: ArborBlockId): ArborEditResult {
    const block = this.requireBlock(blockId);
    if (!block.nextSiblingId) return { changed: false, focus: { blockId, offset: 0 } };
    return this.moveBlock(blockId, {
      pageId: block.pageId,
      parentId: block.parentId,
      afterId: block.nextSiblingId,
    }, "Move block down");
  }

  moveBlock(
    blockId: ArborBlockId,
    destination: ArborMoveDestination,
    label = "Move block",
    options: ArborMoveOptions = {},
  ): ArborEditResult {
    const block = this.requireBlock(blockId);
    const sourcePageId = block.pageId;
    const pageId = destination.pageId ?? block.pageId;
    this.requirePage(pageId);
    this.validateContainer(pageId, destination.parentId);

    if (destination.parentId === block.id || this.isDescendant(destination.parentId, block.id)) {
      throw new Error("Cannot move a block into its own subtree");
    }
    if (destination.afterId === block.id) {
      return { changed: false, focus: { blockId, offset: 0 } };
    }
    this.validateInsertionAnchor(pageId, destination.parentId, destination.afterId);
    if (
      block.pageId === pageId &&
      block.parentId === destination.parentId &&
      block.previousSiblingId === destination.afterId
    ) {
      return { changed: false, focus: { blockId, offset: 0 } };
    }

    return this.recordEdit(
      label,
      "structure",
      null,
      { blockId, offset: 0 },
      { blockId, offset: 0 },
      (recorder) => {
        if (!options.preserveComputation) {
          this.touchBlock(recorder, block.id);
          this.detachComputation(block);
        }
        this.detachNode(recorder, block);
        this.attachNode(recorder, block, pageId, destination.parentId, destination.afterId);
        if (sourcePageId !== pageId) this.setSubtreePage(recorder, block, pageId);
        return { blockId, offset: 0 };
      },
    );
  }

  setCollapsed(blockId: ArborBlockId, collapsed: boolean): ArborEditResult {
    const block = this.requireBlock(blockId);
    if (block.collapsed === collapsed) return { changed: false, focus: null };
    block.collapsed = collapsed;
    this.emit("view", new Set([block.pageId]));
    return { changed: true, focus: null };
  }

  toggleCollapsed(blockId: ArborBlockId): ArborEditResult {
    const block = this.requireBlock(blockId);
    return this.setCollapsed(blockId, !block.collapsed);
  }

  undo(): ArborEditResult {
    const entry = this.undoStack.pop();
    if (!entry) return { changed: false, focus: null };
    this.restoreEntityState(entry.before);
    this.redoStack.push(entry);
    this.emit(entry.kind, entry.pageIds);
    return { changed: true, focus: cloneCaret(entry.focusBefore) };
  }

  redo(): ArborEditResult {
    const entry = this.redoStack.pop();
    if (!entry) return { changed: false, focus: null };
    this.restoreEntityState(entry.after);
    this.undoStack.push(entry);
    this.emit(entry.kind, entry.pageIds);
    return { changed: true, focus: cloneCaret(entry.focusAfter) };
  }

  clearHistory(): void {
    this.undoStack = [];
    this.redoStack = [];
  }

  childIds(pageId: ArborPageId, parentId: ArborBlockId | null): ArborBlockId[] {
    this.validateContainer(pageId, parentId);
    const result: ArborBlockId[] = [];
    let cursor = parentId
      ? this.requireBlock(parentId).firstChildId
      : this.requirePage(pageId).firstChildId;
    while (cursor) {
      result.push(cursor);
      cursor = this.requireBlock(cursor).nextSiblingId;
    }
    return result;
  }

  toSnapshot(): ArborDocumentSnapshot {
    const pages: ArborPageSnapshot[] = [];
    const blocks: ArborBlockSnapshot[] = [];
    for (const page of this.pages.values()) {
      pages.push({ id: page.id, title: page.title, children: this.childIds(page.id, null) });
      const stack = [...this.childIds(page.id, null)].reverse();
      while (stack.length > 0) {
        const id = stack.pop()!;
        const block = this.requireBlock(id);
        const children = this.childIds(page.id, id);
        blocks.push({
          id: block.id,
          pageId: block.pageId,
          parentId: block.parentId,
          children,
          text: block.text,
          ...(block.computation ? { computation: { ...block.computation } } : {}),
          ...(block.collapsed ? { collapsed: true } : {}),
        });
        for (let index = children.length - 1; index >= 0; index -= 1) stack.push(children[index]!);
      }
    }
    return { version: 1, pages, blocks };
  }

  replaceSnapshot(
    snapshot: ArborDocumentSnapshot,
    label = "Apply outline transaction",
  ): ArborEditResult {
    const replacement = new ArborOutlineStore(snapshot, {
      idFactory: this.idFactory,
      historyLimit: 0,
    });
    for (const [id, block] of replacement.blocks) {
      block.collapsed = this.blocks.get(id)?.collapsed ?? block.collapsed;
    }
    if (JSON.stringify(this.toSnapshot()) === JSON.stringify(replacement.toSnapshot())) {
      return { changed: false, focus: null };
    }

    return this.recordEdit(label, "structure", null, null, null, (recorder) => {
      for (const id of new Set([...this.blocks.keys(), ...replacement.blocks.keys()])) {
        this.touchBlock(recorder, id);
      }
      for (const id of new Set([...this.pages.keys(), ...replacement.pages.keys()])) {
        this.touchPage(recorder, id);
      }

      this.blocks.clear();
      this.pages.clear();
      for (const [id, block] of replacement.blocks) {
        this.blocks.set(id, cloneBlock(block));
      }
      for (const [id, page] of replacement.pages) this.pages.set(id, clonePage(page));
      return null;
    });
  }

  private loadSnapshot(snapshot: ArborDocumentSnapshot): void {
    if (snapshot.version !== 1) throw new Error(`Unsupported Arbor snapshot version: ${snapshot.version}`);
    for (const input of snapshot.pages) {
      if (this.pages.has(input.id)) throw new Error(`Duplicate Arbor page id: ${input.id}`);
      this.pages.set(input.id, {
        id: input.id,
        title: input.title,
        firstChildId: null,
        lastChildId: null,
        childCount: 0,
      });
      this.pageStructureRevisions.set(input.id, 0);
    }

    const snapshots = new Map<ArborBlockId, ArborBlockSnapshot>();
    const placed = new Set<ArborBlockId>();
    for (const input of snapshot.blocks) {
      if (snapshots.has(input.id)) throw new Error(`Duplicate Arbor block id: ${input.id}`);
      if (!this.pages.has(input.pageId)) throw new Error(`Missing page for Arbor block: ${input.id}`);
      snapshots.set(input.id, input);
      this.blocks.set(input.id, {
        id: input.id,
        pageId: input.pageId,
        text: input.text,
        parentId: input.parentId,
        firstChildId: input.children[0] ?? null,
        lastChildId: input.children.at(-1) ?? null,
        previousSiblingId: null,
        nextSiblingId: null,
        childCount: input.children.length,
        collapsed: input.collapsed ?? false,
        ...(input.computation ? { computation: { ...input.computation } } : {}),
      });
    }

    for (const pageInput of snapshot.pages) {
      const page = this.requirePage(pageInput.id);
      page.firstChildId = pageInput.children[0] ?? null;
      page.lastChildId = pageInput.children.at(-1) ?? null;
      page.childCount = pageInput.children.length;
      this.linkSiblings(page.id, null, pageInput.children, snapshots, placed);
    }
    for (const input of snapshot.blocks) {
      this.linkSiblings(input.pageId, input.id, input.children, snapshots, placed);
    }
    if (placed.size !== snapshots.size) {
      const orphan = snapshot.blocks.find((block) => !placed.has(block.id));
      throw new Error(`Unplaced Arbor block: ${orphan?.id ?? "unknown"}`);
    }
    this.validateAcyclicSnapshot(snapshot.blocks);
  }

  private validateAcyclicSnapshot(blocks: readonly ArborBlockSnapshot[]): void {
    const complete = new Set<ArborBlockId>();
    for (const input of blocks) {
      if (complete.has(input.id)) continue;
      const path: ArborBlockId[] = [];
      const visiting = new Set<ArborBlockId>();
      let cursor: ArborBlockId | null = input.id;
      while (cursor && !complete.has(cursor)) {
        if (visiting.has(cursor)) throw new Error(`Cyclic Arbor block ancestry: ${cursor}`);
        visiting.add(cursor);
        path.push(cursor);
        cursor = this.requireBlock(cursor).parentId;
      }
      for (const id of path) complete.add(id);
    }
  }

  private linkSiblings(
    pageId: ArborPageId,
    parentId: ArborBlockId | null,
    ids: readonly ArborBlockId[],
    snapshots: ReadonlyMap<ArborBlockId, ArborBlockSnapshot>,
    placed: Set<ArborBlockId>,
  ): void {
    ids.forEach((id, index) => {
      if (placed.has(id)) throw new Error(`Duplicate child Arbor block id: ${id}`);
      placed.add(id);
      const block = this.requireBlock(id);
      const snapshot = snapshots.get(id)!;
      if (snapshot.pageId !== pageId || snapshot.parentId !== parentId) {
        throw new Error(`Invalid placement for Arbor block: ${id}`);
      }
      block.previousSiblingId = ids[index - 1] ?? null;
      block.nextSiblingId = ids[index + 1] ?? null;
    });
  }

  private recordEdit(
    label: string,
    kind: Exclude<ArborChangeKind, "view">,
    mergeKey: string | null,
    focusBefore: ArborCaretTarget | null,
    focusAfter: ArborCaretTarget | null,
    edit: (recorder: MutationRecorder) => ArborCaretTarget | null,
  ): ArborEditResult {
    const recorder: MutationRecorder = {
      before: { blocks: new Map(), pages: new Map() },
      pageIds: new Set(),
    };
    let focus: ArborCaretTarget | null;
    try {
      focus = edit(recorder);
    } catch (error) {
      this.restoreEntityState(recorder.before);
      throw error;
    }
    const after = this.captureCurrentState(recorder.before);
    const entry: HistoryEntry = {
      label,
      kind,
      before: recorder.before,
      after,
      pageIds: recorder.pageIds,
      focusBefore: cloneCaret(focusBefore),
      focusAfter: cloneCaret(focusAfter ?? focus),
      mergeKey,
    };

    const transaction = this.activeTransaction;
    if (transaction) {
      for (const [id, before] of recorder.before.blocks) {
        if (!transaction.before.blocks.has(id)) transaction.before.blocks.set(id, before);
      }
      for (const [id, before] of recorder.before.pages) {
        if (!transaction.before.pages.has(id)) transaction.before.pages.set(id, before);
      }
      for (const pageId of recorder.pageIds) transaction.pageIds.add(pageId);
      if (!transaction.changed) transaction.focusBefore = entry.focusBefore;
      transaction.focusAfter = entry.focusAfter;
      transaction.kind = transaction.kind === "structure" || kind === "structure"
        ? "structure"
        : "content";
      transaction.changed = true;
      return { changed: true, focus };
    }

    const previous = this.undoStack.at(-1);
    if (mergeKey && previous?.mergeKey === mergeKey && previous.kind === kind) {
      for (const [id, block] of recorder.before.blocks) {
        if (!previous.before.blocks.has(id)) previous.before.blocks.set(id, block);
      }
      for (const [id, page] of recorder.before.pages) {
        if (!previous.before.pages.has(id)) previous.before.pages.set(id, page);
      }
      for (const [id, block] of after.blocks) previous.after.blocks.set(id, block);
      for (const [id, page] of after.pages) previous.after.pages.set(id, page);
      previous.pageIds = new Set([...previous.pageIds, ...entry.pageIds]);
      previous.focusAfter = entry.focusAfter;
    } else if (this.historyLimit > 0) {
      this.undoStack.push(entry);
      if (this.undoStack.length > this.historyLimit) this.undoStack.shift();
    }
    this.redoStack = [];
    this.emit(kind, recorder.pageIds);
    return { changed: true, focus };
  }

  private touchBlock(recorder: MutationRecorder, id: ArborBlockId): void {
    if (!recorder.before.blocks.has(id)) {
      const block = this.blocks.get(id);
      recorder.before.blocks.set(id, block ? cloneBlock(block) : null);
      if (block) recorder.pageIds.add(block.pageId);
    }
  }

  private touchPage(recorder: MutationRecorder, id: ArborPageId): void {
    if (!recorder.before.pages.has(id)) {
      const page = this.pages.get(id);
      recorder.before.pages.set(id, page ? clonePage(page) : null);
    }
    recorder.pageIds.add(id);
  }

  private captureCurrentState(touched: EntityState): EntityState {
    const state: EntityState = { blocks: new Map(), pages: new Map() };
    for (const id of touched.blocks.keys()) {
      const block = this.blocks.get(id);
      state.blocks.set(id, block ? cloneBlock(block) : null);
    }
    for (const id of touched.pages.keys()) {
      const page = this.pages.get(id);
      state.pages.set(id, page ? clonePage(page) : null);
    }
    return state;
  }

  private restoreEntityState(state: EntityState): void {
    for (const [id, block] of state.blocks) {
      if (block) {
        const restored = cloneBlock(block);
        const current = this.blocks.get(id);
        if (current) restored.collapsed = current.collapsed;
        this.blocks.set(id, restored);
      }
      else this.blocks.delete(id);
    }
    for (const [id, page] of state.pages) {
      if (page) this.pages.set(id, clonePage(page));
      else this.pages.delete(id);
    }
  }

  private detachNode(recorder: MutationRecorder, block: ArborBlockNode): void {
    this.touchBlock(recorder, block.id);
    const previous = block.previousSiblingId ? this.requireBlock(block.previousSiblingId) : null;
    const next = block.nextSiblingId ? this.requireBlock(block.nextSiblingId) : null;
    if (previous) {
      this.touchBlock(recorder, previous.id);
      previous.nextSiblingId = next?.id ?? null;
    }
    if (next) {
      this.touchBlock(recorder, next.id);
      next.previousSiblingId = previous?.id ?? null;
    }

    if (block.parentId) {
      const parent = this.requireBlock(block.parentId);
      this.touchBlock(recorder, parent.id);
      this.detachComputation(parent);
      if (parent.firstChildId === block.id) parent.firstChildId = next?.id ?? null;
      if (parent.lastChildId === block.id) parent.lastChildId = previous?.id ?? null;
      parent.childCount -= 1;
    } else {
      const page = this.requirePage(block.pageId);
      this.touchPage(recorder, page.id);
      if (page.firstChildId === block.id) page.firstChildId = next?.id ?? null;
      if (page.lastChildId === block.id) page.lastChildId = previous?.id ?? null;
      page.childCount -= 1;
    }

    recorder.pageIds.add(block.pageId);
    block.previousSiblingId = null;
    block.nextSiblingId = null;
  }

  private attachNode(
    recorder: MutationRecorder,
    block: ArborBlockNode,
    pageId: ArborPageId,
    parentId: ArborBlockId | null,
    afterId: ArborBlockId | null,
  ): void {
    this.touchBlock(recorder, block.id);
    const parent = parentId ? this.requireBlock(parentId) : null;
    const page = this.requirePage(pageId);
    const firstId = parent ? parent.firstChildId : page.firstChildId;
    const previous = afterId ? this.requireBlock(afterId) : null;
    const next = previous?.nextSiblingId
      ? this.requireBlock(previous.nextSiblingId)
      : afterId
        ? null
        : firstId
          ? this.requireBlock(firstId)
          : null;

    if (previous) {
      this.touchBlock(recorder, previous.id);
      previous.nextSiblingId = block.id;
    }
    if (next) {
      this.touchBlock(recorder, next.id);
      next.previousSiblingId = block.id;
    }

    block.pageId = pageId;
    block.parentId = parentId;
    block.previousSiblingId = previous?.id ?? null;
    block.nextSiblingId = next?.id ?? null;

    if (parent) {
      this.touchBlock(recorder, parent.id);
      this.detachComputation(parent);
      if (!previous) parent.firstChildId = block.id;
      if (!next) parent.lastChildId = block.id;
      parent.childCount += 1;
    } else {
      this.touchPage(recorder, page.id);
      if (!previous) page.firstChildId = block.id;
      if (!next) page.lastChildId = block.id;
      page.childCount += 1;
    }
    recorder.pageIds.add(pageId);
  }

  private setSubtreePage(
    recorder: MutationRecorder,
    root: ArborBlockNode,
    pageId: ArborPageId,
  ): void {
    const stack = [root.id];
    while (stack.length > 0) {
      const block = this.requireBlock(stack.pop()!);
      this.touchBlock(recorder, block.id);
      block.pageId = pageId;
      let childId = block.firstChildId;
      while (childId) {
        stack.push(childId);
        childId = this.requireBlock(childId).nextSiblingId;
      }
    }
  }

  private detachComputation(block: ArborBlockNode): void {
    if (block.computation?.state === "live" || block.computation?.state === "snapshot") {
      block.computation = { ...block.computation, state: "detached" };
    }
  }

  private previousVisibleBlock(block: ArborBlockNode): ArborBlockNode | null {
    if (!block.previousSiblingId) {
      return block.parentId ? this.requireBlock(block.parentId) : null;
    }
    let candidate = this.requireBlock(block.previousSiblingId);
    while (!candidate.collapsed && candidate.lastChildId) {
      candidate = this.requireBlock(candidate.lastChildId);
    }
    return candidate;
  }

  private isDescendant(
    possibleDescendantId: ArborBlockId | null,
    ancestorId: ArborBlockId,
  ): boolean {
    let cursor = possibleDescendantId;
    while (cursor) {
      if (cursor === ancestorId) return true;
      cursor = this.requireBlock(cursor).parentId;
    }
    return false;
  }

  private validateContainer(pageId: ArborPageId, parentId: ArborBlockId | null): void {
    this.requirePage(pageId);
    if (parentId && this.requireBlock(parentId).pageId !== pageId) {
      throw new Error("Arbor parent and destination page do not match");
    }
  }

  private validateInsertionAnchor(
    pageId: ArborPageId,
    parentId: ArborBlockId | null,
    afterId: ArborBlockId | null,
  ): void {
    if (!afterId) return;
    const after = this.requireBlock(afterId);
    if (after.pageId !== pageId || after.parentId !== parentId) {
      throw new Error("Arbor insertion anchor is outside the destination container");
    }
  }

  private requirePage(pageId: ArborPageId): ArborPageNode {
    const page = this.pages.get(pageId);
    if (!page) throw new Error(`Unknown Arbor page: ${pageId}`);
    return page;
  }

  private requireBlock(blockId: ArborBlockId): ArborBlockNode {
    const block = this.blocks.get(blockId);
    if (!block) throw new Error(`Unknown Arbor block: ${blockId}`);
    return block;
  }

  private emit(kind: ArborChangeKind, pageIds: ReadonlySet<ArborPageId>): void {
    this.revision += 1;
    if (kind !== "content") {
      for (const pageId of pageIds) {
        this.pageStructureRevisions.set(
          pageId,
          (this.pageStructureRevisions.get(pageId) ?? 0) + 1,
        );
      }
    }
    const change: ArborStoreChange = { revision: this.revision, kind, pageIds };
    for (const listener of this.listeners) listener(change);
  }
}

function sameComputation(
  left: ArborComputationMetadata | undefined,
  right: ArborComputationMetadata | undefined,
): boolean {
  if (left === right) return true;
  if (!left || !right) return false;
  return left.version === right.version
    && left.state === right.state
    && left.producerId === right.producerId
    && left.resultKey === right.resultKey
    && left.generation === right.generation
    && left.inputHash === right.inputHash
    && left.worldRevision === right.worldRevision;
}
