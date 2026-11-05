import { EditorState } from "@codemirror/state";
import { describe, expect, it } from "bun:test";
import { collectOrgLineUnwrapRanges } from "./orgLineUnwrap.ts";

function displayedText(source: string): string {
  const state = EditorState.create({ doc: source });
  const ranges = collectOrgLineUnwrapRanges(state);
  let result = source;
  for (const range of ranges.toReversed()) {
    result = result.slice(0, range.from) + range.replacement + result.slice(range.to);
  }
  return result;
}

describe("Org line unwrapping", () => {
  it("joins prose without joining headings or separate paragraphs", () => {
    expect(displayedText([
      "* Heading",
      "A paragraph wrapped",
      "onto another line.",
      "",
      "Another paragraph.",
    ].join("\n"))).toBe([
      "* Heading",
      "A paragraph wrapped onto another line.",
      "",
      "Another paragraph.",
    ].join("\n"));
  });

  it("unwraps list and quote-block paragraphs", () => {
    expect(displayedText([
      "- A list paragraph",
      "  continues here.",
      "",
      "#+begin_quote",
      "A quoted paragraph",
      "continues here.",
      "#+end_quote",
    ].join("\n"))).toBe([
      "- A list paragraph continues here.",
      "",
      "#+begin_quote",
      "A quoted paragraph continues here.",
      "#+end_quote",
    ].join("\n"));
  });

  it("preserves explicit line breaks and line-sensitive blocks", () => {
    expect(displayedText([
      "An explicit break\\\\",
      "stays on its line.",
      "",
      "#+begin_src text",
      "code stays",
      "on separate lines",
      "#+end_src",
      "",
      "#+begin_verse",
      "verse stays",
      "on separate lines",
      "#+end_verse",
    ].join("\n"))).toBe([
      "An explicit break\\\\",
      "stays on its line.",
      "",
      "#+begin_src text",
      "code stays",
      "on separate lines",
      "#+end_src",
      "",
      "#+begin_verse",
      "verse stays",
      "on separate lines",
      "#+end_verse",
    ].join("\n"));
  });

  it("rejoins wrapped words without retaining the wrap hyphen", () => {
    expect(displayedText("The docu-\nment stays readable.")).toBe(
      "The document stays readable.",
    );
  });
});
