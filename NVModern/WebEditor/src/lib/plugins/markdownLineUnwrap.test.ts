import { EditorState } from "@codemirror/state";
import { describe, expect, it } from "bun:test";
import { createNv3MarkdownExtensions } from "../index.ts";
import { collectMarkdownLineUnwrapRanges } from "./markdownLineUnwrap.ts";

function displayedText(source: string): string {
  const state = EditorState.create({
    doc: source,
    extensions: createNv3MarkdownExtensions(),
  });
  const ranges = collectMarkdownLineUnwrapRanges(state);
  let result = source;
  for (const range of ranges.toReversed()) {
    result = result.slice(0, range.from) + range.replacement + result.slice(range.to);
  }
  return result;
}

describe("Markdown line unwrapping", () => {
  it("joins only soft breaks in prose paragraphs", () => {
    const source = [
      "A paragraph wrapped",
      "onto another line.",
      "",
      "Another paragraph.  ",
      "This is a hard break.",
      "",
      "```text",
      "code stays",
      "on separate lines",
      "```",
    ].join("\n");

    expect(displayedText(source)).toBe([
      "A paragraph wrapped onto another line.",
      "",
      "Another paragraph.  ",
      "This is a hard break.",
      "",
      "```text",
      "code stays",
      "on separate lines",
      "```",
    ].join("\n"));
  });

  it("preserves container prefixes and unwraps their continuation text", () => {
    expect(displayedText([
      "> A quoted paragraph",
      "> continues here.",
      "",
      "- A list paragraph",
      "  continues here.",
    ].join("\n"))).toBe([
      "> A quoted paragraph continues here.",
      "",
      "- A list paragraph continues here.",
    ].join("\n"));
  });

  it("rejoins wrapped words without retaining the wrap hyphen", () => {
    expect(displayedText("The docu-\nment stays readable.")).toBe(
      "The document stays readable.",
    );
  });

  it("leaves front matter untouched", () => {
    const source = [
      "---",
      "summary: a wrapped",
      "  metadata value",
      "---",
      "Body text wraps",
      "onto one line.",
    ].join("\n");

    expect(displayedText(source)).toBe([
      "---",
      "summary: a wrapped",
      "  metadata value",
      "---",
      "Body text wraps onto one line.",
    ].join("\n"));
  });
});
