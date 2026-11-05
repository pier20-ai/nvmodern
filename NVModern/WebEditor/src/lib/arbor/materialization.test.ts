import { describe, expect, it } from "bun:test";
import { arborBlockId, arborPageId, createSequentialArborIdFactory } from "./ids.ts";
import {
  applyArborMaterialization,
  parseArborAnchor,
  serializeArborAnchor,
} from "./materialization.ts";
import { ArborOutlineStore } from "./store.ts";
import type {
  ArborComputationMetadata,
  ArborDocumentSnapshot,
} from "./types.ts";

const producerId = arborBlockId("producer");
const inputA = "a".repeat(40);
const inputB = "b".repeat(40);

function computation(
  state: ArborComputationMetadata["state"],
  generation: number,
  resultKey = "scalar",
): ArborComputationMetadata {
  return {
    version: 1,
    state,
    producerId,
    resultKey,
    generation,
    inputHash: inputA,
    worldRevision: 4,
  };
}

function fixture(children: ArborDocumentSnapshot["blocks"] = []): ArborOutlineStore {
  const pageId = arborPageId("page");
  return ArborOutlineStore.fromSnapshot({
    version: 1,
    pages: [{ id: pageId, title: "Test", children: [producerId] }],
    blocks: [{
      id: producerId,
      pageId,
      parentId: null,
      children: children.map((block) => block.id),
      text: "= (+ 40 2)",
    }, ...children],
  }, { idFactory: createSequentialArborIdFactory("result") });
}

function child(
  id: string,
  text: string,
  metadata: ArborComputationMetadata,
): ArborDocumentSnapshot["blocks"][number] {
  return {
    id: arborBlockId(id),
    pageId: arborPageId("page"),
    parentId: producerId,
    children: [],
    text,
    computation: metadata,
  };
}

