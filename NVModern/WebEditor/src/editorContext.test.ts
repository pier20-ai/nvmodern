import { EditorSelection, EditorState } from "@codemirror/state";
import { describe, expect, it } from "bun:test";
import {
  queryEditorContextFromState,
  selectionSnapshot,
  sliceAroundCursor,
  sliceLineRange,
} from "./editorContext.ts";

const DOC = [
  "# Inbox",
  "alpha",
  "beta",
  "gamma",
  "## Tasks",
  "delta",
  "epsilon",
].join("\n");

function createState(doc = DOC, cursor = 0): EditorState {
  return EditorState.create({
    doc,
    selection: EditorSelection.cursor(cursor),
  });
}

describe("editorContext", () => {
  it("slices a line range and reports truncation", () => {
    const state = createState();
    const full = sliceLineRange(state, 2, 4, 4000);
    expect(full).toEqual({
      startLine: 2,
      endLine: 4,
      text: "alpha\nbeta\ngamma",
      truncated: false,
    });

    const truncated = sliceLineRange(state, 1, 7, 8);
    expect(truncated.truncated).toBe(true);
    expect(truncated.text).toBe("# Inbox\n");
    expect(truncated.startLine).toBe(1);
    expect(truncated.endLine).toBe(7);
  });

  it("captures a ranged selection with 1-based lines", () => {
    const from = DOC.indexOf("beta");
    const to = from + "beta\ngamma".length;
    const state = EditorState.create({
      doc: DOC,
      selection: EditorSelection.range(from, to),
    });
    expect(selectionSnapshot(state)).toEqual({
      text: "beta\ngamma",
      startLine: 3,
      endLine: 4,
      empty: false,
    });
  });

  it("slices content around the cursor", () => {
    const cursor = DOC.indexOf("gamma") + 2;
    const state = createState(DOC, cursor);
    const around = sliceAroundCursor(state, { radiusLines: 1, maxChars: 4000 });
    expect(around.line).toBe(4);
    expect(around.column).toBe(3);
    expect(around.startLine).toBe(3);
    expect(around.endLine).toBe(5);
    expect(around.text).toBe("beta\ngamma\n## Tasks");
    expect(around.truncated).toBe(false);
  });

  it("omits slices the caller did not request", () => {
    const state = createState();
    const result = queryEditorContextFromState(state, {
      path: "Inbox.md",
      title: "Inbox",
      options: {
        includeSelection: true,
        includeViewport: false,
        includeCursor: false,
      },
      viewportStartLine: 2,
      viewportEndLine: 3,
    });
    expect(result.path).toBe("Inbox.md");
    expect(result.title).toBe("Inbox");
    expect(result.selection?.empty).toBe(true);
    expect(result.viewport).toBeNull();
    expect(result.cursor).toBeNull();
  });
});
