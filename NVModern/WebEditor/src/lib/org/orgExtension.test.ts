import { EditorSelection, EditorState, Text } from "@codemirror/state";
import { EditorView, type DecorationSet } from "@codemirror/view";
import { describe, expect, it } from "bun:test";
import { buildOrgModeDecorations, createOrgModeExtension, doneStatesFor } from "./orgExtension.ts";

function linkPresentation(doc: Text, decorations: DecorationSet) {
  const hidden: Array<{ from: number; to: number }> = [];
  const links: Array<{ text: string; href: string }> = [];
  decorations.between(0, doc.length, (from, to, decoration) => {
    if (decoration.spec.class === "nv3-link-hidden-syntax") hidden.push({ from, to });
    if (decoration.spec.attributes?.["data-om-link"] === "true") {
      links.push({ text: doc.sliceString(from, to), href: decoration.spec.attributes["data-om-href"] });
    }
  });
  hidden.sort((left, right) => left.from - right.from);
  let visible = "";
  let cursor = 0;
  for (const range of hidden) {
    visible += doc.sliceString(cursor, range.from);
    cursor = range.to;
  }
  visible += doc.sliceString(cursor);
  return { visible, hidden, links };
}

describe("org-mode link concealment", () => {
  it("shows the description and preserves the complete clickable file target", () => {
    const target = "./shared.trading.org::*<2025-11-04 Tue> Superconductors & Equivalences";
    const doc = Text.of([`Full notes in [[${target}][shared.trading.org]].`]);
    const result = linkPresentation(doc, buildOrgModeDecorations(doc, []));
    expect(result.visible).toBe("Full notes in shared.trading.org.");
    expect(result.links).toEqual([{ text: `[[${target}][shared.trading.org]]`, href: target }]);
  });

  it("reveals only the active link, even when other links share its line", () => {
    const first = "[[./first.org][First]]";
    const doc = Text.of([`${first} and [[https://example.com][Second]]`]);
    for (let cursor = 0; cursor <= first.length; cursor++) {
      expect(linkPresentation(doc, buildOrgModeDecorations(doc, [cursor])).visible)
        .toBe(`${first} and Second`);
    }
    expect(linkPresentation(doc, buildOrgModeDecorations(doc, [first.length + 2])).visible)
      .toBe("First and Second");
  });

  it("preserves protocols in labeled, bare, and angle links", () => {
    const doc = Text.of(["[[file:./notes.org::42][Notes]] [[https://example.com][Site]] https://example.org <https://example.net>"]);
    const result = linkPresentation(doc, buildOrgModeDecorations(doc, []));
    expect(result.visible).toBe("Notes Site https://example.org <https://example.net>");
    expect(result.links.map((link) => link.href))
      .toEqual(["file:./notes.org::42", "https://example.com", "https://example.org", "https://example.net"]);
  });

  it("supports links in headings and multiline descriptions", () => {
    const doc = Text.of(["* See [[./notes.org][Notes]]", "Details: [[./other.org][A long", "description]]"]);
    expect(linkPresentation(doc, buildOrgModeDecorations(doc, [])).visible)
      .toBe("* See Notes\nDetails: A long\ndescription");
  });

  it("keeps untitled links and literal links in code unchanged", () => {
    const source = ["[[./notes.org]]", "~[[./code.org][Code]]~", "#+BEGIN_SRC org", "[[./source.org][Source]]", "#+END_SRC"].join("\n");
    const doc = Text.of(source.split("\n"));
    expect(linkPresentation(doc, buildOrgModeDecorations(doc, [])).visible).toBe(source);
  });

  it("updates on cursor moves, overlapping selections, multiple cursors, and edits", () => {
    let state = EditorState.create({
      doc: "Before [[./notes.org][Notes]] after",
      extensions: [createOrgModeExtension(), EditorState.allowMultipleSelections.of(true)],
    });
    function visible(): string {
      const source = state.facet(EditorView.decorations).find((value) => typeof value !== "function");
      if (!source || typeof source === "function") throw new Error("Expected Org decorations");
      return linkPresentation(state.doc, source).visible;
    }
    expect(visible()).toBe("Before Notes after");
    state = state.update({ selection: { anchor: 12 } }).state;
    expect(visible()).toBe(state.doc.toString());
    state = state.update({ selection: { anchor: 0 } }).state;
    expect(visible()).toBe("Before Notes after");
    state = state.update({ selection: { anchor: 0, head: state.doc.length } }).state;
    expect(visible()).toBe(state.doc.toString());
    state = state.update({ selection: EditorSelection.create([EditorSelection.cursor(0), EditorSelection.cursor(12)]) }).state;
    expect(visible()).toBe(state.doc.toString());
    const from = state.doc.toString().indexOf("[[");
    const to = state.doc.toString().indexOf("]]") + 2;
    state = state.update({ selection: { anchor: 0 }, changes: { from, to, insert: "[[./new.org][New title]]" } }).state;
    expect(visible()).toBe("Before New title after");
  });
});

