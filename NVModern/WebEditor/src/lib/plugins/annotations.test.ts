import { describe, expect, it } from "bun:test";
import { EditorState, type TransactionSpec } from "@codemirror/state";
import { Decoration, EditorView } from "@codemirror/view";
import { nv3AnnotationComposerRange } from "./annotationComposer.ts";
import {
  addNv3AnnotationAt,
  addNv3Annotations,
  answerNv3Annotation,
  editNv3AnnotationNote,
  nv3AnnotationsChanged,
  createNv3AnnotationsExtension,
  findNv3AnnotationAnchor,
  listNv3Annotations,
  removeNv3Annotations,
  revealNv3Annotation,
  type Nv3AnnotationTarget,
} from "./annotations.ts";

interface TestTarget extends Nv3AnnotationTarget {
  state: EditorState;
  destroy(): void;
}

function createView(doc: string): TestTarget {
  const target: TestTarget = {
    state: EditorState.create({ doc, extensions: [createNv3AnnotationsExtension()] }),
    dispatch(spec: TransactionSpec) {
      target.state = target.state.update(spec).state;
    },
    destroy() {},
  };
  return target;
}

/** Mark classes and widget count currently decorating the document. */
function decorations(state: EditorState): { marks: Array<{ text: string; className: string }>; widgets: number } {
  const marks: Array<{ text: string; className: string }> = [];
  let widgets = 0;
  for (const source of state.facet(EditorView.decorations)) {
    if (typeof source === "function") continue;
    source.between(0, state.doc.length, (from, to, value: Decoration) => {
      if (from === to) widgets += 1;
      else marks.push({ text: state.doc.sliceString(from, to), className: String(value.spec.class ?? "") });
    });
  }
  return { marks, widgets };
}

describe("findNv3AnnotationAnchor", () => {
  it("finds an exact quote", () => {
    const text = "Alpha beta gamma.";
    expect(findNv3AnnotationAnchor(text, { quote: "beta" })).toEqual({ from: 6, to: 10, candidates: 1 });
  });

  it("tolerates whitespace and line-wrap differences", () => {
    const text = "The quick brown\n  fox jumps over the lazy dog.";
    const match = findNv3AnnotationAnchor(text, { quote: "brown fox jumps" });
    expect(match).not.toBeNull();
    expect(text.slice(match!.from, match!.to)).toBe("brown\n  fox jumps");
  });

  it("uses occurrence, then prefix/suffix to pick among repeats", () => {
    const text = "one cat. two cat. three cat.";
    expect(findNv3AnnotationAnchor(text, { quote: "cat", occurrence: 2 })).toMatchObject({ from: 13, candidates: 3 });
    expect(findNv3AnnotationAnchor(text, { quote: "cat", prefix: "three " })).toMatchObject({ from: 24 });
    expect(findNv3AnnotationAnchor(text, { quote: "cat", suffix: ". two" })).toMatchObject({ from: 4 });
  });

  it("returns null for missing or empty quotes", () => {
    expect(findNv3AnnotationAnchor("abc", { quote: "xyz" })).toBeNull();
    expect(findNv3AnnotationAnchor("abc", { quote: "  " })).toBeNull();
  });
});

