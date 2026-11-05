import { describe, expect, test } from "bun:test";
import { parseDiffFromFile } from "@pierre/diffs";

describe("diff preview inputs", () => {
  test("keeps a one-word replacement in one minimal hunk", () => {
    const diff = parseDiffFromFile(
      { name: "Before.md", contents: "# Note\n\nThe old word stays local.\n\nEnd.\n", lang: "markdown" },
      { name: "After.md", contents: "# Note\n\nThe new word stays local.\n\nEnd.\n", lang: "markdown" },
      undefined,
      true,
    );

    expect(diff.hunks).toHaveLength(1);
    expect(diff.hunks[0]?.deletionLines).toBe(1);
    expect(diff.hunks[0]?.additionLines).toBe(1);
  });

  test("reports no hunks for identical Markdown", () => {
    const contents = "# Same\n\nNo changes.\n";
    const diff = parseDiffFromFile(
      { name: "Left.md", contents, lang: "markdown" },
      { name: "Right.md", contents, lang: "markdown" },
      undefined,
      true,
    );

    expect(diff.hunks).toHaveLength(0);
  });
});