function lineClasses(source: string): Map<number, string[]> {
  const doc = Text.of(source.split("\n"));
  const result = new Map<number, string[]>();

  buildOrgModeDecorations(doc, []).between(0, doc.length, (from, to, decoration) => {
    if (from !== to) return;
    const className = typeof decoration.spec.class === "string"
      ? decoration.spec.class
      : typeof decoration.spec.attributes?.class === "string"
        ? decoration.spec.attributes.class
        : null;
    if (!className) return;
    const line = doc.lineAt(from).number;
    const classes = result.get(line) ?? [];
    classes.push(...className.split(/\s+/));
    result.set(line, classes);
  });

  return result;
}

function lineStyles(source: string): Map<number, string[]> {
  const doc = Text.of(source.split("\n"));
  const result = new Map<number, string[]>();

  buildOrgModeDecorations(doc, []).between(0, doc.length, (from, to, decoration) => {
    if (from !== to || typeof decoration.spec.attributes?.style !== "string") return;
    const line = doc.lineAt(from).number;
    const styles = result.get(line) ?? [];
    styles.push(decoration.spec.attributes.style);
    result.set(line, styles);
  });

  return result;
}

function markedTextByClass(source: string): Map<string, string[]> {
  const doc = Text.of(source.split("\n"));
  const result = new Map<string, string[]>();
  buildOrgModeDecorations(doc, []).between(0, doc.length, (from, to, decoration) => {
    if (from >= to || typeof decoration.spec.class !== "string") return;
    for (const className of decoration.spec.class.split(/\s+/)) {
      const values = result.get(className) ?? [];
      values.push(doc.sliceString(from, to));
      result.set(className, values);
    }
  });
  return result;
}

