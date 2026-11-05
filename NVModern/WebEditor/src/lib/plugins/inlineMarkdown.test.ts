import { describe, expect, it } from "bun:test";
import { renderBasicInlineMarkdown, type Nv3InlineMarkdownRenderNode } from "./inlineMarkdown.ts";

function visibleText(nodes: readonly Nv3InlineMarkdownRenderNode[]): string {
  return nodes.map((node) => {
    if (node.kind === "strong" || node.kind === "emphasis") return visibleText(node.children);
    if (node.kind === "latex") return node.source;
    return node.text;
  }).join("");
}

describe("renderBasicInlineMarkdown", () => {
  it("preserves bold currency and duration text alongside real inline math", () => {
    const nodes = renderBasicInlineMarkdown("Costs **$500k–$5M+**, takes **6–18 months**, and uses ($\\pi_{0.6}\\text{ +UPT}$).");
    expect(nodes.filter((node) => node.kind === "strong").map((node) => visibleText(node.children)))
      .toEqual(["$500k–$5M+", "6–18 months"]);
    expect(nodes.filter((node) => node.kind === "latex").map((node) => node.source))
      .toEqual([String.raw`$\pi_{0.6}\text{ +UPT}$`]);
  });

  it("retains navigation targets and exact source ranges for titled and untitled links", () => {
    const source = "😀 **[[folder/note#Heading|Title]]** and [[other#^block]]";
    const nodes = renderBasicInlineMarkdown(source);
    const strong = nodes.find((node) => node.kind === "strong");
    const first = strong?.kind === "strong" ? strong.children.find((node) => node.kind === "wikilink") : null;
    const second = nodes.find((node) => node.kind === "wikilink");
    expect(first).toMatchObject({ kind: "wikilink", target: "folder/note#Heading|Title", text: "Title" });
    expect(second).toMatchObject({ kind: "wikilink", target: "other#^block", text: "other#^block" });
    for (const node of [first, second]) {
      if (node?.kind !== "wikilink") throw new Error("Expected a navigable wikilink");
      expect(source.slice(node.from, node.to)).toBe(`[[${node.target}]]`);
    }
  });

  it("shows wikilink titles and uses the target when no title exists", () => {
    expect(visibleText(renderBasicInlineMarkdown(
      "See [[papers/context/note|Friendly title]], [[note#Heading]], and [[other| ]].",
    ))).toBe("See Friendly title, note#Heading, and other.");
  });

  it("keeps Markdown markers inside wikilink targets out of inline formatting", () => {
    const nodes = renderBasicInlineMarkdown("**See [[a_path_*name|Friendly_title]]**");
    expect(nodes[0]?.kind).toBe("strong");
    expect(visibleText(nodes)).toBe("See Friendly_title");
  });

  it("accepts escaped table alias separators and keeps links in code literal", () => {
    expect(visibleText(renderBasicInlineMarkdown("[[note\\|Title]]"))).toBe("Title");
    expect(renderBasicInlineMarkdown("`[[note|Title]]`")).toEqual([
      { kind: "code", text: "[[note|Title]]" },
    ]);
  });

  it("keeps LaTeX containing wikilink-like brackets intact", () => {
    const nodes = renderBasicInlineMarkdown("$[[x|y]]$ and [[note|Title]]");
    expect(nodes[0]?.kind).toBe("latex");
    expect(visibleText(nodes)).toBe("$[[x|y]]$ and Title");
  });

  it("parses bold, italic, and inline code while keeping surrounding prose", () => {
    const nodes = renderBasicInlineMarkdown("plain **bold** and *italic* with `code`");

    expect(nodes.map((node) => node.kind)).toEqual([
      "text",
      "strong",
      "text",
      "emphasis",
      "text",
      "code",
    ]);
    expect(visibleText(nodes)).toBe("plain bold and italic with code");
  });

  it("renders LaTeX inside emphasis without treating TeX underscores as Markdown", () => {
    const nodes = renderBasicInlineMarkdown("**gain $x_y$** and $z_k$");
    const strong = nodes.find((node) => node.kind === "strong");

    expect(strong?.kind).toBe("strong");
    expect(strong?.kind === "strong" ? strong.children.map((node) => node.kind) : []).toEqual([
      "text",
      "latex",
    ]);
    expect(nodes.at(-1)?.kind).toBe("latex");
  });

  it("does not parse Markdown or LaTeX inside inline code", () => {
    expect(renderBasicInlineMarkdown("`**raw** $x$`")).toEqual([
      { kind: "code", text: "**raw** $x$" },
    ]);
  });

  it("leaves unmatched delimiters visible", () => {
    expect(renderBasicInlineMarkdown("unfinished **bold")).toEqual([
      { kind: "text", text: "unfinished **bold" },
    ]);
  });
});
