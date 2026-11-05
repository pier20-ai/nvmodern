import { describe, expect, it } from "bun:test";
import { EditorSelection, EditorState } from "@codemirror/state";
import { documentScannerFacet } from "./documentIndex.ts";
import { nv3InteractionModeField, setNv3InteractionModeEffect } from "./interactionState.ts";
import { buildLinkData } from "./links.ts";
import { markdownDocumentScanner } from "./markdownScanner.ts";

function createState(link: string): EditorState {
  return EditorState.create({
    doc: `before ${link} after`,
    extensions: [
      documentScannerFacet.of(markdownDocumentScanner),
      nv3InteractionModeField,
      EditorState.allowMultipleSelections.of(true),
    ],
  });
}

function hiddenText(state: EditorState): string[] {
  const hidden: string[] = [];
  buildLinkData(state, {}).decorations.between(0, state.doc.length, (from, to, decoration) => {
    if (decoration.spec.class === "nv3-link-hidden-syntax") {
      hidden.push(state.sliceDoc(from, to));
    }
  });
  return hidden;
}

describe("titled wikilink decorations", () => {
  it("shows only the title while preserving the original navigation target", () => {
    const state = createState("[[folder/note#Heading|Friendly title]]");
    let resolvedTarget = "";
    const { decorations, index } = buildLinkData(state, {
      resolveWikilinkHref: ({ target }) => {
        resolvedTarget = target;
        return "note://resolved";
      },
    });
    expect(hiddenText(state)).toEqual(["[[folder/note#Heading|", "]]"]);
    expect(resolvedTarget).toBe("folder/note#Heading|Friendly title");
    expect(index.occurrences[0]?.target).toBe(resolvedTarget);
    const anchors: unknown[] = [];
    decorations.between(0, state.doc.length, (_from, _to, decoration) => {
      if (decoration.spec.tagName === "a") anchors.push(decoration.spec.attributes);
    });
    expect(anchors).toEqual([expect.objectContaining({
      href: "note://resolved",
      "data-nv3-target": resolvedTarget,
    })]);
  });

  it("reveals the full syntax throughout the link and conceals it after leaving", () => {
    let state = createState("[[folder/note|Title]]");
    const from = 7;
    const to = state.doc.length - 6;
    for (let anchor = from; anchor <= to; anchor++) {
      state = state.update({ selection: { anchor } }).state;
      expect(hiddenText(state)).toEqual([]);
    }
    state = state.update({ selection: { anchor: state.doc.length } }).state;
    expect(hiddenText(state)).toEqual(["[[folder/note|", "]]"]);
  });

  it("reveals the syntax when any selection touches the link", () => {
    const state = createState("[[note|Title]]").update({
      selection: EditorSelection.create([EditorSelection.cursor(0), EditorSelection.range(9, 12)]),
    }).state;
    expect(hiddenText(state)).toEqual([]);
  });

  it("keeps the title concealed while typing elsewhere", () => {
    const state = createState("[[note#^block|Title]]").update({
      changes: { from: 0, insert: "x" },
      effects: setNv3InteractionModeEffect.of("typing"),
    }).state;
    expect(hiddenText(state)).toEqual(["[[note#^block|", "]]"]);
  });

  it("uses source offsets when paths and titles have surrounding spaces", () => {
    expect(hiddenText(createState("[[  note  |  Friendly title  ]]")))
      .toEqual(["[[  note  |  ", "  ]]"]);
  });

  it("preserves untitled links and ignores link syntax in code", () => {
    for (const link of ["[[note/path]]", "[[note/path|]]", "[[note/path|  ]]", "`[[note|Title]]`"]) {
      expect(hiddenText(createState(link))).toEqual([]);
    }
  });
});
