import { EditorSelection, EditorState, type StateCommand } from "@codemirror/state";
import { redo, undo } from "@codemirror/commands";
import { deleteMarkupBackward, insertNewlineContinueMarkupCommand } from "@codemirror/lang-markdown";
import { describe, expect, it } from "bun:test";
import { createNv3EditorState, indentMarkdownListItem, outdentMarkdownListItem } from "../index.ts";
import { getNv3OrgParseResult } from "./orgIndex.ts";
import { continueOrgList, deleteOrgListItemBackward, indentOrgListItem, outdentOrgListItem } from "./orgListEditing.ts";

function createState(doc: string, at: string | number = 0, fileType: "org" | "markdown" = "org"): EditorState {
  const anchor = typeof at === "number" ? at : doc.indexOf(at);
  return createNv3EditorState({ doc, fileType, selection: { anchor } });
}

function apply(state: EditorState, command: StateCommand) {
  let next = state;
  const handled = command({ state, dispatch: transaction => { next = transaction.state; } });
  return { handled, state: next, text: next.doc.toString() };
}

describe("Org list editing", () => {
  it("indents a middle item, restarts the child list, and closes the gap in its outer list", () => {
    const doc = "1. One\n2. Two\n3. Three";
    const result = apply(createState(doc, "Two"), indentOrgListItem);
    expect(result.handled).toBe(true);
    expect(result.text).toBe("1. One\n  1. Two\n2. Three");
    expect(result.state.doc.sliceString(result.state.selection.main.head, result.state.selection.main.head + 3)).toBe("Two");
  });

  it("appends to existing nested siblings instead of retaining the outer number", () => {
    const doc = "1. One\n2. Two\n  1. Child\n3. Three";
    expect(apply(createState(doc, "Three"), indentOrgListItem).text).toBe("1. One\n2. Two\n  1. Child\n  2. Three");
  });

  it("moves the innermost item rather than its containing parent", () => {
    const doc = "1. Parent\n  1. First\n  2. Second\n2. Next";
    expect(apply(createState(doc, "Second"), indentOrgListItem).text).toBe("1. Parent\n  1. First\n    1. Second\n2. Next");
  });

  it("outdents a nested item and renumbers both list levels", () => {
    const doc = "1. Parent\n  1. First\n  2. Second\n  3. Third\n2. Next";
    expect(apply(createState(doc, "Second"), outdentOrgListItem).text).toBe("1. Parent\n  1. First\n2. Second\n  1. Third\n3. Next");
  });

  it("moves continuation lines and descendant items together", () => {
    const doc = "1. One\n2. Two\n   continuation\n  - Child\n3. Three";
    expect(apply(createState(doc, "Two"), indentOrgListItem).text).toBe("1. One\n  1. Two\n     continuation\n    - Child\n2. Three");
  });

  it("respects existing nesting widths when indenting and outdenting", () => {
    const doc = "1. Parent\n   1. Child\n2. Next";
    expect(apply(createState(doc, "Next"), indentOrgListItem).text).toBe("1. Parent\n   1. Child\n   2. Next");
    expect(apply(createState(doc, "Child"), outdentOrgListItem).text).toBe("1. Parent\n2. Child\n3. Next");
    const tabs = "1. Parent\n\t1. Child\n2. Next";
    expect(apply(createState(tabs, "Next"), indentOrgListItem).text).toBe("1. Parent\n\t1. Child\n\t2. Next");
    const empty = "1. Parent\n  1.\n2. Next";
    expect(apply(createState(empty, "Next"), indentOrgListItem).text).toBe("1. Parent\n  1.\n  2. Next");
  });

  it("does not indent the first sibling under a nonexistent previous item", () => {
    const state = createState("1. One\n2. Two", "One");
    expect(apply(state, indentOrgListItem).handled).toBe(false);
    expect(apply(state, outdentOrgListItem).handled).toBe(false);
  });

  it("handles multiple cursors without moving a selected descendant twice", () => {
    const doc = "1. One\n2. Two\n  - Child\n3. Three";
    let state = createState(doc);
    state = state.update({ selection: EditorSelection.create([EditorSelection.cursor(doc.indexOf("Two")), EditorSelection.cursor(doc.indexOf("Child")), EditorSelection.cursor(doc.indexOf("Three"))]) }).state;
    expect(apply(state, indentOrgListItem).text).toBe("1. One\n  1. Two\n    - Child\n  2. Three");
  });

  it("continues the final ordered item with N+1 and places the caret after its marker", () => {
    const doc = "1. One\n2. Two\n3. Three";
    const result = apply(createState(doc, doc.length), continueOrgList);
    expect(result.text).toBe(doc + "\n4. ");
    expect(result.state.selection.main.head).toBe(result.state.doc.length);
    expect(getNv3OrgParseResult(result.state)?.listItems).toHaveLength(4);
  });

  it("splits an item and renumbers subsequent siblings", () => {
    const doc = "1. One\n2. Two\n3. Three";
    expect(apply(createState(doc, doc.indexOf("Two") + 1), continueOrgList).text).toBe("1. One\n2. T\n3. wo\n4. Three");
  });

  it("splits at the beginning of the body without deleting the original marker's space", () => {
    const doc = "1. One\n2. Two\n3. Three";
    expect(apply(createState(doc, "Two"), continueOrgList).text).toBe("1. One\n2. \n3. Two\n4. Three");
  });

  it("continues across the 9-to-10 marker width change with the correct caret", () => {
    const doc = Array.from({ length: 9 }, (_, index) => `${index + 1}. Item`).join("\n");
    const result = apply(createState(doc, doc.length), continueOrgList);
    expect(result.text).toBe(doc + "\n10. ");
    expect(result.state.selection.main.head).toBe(result.state.doc.length);
  });

  it("continues ordered checklists with a fresh unchecked state", () => {
    const doc = "1) [X] One\n2) [X] Two";
    expect(apply(createState(doc, doc.length), continueOrgList).text).toBe(doc + "\n3) [ ] ");
  });

  it("supports alphabetic markers and renumbers the source list", () => {
    const doc = "a) One\nb) Two\nc) Three";
    expect(apply(createState(doc, "Two"), indentOrgListItem).text).toBe("a) One\n  a) Two\nb) Three");
    expect(apply(createState(doc, doc.length), continueOrgList).text).toBe(doc + "\nd) ");
  });

  it("honors explicit Org counter resets while continuing their numbering", () => {
    const doc = "1. One\n5. [@5] Two\n6. Three";
    expect(apply(createState(doc, doc.length), continueOrgList).text).toBe(doc + "\n7. ");
    const named = "1. One\n5. [@start:5] Two";
    expect(apply(createState(named, named.length), continueOrgList).text).toBe(named + "\n6. ");
  });

  it("exits an empty outer item and outdents an empty nested item one level", () => {
    const outer = "1. One\n2. Two\n3. ";
    expect(apply(createState(outer, outer.length), continueOrgList).text).toBe("1. One\n2. Two\n");
    const nested = "1. One\n  1. Child\n  2. ";
    const separated = apply(createState(nested, nested.length), continueOrgList);
    expect(separated.text).toBe("1. One\n  1. Child\n\n  2. ");
    expect(apply(separated.state, continueOrgList).text).toBe("1. One\n  1. Child\n\n2. ");
  });

  it("preserves blank separators when continuing a loose list", () => {
    const doc = "1. One\n\n2. Two";
    expect(apply(createState(doc, doc.length), continueOrgList).text).toBe(doc + "\n\n3. ");
    const empty = "1. One\n2. ";
    const first = apply(createState(empty, empty.length), continueOrgList);
    expect(first.text).toBe("1. One\n\n2. ");
    expect(apply(first.state, continueOrgList).text).toBe("1. One\n\n");
  });

  it("continues a physical continuation line without inserting another list marker", () => {
    const doc = "1. One\n   continued";
    expect(apply(createState(doc, doc.length), continueOrgList).text).toBe(doc + "\n   ");
  });

  it("renumbers lists after deleting an item directly", () => {
    const doc = "1. One\n2. Two\n3. Three";
    const state = createState(doc);
    expect(state.update({ changes: { from: state.doc.line(2).from, to: state.doc.line(3).from } }).state.doc.toString()).toBe("1. One\n2. Three");
  });

  it("preserves correctly numbered leading-zero markers, like Markdown", () => {
    const doc = "01. One\n02. Two";
    expect(apply(createState(doc, doc.length), continueOrgList).text).toBe(doc + "\n3. ");
  });

  it("handles empty-item Backspace without deleting any body text", () => {
    const doc = "1. One\n2. ";
    const result = apply(createState(doc, doc.length), deleteOrgListItemBackward);
    expect(result.handled).toBe(true);
    expect(result.text.trimEnd()).toBe("1. One");
  });

  it("turns the first nested marker into a continuation of its parent", () => {
    const doc = "1. One\n  1. Child";
    expect(apply(createState(doc, "Child"), deleteOrgListItemBackward).text).toBe("1. One\n   Child");
  });

  it("leaves unrelated lists and source blocks unchanged", () => {
    const doc = "1. One\n2. Two\n\nParagraph\n\n8. Untouched\n12. Untouched\n\n#+begin_src text\n7. Literal\n9. Literal\n#+end_src";
    const result = apply(createState(doc, "Two"), indentOrgListItem);
    expect(result.text).toContain("8. Untouched\n12. Untouched");
    expect(result.text).toContain("7. Literal\n9. Literal");
    const code = createState(doc, doc.indexOf("7. Literal") + 10);
    expect(apply(code, continueOrgList).handled).toBe(false);
    expect(apply(code, indentOrgListItem).handled).toBe(false);
  });

  it("undoes and redoes indentation and renumbering as one edit", () => {
    const doc = "1. One\n2. Two\n3. Three";
    const changed = apply(createState(doc, "Two"), indentOrgListItem).state;
    const reverted = apply(changed, undo);
    expect(reverted.text).toBe(doc);
    expect(apply(reverted.state, redo).text).toBe("1. One\n  1. Two\n2. Three");
    const originalNumbers = "10. One\n30. Two";
    const normalized = apply(createState(originalNumbers, "Two"), indentOrgListItem);
    expect(normalized.text).toBe("1. One\n  1. Two");
    expect(apply(normalized.state, undo).text).toBe(originalNumbers);
  });

  it("keeps a read-only buffer unchanged", () => {
    const state = createNv3EditorState({ doc: "1. One\n2. Two", fileType: "org", selection: { anchor: 13 }, extraExtensions: [EditorState.readOnly.of(true)] });
    for (const command of [continueOrgList, indentOrgListItem, outdentOrgListItem, deleteOrgListItemBackward]) expect(apply(state, command).handled).toBe(false);
  });
});

