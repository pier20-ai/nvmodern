import type { ArborBlockId, ArborVirtualWindow, ArborVisibleRow } from "./types.ts";

export interface ArborVirtualizerOptions {
  estimatedRowHeight?: number;
  overscanPixels?: number;
}

/** Variable-height virtualizer with O(log n) measurement and offset lookup. */
export class ArborVirtualizer {
  private rows: readonly ArborVisibleRow[] = [];
  private readonly measuredHeights = new Map<ArborBlockId, number>();
  private indexById = new Map<ArborBlockId, number>();
  private heights = new Float64Array(0);
  private tree = new Float64Array(1);
  readonly estimatedRowHeight: number;
  readonly overscanPixels: number;

  constructor(options: ArborVirtualizerOptions = {}) {
    this.estimatedRowHeight = Math.max(1, options.estimatedRowHeight ?? 28);
    this.overscanPixels = Math.max(0, options.overscanPixels ?? 280);
  }

  setRows(rows: readonly ArborVisibleRow[]): void {
    if (rows === this.rows) return;
    this.rows = rows;
    this.indexById = new Map();
    this.heights = new Float64Array(rows.length);
    this.tree = new Float64Array(rows.length + 1);

    for (let index = 0; index < rows.length; index += 1) {
      const row = rows[index]!;
      this.indexById.set(row.id, index);
      const height = this.measuredHeights.get(row.id) ?? this.estimatedRowHeight;
      this.heights[index] = height;
      const treeIndex = index + 1;
      this.tree[treeIndex] = (this.tree[treeIndex] ?? 0) + height;
      const parent = treeIndex + (treeIndex & -treeIndex);
      if (parent < this.tree.length) {
        this.tree[parent] = (this.tree[parent] ?? 0) + (this.tree[treeIndex] ?? 0);
      }
    }
  }

  updateRowHeight(blockId: ArborBlockId, height: number): boolean {
    const normalized = Math.max(1, height);
    this.measuredHeights.set(blockId, normalized);
    const index = this.indexById.get(blockId);
    if (index === undefined) return false;
    const delta = normalized - this.heights[index]!;
    if (Math.abs(delta) < 0.25) return false;
    this.heights[index] = normalized;
    this.add(index + 1, delta);
    return true;
  }

  measure(blockId: ArborBlockId, height: number): boolean {
    return this.updateRowHeight(blockId, height);
  }

  forgetMeasurement(blockId: ArborBlockId): void {
    this.measuredHeights.delete(blockId);
    const index = this.indexById.get(blockId);
    if (index === undefined) return;
    const delta = this.estimatedRowHeight - this.heights[index]!;
    if (delta === 0) return;
    this.heights[index] = this.estimatedRowHeight;
    this.add(index + 1, delta);
  }

  offsetForIndex(index: number): number {
    return this.prefixSum(Math.max(0, Math.min(this.rows.length, Math.floor(index))));
  }

  indexAtOffset(offset: number): number {
    if (this.rows.length === 0) return 0;
    return Math.min(this.rows.length - 1, this.lowerBound(Math.max(0, offset)));
  }

  windowForViewport(
    scrollTop: number,
    viewportHeight: number,
    overscanPixels = this.overscanPixels,
  ): ArborVirtualWindow {
    const totalHeight = this.prefixSum(this.rows.length);
    if (this.rows.length === 0) {
      return {
        rows: [],
        startIndex: 0,
        endIndex: 0,
        paddingTop: 0,
        paddingBottom: 0,
        totalHeight: 0,
      };
    }

    const overscan = Math.max(0, overscanPixels);
    const startOffset = Math.max(0, scrollTop - overscan);
    const endOffset = Math.min(totalHeight, scrollTop + Math.max(0, viewportHeight) + overscan);
    const startIndex = this.lowerBound(startOffset);
    const endIndex = Math.min(this.rows.length, this.lowerBound(endOffset) + 1);
    const paddingTop = this.prefixSum(startIndex);
    const renderedBottom = this.prefixSum(endIndex);
    return {
      rows: this.rows.slice(startIndex, endIndex),
      startIndex,
      endIndex,
      paddingTop,
      paddingBottom: Math.max(0, totalHeight - renderedBottom),
      totalHeight,
    };
  }

  private add(index: number, delta: number): void {
    for (let cursor = index; cursor < this.tree.length; cursor += cursor & -cursor) {
      this.tree[cursor] = this.tree[cursor]! + delta;
    }
  }

  /** Sum of the first `count` row heights. */
  private prefixSum(count: number): number {
    let result = 0;
    for (let cursor = count; cursor > 0; cursor -= cursor & -cursor) {
      result += this.tree[cursor]!;
    }
    return result;
  }

  /** Number of rows whose cumulative height is <= offset. */
  private lowerBound(offset: number): number {
    let index = 0;
    let accumulated = 0;
    let bit = 1;
    while (bit * 2 < this.tree.length) bit *= 2;
    for (; bit !== 0; bit >>= 1) {
      const next = index + bit;
      if (next < this.tree.length && accumulated + this.tree[next]! <= offset) {
        index = next;
        accumulated += this.tree[next]!;
      }
    }
    return Math.min(index, this.rows.length);
  }
}
