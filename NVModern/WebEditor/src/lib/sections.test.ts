import { describe, expect, test } from "bun:test";
import { resolveNv3SectionRange } from "./sections.ts";

function slice(text: string, range: { from: number; to: number } | null): string | null {
  return range ? text.slice(range.from, range.to) : null;
}

describe("Markdown heading sections", () => {
  const doc = [
    "---",
    "title: Demo",
    "---",
    "# Top",
    "intro",
    "",
    "## Alpha",
    "alpha body",
    "",
    "### Alpha child",
    "child body",
    "",
    "```md",
    "## Not a heading",
    "```",
    "",
    "## Beta ##",
    "beta body",
    "",
  ].join("\n");

  test("takes the heading and its subtree up to the next sibling", () => {
    expect(slice(doc, resolveNv3SectionRange(doc, "markdown", { heading: "Alpha" }))).toBe(
      ["## Alpha", "alpha body", "", "### Alpha child", "child body", "", "```md", "## Not a heading", "```"].join("\n"),
    );
  });

  test("matches case and whitespace insensitively, ignoring closing hashes", () => {
    expect(slice(doc, resolveNv3SectionRange(doc, "markdown", { heading: "  beta " }))).toBe(
      "## Beta ##\nbeta body",
    );
  });

  test("a nested heading ends at the next heading of its level or above", () => {
    expect(slice(doc, resolveNv3SectionRange(doc, "markdown", { heading: "Alpha child" }))).toBe(
      ["### Alpha child", "child body", "", "```md", "## Not a heading", "```"].join("\n"),
    );
  });

  test("the top heading runs to the end of the note", () => {
    const range = resolveNv3SectionRange(doc, "markdown", { heading: "Top" });
    expect(range?.kind).toBe("heading");
    expect(slice(doc, range)?.endsWith("beta body")).toBe(true);
  });

  test("headings inside code fences and missing headings do not match", () => {
    expect(resolveNv3SectionRange(doc, "markdown", { heading: "Not a heading" })).toBeNull();
    expect(resolveNv3SectionRange(doc, "markdown", { heading: "Gamma" })).toBeNull();
  });

  test("heading focus wins over block focus; empty focus resolves nothing", () => {
    expect(slice(doc, resolveNv3SectionRange(doc, "markdown", { heading: "Beta", block: "x" }))).toBe(
      "## Beta ##\nbeta body",
    );
    expect(resolveNv3SectionRange(doc, "markdown", {})).toBeNull();
    expect(resolveNv3SectionRange(doc, "markdown", null)).toBeNull();
    expect(resolveNv3SectionRange(doc, "plain", { heading: "Alpha" })).toBeNull();
  });
});

describe("Markdown block sections", () => {
  const doc = [
    "# Notes",
    "First line of a paragraph",
    "that ends with an id ^para-1",
    "",
    "- item one ^item-1",
    "  - nested child",
    "  - another child",
    "- item two",
    "  continued text ^cont",
    "",
    "| a | b |",
    "| - | - |",
    "| 1 | 2 |",
    "",
    "^table-1",
    "",
    "## Heading with id ^head-1",
    "after",
  ].join("\n");

  test("a paragraph runs from its first line to the marker", () => {
    expect(slice(doc, resolveNv3SectionRange(doc, "markdown", { block: "para-1" }))).toBe(
      "First line of a paragraph\nthat ends with an id ^para-1",
    );
  });

  test("a list item includes its nested children", () => {
    expect(slice(doc, resolveNv3SectionRange(doc, "markdown", { block: "^ITEM-1" }))).toBe(
      "- item one ^item-1\n  - nested child\n  - another child",
    );
  });

  test("a continuation line belongs to its list item", () => {
    expect(slice(doc, resolveNv3SectionRange(doc, "markdown", { block: "cont" }))).toBe(
      "- item two\n  continued text ^cont",
    );
  });

  test("a standalone marker refers to the block above it", () => {
    expect(slice(doc, resolveNv3SectionRange(doc, "markdown", { block: "table-1" }))).toBe(
      "| a | b |\n| - | - |\n| 1 | 2 |",
    );
  });

  test("a marker on a heading is that heading line", () => {
    const range = resolveNv3SectionRange(doc, "markdown", { block: "head-1" });
    expect(range?.kind).toBe("block");
    expect(slice(doc, range)).toBe("## Heading with id ^head-1");
  });

  test("unknown ids resolve nothing", () => {
    expect(resolveNv3SectionRange(doc, "markdown", { block: "nope" })).toBeNull();
  });
});

describe("Org sections", () => {
  const doc = [
    "#+title: Org demo",
    "* TODO Project plan :work:",
    "plan body",
    "** Milestones",
    "milestone body",
    "* Done items",
    "#+begin_src text",
    "not a marker ^inside",
    "#+end_src",
    "A paragraph line",
    "ending here ^org-block",
    "",
  ].join("\n");

  test("a headline focus takes its subtree, ignoring TODO keyword and tags", () => {
    expect(slice(doc, resolveNv3SectionRange(doc, "org", { heading: "project plan" }))).toBe(
      "* TODO Project plan :work:\nplan body\n** Milestones\nmilestone body",
    );
  });

  test("a nested headline ends at the next headline of its level or above", () => {
    expect(slice(doc, resolveNv3SectionRange(doc, "org", { heading: "Milestones" }))).toBe(
      "** Milestones\nmilestone body",
    );
  });

  test("block markers resolve outside source blocks only", () => {
    expect(slice(doc, resolveNv3SectionRange(doc, "org", { block: "org-block" }))).toBe(
      "A paragraph line\nending here ^org-block",
    );
    expect(resolveNv3SectionRange(doc, "org", { block: "inside" })).toBeNull();
  });
});
