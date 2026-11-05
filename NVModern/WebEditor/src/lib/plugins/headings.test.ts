import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { EditorState } from "@codemirror/state";
import { describe, expect, it } from "bun:test";
import {
  collectMarkdownHeadingSections,
  collectMarkdownTocHeadings,
  collectMarkdownOutlineHeadings,
  collectOrgOutlineHeadings,
  collectOrgTocHeadings,
  createNv3EditorState,
  resolveActiveTocHeadingId,
  createNv3MarkdownExtensions,
} from "../index.ts";

function createState(doc: string): EditorState {
  return EditorState.create({
    doc,
    extensions: createNv3MarkdownExtensions(),
  });
}

describe("markdown headings", () => {
  it("parses only atx headings after setext headings are disabled", () => {
    const state = createState([
      "# Inbox",
      "Spec",
      "====",
      "Notes",
      "----",
      "## Tasks",
    ].join("\n"));

    ensureSyntaxTree(state, state.doc.length, 150);

    const nodeNames: string[] = [];
    syntaxTree(state).iterate({
      enter(node) {
        nodeNames.push(node.name);
      },
    });

    expect(nodeNames).toContain("ATXHeading1");
    expect(nodeNames).toContain("ATXHeading2");
    expect(nodeNames).not.toContain("SetextHeading1");
    expect(nodeNames).not.toContain("SetextHeading2");
  });

  it("collects table-of-contents entries only from atx headings", () => {
    const state = createState([
      "# Inbox",
      "Spec",
      "====",
      "Notes",
      "----",
      "## Tasks",
    ].join("\n"));

    expect(collectMarkdownTocHeadings(state).map((heading) => heading.text)).toEqual([
      "Inbox",
      "Tasks",
    ]);
  });

  it("computes heading section fold ranges up to the next same-or-higher heading", () => {
    const doc = [
      "# One",
      "alpha",
      "## Two",
      "beta",
      "### Three",
      "gamma",
      "## Four",
      "delta",
    ].join("\n");
    const state = createState(doc);
    const sections = collectMarkdownHeadingSections(state);

    expect(
      sections.map((section) => ({
        text: section.text,
        level: section.level,
        body: state.doc.sliceString(section.bodyFrom, section.bodyTo),
      })),
    ).toEqual([
      {
        text: "One",
        level: 1,
        body: "\nalpha\n## Two\nbeta\n### Three\ngamma\n## Four\ndelta",
      },
      {
        text: "Two",
        level: 2,
        body: "\nbeta\n### Three\ngamma",
      },
      {
        text: "Three",
        level: 3,
        body: "\ngamma",
      },
      {
        text: "Four",
        level: 2,
        body: "\ndelta",
      },
    ]);
  });
});


describe("complete document outlines", () => {
  it("retains all six Markdown levels while the compact ToC stays bounded", () => {
    const state = createState([
      "# One", "## Two", "### Three", "#### Four", "##### Five", "###### Six",
      "```md", "# Not a heading", "```", "## Two",
    ].join("\n"));
    const headings = collectMarkdownOutlineHeadings(state);
    expect(headings.map((heading) => heading.level)).toEqual([1, 2, 3, 4, 5, 6, 2]);
    expect(new Set(headings.map((heading) => heading.id)).size).toBe(headings.length);
    expect(collectMarkdownTocHeadings(state).map((heading) => heading.text))
      .toEqual(["One", "Two", "Three", "Two"]);
    expect(headings[5]?.line).toBe(6);
  });

  it("retains arbitrary Org depth, titles and live source positions", () => {
    const state = createNv3EditorState({
      fileType: "org",
      doc: "* TODO Deploy :ops:\n** Rollback\n******* Deep heading\n** Rollback",
    });
    const headings = collectOrgOutlineHeadings(state);
    expect(headings.map((heading) => [heading.text, heading.level]))
      .toEqual([["Deploy", 1], ["Rollback", 2], ["Deep heading", 7], ["Rollback", 2]]);
    expect(new Set(headings.map((heading) => heading.id)).size).toBe(4);
    expect(collectOrgTocHeadings(state).map((heading) => heading.level)).toEqual([1, 2, 3, 2]);
    expect(resolveActiveTocHeadingId(headings, headings[2]!.from, headings[2]!.to))
      .toBe(headings[2]!.id);
    const edited = state.update({ changes: { from: 0, insert: "Intro\n" } }).state;
    expect(collectOrgOutlineHeadings(edited)[2]?.line).toBe(4);
    expect(collectOrgOutlineHeadings(edited)[2]?.from).toBe(headings[2]!.from + 6);
  });
});
