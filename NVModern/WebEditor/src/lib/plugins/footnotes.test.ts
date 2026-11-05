import { describe, expect, it } from "bun:test";
import { scanMarkdownFootnotes } from "./footnotes.ts";

describe("scanMarkdownFootnotes", () => {
  it("detects references and definitions with two-space continuation lines", () => {
    const input = [
      "Paragraph with [^alpha] and [^missing].",
      "",
      "[^alpha]: First line",
      "  second line",
      "  ",
      "  third line",
    ].join("\n");

    const index = scanMarkdownFootnotes(input);

    expect(index.references.map((reference) => ({ id: reference.id, resolved: reference.resolved }))).toEqual([
      { id: "alpha", resolved: true },
      { id: "missing", resolved: false },
    ]);
    expect(index.definitions).toHaveLength(1);
    expect(index.definitions[0]).toMatchObject({
      id: "alpha",
      line: 3,
      toLine: 6,
      content: "First line\nsecond line\n\nthird line",
    });
    expect(index.unresolvedReferenceIds).toEqual(["missing"]);
  });

  it("does not treat one-space lines as footnote continuations", () => {
    const input = [
      "[^alpha]: First line",
      " next line is not continuation",
      "Paragraph [^alpha]",
    ].join("\n");

    const index = scanMarkdownFootnotes(input);

    expect(index.definitions).toHaveLength(1);
    expect(index.definitions[0]?.toLine).toBe(1);
    expect(index.definitions[0]?.content).toBe("First line");
    expect(index.references.map((reference) => reference.id)).toEqual(["alpha"]);
  });

  it("skips frontmatter, fenced code, inline code, and definition labels", () => {
    const input = [
      "---",
      "footnote: [^meta]",
      "---",
      "Visible [^one] and `[^code]`.",
      "[^one]: Body",
      "```md",
      "[^fenced]: nope",
      "```",
    ].join("\n");

    const index = scanMarkdownFootnotes(input);

    expect(index.references.map((reference) => reference.id)).toEqual(["one"]);
    expect(index.definitions.map((definition) => definition.id)).toEqual(["one"]);
  });
});
