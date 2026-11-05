import { insertNewlineContinueMarkup } from "@codemirror/lang-markdown";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { EditorState, type StateCommand } from "@codemirror/state";
import { describe, expect, it } from "bun:test";
import {
  createNv3MarkdownExtensions,
  indentMarkdownListItem,
  outdentMarkdownListItem,
} from "../index.ts";

function createState(doc: string, anchor = 0): EditorState {
  return EditorState.create({
    doc,
    selection: { anchor },
    extensions: createNv3MarkdownExtensions(),
  });
}

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

describe("markdown list editing", () => {
  it("treats four-space indents as regular markdown content while preserving fenced code", () => {
    const state = createState(["    not a code block", "", "```ts", "const x = 1", "```"].join("\n"));

    ensureSyntaxTree(state, state.doc.length, 150);

    let hasIndentedCodeBlock = false;
    let hasFencedCode = false;
    syntaxTree(state).iterate({
      enter(node) {
        if (node.name === "CodeBlock") hasIndentedCodeBlock = true;
        if (node.name === "FencedCode") hasFencedCode = true;
      },
    });

    expect(hasIndentedCodeBlock).toBe(false);
    expect(hasFencedCode).toBe(true);
  });

  it("does not parse bare bracket text as markdown links or images", () => {
    const state = createState(["[!note] plain", "![alt](image.png)", "[label](https://example.com)"].join("\n"));

    ensureSyntaxTree(state, state.doc.length, 150);

    let hasLinkNode = false;
    let hasImageNode = false;
    syntaxTree(state).iterate({
      enter(node) {
        if (node.name === "Link") hasLinkNode = true;
        if (node.name === "Image") hasImageNode = true;
      },
    });

    expect(hasLinkNode).toBe(false);
    expect(hasImageNode).toBe(false);
  });

  it("renumbers ordered lists after pressing Enter", () => {
    const initial = ["1. One", "2. Two", "3. Three"].join("\n");
    const state = createState(initial, initial.indexOf("Two") + "Two".length);

    const result = applyCommand(state, insertNewlineContinueMarkup);

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe(["1. One", "2. Two", "3. ", "4. Three"].join("\n"));
  });

  it("renumbers ordered lists after deleting an item", () => {
    const state = createState(["1. One", "2. Two", "3. Three"].join("\n"));
    const deleteFrom = state.doc.line(2).from;
    const deleteTo = state.doc.line(3).from;

    const transaction = state.update({
      changes: { from: deleteFrom, to: deleteTo },
    });

    expect(transaction.state.doc.toString()).toBe(["1. One", "2. Three"].join("\n"));
  });

  it("renumbers ordered task lists while preserving task markers", () => {
    const state = createState(["1. [ ] One", "2. [X] Two", "3. [ ] Three"].join("\n"));
    const deleteFrom = state.doc.line(2).from;
    const deleteTo = state.doc.line(3).from;

    const transaction = state.update({
      changes: { from: deleteFrom, to: deleteTo },
    });

    expect(transaction.state.doc.toString()).toBe(["1. [ ] One", "2. [ ] Three"].join("\n"));
  });

  it("indents an ordered list item under its previous sibling and restarts numbering", () => {
    const doc = ["1. One", "2. Two", "3. Three"].join("\n");
    const state = createState(doc, doc.indexOf("Three"));

    const result = applyCommand(state, indentMarkdownListItem);

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe(["1. One", "2. Two", "    1. Three"].join("\n"));
  });

  it("renumbers existing nested ordered siblings when indenting into them", () => {
    const doc = ["1. One", "2. Two", "    1. Child", "3. Three"].join("\n");
    const state = createState(doc, doc.indexOf("Three"));

    const result = applyCommand(state, indentMarkdownListItem);

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe(
      ["1. One", "2. Two", "    1. Child", "    2. Three"].join("\n"),
    );
  });

  it("outdents a nested ordered list item and renumbers the parent list", () => {
    const doc = ["1. One", "2. Two", "    1. Three", "3. Four"].join("\n");
    const state = createState(doc, doc.indexOf("Three"));

    const result = applyCommand(state, outdentMarkdownListItem);

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe(["1. One", "2. Two", "3. Three", "4. Four"].join("\n"));
  });

  it("indents bullet list items with four spaces", () => {
    const doc = ["- One", "- Two", "- Three"].join("\n");
    const state = createState(doc, doc.indexOf("Three"));

    const result = applyCommand(state, indentMarkdownListItem);

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe(["- One", "- Two", "    - Three"].join("\n"));
  });

  it("indents ordered lists inside blockquotes after the quote prefix", () => {
    const doc = ["> 1. One", "> 2. Two", "> 3. Three"].join("\n");
    const state = createState(doc, doc.indexOf("Three"));

    const result = applyCommand(state, indentMarkdownListItem);

    expect(result.applied).toBe(true);
    expect(result.state.doc.toString()).toBe(
      ["> 1. One", "> 2. Two", ">     1. Three"].join("\n"),
    );
  });
});
