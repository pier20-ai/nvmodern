import { describe, expect, it } from "bun:test";
import { scanMarkdownCallouts } from "./callouts.ts";

describe("scanMarkdownCallouts", () => {
  it("detects simple callout blocks and their ranges", () => {
    const input = [
      "> [!note] Important",
      "> First line",
      "> Second line",
      "",
      "Plain paragraph",
    ].join("\n");

    const blocks = scanMarkdownCallouts(input);

    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toMatchObject({
      type: "note",
      title: "Important",
      fromLine: 1,
      toLine: 3,
      depth: 1,
    });
  });

  it("supports nested blockquote depth and body content inside the callout", () => {
    const input = [
      "> > [!warning] Heads up",
      "> > Nested body",
      "> > - list item",
      "> Outside nested quote",
    ].join("\n");

    const blocks = scanMarkdownCallouts(input);

    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toMatchObject({
      type: "warning",
      title: "Heads up",
      fromLine: 1,
      toLine: 3,
      depth: 2,
    });
  });

  it("skips fence and frontmatter content while still scanning normal quoted callouts", () => {
    const input = [
      "---",
      "kind: note",
      "---",
      "> [!tip] Keep",
      "> Visible",
      "```md",
      "> [!danger] Ignored in fence",
      "```",
    ].join("\n");

    const blocks = scanMarkdownCallouts(input);

    expect(blocks).toHaveLength(1);
    expect(blocks[0]).toMatchObject({
      type: "tip",
      title: "Keep",
      fromLine: 4,
      toLine: 5,
    });
  });
});