describe("org-mode decorations", () => {
  it("highlights every top-of-file #+ directive as an org keyword", () => {
    const classes = lineClasses([
      "#+TITLE: Forecasting Theory Study Plan",
      "#+AUTHOR: Manu",
      "#+STARTUP: overview",
      "#+CUSTOM_PROPERTY: custom value",
      "",
      "* First heading",
    ].join("\n"));

    for (const line of [1, 2, 3, 4]) {
      expect(classes.get(line)).toContain("om-keyword");
    }
    expect(classes.get(6)).toContain("om-heading");
  });

  it("differentiates property keys and values", () => {
    const source = [":PROPERTIES:", ":ID: abc-123", ":OWNER: alex", ":END:"].join("\n");
    const lines = lineClasses(source);
    const marks = markedTextByClass(source);

    expect(lines.get(1)).toContain("om-properties-boundary");
    expect(lines.get(2)).toContain("om-property-line");
    expect(lines.get(4)).toContain("om-properties-boundary");
    expect(marks.get("om-property-key")).toEqual([":ID:", ":OWNER:"]);
    expect(marks.get("om-property-value")).toEqual(["abc-123", "alex"]);
  });

  it("styles definition terms and source block structure", () => {
    const source = [
      "- calibration :: agreement between forecasts and outcomes",
      "#+BEGIN_SRC python",
      "print('hello')",
      "#+END_SRC",
    ].join("\n");
    const lines = lineClasses(source);
    const marks = markedTextByClass(source);

    expect(lines.get(1)).toContain("om-description-list");
    expect(marks.get("om-description-term")).toEqual(["calibration"]);
    expect(lines.get(2)).toContain("om-src-delimiter");
    expect(lines.get(3)).toContain("om-src-body");
    expect(lines.get(4)).toContain("om-src-delimiter");
  });

  it("gives numbered and bullet checkboxes the same interactive token ranges", () => {
    const source = [
      "- [ ] bullet",
      "1. [ ] numbered",
      "  12) [X] nested checked",
      "2. [-] partial",
    ].join("\n");
    const doc = Text.of(source.split("\n"));
    const tokens: string[] = [];
    const checked: boolean[] = [];
    buildOrgModeDecorations(doc, []).between(0, doc.length, (from, to, decoration) => {
      const attrs = decoration.spec.attributes;
      if (attrs?.["data-om-checkbox"] !== "true") return;
      const tokenFrom = Number(attrs["data-om-from"]);
      const tokenTo = Number(attrs["data-om-to"]);
      expect(from).toBe(tokenFrom);
      expect(to).toBe(tokenTo + 1);
      tokens.push(doc.sliceString(tokenFrom, tokenTo));
      checked.push(decoration.spec.class.includes("om-checked"));
    });
    expect(tokens).toEqual(["[ ]", "[ ]", "[X]", "[-]"]);
    expect(checked).toEqual([false, false, true, false]);
  });

  it("uses line-box indentation and hanging list prefixes without spacer widgets", () => {
    const source = [
      "* H1",
      "** H2",
      "*** H3",
      "- a long top-level item that can wrap",
      "  10. a nested ordered item that can wrap",
      "  - [ ] a nested task that can wrap",
    ].join("\n");
    const doc = Text.of(source.split("\n"));
    const decorations = buildOrgModeDecorations(doc, []);
    const lines = lineClasses(source);
    const styles = lineStyles(source);
    const markerTexts: string[] = [];
    let widgetCount = 0;

    decorations.between(0, doc.length, (from, to, decoration) => {
      const className = typeof decoration.spec.class === "string" ? decoration.spec.class : "";
      if (className.split(/\s+/).includes("om-list-marker")) {
        markerTexts.push(doc.sliceString(from, to));
      }
      if (decoration.widget) widgetCount += 1;
    });

    expect(lines.get(3)).toContain("om-section-indent-line");
    for (const lineNumber of [4, 5, 6]) {
      expect(lines.get(lineNumber)).toContain("om-section-indent-line");
      expect(lines.get(lineNumber)).toContain("om-list-line");
    }
    expect(styles.get(4)).toContain("--om-list-prefix-width:2ch;");
    expect(styles.get(5)).toContain("--om-list-prefix-width:6ch;");
    expect(styles.get(6)).toContain("--om-list-prefix-width:8ch;");
    expect(markerTexts).toEqual(["- ", "  10. ", "  - "]);
    expect(widgetCount).toBe(0);
  });
});

