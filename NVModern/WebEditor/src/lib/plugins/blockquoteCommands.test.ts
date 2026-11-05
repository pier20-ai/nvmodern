import { EditorSelection, EditorState, type StateCommand } from "@codemirror/state";
import { describe, expect, it } from "bun:test";
import {
  prefixMarkdownSelectionLines,
  quoteMarkdownSelection,
  unquoteMarkdownSelection,
} from "./blockquoteCommands.ts";

function applyCommand(state: EditorState, command: StateCommand): { applied: boolean; state: EditorState } {
  let nextState = state;
  const applied = command({
    state,
    dispatch(transaction) {
      nextState = transaction.state;
    },
  });

  return { applied, state: nextState };
}

describe("Markdown blockquote selection commands", () => {
  it("quotes every selected line, including blank lines", () => {
    const doc = "alpha\n\nbeta";
    const state = EditorState.create({ doc, selection: { anchor: 1, head: doc.length } });

    const result = applyCommand(state, quoteMarkdownSelection);

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe("> alpha\n> \n> beta");
  });

  it("unquotes one level and leaves unquoted selected lines unchanged", () => {
    const doc = "> alpha\nbeta\n>gamma";
    const state = EditorState.create({ doc, selection: { anchor: 0, head: doc.length } });

    const result = applyCommand(state, unquoteMarkdownSelection);

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe("alpha\nbeta\ngamma");
  });

  it("does nothing when the selection is empty", () => {
    const state = EditorState.create({ doc: "alpha", selection: { anchor: 2 } });

    const quoted = applyCommand(state, quoteMarkdownSelection);
    const unquoted = applyCommand(state, unquoteMarkdownSelection);

    expect(quoted.applied).toBe(false);
    expect(unquoted.applied).toBe(false);
    expect(quoted.state.doc.toString()).toBe("alpha");
  });

  it("prefixes the first and continuation lines atomically", () => {
    const doc = "alpha\nbeta\ngamma";
    const state = EditorState.create({ doc, selection: { anchor: 1, head: doc.length } });

    const result = applyCommand(state, (target) => prefixMarkdownSelectionLines(target, {
      firstPrefix: "> [!user] ",
      continuationPrefix: "> ",
    }));

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe("> [!user] alpha\n> beta\n> gamma");
  });

  it("starts each disjoint selection with the first prefix", () => {
    const doc = "alpha\nbeta\ngamma";
    const state = EditorState.create({
      doc,
      selection: EditorSelection.create([
        EditorSelection.range(0, 5),
        EditorSelection.range(11, doc.length),
      ]),
      extensions: [EditorState.allowMultipleSelections.of(true)],
    });

    const result = applyCommand(state, (target) => prefixMarkdownSelectionLines(target, {
      firstPrefix: "first: ",
      continuationPrefix: "next: ",
    }));

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe("first: alpha\nbeta\nfirst: gamma");
  });
});
