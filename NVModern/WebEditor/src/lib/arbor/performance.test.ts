import { expect, it } from "bun:test";
import { arborBlockId, arborPageId, createSequentialArborIdFactory } from "./ids.ts";
import { ArborOutlineStore } from "./store.ts";
import type {
  ArborBlockId,
  ArborBlockSnapshot,
  ArborDocumentSnapshot,
  ArborPageSnapshot,
} from "./types.ts";
import { ArborVisibleIndex } from "./visibleIndex.ts";
import { ArborVirtualizer } from "./virtualizer.ts";

function percentile(values: number[], quantile: number): number {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * quantile))] ?? 0;
}

function largeSnapshot(): ArborDocumentSnapshot {
  const pages: ArborPageSnapshot[] = [];
  const blocks: ArborBlockSnapshot[] = [];
  for (let pageIndex = 0; pageIndex < 10_000; pageIndex += 1) {
    const pageId = arborPageId(`page-${pageIndex}`);
    const count = pageIndex === 0 ? 20_008 : 8;
    const children: ArborBlockId[] = [];
    for (let blockIndex = 0; blockIndex < count; blockIndex += 1) {
      const id = arborBlockId(`block-${pageIndex}-${blockIndex}`);
      const isDeepChild = pageIndex === 0 && blockIndex > 0 && blockIndex <= 5_000;
      children.push(id);
      blocks.push({
        id,
        pageId,
        parentId: isDeepChild ? arborBlockId("block-0-0") : null,
        children: blockIndex === 0 && pageIndex === 0
          ? Array.from({ length: 5_000 }, (_, index) => arborBlockId(`block-0-${index + 1}`))
          : [],
        text: `Block ${pageIndex}/${blockIndex}`,
      });
    }
    pages.push({
      id: pageId,
      title: `Page ${pageIndex}`,
      children: pageIndex === 0
        ? [children[0]!, ...children.slice(5_001)]
        : children,
    });
  }
  return { version: 1, pages, blocks };
}

it("keeps the 100k-block / 10k-page hot paths bounded", () => {
  const snapshot = largeSnapshot();
  expect(snapshot.blocks).toHaveLength(100_000);
  expect(snapshot.pages).toHaveLength(10_000);
  const startedLoad = performance.now();
  const store = ArborOutlineStore.fromSnapshot(snapshot, {
    historyLimit: 0,
    idFactory: createSequentialArborIdFactory("perf"),
  });
  const loadMs = performance.now() - startedLoad;

  const pageId = arborPageId("page-0");
  const visible = new ArborVisibleIndex(store);
  const startedFlatten = performance.now();
  const rows = visible.rows(pageId);
  const flattenMs = performance.now() - startedFlatten;
  expect(rows).toHaveLength(20_008);

  const virtualizer = new ArborVirtualizer({ estimatedRowHeight: 28, overscanPixels: 280 });
  const startedViewport = performance.now();
  virtualizer.setRows(rows);
  const window = virtualizer.windowForViewport(280_000, 900);
  const viewportMs = performance.now() - startedViewport;
  expect(window.rows.length).toBeLessThanOrEqual(54);

  const editTimes: number[] = [];
  for (let index = 0; index < 500; index += 1) {
    const started = performance.now();
    store.setBlockText(arborBlockId("block-0-10000"), `Keystroke ${index}`, {
      historyGroup: "typing:perf",
    });
    editTimes.push(performance.now() - started);
  }
  const editP95Ms = percentile(editTimes, 0.95);

  store.setCollapsed(arborBlockId("block-0-0"), true);
  const collapsedRows = visible.rows(pageId);
  expect(collapsedRows).toHaveLength(15_008);
  const startedExpand = performance.now();
  store.setCollapsed(arborBlockId("block-0-0"), false);
  const expandedRows = visible.rows(pageId);
  const expandMs = performance.now() - startedExpand;
  expect(expandedRows).toHaveLength(20_008);

  console.info("ARBOR_PERF", JSON.stringify({
    loadMs: Number(loadMs.toFixed(2)),
    flattenMs: Number(flattenMs.toFixed(2)),
    viewportMs: Number(viewportMs.toFixed(2)),
    editP95Ms: Number(editP95Ms.toFixed(3)),
    expand5kMs: Number(expandMs.toFixed(2)),
    renderedRows: window.rows.length,
  }));

  // Wide enough for shared CI, while retaining the product budgets in the output.
  expect(loadMs).toBeLessThan(2_000);
  expect(flattenMs).toBeLessThan(250);
  expect(viewportMs).toBeLessThan(100);
  expect(editP95Ms).toBeLessThan(8);
  expect(expandMs).toBeLessThan(50);
});
