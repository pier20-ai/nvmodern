import { markdownLanguage } from "@codemirror/lang-markdown";
import { parseNv3WikilinkTarget } from "./wikilinks.ts";
import {
  renderMarkdownInlineLatex,
  scanMarkdownLatex,
  type Nv3InlineLatexRenderSegment,
} from "./latex.ts";

export type Nv3InlineMarkdownRenderNode =
  | Nv3InlineLatexRenderSegment
  | { kind: "strong"; children: Nv3InlineMarkdownRenderNode[] }
  | { kind: "emphasis"; children: Nv3InlineMarkdownRenderNode[] }
  | { kind: "wikilink"; text: string; target: string; from: number; to: number }
  | { kind: "code"; text: string };

type MarkdownSyntaxNode = ReturnType<typeof markdownLanguage.parser.parse>["topNode"];

function maskInlineSources(text: string): string {
  const characters = text.split("");
  const fragments = scanMarkdownLatex(text).fragments.filter(
    (fragment) => fragment.kind === "inline-dollar" || fragment.kind === "inline-paren",
  );

  for (const fragment of fragments) {
    for (let index = fragment.from; index < fragment.to; index += 1) {
      if (!/\s/.test(characters[index] ?? "")) characters[index] = "x";
    }
  }

  for (const match of text.matchAll(/\[\[([^\]\n]+?)\]\]/g)) {
    for (let index = match.index; index < match.index + match[0].length; index++) {
      characters[index] = "x";
    }
  }

  return characters.join("");
}

function appendPlainText(
  nodes: Nv3InlineMarkdownRenderNode[],
  source: string,
  from: number,
  to: number,
): void {
  if (from >= to) return;
  const text = source.slice(from, to);
  const latex = text.includes("[[") ? scanMarkdownLatex(text).fragments : [];
  let cursor = 0;
  for (const match of text.matchAll(/\[\[([^\]\n]+?)\]\]/g)) {
    if (latex.some((fragment) => fragment.from <= match.index && match.index < fragment.to)) continue;
    nodes.push(...renderMarkdownInlineLatex(text.slice(cursor, match.index)));
    const target = parseNv3WikilinkTarget(match[1]!.replace(/\\\|/g, "|"));
    nodes.push({
      kind: "wikilink",
      text: target.alias || target.core,
      target: target.raw.trim(),
      from: from + match.index,
      to: from + match.index + match[0].length,
    });
    cursor = match.index + match[0].length;
  }
  nodes.push(...renderMarkdownInlineLatex(text.slice(cursor)));
}

function markupContentBounds(
  node: MarkdownSyntaxNode,
  markName: "EmphasisMark" | "CodeMark",
): { from: number; to: number } {
  let from = node.from;
  let to = node.to;
  if (node.firstChild?.name === markName && node.firstChild.from === from) {
    from = node.firstChild.to;
  }
  if (node.lastChild?.name === markName && node.lastChild.to === to) {
    to = node.lastChild.from;
  }
  return { from, to };
}

function normalizeInlineCode(text: string): string {
  const singleLine = text.replace(/\r?\n/g, " ");
  if (
    singleLine.length >= 2 &&
    singleLine.startsWith(" ") &&
    singleLine.endsWith(" ") &&
    /\S/.test(singleLine)
  ) {
    return singleLine.slice(1, -1);
  }
  return singleLine;
}

function renderChildren(
  node: MarkdownSyntaxNode,
  source: string,
  from = node.from,
  to = node.to,
): Nv3InlineMarkdownRenderNode[] {
  const nodes: Nv3InlineMarkdownRenderNode[] = [];
  let cursor = from;

  for (let child = node.firstChild; child; child = child.nextSibling) {
    if (child.to <= from) continue;
    if (child.from >= to) break;

    if (child.from > cursor) {
      appendPlainText(nodes, source, cursor, Math.min(child.from, to));
    }

    if (child.name === "Paragraph") {
      nodes.push(...renderChildren(child, source, Math.max(from, child.from), Math.min(to, child.to)));
    } else if (child.name === "StrongEmphasis" || child.name === "Emphasis") {
      const bounds = markupContentBounds(child, "EmphasisMark");
      nodes.push({
        kind: child.name === "StrongEmphasis" ? "strong" : "emphasis",
        children: renderChildren(child, source, bounds.from, bounds.to),
      });
    } else if (child.name === "InlineCode") {
      const bounds = markupContentBounds(child, "CodeMark");
      nodes.push({
        kind: "code",
        text: normalizeInlineCode(source.slice(bounds.from, bounds.to)),
      });
    } else if (child.name !== "EmphasisMark" && child.name !== "CodeMark") {
      appendPlainText(nodes, source, Math.max(from, child.from), Math.min(to, child.to));
    }

    cursor = Math.max(cursor, Math.min(child.to, to));
  }

  appendPlainText(nodes, source, cursor, to);
  return nodes;
}

/** Parses the small inline Markdown subset rendered by embedded table cells. */
export function renderBasicInlineMarkdown(text: string): Nv3InlineMarkdownRenderNode[] {
  if (!text) return [];
  if (!/[`*_]/.test(text)) {
    const nodes: Nv3InlineMarkdownRenderNode[] = [];
    appendPlainText(nodes, text, 0, text.length);
    return nodes;
  }
  const tree = markdownLanguage.parser.parse(maskInlineSources(text));
  return renderChildren(tree.topNode, text);
}
