import { describe, expect, it } from "bun:test";
import { Text } from "@codemirror/state";
import { orgDocumentScanner } from "./orgIndex.ts";

describe("orgDocumentScanner", () => {
  it("maps headings, tags, links, code blocks, tasks, and latex to DocumentScanIndex", () => {
    const doc = Text.of([
      "* TODO First heading :project:urgent:",
      "** DONE Sub-heading",
      "",
      "A paragraph with [[https://example.com][link]] and $E = mc^2$.",
      "",
      "- [ ] unchecked task",
      "- [X] completed task",
      "",
      "#+BEGIN_SRC python",
      "print('hello')",
      "#+END_SRC",
    ]);

    const index = orgDocumentScanner(doc);

    // Headings
    expect(index.headings).toHaveLength(2);
    expect(index.headings[0]?.text).toBe("First heading");
    expect(index.headings[0]?.level).toBe(1);
    expect(index.headings[1]?.text).toBe("Sub-heading");
    expect(index.headings[1]?.level).toBe(2);

    // Heading tags
    expect(index.headingTags).toHaveLength(2);
    expect(index.headingTags.map((t) => t.tag)).toEqual(["project", "urgent"]);

    // Links
    expect(index.links).toHaveLength(1);
    expect(index.links[0]?.target).toBe("https://example.com");

    // Tasks
    expect(index.tasks).toHaveLength(2);
    expect(index.tasks[0]?.checked).toBe(false);
    expect(index.tasks[1]?.checked).toBe(true);

    // Code blocks
    expect(index.codeBlocks).toHaveLength(1);
    expect(index.codeBlocks[0]?.language).toBe("python");
    expect(index.codeBlocks[0]?.closed).toBe(true);

    // LaTeX
    expect(index.latexFragments).toHaveLength(1);
    expect(index.latexFragments[0]?.kind).toBe("inline-dollar");

    // Empty fields for org
    expect(index.tags).toHaveLength(0);
    expect(index.mentions).toHaveLength(0);
    expect(index.blockIDs).toHaveLength(0);
    expect(index.inlineLinks).toHaveLength(0);
    expect(index.transclusions).toHaveLength(0);
  });

  it("handles empty documents", () => {
    const index = orgDocumentScanner(Text.of([""]));

    expect(index.headings).toHaveLength(0);
    expect(index.links).toHaveLength(0);
    expect(index.tasks).toHaveLength(0);
    expect(index.codeBlocks).toHaveLength(0);
  });

  it("maps \\(...\\) inline latex to inline-paren fragments", () => {
    const doc = Text.of(["Inline: \\(a^2 + b^2\\) here."]);
    const index = orgDocumentScanner(doc);

    expect(index.latexFragments).toHaveLength(1);
    expect(index.latexFragments[0]?.kind).toBe("inline-paren");
  });
});