describe("Arbor materialization state machine", () => {
  it("round-trips computation metadata beside the stable block id", () => {
    const anchor = serializeArborAnchor(arborBlockId("result-1"), computation("live", 3));
    expect(anchor).toBe(`result-1~c1~l~producer~scalar~3~${inputA}~4`);
    expect(parseArborAnchor(anchor)).toEqual({
      id: arborBlockId("result-1"),
      computation: computation("live", 3),
    });
    expect(parseArborAnchor("ordinary-id")).toEqual({ id: arborBlockId("ordinary-id") });
    expect(parseArborAnchor("bad~anchor")).toBeNull();
  });

  it("repairs boolean computation revisions written by the native bridge", () => {
    const anchor = parseArborAnchor(
      `result-1~c1~l~producer~effect~true~${inputA}~true`,
    );
    expect(anchor?.computation?.generation).toBe(1);
    expect(anchor?.computation?.worldRevision).toBe(1);
    expect(serializeArborAnchor(anchor!.id, anchor!.computation)).toBe(
      `result-1~c1~l~producer~effect~1~${inputA}~1`,
    );
  });

  it("persists a source-backed result contract without exposing a path", () => {
    const metadata: ArborComputationMetadata = {
      ...computation("live", 3),
      version: 2,
      originBlockId: arborBlockId("source"),
      updatePolicy: "source-text",
    };
    const anchor = serializeArborAnchor(arborBlockId("result-1"), metadata);
    expect(anchor).toBe(`result-1~c2~l~producer~scalar~3~${inputA}~4~source~t`);
    expect(parseArborAnchor(anchor)).toEqual({ id: arborBlockId("result-1"), computation: metadata });
  });

  it("(a) creates the first live result only on an explicit run", () => {
    const store = fixture();
    applyArborMaterialization(store, {
      producerId,
      mode: "refresh",
      generation: 1,
      inputHash: inputA,
      worldRevision: 1,
      results: [{ key: "scalar", markdown: "42" }],
    });
    const result = store.getBlock(arborBlockId("result_b1"));
    expect(result?.text).toBe("42");
    expect(result?.computation?.state).toBe("live");
    expect(result?.parentId).toBe(producerId);
  });

  it("(b) refreshes an unedited live result in place", () => {
    const store = fixture([child("live", "41", computation("live", 1))]);
    applyArborMaterialization(store, {
      producerId,
      mode: "refresh",
      generation: 2,
      inputHash: inputA,
      worldRevision: 5,
      results: [{ key: "scalar", markdown: "42" }],
    });
    expect(store.childIds(arborPageId("page"), producerId)).toEqual([arborBlockId("live")]);
    expect(store.getBlock(arborBlockId("live"))?.text).toBe("42");
    expect(store.getBlock(arborBlockId("live"))?.computation?.generation).toBe(2);
  });

  it("(c) preserves an edited result and appends a new live sibling", () => {
    const store = fixture([child("edited", "my 42", computation("detached", 1))]);
    applyArborMaterialization(store, {
      producerId,
      mode: "refresh",
      generation: 2,
      inputHash: inputA,
      results: [{ key: "scalar", markdown: "42" }],
    });
    expect(store.childIds(arborPageId("page"), producerId)).toEqual([
      arborBlockId("edited"),
      arborBlockId("result_b1"),
    ]);
    expect(store.getBlock(arborBlockId("edited"))?.text).toBe("my 42");
  });

  it("(d) updates the live result after its producer input changes", () => {
    const store = fixture([child("live", "42", computation("live", 1))]);
    applyArborMaterialization(store, {
      producerId,
      mode: "refresh",
      generation: 2,
      inputHash: inputB,
      results: [{ key: "scalar", markdown: "43" }],
    });
    expect(store.getBlock(arborBlockId("live"))?.text).toBe("43");
    expect(store.getBlock(arborBlockId("live"))?.computation?.inputHash).toBe(inputB);
  });

  it("(e) freezes the current generation and appends Run as New output", () => {
    const store = fixture([child("live", "42", computation("live", 1))]);
    applyArborMaterialization(store, {
      producerId,
      mode: "append",
      generation: 2,
      inputHash: inputA,
      results: [{ key: "scalar", markdown: "42" }],
    });
    expect(store.childIds(arborPageId("page"), producerId)).toEqual([
      arborBlockId("live"),
      arborBlockId("result_b1"),
    ]);
    expect(store.getBlock(arborBlockId("live"))?.computation?.state).toBe("snapshot");
    expect(store.getBlock(arborBlockId("result_b1"))?.computation?.state).toBe("live");
  });

  it("reconciles one ordinary child per query row by stable result key", () => {
    const store = fixture([
      child("kept", "Old A", computation("live", 1, "a")),
      child("removed", "Old B", computation("live", 1, "b")),
    ]);
    applyArborMaterialization(store, {
      producerId,
      mode: "refresh",
      generation: 2,
      inputHash: inputA,
      results: [
        { key: "a", markdown: "New A" },
        { key: "c", markdown: "New C" },
      ],
    });
    expect(store.hasBlock(arborBlockId("removed"))).toBe(false);
    expect(store.getBlock(arborBlockId("kept"))?.text).toBe("New A");
    expect(store.childIds(arborPageId("page"), producerId)).toEqual([
      arborBlockId("kept"),
      arborBlockId("result_b1"),
    ]);
  });

  it("attaches source origin metadata to a live query result", () => {
    const store = fixture();
    applyArborMaterialization(store, {
      producerId,
      mode: "refresh",
      generation: 1,
      inputHash: inputA,
      worldRevision: 4,
      results: [{
        key: "a",
        markdown: "Alpha",
        origin: { blockID: arborBlockId("alpha"), documentID: "doc", path: "Demo.outline" },
        updatePolicy: "source-text",
      }],
    });
    expect(store.getBlock(arborBlockId("result_b1"))?.computation).toMatchObject({
      version: 2,
      originBlockId: arborBlockId("alpha"),
      updatePolicy: "source-text",
    });
  });
});
