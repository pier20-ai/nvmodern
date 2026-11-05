import type { ArborOutlineStore } from "./store.ts";
import type {
  ArborBlockId,
  ArborPageId,
  ArborVisibleRow,
  ArborVisibleSlice,
} from "./types.ts";

interface CachedRows {
  revision: number;
  rows: readonly ArborVisibleRow[];
  indexById: ReadonlyMap<ArborBlockId, number>;
}

/** A page-local visible-order cache; content edits do not invalidate it. */
export class ArborVisibleIndex {
  private readonly cache = new Map<string, CachedRows>();

  constructor(private readonly store: ArborOutlineStore) {}

  rows(pageId: ArborPageId, zoomBlockId: ArborBlockId | null = null): readonly ArborVisibleRow[] {
    return this.cached(pageId, zoomBlockId).rows;
  }

  slice(
    pageId: ArborPageId,
    offset: number,
    limit: number,
    zoomBlockId: ArborBlockId | null = null,
  ): ArborVisibleSlice {
    const rows = this.rows(pageId, zoomBlockId);
    const safeOffset = Math.max(0, Math.min(rows.length, Math.floor(offset)));
    const safeLimit = Math.max(0, Math.floor(limit));
    return {
      rows: rows.slice(safeOffset, safeOffset + safeLimit),
      offset: safeOffset,
      total: rows.length,
    };
  }

  indexOf(
    pageId: ArborPageId,
    blockId: ArborBlockId,
    zoomBlockId: ArborBlockId | null = null,
  ): number {
    return this.cached(pageId, zoomBlockId).indexById.get(blockId) ?? -1;
  }

  invalidate(pageId?: ArborPageId): void {
    if (!pageId) {
      this.cache.clear();
      return;
    }
    const prefix = `${pageId}\u0000`;
    for (const key of this.cache.keys()) {
      if (key.startsWith(prefix)) this.cache.delete(key);
    }
  }

  private cached(pageId: ArborPageId, zoomBlockId: ArborBlockId | null): CachedRows {
    const key = `${pageId}\u0000${zoomBlockId ?? ""}`;
    const revision = this.store.getPageStructureRevision(pageId);
    const existing = this.cache.get(key);
    if (existing?.revision === revision) return existing;

    const rows = this.buildRows(pageId, zoomBlockId);
    const indexById = new Map<ArborBlockId, number>();
    rows.forEach((row, index) => indexById.set(row.id, index));
    const next = { revision, rows, indexById };
    this.cache.set(key, next);
    return next;
  }

  private buildRows(
    pageId: ArborPageId,
    zoomBlockId: ArborBlockId | null,
  ): readonly ArborVisibleRow[] {
    const page = this.store.getPage(pageId);
    if (!page) throw new Error(`Unknown Arbor page: ${pageId}`);

    const roots: ArborBlockId[] = [];
    if (zoomBlockId) {
      const zoom = this.store.getBlock(zoomBlockId);
      if (!zoom || zoom.pageId !== pageId) throw new Error("Arbor zoom block is outside the page");
      roots.push(zoomBlockId);
    } else {
      let id = page.lastChildId;
      while (id) {
        roots.push(id);
        id = this.store.getBlock(id)?.previousSiblingId ?? null;
      }
    }

    const rows: ArborVisibleRow[] = [];
    const stack = roots.map((id) => ({ id, depth: 0 }));
    while (stack.length > 0) {
      const { id, depth } = stack.pop()!;
      const block = this.store.getBlock(id);
      if (!block) throw new Error(`Broken Arbor outline link: ${id}`);
      rows.push({
        id: block.id,
        pageId: block.pageId,
        parentId: block.parentId,
        depth,
        hasChildren: block.childCount > 0,
        collapsed: block.collapsed,
      });

      if (!block.collapsed) {
        let childId = block.lastChildId;
        while (childId) {
          stack.push({ id: childId, depth: depth + 1 });
          childId = this.store.getBlock(childId)?.previousSiblingId ?? null;
        }
      }
    }
    return rows;
  }
}
