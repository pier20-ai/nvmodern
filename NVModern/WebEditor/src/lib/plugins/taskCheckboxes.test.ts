import { describe, expect, it } from "bun:test";
import { detectMarkdownTaskCheckboxes } from "./taskCheckboxes.ts";

describe("detectMarkdownTaskCheckboxes", () => {
  it("detects basic unchecked and checked task markers", () => {
    const input = ["- [ ] todo", "- [X] done", "1. [x] also done"].join("\n");
    const matches = detectMarkdownTaskCheckboxes(input);

    expect(matches).toHaveLength(3);
    expect(matches[0]?.checked).toBe(false);
    expect(matches[1]?.checked).toBe(true);
    expect(matches[2]?.checked).toBe(true);
  });

  it("ignores frontmatter and fenced code", () => {
    const input = [
      "---",
      "task: '- [ ] nope'",
      "---",
      "```md",
      "- [ ] nope",
      "```",
      "- [ ] yes",
    ].join("\n");

    const matches = detectMarkdownTaskCheckboxes(input);

    expect(matches).toHaveLength(1);
    expect(matches[0]?.line).toBe(7);
  });
});
