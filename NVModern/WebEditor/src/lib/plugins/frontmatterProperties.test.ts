import { describe, expect, it } from "bun:test";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { createMarkdownFrontmatterPropertiesExtension, nv3FrontmatterRows, nv3FrontmatterSegments } from "./frontmatterProperties.ts";

describe("nv3FrontmatterSegments", () => {
  it("turns wikilinks into links labelled by their last path segment or alias", () => {
    expect(nv3FrontmatterSegments("[[papers/context/self-attention]]")).toEqual([
      { kind: "wikilink", target: "papers/context/self-attention", label: "self-attention" },
    ]);
    expect(nv3FrontmatterSegments("see [[Note#Section|the bit]] here")).toEqual([
      { kind: "text", text: "see " },
      { kind: "wikilink", target: "Note#Section|the bit", label: "the bit" },
      { kind: "text", text: " here" },
    ]);
  });

  it("shortens bare URLs and leaves other text alone", () => {
    expect(nv3FrontmatterSegments("https://arxiv.org/abs/2312.10794v5")).toEqual([
      { kind: "url", href: "https://arxiv.org/abs/2312.10794v5", label: "arxiv.org/abs/2312.10794v5" },
    ]);
    expect(nv3FrontmatterSegments("Bulletin of the AMS")).toEqual([{ kind: "text", text: "Bulletin of the AMS" }]);
  });
});

describe("nv3FrontmatterRows", () => {
  it("keeps source order, humanises keys, and pills tags", () => {
    const rows = nv3FrontmatterRows({
      title: "A Mathematical Perspective",
      published_in: "Bulletin",
      authors: ["Borjan Geshkovski", "Cyril Letrouit"],
      tags: ["transformers", "dynamical-systems"],
      year: 2023,
      created: new Date("2026-10-27T00:00:00Z"),
    });
    expect(rows.map((row) => row.label)).toEqual(["title", "published in", "authors", "tags", "year", "created"]);
    expect(rows.find((row) => row.key === "authors")).toMatchObject({ pills: false, items: [[{ text: "Borjan Geshkovski" }], [{ text: "Cyril Letrouit" }]] });
    expect(rows.find((row) => row.key === "tags")?.pills).toBe(true);
    expect(rows.find((row) => row.key === "year")?.items).toEqual([[{ kind: "text", text: "2023" }]]);
    expect(rows.find((row) => row.key === "created")?.items).toEqual([[{ kind: "text", text: "2026-10-27" }]]);
  });
});

describe("frontmatter properties decoration", () => {
  const doc = "---\ntitle: Note\ntags:\n  - a\n---\nBody text\n";

  function replacedRanges(state: EditorState): Array<[number, number]> {
    const ranges: Array<[number, number]> = [];
    for (const source of state.facet(EditorView.decorations)) {
      if (typeof source === "function") continue;
      source.between(0, state.doc.length, (from, to) => {
        ranges.push([from, to]);
      });
    }
    return ranges;
  }

  it("replaces the frontmatter while the caret is outside it", () => {
    const state = EditorState.create({ doc, extensions: [createMarkdownFrontmatterPropertiesExtension()] });
    expect(replacedRanges(state)).toEqual([[0, doc.indexOf("Body") - 1]]);
  });

  it("shows source while the caret is inside", () => {
    const state = EditorState.create({
      doc,
      selection: { anchor: 8 },
      extensions: [createMarkdownFrontmatterPropertiesExtension()],
    });
    expect(replacedRanges(state)).toEqual([]);
  });

  it("leaves frontmatter that doesn't parse as source", () => {
    const broken = "---\ntitle: [unclosed\n---\nBody\n";
    const state = EditorState.create({ doc: broken, extensions: [createMarkdownFrontmatterPropertiesExtension()] });
    expect(replacedRanges(state)).toEqual([]);
  });
});