describe("annotation commands", () => {
  it("adds numbered annotations without changing the document", () => {
    const doc = "# Title\n\nFirst idea here.\n\nSecond idea there.\n";
    const view = createView(doc);
    const results = addNv3Annotations(view, [{ quote: "First idea" }, { quote: "Second idea", style: "underline" }]);

    expect(results.map((result) => [result.label, result.status, result.line])).toEqual([
      ["1", "anchored", 3],
      ["2", "anchored", 5],
    ]);
    expect(view.state.doc.toString()).toBe(doc);
    const rendered = decorations(view.state);
    expect(rendered.widgets).toBe(2);
    expect(rendered.marks.find((mark) => mark.className.includes("nv3-annotation-underline"))?.text).toBe("Second idea");
    view.destroy();
  });

  it("reports missing and ambiguous quotes", () => {
    const view = createView("echo echo");
    const results = addNv3Annotations(view, [{ quote: "nope" }, { quote: "echo" }]);
    expect(results[0]).toMatchObject({ label: "1", status: "notFound" });
    expect(results[1]).toMatchObject({ label: "2", status: "ambiguous", candidates: 2 });
    view.destroy();
  });

  it("follows edits around an annotation and re-anchors after replacement", () => {
    const view = createView("keep this phrase");
    addNv3Annotations(view, [{ quote: "this phrase" }]);
    view.dispatch({ changes: { from: 0, insert: "Please " } });
    expect(listNv3Annotations(view.state)[0]).toMatchObject({ text: "this phrase", detached: false });

    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: "reloaded: this phrase again" } });
    expect(listNv3Annotations(view.state)[0]).toMatchObject({ text: "this phrase", detached: false });

    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: "gone" } });
    expect(listNv3Annotations(view.state)[0]).toMatchObject({ text: null, detached: true });
    view.destroy();
  });

  it("replaces by author and removes by label", () => {
    const view = createView("a b c d");
    addNv3Annotations(view, [{ quote: "a" }, { quote: "b" }]);
    addNv3Annotations(view, [{ quote: "c", author: "user" }]);
    addNv3Annotations(view, [{ quote: "d" }], { replace: "agent" });

    expect(listNv3Annotations(view.state).map((item) => [item.label, item.author])).toEqual([
      ["Q1", "user"],
      ["1", "agent"],
    ]);
    expect(removeNv3Annotations(view, { labels: ["Q1"] })).toBe(1);
    expect(removeNv3Annotations(view)).toBe(1);
    expect(listNv3Annotations(view.state)).toEqual([]);
    view.destroy();
  });

  it("accepts numeric labels", () => {
    const view = createView("alpha beta");
    const results = addNv3Annotations(view, [{ quote: "beta", label: 7 as unknown as string }]);
    expect(results[0]).toMatchObject({ label: "7", status: "anchored" });
    expect(revealNv3Annotation(view, "7")).toBe(true);
  });

  it("reveals an annotation by label", () => {
    const view = createView("alpha beta");
    addNv3Annotations(view, [{ quote: "beta", label: "B" }]);
    expect(revealNv3Annotation(view, "B")).toBe(true);
    expect(decorations(view.state).marks.find((mark) => mark.className.includes("nv3-annotation-focused"))?.text).toBe("beta");
    expect(revealNv3Annotation(view, "missing")).toBe(false);
    view.destroy();
  });

  it("annotates the user's exact range with Q labels and re-finds it by context", () => {
    const view = createView("cat one. cat two.");
    const result = addNv3AnnotationAt(view, 9, 12, { author: "user", note: "Which cat?" });
    expect(result).toMatchObject({ label: "Q1", status: "anchored" });
    const [snapshot] = listNv3Annotations(view.state);
    expect(snapshot).toMatchObject({ author: "user", note: "Which cat?", text: "cat", line: 1 });

    // Replacing the document re-anchors by quote plus context, not the first "cat".
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: "cat one. cat two." } });
    const marked = listNv3Annotations(view.state)[0];
    expect(marked?.text).toBe("cat");
    view.destroy();
  });

  it("answers a question and reports the change", () => {
    const view = createView("why this?");
    addNv3AnnotationAt(view, 0, 3, { author: "user", note: "Why?" });
    const before = view.state;
    expect(answerNv3Annotation(view, "Q1", "Because **reasons**.", "Claude")).toBe(true);
    expect(nv3AnnotationsChanged(before, view.state)).toBe(true);
    expect(listNv3Annotations(view.state)[0]).toMatchObject({ answer: "Because **reasons**.", answeredBy: "Claude" });

    answerNv3Annotation(view, "Q1", "");
    expect(listNv3Annotations(view.state)[0]?.answer).toBeUndefined();
    expect(answerNv3Annotation(view, "Q9", "x")).toBe(false);
    view.destroy();
  });

  it("composes over the selection, else the trimmed caret line", () => {
    const state = EditorState.create({ doc: "  indented line  \nnext", selection: { anchor: 4 } });
    expect(nv3AnnotationComposerRange(state)).toEqual({ from: 2, to: 15, caret: 4 });
    const selected = EditorState.create({ doc: "abc def", selection: { anchor: 4, head: 7 } });
    expect(nv3AnnotationComposerRange(selected)).toEqual({ from: 4, to: 7 });
  });

  it("edits a question and marks an existing answer stale until re-answered", () => {
    const view = createView("some passage");
    addNv3AnnotationAt(view, 0, 4, { author: "user", note: "First wording?" });
    answerNv3Annotation(view, "Q1", "An answer.", "Claude");
    expect(editNv3AnnotationNote(view, "Q1", "  Second wording?  ")).toBe(true);
    expect(listNv3Annotations(view.state)[0]).toMatchObject({ note: "Second wording?", answer: "An answer.", answerStale: true });

    answerNv3Annotation(view, "Q1", "A new answer.");
    expect(listNv3Annotations(view.state)[0]?.answerStale).toBeUndefined();

    editNv3AnnotationNote(view, "Q1", "");
    expect(listNv3Annotations(view.state)[0]?.note).toBeUndefined();
    expect(editNv3AnnotationNote(view, "Q9", "x")).toBe(false);
  });

  it("starts marks after list, task, quote and heading markers", () => {
    const view = createView("1. **First item** text\n- [ ] task here\n> quoted line\n## Heading");
    addNv3AnnotationAt(view, 0, 22, { author: "user", note: "Why?" });
    addNv3Annotations(view, [{ quote: "- [ ] task here" }, { quote: "> quoted line" }, { quote: "## Heading" }]);
    expect(listNv3Annotations(view.state).map((item) => item.text)).toEqual([
      "**First item** text",
      "task here",
      "quoted line",
      "Heading",
    ]);
    expect(listNv3Annotations(view.state)[0]?.quote).toBe("**First item** text");
  });

  it("keeps unanchored annotations detached on restore and re-attaches them", () => {
    const view = createView("text changed while closed");
    const results = addNv3Annotations(view, [{ quote: "original passage", author: "user", note: "Q?" }], {
      replace: true,
      keepUnanchored: true,
    });
    expect(results[0]?.status).toBe("notFound");
    expect(listNv3Annotations(view.state)[0]).toMatchObject({ label: "Q1", note: "Q?", detached: true });

    view.dispatch({ changes: { from: view.state.doc.length, insert: " original passage" } });
    expect(listNv3Annotations(view.state)[0]).toMatchObject({ detached: false, text: "original passage" });
  });
});
