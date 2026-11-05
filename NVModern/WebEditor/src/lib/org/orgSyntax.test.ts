import { EditorSelection, EditorState } from "@codemirror/state";
import { history, redo, undo } from "@codemirror/commands";
import { EditorView, type DecorationSet } from "@codemirror/view";
import { parse } from "uniorg-parse";
import { describe, expect, it } from "bun:test";
import { createOrgModeExtension } from "./orgExtension.ts";
import { parseOrgText } from "./parser.ts";
import { documentScanField, documentScannerFacet } from "../plugins/documentIndex.ts";
import { nv3OrgParseStateField, orgDocumentScanner } from "../plugins/orgIndex.ts";
import { createOrgLineUnwrapExtension } from "../plugins/orgLineUnwrap.ts";
import { getOrgSyntax, getOrgSyntaxForState, ORG_TODO_STATES } from "./orgSyntax.ts";

const largeSource = [
  "Title",
  "* TODO Task",
  "- [ ] Check",
  "Before [[./target.org][Target]] after",
  "A wrapped paragraph",
  "continues here.",
  "",
  ...Array.from({ length: 1600 }, (_, i) => i % 10 === 0 ? `* Section ${i}` : "Plain filler text."),
].join("\n");

function createState(doc = largeSource, unwrap = false): EditorState {
  return EditorState.create({
    doc,
    extensions: [
      documentScannerFacet.of(orgDocumentScanner), documentScanField, nv3OrgParseStateField,
      createOrgModeExtension(), unwrap ? createOrgLineUnwrapExtension() : [],
      history(),
      EditorState.allowMultipleSelections.of(true),
    ],
  });
}

function decorations(state: EditorState): DecorationSet[] {
  return state.facet(EditorView.decorations).filter((value): value is DecorationSet => typeof value !== "function");
}

function hiddenSyntax(state: EditorState): string[] {
  const hidden: string[] = [];
  for (const set of decorations(state)) {
    set.between(0, state.doc.length, (from, to, decoration) => {
      if (decoration.spec.class === "nv3-link-hidden-syntax") hidden.push(state.doc.sliceString(from, to));
    });
  }
  return hidden;
}

