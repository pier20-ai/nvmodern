import {
  GFM,
  type DelimiterType,
  type InlineContext,
  type MarkdownConfig,
  parser as commonMarkParser,
} from "@lezer/markdown";
import type {
  ArborMarkdownBlock,
  ArborMarkdownDocument,
  ArborMarkdownInline,
} from "./types.ts";

const highlightDelimiter: DelimiterType = {
  resolve: "Highlight",
  mark: "HighlightMark",
};

function closedToken(
  cx: InlineContext,
  pos: number,
  open: string,
  close: string,
): number {
  if (cx.slice(pos, pos + open.length) !== open) return -1;
  const relativeEnd = cx.text.indexOf(close, pos - cx.offset + open.length);
  return relativeEnd < 0 ? -1 : cx.offset + relativeEnd + close.length;
}

function isTagStart(character: number): boolean {
  return character >= 0 && /[\p{L}\p{N}]/u.test(String.fromCharCode(character));
}

function isTagCharacter(character: number): boolean {
  return character >= 0 && /[\p{L}\p{N}_/-]/u.test(String.fromCharCode(character));
}

const arborSyntax: MarkdownConfig = {
  defineNodes: [
    "PageLink",
    "BlockRef",
    "Tag",
    "Highlight",
    "HighlightMark",
    "InlineMath",
    "DisplayMath",
  ],
  parseInline: [
    {
      name: "ArborPageLink",
      before: "Link",
      parse(cx, next, pos) {
        if (next !== 91) return -1;
        const end = closedToken(cx, pos, "[[", "]]");
        return end < 0 ? -1 : cx.addElement(cx.elt("PageLink", pos, end));
      },
    },
    {
      name: "ArborBlockRef",
      parse(cx, next, pos) {
        if (next !== 40) return -1;
        const end = closedToken(cx, pos, "((", "))");
        return end < 0 ? -1 : cx.addElement(cx.elt("BlockRef", pos, end));
      },
    },
    {
      name: "ArborHighlight",
      before: "Emphasis",
      parse(cx, next, pos) {
        if (next !== 94 || cx.char(pos + 1) !== 94) return -1;
        return cx.addDelimiter(highlightDelimiter, pos, pos + 2, true, true);
      },
    },
    {
      name: "ArborMath",
      before: "Emphasis",
      parse(cx, next, pos) {
        if (next !== 36) return -1;
        const display = cx.char(pos + 1) === 36;
        const markerLength = display ? 2 : 1;
        let cursor = pos + markerLength;
        while (cursor < cx.end) {
          if (
            cx.char(cursor) === 36 &&
            (!display || cx.char(cursor + 1) === 36) &&
            cx.char(cursor - 1) !== 92
          ) {
            const end = cursor + markerLength;
            return cx.addElement(cx.elt(display ? "DisplayMath" : "InlineMath", pos, end));
          }
          cursor += 1;
        }
        return -1;
      },
    },
    {
      name: "ArborTag",
      parse(cx, next, pos) {
        if (next !== 35 || isTagCharacter(cx.char(pos - 1))) return -1;
        let cursor = pos + 1;
        if (!isTagStart(cx.char(cursor))) return -1;
        while (cursor < cx.end && isTagCharacter(cx.char(cursor))) cursor += 1;
        return cx.addElement(cx.elt("Tag", pos, cursor));
      },
    },
  ],
};

const markdownParser = commonMarkParser.configure([GFM, arborSyntax]);
type SyntaxNode = ReturnType<typeof markdownParser.parse>["topNode"];

class AstBuilder {
  constructor(private readonly source: string) {}

  build(): ArborMarkdownDocument {
    const tree = markdownParser.parse(this.source);
    return {
      source: this.source,
      blocks: this.children(tree.topNode).map((node) => this.block(node)),
    };
  }

  private children(node: SyntaxNode): SyntaxNode[] {
    const result: SyntaxNode[] = [];
    for (let child = node.firstChild; child; child = child.nextSibling) result.push(child);
    return result;
  }

  private plainText(from: number, to: number): ArborMarkdownInline | null {
    return from < to ? { kind: "text", from, to } : null;
  }

  private inlineChildren(
    parent: SyntaxNode,
    from = parent.from,
    to = parent.to,
  ): ArborMarkdownInline[] {
    const result: ArborMarkdownInline[] = [];
    let cursor = from;

    for (const child of this.children(parent)) {
      if (child.to <= from || child.from >= to) continue;

      const before = this.plainText(cursor, Math.min(child.from, to));
      if (before) result.push(before);

      const parsed = this.inline(child);
      if (parsed) {
        result.push(parsed);
      } else {
        const literal = this.plainText(Math.max(cursor, child.from), Math.min(child.to, to));
        if (literal) result.push(literal);
      }
      cursor = Math.max(cursor, Math.min(child.to, to));
    }

    const tail = this.plainText(cursor, to);
    if (tail) result.push(tail);
    return result;
  }

