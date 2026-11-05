import { describe, expect, it } from "bun:test";
import { arborPageId } from "./ids.ts";
import { parseArborBlockText, parseArborSource, serializeArborPage } from "./sourceCodec.ts";
import { ArborOutlineStore } from "./store.ts";

describe("Arbor source codec", () => {
  it("separates a pasted stable id from the visible block text", () => {
    expect(parseArborBlockText(
      "! (clipboard/write \"Arbor clipboard test\") ^clipboard-write",
    )).toEqual({
      text: "! (clipboard/write \"Arbor clipboard test\")",
      anchor: { id: "clipboard-write" },
    });
    expect(parseArborBlockText("Keep ^an invalid id")).toEqual({
      text: "Keep ^an invalid id",
    });
  });

  it("parses stable ids, indentation, and multiline block text", () => {
    const parsed = parseArborSource([
      "#lang arbor/0",
      "- Parent ^parent-1",
      "  | second line",
      "  - Child ^child-1",
      "- Sibling ^sibling-1",
      "",
    ].join("\n"), { title: "Outline", pageId: arborPageId("outline") });

    expect(parsed.diagnostics).toEqual([]);
    expect(parsed.synthesizedIds).toEqual([]);
    expect(parsed.snapshot.pages[0]?.children).toEqual(["parent-1", "sibling-1"]);
    expect(parsed.snapshot.blocks[0]?.text).toBe("Parent\nsecond line");
    expect(parsed.snapshot.blocks[0]?.children).toEqual(["child-1"]);
  });

  it("synthesizes deterministic ids only when missing and writes them canonically", () => {
    const source = "#lang arbor/0\n- Missing\n  - Also missing\n";
    const first = parseArborSource(source, { title: "Same" });
    const second = parseArborSource(source, { title: "Same" });
    expect(first.synthesizedIds).toEqual(second.synthesizedIds);
    expect(first.synthesizedIds).toHaveLength(2);

    const store = ArborOutlineStore.fromSnapshot(first.snapshot);
    const serialized = serializeArborPage(store, first.pageId);
    const reparsed = parseArborSource(serialized, { title: "Same", pageId: first.pageId });
    expect(reparsed.synthesizedIds).toEqual([]);
    expect(reparsed.snapshot).toEqual(first.snapshot);
    expect(serialized.endsWith("\n")).toBe(true);
  });

  it("reports malformed language, indentation jumps, and duplicate ids", () => {
    const parsed = parseArborSource([
      "#lang arbor/9",
      "    - Jump ^same-id",
      "- Duplicate ^same-id",
    ].join("\n"));
    expect(parsed.diagnostics.map((diagnostic) => diagnostic.code)).toEqual([
      "arbor.unsupported-language",
      "arbor.indentation-jump",
      "arbor.duplicate-id",
    ]);
  });

  it("persists versioned computation metadata without changing the stable id", () => {
    const source = [
      "#lang arbor/0",
      "- = (+ 40 2) ^sum",
      `  - 42 ^answer~c1~l~sum~scalar~2~${"a".repeat(40)}~7`,
      "",
    ].join("\n");
    const parsed = parseArborSource(source, { title: "Computed" });
    expect(parsed.diagnostics).toEqual([]);
    expect(parsed.snapshot.blocks[1]?.id).toBe("answer");
    expect(parsed.snapshot.blocks[1]?.computation).toEqual({
      version: 1,
      state: "live",
      producerId: "sum",
      resultKey: "scalar",
      generation: 2,
      inputHash: "a".repeat(40),
      worldRevision: 7,
    });
    const store = ArborOutlineStore.fromSnapshot(parsed.snapshot);
    expect(serializeArborPage(store, parsed.pageId)).toBe(source);
  });

  it("hides and canonicalizes legacy boolean computation metadata", () => {
    const source = [
      "#lang arbor/0",
      "- ! (clock/today) ^today",
      `  - 2026-08-16 ^result~c1~l~today~effect~true~${"a".repeat(40)}~2`,
      "",
    ].join("\n");
    const parsed = parseArborSource(source, { title: "Computed" });
    expect(parsed.diagnostics).toEqual([]);
    expect(parsed.snapshot.blocks[1]?.text).toBe("2026-08-16");

    const store = ArborOutlineStore.fromSnapshot(parsed.snapshot);
    expect(serializeArborPage(store, parsed.pageId)).toContain(
      `2026-08-16 ^result~c1~l~today~effect~1~${"a".repeat(40)}~2`,
    );
  });
});