describe("shared Org syntax", () => {
  it("reuses syntax and the custom index by immutable Text identity", () => {
    const state = createState();
    const parsed = parseOrgText(state.doc);
    expect(state.field(nv3OrgParseStateField)).toBe(parsed);
    expect(parseOrgText(state.doc)).toBe(parsed);
    const syntax = getOrgSyntax(state.doc);
    const moved = state.update({ selection: { anchor: 10 } }).state;
    expect(getOrgSyntax(moved.doc)).toBe(syntax);
    expect(parseOrgText(moved.doc)).toBe(parsed);
    const edited = state.update({ changes: { from: 0, insert: "New " } }).state;
    expect(parseOrgText(edited.doc)).not.toBe(parsed);
    expect(parseOrgText(edited.doc)).toBe(edited.field(nv3OrgParseStateField));
  });

  it("publishes current syntax and command indices in the same edit transaction", () => {
    const state = createState();
    const from = state.doc.toString().indexOf("Task");
    const edited = state.update({ changes: { from, to: from + 4, insert: "Changed" } }).state;
    const syntax = getOrgSyntaxForState(edited);
    expect(syntax.source).toBe(edited.doc.toString());
    expect(syntax.statistics.strategy).toBe("section");
    expect(syntax.statistics.parsedCharacters).toBeLessThan(edited.doc.length / 10);
    expect(edited.field(nv3OrgParseStateField).headings[0]?.title).toBe("Changed");
    expect(edited.field(documentScanField).headings[0]?.text).toBe("Changed");
    expect(syntax.tree).toEqual(parse(syntax.source, { trackPosition: true, todoKeywords: ORG_TODO_STATES }));
  });

  it("falls back synchronously when heading structure changes", () => {
    const state = createState();
    const from = state.doc.toString().indexOf("Before");
    const edited = state.update({ changes: { from, insert: "* New section\n" } }).state;
    const syntax = getOrgSyntaxForState(edited);
    expect(syntax.source).toBe(edited.doc.toString());
    expect(syntax.statistics.strategy).toBe("full");
    expect(syntax.tree).toEqual(parse(syntax.source, { trackPosition: true, todoKeywords: ORG_TODO_STATES }));
  });

  it("keeps TODO and checkbox click targets current through consecutive edits", () => {
    let state = createState();
    state = state.update({ changes: { from: 0, insert: "Inserted\n" } }).state;
    state = state.update({ changes: { from: 0, insert: "Again\n" } }).state;
    let count = 0;
    for (const set of decorations(state)) {
      set.between(0, state.doc.length, (from, to, decoration) => {
        const attributes = decoration.spec.attributes;
        if (!attributes?.["data-om-from"]) return;
        const start = Number(attributes["data-om-from"]);
        const end = Number(attributes["data-om-to"]);
        const expected = attributes["data-om-todo"] ? "TODO" : "[ ]";
        expect(state.doc.sliceString(start, end)).toBe(expected);
        expect(start).toBe(state.doc.toString().indexOf(expected));
        count++;
      });
    }
    expect(count).toBe(2);
  });

  it("updates link presentation immediately, including overlapping selections and multiple cursors", () => {
    let state = createState();
    expect(hiddenSyntax(state)).toHaveLength(2);
    const label = state.doc.toString().indexOf("Target");
    state = state.update({ changes: { from: label, insert: "Changed " } }).state;
    expect(getOrgSyntaxForState(state).source).toBe(state.doc.toString());
    expect(hiddenSyntax(state)).toEqual(["[[./target.org][", "]]"]);
    const link = state.doc.toString().indexOf("[[");
    const syntax = getOrgSyntaxForState(state);
    state = state.update({ selection: EditorSelection.create([EditorSelection.cursor(0), EditorSelection.cursor(link + 3)]) }).state;
    expect(hiddenSyntax(state)).toEqual([]);
    expect(getOrgSyntaxForState(state)).toBe(syntax);
    state = state.update({ selection: { anchor: link - 2, head: label + 4 } }).state;
    expect(hiddenSyntax(state)).toEqual([]);
    state = state.update({ selection: { anchor: 0 } }).state;
    expect(hiddenSyntax(state)).toHaveLength(2);
  });

  it("shares current syntax with prose unwrapping without a later reflow", async () => {
    let state = createState(largeSource, true);
    const from = state.doc.toString().indexOf("continues here.");
    state = state.update({ changes: { from, insert: "#+TITLE: " } }).state;
    const syntax = getOrgSyntaxForState(state);
    expect(syntax.source).toBe(state.doc.toString());
    for (const set of decorations(state)) {
      set.between(from - 1, from + 1, (_start, _end, decoration) => {
        expect(decoration.spec.widget?.constructor.name).not.toBe("MarkdownSoftBreakWidget");
      });
    }
    const initial = decorations(state);
    await new Promise(resolve => setTimeout(resolve, 250));
    expect(getOrgSyntaxForState(state)).toBe(syntax);
    expect(decorations(state)).toEqual(initial);
  });

  it("preserves undo and redo with immediately current syntax", () => {
    let state = createState();
    const original = state.doc.toString();
    state = state.update({ changes: { from: 0, insert: "Inserted\n" }, userEvent: "input.type" }).state;
    const target = {
      get state() { return state; },
      dispatch(transaction: Parameters<EditorView["update"]>[0][number]) { state = transaction.state; },
    };
    expect(undo(target)).toBe(true);
    expect(state.doc.toString()).toBe(original);
    expect(hiddenSyntax(state)).toHaveLength(2);
    expect(redo(target)).toBe(true);
    expect(state.doc.toString()).toBe("Inserted\n" + original);
    expect(hiddenSyntax(state)).toHaveLength(2);
  });

  it("handles whole-buffer replacement and deletion", () => {
    let state = createState();
    state = state.update({ changes: { from: 0, to: state.doc.length, insert: "* TODO New\n[[./new.org][New]]" } }).state;
    expect(getOrgSyntaxForState(state).source).toBe(state.doc.toString());
    expect(state.field(nv3OrgParseStateField).headings[0]?.title).toBe("New");
    expect(hiddenSyntax(state)).toEqual(["[[./new.org][", "]]"]);
    state = state.update({ changes: { from: 0, to: state.doc.length } }).state;
    expect(state.doc.length).toBe(0);
    expect(hiddenSyntax(state)).toEqual([]);
  });
});