  private wrapped(
    kind: "strong" | "emphasis" | "strikethrough" | "highlight",
    node: SyntaxNode,
    markName: string,
  ): ArborMarkdownInline {
    const marks = this.children(node).filter((child) => child.name === markName);
    return {
      kind,
      from: node.from,
      to: node.to,
      children: this.inlineChildren(
        node,
        marks[0]?.to ?? node.from,
        marks.at(-1)?.from ?? node.to,
      ),
    };
  }

  private link(node: SyntaxNode): ArborMarkdownInline {
    const children = this.children(node);
    const marks = children.filter((child) => child.name === "LinkMark");
    const url = children.find((child) => child.name === "URL");
    const labelFrom = marks[0]?.to ?? node.from;
    const labelTo = marks[1]?.from ?? labelFrom;
    return {
      kind: "link",
      from: node.from,
      to: node.to,
      href: url ? this.source.slice(url.from, url.to) : "",
      children: this.inlineChildren(node, labelFrom, labelTo),
    };
  }

  private inline(node: SyntaxNode): ArborMarkdownInline | null {
    switch (node.name) {
      case "StrongEmphasis":
        return this.wrapped("strong", node, "EmphasisMark");
      case "Emphasis":
        return this.wrapped("emphasis", node, "EmphasisMark");
      case "Strikethrough":
        return this.wrapped("strikethrough", node, "StrikethroughMark");
      case "Highlight":
        return this.wrapped("highlight", node, "HighlightMark");
      case "InlineCode": {
        const marks = this.children(node).filter((child) => child.name === "CodeMark");
        return {
          kind: "code",
          from: node.from,
          to: node.to,
          contentFrom: marks[0]?.to ?? node.from,
          contentTo: marks.at(-1)?.from ?? node.to,
        };
      }
      case "PageLink":
        return {
          kind: "page-link",
          from: node.from,
          to: node.to,
          target: this.source.slice(node.from + 2, node.to - 2).trim(),
        };
      case "BlockRef":
        return {
          kind: "block-ref",
          from: node.from,
          to: node.to,
          target: this.source.slice(node.from + 2, node.to - 2).trim(),
        };
      case "Tag":
        return {
          kind: "tag",
          from: node.from,
          to: node.to,
          tag: this.source.slice(node.from + 1, node.to),
        };
      case "Link":
        return this.link(node);
      case "Image": {
        const children = this.children(node);
        const marks = children.filter((child) => child.name === "LinkMark");
        const url = children.find((child) => child.name === "URL");
        return {
          kind: "image",
          from: node.from,
          to: node.to,
          alt: this.source.slice(marks[0]?.to ?? node.from, marks[1]?.from ?? node.from),
          src: url ? this.source.slice(url.from, url.to) : "",
        };
      }
      case "InlineMath":
      case "DisplayMath": {
        const markerLength = node.name === "DisplayMath" ? 2 : 1;
        return {
          kind: "math",
          from: node.from,
          to: node.to,
          contentFrom: node.from + markerLength,
          contentTo: node.to - markerLength,
          display: node.name === "DisplayMath",
        };
      }
      default:
        return null;
    }
  }

  private block(node: SyntaxNode): ArborMarkdownBlock {
    if (node.name === "Paragraph") {
      return {
        kind: "paragraph",
        from: node.from,
        to: node.to,
        children: this.inlineChildren(node),
      };
    }

    const heading = node.name.match(/^ATXHeading([1-6])$/);
    if (heading) {
      const mark = this.children(node).find((child) => child.name === "HeaderMark");
      let contentFrom = mark?.to ?? node.from;
      while (contentFrom < node.to && /\s/.test(this.source[contentFrom] ?? "")) contentFrom += 1;
      return {
        kind: "heading",
        from: node.from,
        to: node.to,
        level: Number(heading[1]) as 1 | 2 | 3 | 4 | 5 | 6,
        children: this.inlineChildren(node, contentFrom, node.to),
      };
    }

    if (node.name === "FencedCode") {
      const children = this.children(node);
      const code = children.find((child) => child.name === "CodeText");
      const info = children.find((child) => child.name === "CodeInfo");
      return {
        kind: "code-block",
        from: node.from,
        to: node.to,
        codeFrom: code?.from ?? node.from,
        codeTo: code?.to ?? node.to,
        language: info ? this.source.slice(info.from, info.to).trim() || null : null,
      };
    }

    return { kind: "text-block", from: node.from, to: node.to };
  }
}

export function parseArborMarkdown(source: string): ArborMarkdownDocument {
  return new AstBuilder(source).build();
}
