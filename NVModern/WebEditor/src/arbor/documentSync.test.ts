import { describe, expect, it } from "bun:test";
import {
  ArborOutlineStore,
  parseArborSource,
} from "../lib/arbor/index.ts";
import { startArborDocumentSync } from "./documentSync.ts";
import type {
  ArborDocumentReplaceRequest,
  ArborDocumentWrite,
  ArborHost,
  ArborIntentRequest,
  ArborProducerRequest,
  ArborQueryRequest,
} from "./host.ts";

function fixtureHost(options: {
  rejectRevision?: number;
  rejectIntent?: boolean;
  mutationSource?: string;
} = {}) {
  const saves: ArborDocumentWrite[] = [];
  const replacements: ArborDocumentReplaceRequest[] = [];
  const queries: ArborQueryRequest[] = [];
  const producers: ArborProducerRequest[] = [];
  const intents: ArborIntentRequest[] = [];
  const host: ArborHost = {
    kernelEnabled: true,
    saveDocument(document) {
      saves.push(document);
    },
    async evaluate() {
      return { ok: true };
    },
    async replaceDocument(request) {
      replacements.push(request);
      if (request.document.revision === options.rejectRevision) throw new Error("kernel down");
      return { ok: true, outcome: "replaced", revision: request.document.revision };
    },
    async runQuery(request) {
      queries.push(request);
      return { ok: true, revision: request.revision, columns: ["Block"], rows: [["one"]] };
    },
    async getView(request) {
      return { ok: true, revision: request.revision, worldRevision: 1, views: [] };
    },
    async runProducer(request) {
      producers.push(request);
      if (options.mutationSource) {
        return {
          ok: true,
          revision: request.revision + 1,
          worldRevision: 2,
          producerID: request.producerId,
          kind: "mutation" as const,
          mode: request.mode,
          generation: 1,
          inputHash: "a".repeat(40),
          results: [],
          document: {
            id: request.documentId,
            path: "Test.outline",
            revision: request.revision + 1,
            source: options.mutationSource,
          },
        };
      }
      return {
        ok: true,
        revision: request.revision,
        worldRevision: 2,
        producerID: request.producerId,
        kind: "expression",
        mode: request.mode,
        generation: 1,
        inputHash: "a".repeat(40),
        results: [{ key: "scalar", markdown: "42" }],
      };
    },
    async applyIntent(request) {
      intents.push(request);
      if (options.rejectIntent) return { ok: false };
      return {
        ok: true,
        origin: { blockID: "source", documentID: request.documentId, path: "Test.outline" },
        text: request.intent.text,
      };
    },
    openLink() {},
    openInlineLink() {},
  };
  return {
    host,
    saves,
    replacements,
    queries,
    producers,
    intents,
  };
}

function fixtureStore(source = "#lang arbor/0\n- One ^one\n") {
  const parsed = parseArborSource(source, { title: "Test" });
  return {
    store: ArborOutlineStore.fromSnapshot(parsed.snapshot),
    pageId: parsed.pageId,
  };
}

