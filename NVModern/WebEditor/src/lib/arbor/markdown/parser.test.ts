import { describe, expect, it } from "bun:test";
import { parseArborMarkdown } from "./parser.ts";

describe("parseArborMarkdown", () => {
  it("parses nested Markdown with exact source ranges", () => {
    const source = "plain **bold *nested*** and `code`";
    const document = parseArborMarkdown(source);
    const paragraph = document.blocks[0];

    expect(paragraph?.kind).toBe("paragraph");
    if (paragraph?.kind !== "paragraph") return;
    expect(paragraph.children.map((node) => node.kind)).toEqual([
      "text",
      "strong",
      "text",
      "code",
    ]);

    const strong = paragraph.children[1];
    expect(strong).toMatchObject({ kind: "strong", from: 6, to: 23 });
    expect(strong?.kind === "strong" ? strong.children.map((node) => node.kind) : []).toEqual([
      "text",
      "emphasis",
    ]);
    expect(paragraph.children[3]).toEqual({
      kind: "code",
      from: 28,
      to: 34,
      contentFrom: 29,
      contentTo: 33,
    });
  });

  it("parses Arbor syntax as first-class nodes", () => {
    const source = "[[Page]] ((block-1)) ^^highlight^^ #tag";
    const document = parseArborMarkdown(source);
    const paragraph = document.blocks[0];

    expect(paragraph?.kind).toBe("paragraph");
    if (paragraph?.kind !== "paragraph") return;
    expect(paragraph.children.map((node) => node.kind)).toEqual([
      "page-link",
      "text",
      "block-ref",
      "text",
      "highlight",
      "text",
      "tag",
    ]);
    expect(paragraph.children[0]).toMatchObject({ target: "Page", from: 0, to: 8 });
    expect(paragraph.children[2]).toMatchObject({ target: "block-1", from: 9, to: 20 });
    expect(paragraph.children[6]).toMatchObject({ tag: "tag", from: 35, to: 39 });
  });

  it("parses headings, links, images, math, and fenced code", () => {
    const source = [
      "## Heading with [link](https://example.com)",
      "",
      "![alt](https://example.com/image.png)",
      "",
      "$x^2$ and $$sum(x)$$",
      "",
      "```ts",
      "const x = 1",
      "```",
    ].join("\n");
    const document = parseArborMarkdown(source);

    expect(document.blocks.map((block) => block.kind)).toEqual([
      "heading",
      "paragraph",
      "paragraph",
      "code-block",
    ]);
    expect(document.blocks[0]).toMatchObject({ kind: "heading", level: 2 });

    const imageParagraph = document.blocks[1];
    expect(imageParagraph?.kind === "paragraph" ? imageParagraph.children[0] : null).toMatchObject({
      kind: "image",
      alt: "alt",
      src: "https://example.com/image.png",
    });

    const mathParagraph = document.blocks[2];
    expect(mathParagraph?.kind === "paragraph"
      ? mathParagraph.children.filter((node) => node.kind === "math").map((node) => node.display)
      : []).toEqual([false, true]);

    expect(document.blocks[3]).toMatchObject({
      kind: "code-block",
      language: "ts",
    });
  });

  it("keeps malformed syntax as literal text", () => {
    const source = "unfinished **bold and [[page";
    const document = parseArborMarkdown(source);
    const paragraph = document.blocks[0];

    expect(paragraph).toEqual({
      kind: "paragraph",
      from: 0,
      to: source.length,
      children: [{ kind: "text", from: 0, to: source.length }],
    });
  });
});
