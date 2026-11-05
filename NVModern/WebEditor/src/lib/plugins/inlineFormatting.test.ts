import { EditorSelection, EditorState, type StateCommand } from "@codemirror/state";
import { describe, expect, it } from "bun:test";
import {
  createNv3MarkdownExtensions,
  toggleMarkdownBold,
  toggleMarkdownItalic,
} from "../index.ts";

// The config parameter is itself optional, so it has to be unwrapped before
// indexing into it.
type SelectionSpec = NonNullable<NonNullable<Parameters<typeof EditorState.create>[0]>["selection"]>;

function createState(doc: string, selection: SelectionSpec): EditorState {
  return EditorState.create({
    doc,
    selection,
    extensions: createNv3MarkdownExtensions(),
  });
}

function applyCommand(state: EditorState, command: StateCommand) {
  let nextState = state;
  const applied = command({
    state,
    dispatch(transaction) {
      nextState = transaction.state;
    },
  });

  return { applied, state: nextState };
}

describe("inline formatting", () => {
  it("wraps a markdown selection in bold markers", () => {
    const state = createState("hello world", { anchor: 6, head: 11 });

    const result = applyCommand(state, toggleMarkdownBold);

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe("hello **world**");
    expect(result.state.selection.main.from).toBe(8);
    expect(result.state.selection.main.to).toBe(13);
    expect(result.state.doc.sliceString(result.state.selection.main.from, result.state.selection.main.to)).toBe(
      "world",
    );
  });

  it("unwraps a markdown bold selection when markers already surround it", () => {
    const state = createState("hello **world**", { anchor: 8, head: 13 });

    const result = applyCommand(state, toggleMarkdownBold);

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe("hello world");
    expect(result.state.selection.main.from).toBe(6);
    expect(result.state.selection.main.to).toBe(11);
    expect(result.state.doc.sliceString(result.state.selection.main.from, result.state.selection.main.to)).toBe(
      "world",
    );
  });

  it("wraps multiple selections in italic markers", () => {
    // Must be a real `EditorSelection`: `EditorState.create` only reads
    // `anchor`/`head` off a plain object, so a `{ranges: [...]}` literal
    // collapsed to one broken range and never exercised multiple selections.
    const state = createState(
      "alpha beta",
      EditorSelection.create([EditorSelection.range(0, 5), EditorSelection.range(6, 10)]),
    );

    const result = applyCommand(state, toggleMarkdownItalic);

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe("*alpha* *beta*");
    // In "*alpha* *beta*" the second word starts at 9: index 7 is the space and
    // index 8 is its opening marker.
    expect(result.state.selection.ranges.map((range) => [range.from, range.to])).toEqual([
      [1, 6],
      [9, 13],
    ]);
  });

  it("does nothing for an empty selection", () => {
    const state = createState("hello", { anchor: 2 });

    const result = applyCommand(state, toggleMarkdownBold);

    expect(result.applied).toBe(false);
    expect(result.state.doc.toString()).toBe("hello");
  });
});
