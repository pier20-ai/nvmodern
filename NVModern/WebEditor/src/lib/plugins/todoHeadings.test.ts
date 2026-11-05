import { describe, expect, it } from "bun:test";
import {
  DEFAULT_MARKDOWN_HEADER_STATES,
  resolveMarkdownHeaderStates,
  scanMarkdownHeadingStates,
} from "../index.ts";

describe("markdown heading states", () => {
  it("uses default heading states when frontmatter does not define overrides", () => {
    expect(resolveMarkdownHeaderStates("# [TODO] Task")).toEqual(DEFAULT_MARKDOWN_HEADER_STATES);
  });

  it("merges frontmatter header state overrides by normalized state name", () => {
    const doc = [
      "---",
      "header_states:",
      "  doing: '#ff8800'",
      "  review: 'rebeccapurple'",
      "---",
      "# [DOING] Task",
    ].join("\n");

    const states = resolveMarkdownHeaderStates(doc);

    expect(states.DOING).toBe("#ff8800");
    expect(states.REVIEW).toBe("rebeccapurple");
    expect(states.TODO).toBe(DEFAULT_MARKDOWN_HEADER_STATES.TODO);
  });

  it("scans heading states in atx headings while ignoring setext-style underlines, fences, and frontmatter", () => {
    const doc = [
      "---",
      "header_states:",
      "  review: '#7c3aed'",
      "---",
      "# [TODO] Inbox",
      "## [REVIEW] Spec",
      "Ignored",
      "------------",
      "```md",
      "# [DONE] Fenced",
      "```",
      "Text [TODO] body",
    ].join("\n");

    const occurrences = scanMarkdownHeadingStates(doc, resolveMarkdownHeaderStates(doc));

    expect(occurrences.map((occurrence) => occurrence.state)).toEqual(["TODO", "REVIEW"]);
    expect(occurrences.map((occurrence) => occurrence.color)).toEqual([
      DEFAULT_MARKDOWN_HEADER_STATES.TODO,
      "#7c3aed",
    ]);
  });
});
