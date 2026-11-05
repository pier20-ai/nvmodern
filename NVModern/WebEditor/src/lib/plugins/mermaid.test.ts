import { describe, expect, it } from "bun:test";
import { EditorState } from "@codemirror/state";
import { documentScanField, documentScannerFacet } from "./documentIndex.ts";
import { markdownDocumentScanner } from "./markdownScanner.ts";
import { mermaidBlocks, createMarkdownMermaidExtension } from "./mermaid.ts";

function state(doc: string) {
  return EditorState.create({ doc, extensions: [
    documentScannerFacet.of(markdownDocumentScanner), documentScanField,
    createMarkdownMermaidExtension(),
  ] });
}

describe("Mermaid preview blocks", () => {
  it("extracts closed Mermaid blocks without changing source", () => {
    const doc = "Before\n```mermaid\nflowchart LR\n A-->B\n```\nAfter";
    const editor = state(doc);
    expect(mermaidBlocks(editor)).toEqual([{ from: doc.indexOf("\nAfter"), source: "flowchart LR\n A-->B\n" }]);
    expect(editor.doc.toString()).toBe(doc);
  });
  it("ignores other languages and unfinished fences", () => {
    expect(mermaidBlocks(state("```js\nA-->B\n```\n```mermaid\nA-->B"))).toEqual([]);
  });
  it("tracks both changed source and a moved closing fence", () => {
    const editor = state("```mermaid\nflowchart LR\n A-->B\n```");
    const next = editor.update({ changes: { from: 0, insert: "Intro\n" } }).state;
    expect(mermaidBlocks(next)[0]?.from).toBe(editor.doc.length + 6);
    const changed = next.update({ changes: { from: next.doc.toString().indexOf("A-->B"), to: next.doc.toString().indexOf("A-->B") + 5, insert: "A-->C" } }).state;
    expect(mermaidBlocks(changed)[0]?.source).toContain("A-->C");
  });
});
