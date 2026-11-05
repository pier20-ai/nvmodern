import { describe, expect, it } from "bun:test";
import { EditorState, type Transaction, type TransactionSpec } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import { createCalcHelpProvider, calcHelpExampleTemplate } from "./help.ts";
import { calcCatalog, calcPresenterAliases } from "./catalog.ts";
import { createMarkdownCalcExtension } from "../plugins/calc.ts";
import { openCalcExplorer, applyCalcHelpInsertion, dismissCalcHelp } from "../plugins/calcDiscovery.ts";
import type { HelpOpenRequest } from "../help/model.ts";

function hosted(source: string, readOnly = false) {
  let request: HelpOpenRequest | undefined;
  const pos = source.indexOf("¦");
  let state = EditorState.create({
    doc: source.replace("¦", ""), selection: { anchor: pos },
    extensions: [createMarkdownCalcExtension({ onHelpOpen: (value) => { request = value; } }), EditorState.readOnly.of(readOnly)],
  });
  const view = {
    get state() { return state; },
    dispatch(input: Transaction | TransactionSpec) {
      state = "state" in input ? input.state : state.update(input).state;
    },
    coordsAtPos: () => ({ left: 12, top: 15, bottom: 31, right: 13 }),
    focus() {},
  } as unknown as EditorView;
  return { view, open: () => { expect(openCalcExplorer(view)).toBe(true); return request!; } };
}
describe("hosted calc help", () => {
  it("exposes the complete catalog as portable content with unique topic and action IDs", () => {
    const provider = createCalcHelpProvider();
    expect(provider.topics.length).toBe(calcCatalog.length + calcPresenterAliases().length);
    expect(new Set(provider.topics.map((topic) => topic.id)).size).toBe(provider.topics.length);
    for (const topic of provider.topics) {
      expect(new Set(topic.insertions.map((action) => action.id)).size).toBe(topic.insertions.length);
      expect(topic.summary.length).toBeGreaterThan(0);
    }
    expect(JSON.parse(JSON.stringify(provider))).toEqual(provider);
  });
  it("hosts F1 without constructing a DOM panel and inserts mapped CodeMirror snippets", () => {
    const { view, open } = hosted("```calc\n2 + 3¦\n```");
    const request = open();
    expect(request).toMatchObject({ providerID: "calc", canInsert: true, allowsMultiline: true, anchor: { x: 12, y: 15, height: 16 } });
    view.dispatch({ changes: { from: 0, insert: "A heading\n" } });
    expect(applyCalcHelpInsertion(view, request.token, "sqrt(${1:9}) -> ")).toBe(true);
    expect(view.state.doc.toString()).toContain("2 + 3\nsqrt(9) -> ");
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe("9");
    expect(applyCalcHelpInsertion(view, request.token, "BAD")).toBe(false);
  });
  it("rejects stale sessions, read-only insertion, multiline inline examples, and removed calc contexts", () => {
    const { view, open } = hosted("{{ 2¦ }}");
    const first = open();
    const second = open();
    expect(applyCalcHelpInsertion(view, first.token, "BAD")).toBe(false);
    expect(dismissCalcHelp(view, first.token)).toBe(false);
    expect(applyCalcHelpInsertion(view, second.token, "1\n2")).toBe(false);
    expect(applyCalcHelpInsertion(view, second.token, "3")).toBe(true);
    const locked = hosted("```calc\n¦\n```", true);
    const lockedRequest = locked.open();
    expect(lockedRequest.canInsert).toBe(false);
    expect(applyCalcHelpInsertion(locked.view, lockedRequest.token, "BAD")).toBe(false);
    const removed = hosted("```calc\n¦\n```");
    const removedRequest = removed.open();
    removed.view.dispatch({ changes: { from: 0, to: removed.view.state.doc.length, insert: "plain text" } });
    expect(applyCalcHelpInsertion(removed.view, removedRequest.token, "BAD")).toBe(false);
  });
  it("escapes example braces while keeping template fields editable", () => {
    const template = calcHelpExampleTemplate({ source: '"value { braces }"', expected: "value { braces }" });
    const { view, open } = hosted("```calc\n¦\n```");
    expect(applyCalcHelpInsertion(view, open().token, template)).toBe(true);
    expect(view.state.doc.toString()).not.toContain("\\{");
  });
});
