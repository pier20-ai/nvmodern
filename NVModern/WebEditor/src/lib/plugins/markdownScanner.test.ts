import { describe, expect, it } from "bun:test";
import { scanMarkdownText } from "./markdownScanner.ts";

describe("scanMarkdownText", () => {
  it("skips frontmatter, fenced blocks, and inline code", () => {
    const input = [
      "---",
      "meta: '#ignore'",
      "---",
      "- [ ] todo",
      "- @listuser",
      "`#nope @none [[none]]`",
      "#tag @user [[note]]",
      "```md",
      "#fence @fence [[fence]]",
      "- [ ] fence task",
      "```",
      "- [X] done",
    ].join("\n");

    const index = scanMarkdownText(input);

    expect(index.hashTagOccurrences.map((occurrence) => occurrence.tag)).toEqual(["tag"]);
    expect(index.mentionOccurrences.map((occurrence) => occurrence.mention)).toEqual([
      "listuser",
      "user",
    ]);
    expect(index.linkOccurrences).toHaveLength(1);
    expect(index.linkOccurrences[0]?.kind).toBe("wikilink");
    expect(index.linkOccurrences[0]?.target).toBe("note");
    expect(index.taskCheckboxOccurrences).toHaveLength(2);
    expect(index.codeFenceBlocks).toEqual([
      {
        fromLine: 8,
        toLine: 11,
        language: "md",
        closed: true,
      },
    ]);
  });

  it("detects trailing heading tags", () => {
    const index = scanMarkdownText("## Heading :alpha:beta=1:");

    expect(index.headingTagOccurrences.map((occurrence) => occurrence.tag)).toEqual([
      "alpha",
      "beta=1",
    ]);
  });

  it("indexes headings and obsidian block ids while skipping fences and inline code", () => {
    const input = [
      "# Alpha",
      "Paragraph ^block-one",
      "`ignored ^inline`",
      "```md",
      "## Fenced",
      "Inside fence ^block-two",
      "```",
      "## Beta",
      "Standalone",
      "^block-three",
    ].join("\n");

    const index = scanMarkdownText(input);

    expect(index.headingOccurrences.map((occurrence) => occurrence.text)).toEqual([
      "Alpha",
      "Beta",
    ]);
    expect(index.blockIDOcurrences.map((occurrence) => occurrence.id)).toEqual([
      "block-one",
      "block-three",
    ]);
  });

  it("indexes transclusions, previews, inline links, and wikilinks", () => {
    const index = scanMarkdownText(
      "[site](https://example.com) ![img](image.png) ![[transclude]] [[wiki]]",
    );

    expect(index.inlineLinkOccurrences).toHaveLength(1);
    expect(index.inlineLinkOccurrences[0]?.href).toBe("https://example.com");

    expect(index.linkOccurrences.map((occurrence) => occurrence.kind)).toEqual([
      "preview",
      "transclusion",
      "wikilink",
    ]);
    expect(index.linkOccurrences.map((occurrence) => occurrence.target)).toEqual([
      "image.png",
      "transclude",
      "wiki",
    ]);
  });

  it("indexes inline links whose labels contain inline code", () => {
    const index = scanMarkdownText(
      "*Full script: [`wl/01_foundations_01_binomial_convergence.wl`](wl/01_foundations_01_binomial_convergence.wl)*",
    );

    expect(index.inlineLinkOccurrences).toHaveLength(1);
    expect(index.inlineLinkOccurrences[0]?.label).toBe("`wl/01_foundations_01_binomial_convergence.wl`");
    expect(index.inlineLinkOccurrences[0]?.href).toBe("wl/01_foundations_01_binomial_convergence.wl");
  });

  it("indexes standalone transclusions separately", () => {
    const input = ["![[a]]", "inline ![[b]]", "   ![[c]]   "].join("\n");
    const index = scanMarkdownText(input);

    expect(index.standaloneTransclusions).toHaveLength(2);
    expect(index.standaloneTransclusions.map((occurrence) => occurrence.target)).toEqual([
      "a",
      "c",
    ]);
    expect(index.standaloneTransclusions.map((occurrence) => [occurrence.from, occurrence.to])).toEqual([
      [0, 6],
      [21, 33],
    ]);
  });

  it("indexes latex fragments while respecting code fences and inline code", () => {
    const input = [
      "Inline $x+1$ and \\(y+1\\).",
      "`$ignored$`",
      "$$",
      "z^2",
      "$$",
      "```md",
      "$fenced$",
      "```",
    ].join("\n");

    const index = scanMarkdownText(input);

    expect(index.latexFragments.map((fragment) => fragment.kind)).toEqual([
      "inline-dollar",
      "inline-paren",
      "block-dollar",
    ]);
  });
});