describe("org-mode headline state and planning styling", () => {
  it("reads closed states from the document's #+TODO line", () => {
    expect([...doneStatesFor("#+TODO: TODO DOING | DONE POSTPONED DROPPED\n* x")].sort())
      .toEqual(["DONE", "DROPPED", "POSTPONED"]);
    expect([...doneStatesFor("#+TODO: TODO(t) NEXT(n) | DONE(d) CANCELLED(c)\n")].sort())
      .toEqual(["CANCELLED", "DONE"]);
    expect([...doneStatesFor("#+SEQ_TODO: TODO WAIT DONE\n")]).toEqual(["DONE"]);
    expect([...doneStatesFor("* no directive")].sort()).toEqual(["DONE", "DROPPED", "POSTPONED"]);
  });

  it("marks headlines with their TODO state so closed ones can be dimmed", () => {
    const classes = lineClasses([
      "#+TODO: TODO DOING | DONE POSTPONED",
      "* TODO open work",
      "* POSTPONED parked work",
      "* DONE finished work",
      "* plain heading",
    ].join("\n"));

    expect(classes.get(2)).toContain("om-heading-todo");
    expect(classes.get(3)).toContain("om-heading-done");
    expect(classes.get(4)).toContain("om-heading-done");
    expect(classes.get(5)).not.toContain("om-heading-todo");
    expect(classes.get(5)).not.toContain("om-heading-done");
  });

  it("uses the document's #+TODO line for the keyword mark, not a fixed list", () => {
    const marks = markedTextByClass([
      "#+TODO: TODO | POSTPONED",
      "* POSTPONED parked",
      "* TODO open",
    ].join("\n"));
    expect(marks.get("om-done")).toEqual(["POSTPONED"]);
    expect(marks.get("om-todo")).toEqual(["TODO"]);
  });

  it("gives the #+title value the H1 mark and leaves other keywords plain", () => {
    const classes = lineClasses([
      "#+TITLE:  Theme set for nvModern  ",
      "#+AUTHOR: Manu",
      "#+title:",
    ].join("\n"));
    const marks = markedTextByClass([
      "#+TITLE:  Theme set for nvModern  ",
      "#+AUTHOR: Manu",
    ].join("\n"));

    expect(classes.get(1)).toContain("om-title");
    expect(classes.get(2)).not.toContain("om-title");
    expect(classes.get(3)).not.toContain("om-title");
    expect(marks.get("om-title-key")).toEqual(["#+TITLE:"]);
    expect(marks.get("om-title-text")).toEqual(["Theme set for nvModern"]);
  });

  it("carries heading typography on a headline mark, not the line", () => {
    const marks = markedTextByClass([
      "* NEXT Laurenziana [2/3] [50%]   :type:michelangelus:",
      "** DOING Swash capitals",
      "plain text",
    ].join("\n"));
    const classes = lineClasses("* NEXT Laurenziana\n** DOING Swash capitals");

    expect(marks.get("om-hl1")).toEqual(["* NEXT Laurenziana [2/3] [50%]   :type:michelangelus:"]);
    expect(marks.get("om-hl2")).toEqual(["** DOING Swash capitals"]);
    expect(marks.get("om-tags")).toEqual([":type:michelangelus:"]);
    expect(marks.get("om-cookie")).toEqual(["[2/3]", "[50%]"]);
    expect(marks.get("om-kw-doing")).toEqual(["DOING"]);
    expect(classes.get(1)).toContain("om-h1");
    expect(classes.get(1)).not.toContain("om-hl1");
  });

  it("labels planning keywords and their timestamps by kind", () => {
    const marks = markedTextByClass([
      "* TODO ship",
      "  SCHEDULED: <2026-09-08 Tue 10:45-13:00> DEADLINE: <2026-09-09 Wed>",
    ].join("\n"));

    expect(marks.get("om-planning-keyword")).toEqual(["SCHEDULED:", "DEADLINE:"]);
    expect(marks.get("om-planning-scheduled")).toEqual(["SCHEDULED:"]);
    expect(marks.get("om-planning-deadline")).toEqual(["DEADLINE:"]);
    expect(marks.get("om-timestamp-scheduled")).toEqual(["<2026-09-08 Tue 10:45-13:00>"]);
    expect(marks.get("om-timestamp-deadline")).toEqual(["<2026-09-09 Wed>"]);
  });
});