describe("Org and Markdown list parity", () => {
  const cases: Array<{ doc: string; at: string | number; org: StateCommand; markdown: StateCommand }> = [
    { doc: "1. One\n2. Two\n3. Three", at: "Two", org: indentOrgListItem, markdown: indentMarkdownListItem },
    { doc: "1. One\n2. Two\n3. Three", at: "Three", org: indentOrgListItem, markdown: indentMarkdownListItem },
    { doc: "1. One\n2. Two\n  1. Child\n3. Three", at: "Three", org: indentOrgListItem, markdown: indentMarkdownListItem },
    { doc: "1. One\n2. Two\n  1. Child\n3. Three", at: "Child", org: outdentOrgListItem, markdown: outdentMarkdownListItem },
    { doc: "- One\n- Two\n- Three", at: "Two", org: indentOrgListItem, markdown: indentMarkdownListItem },
    { doc: "1. One\n2. Two\n3. Three", at: 22, org: continueOrgList, markdown: insertNewlineContinueMarkupCommand({ nonTightLists: true }) },
    { doc: "1. One\n2. ", at: 10, org: continueOrgList, markdown: insertNewlineContinueMarkupCommand({ nonTightLists: true }) },
    { doc: "1. One\n\n2. Two", at: 14, org: continueOrgList, markdown: insertNewlineContinueMarkupCommand({ nonTightLists: true }) },
    { doc: "1. One\n2. Two", at: "Two", org: deleteOrgListItemBackward, markdown: deleteMarkupBackward },
  ];
  for (const [index, example] of cases.entries()) {
    it(`matches Markdown structural behavior (${index + 1})`, () => {
      const mdDoc = example.doc.replace(/^  /gm, "    ");
      const org = apply(createState(example.doc, example.at), example.org);
      const md = apply(createState(mdDoc, example.at, "markdown"), example.markdown);
      expect(org.handled).toBe(md.handled);
      expect(org.text).toBe(md.text.replace(/^    /gm, "  "));
    });
  }
});