describe("Arbor document sync", () => {
  it("persists and indexes the same source revision", async () => {
    const { store, pageId } = fixtureStore();
    const { host, saves, replacements } = fixtureHost();
    let request = 0;
    const sync = startArborDocumentSync({
      store,
      pageId,
      document: { id: "Test.outline", path: "Test.outline" },
      host,
      debounceMs: 60_000,
      initialRevision: 0,
      makeRequestId: () => `request-${++request}`,
    });
    await sync.ready;

    store.setBlockText(parseArborSource("#lang arbor/0\n- One ^one\n").snapshot.blocks[0]!.id, "Two");
    await sync.flush();

    expect(saves).toHaveLength(1);
    expect(replacements).toHaveLength(2);
    expect(saves[0]!.revision).toBe(1);
    expect(replacements[1]!.document.revision).toBe(1);
    expect(replacements[1]!.requestId).toBe(saves[0]!.requestId);
    expect(replacements[1]!.document.source).toBe(saves[0]!.source);
    sync.stop();
  });

  it("keeps persistence successful when the kernel is unavailable", async () => {
    const { store, pageId } = fixtureStore();
    const { host, saves } = fixtureHost({ rejectRevision: 1 });
    const sync = startArborDocumentSync({
      store,
      pageId,
      document: { id: "Test.outline", path: "Test.outline" },
      host,
      debounceMs: 60_000,
      initialRevision: 0,
    });
    await sync.ready;

    store.setBlockText(store.toSnapshot().blocks[0]!.id, "Saved without kernel");
    await expect(sync.flush()).resolves.toBeUndefined();
    expect(saves[0]!.source).toContain("Saved without kernel");
    sync.stop();
  });

  it("queries the latest accepted renderer revision", async () => {
    const { store, pageId } = fixtureStore();
    const { host, queries } = fixtureHost();
    const sync = startArborDocumentSync({
      store,
      pageId,
      document: { id: "Test.outline", path: "Test.outline" },
      host,
      debounceMs: 60_000,
      initialRevision: 0,
    });
    await sync.ready;
    store.setBlockText(store.toSnapshot().blocks[0]!.id, "Two");

    const response = await sync.runQuery("all-blocks", { tag: "todo" });

    expect(queries[0]).toMatchObject({
      documentId: "Test.outline",
      revision: 1,
      queryId: "all-blocks",
      arguments: { tag: "todo" },
    });
    expect(response.rows).toEqual([["one"]]);
    sync.stop();
  });

  it("materializes a producer only after an explicit run and persists the result", async () => {
    const { store, pageId } = fixtureStore("#lang arbor/0\n- = (+ 40 2) ^answer\n");
    const fixture = fixtureHost();
    const sync = startArborDocumentSync({
      store,
      pageId,
      document: { id: "Test.outline", path: "Test.outline" },
      host: fixture.host,
      debounceMs: 60_000,
      initialRevision: 0,
    });
    await sync.ready;
    expect(store.childIds(pageId, store.toSnapshot().blocks[0]!.id)).toEqual([]);
    expect(fixture.producers).toEqual([]);

    await sync.runProducer(store.toSnapshot().blocks[0]!.id);

    expect(fixture.producers[0]).toMatchObject({
      documentId: "Test.outline",
      revision: 0,
      producerId: "answer",
      mode: "refresh",
    });
    const childId = store.childIds(pageId, store.toSnapshot().blocks[0]!.id)[0]!;
    expect(store.getBlock(childId)?.text).toBe("42");
    expect(store.getBlock(childId)?.computation?.state).toBe("live");
    expect(fixture.saves.at(-1)?.source).toContain("~c1~l~answer~scalar~1~");
    expect(fixture.replacements.at(-1)?.document.revision).toBe(1);
    sync.stop();
  });

  it("resynchronizes once when the kernel has a newer accepted revision", async () => {
    const { store, pageId } = fixtureStore("#lang arbor/0\n- = (+ 40 2) ^answer\n");
    const fixture = fixtureHost();
    const runProducer = fixture.host.runProducer;
    let stale = true;
    fixture.host.runProducer = async (request) => {
      if (stale) {
        stale = false;
        fixture.producers.push(request);
        return {
          ok: false,
          revision: request.revision,
          acceptedRevision: 5,
          diagnostics: [{
            severity: "error",
            code: "ARBOR3302",
            message: "Producer revision does not match the accepted document revision.",
          }],
        };
      }
      return runProducer(request);
    };
    const sync = startArborDocumentSync({
      store,
      pageId,
      document: { id: "Test.outline", path: "Test.outline" },
      host: fixture.host,
      debounceMs: 60_000,
      initialRevision: 0,
    });
    await sync.ready;

    const response = await sync.runProducer(store.toSnapshot().blocks[0]!.id);

    expect(response.ok).toBe(true);
    expect(fixture.producers.map((request) => request.revision)).toEqual([0, 6]);
    expect(fixture.replacements.at(-1)?.document.revision).toBe(7);
    expect(store.childIds(pageId, store.toSnapshot().blocks[0]!.id)).toHaveLength(1);
    sync.stop();
  });

  it("installs an accepted outline transaction without saving it twice", async () => {
    const source = "#lang arbor/0\n- ! (outline/insert-child (self) \"New\") ^maker\n";
    const candidate = `${source.trimEnd()}\n  - New ^managed\n`;
    const { store, pageId } = fixtureStore(source);
    const fixture = fixtureHost({ mutationSource: candidate });
    const sync = startArborDocumentSync({
      store,
      pageId,
      document: { id: "Test.outline", path: "Test.outline" },
      host: fixture.host,
      debounceMs: 60_000,
      initialRevision: 0,
    });
    await sync.ready;

    await sync.runProducer(store.toSnapshot().blocks[0]!.id);

    expect(sync.revision()).toBe(1);
    expect(store.childIds(pageId, store.toSnapshot().blocks[0]!.id)).toHaveLength(1);
    expect(store.history.undoDepth).toBe(1);
    expect(fixture.saves).toHaveLength(0);
    store.undo();
    expect(store.childIds(pageId, store.toSnapshot().blocks[0]!.id)).toEqual([]);
    await sync.flush();
    expect(sync.revision()).toBe(2);
    expect(fixture.saves.at(-1)?.source).toBe(source);
    sync.stop();
  });

  it("applies a source-backed edit to its origin and keeps the result live", async () => {
    const source = [
      "#lang arbor/0",
      "- Original ^source",
      "- {{query: (find (?block) (where (block-text ?block \"Original\")))}} ^query",
      `  - Original ^result~c2~l~query~row~1~${"a".repeat(40)}~1~source~t`,
      "",
    ].join("\n");
    const { store, pageId } = fixtureStore(source);
    const fixture = fixtureHost();
    const sync = startArborDocumentSync({
      store,
      pageId,
      document: { id: "Test.outline", path: "Test.outline" },
      host: fixture.host,
      debounceMs: 60_000,
      initialRevision: 0,
    });
    await sync.ready;
    const resultId = store.toSnapshot().blocks.find((block) => block.id === "result")!.id;
    store.setBlockText(resultId, "Renamed", { preserveComputation: true });

    expect(await sync.applyIntent(resultId, "Renamed")).toBe(true);
    expect(store.getBlock(resultId)?.computation?.state).toBe("live");
    expect(store.getBlock(store.toSnapshot().blocks.find((block) => block.id === "source")!.id)?.text)
      .toBe("Renamed");
    expect(fixture.intents[0]).toMatchObject({ revision: 1, resultId: "result" });
    expect(fixture.saves.at(-1)?.source).toContain("- Renamed ^source");
    sync.stop();
  });

  it("preserves the edited text but detaches when a source-backed intent fails", async () => {
    const source = [
      "#lang arbor/0",
      "- Original ^source",
      `- Edited ^result~c2~l~query~row~1~${"a".repeat(40)}~1~source~t`,
      "",
    ].join("\n");
    const { store, pageId } = fixtureStore(source);
    const fixture = fixtureHost({ rejectIntent: true });
    const sync = startArborDocumentSync({
      store,
      pageId,
      document: { id: "Test.outline", path: "Test.outline" },
      host: fixture.host,
      debounceMs: 60_000,
      initialRevision: 0,
    });
    await sync.ready;
    const resultId = store.toSnapshot().blocks.find((block) => block.id === "result")!.id;

    expect(await sync.applyIntent(resultId, "Edited")).toBe(false);
    expect(store.getBlock(resultId)?.text).toBe("Edited");
    expect(store.getBlock(resultId)?.computation?.state).toBe("detached");
    sync.stop();
  });
});
