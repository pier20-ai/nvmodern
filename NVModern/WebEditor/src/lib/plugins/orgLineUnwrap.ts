import { StateField, type EditorState, type Extension, type Text } from "@codemirror/state";
import { EditorView, type DecorationSet } from "@codemirror/view";
import { getOrgSyntax, getOrgSyntaxForState, orgSyntaxExtension } from "../org/orgSyntax.ts";
import {
  collectParagraphLineUnwrapRanges,
  buildLineUnwrapDecorations,
  leadingWhitespaceOffset,
  type LineUnwrapParagraphRange,
  type MarkdownLineUnwrapRange,
} from "./markdownLineUnwrap.ts";

const linePreservingNodeTypes = new Set([
  "comment-block",
  "example-block",
  "export-block",
  "fixed-width",
  "src-block",
  "verse-block",
]);

const paragraphCache = new WeakMap<Text, LineUnwrapParagraphRange[]>();

function paragraphRanges(doc: Text): LineUnwrapParagraphRange[] {
  const cached = paragraphCache.get(doc);
  if (cached) return cached;
  const { source, tree } = getOrgSyntax(doc);
  const ranges: LineUnwrapParagraphRange[] = [];

  function visit(node: any, preservesLines = false): void {
    const nextPreservesLines = preservesLines || linePreservingNodeTypes.has(node.type);
    const from = node.position?.start?.offset;
    const rawTo = node.position?.end?.offset;

    if (
      node.type === "paragraph"
      && !nextPreservesLines
      && typeof from === "number"
      && typeof rawTo === "number"
    ) {
      let to = rawTo;
      while (to > from && (source[to - 1] === "\n" || source[to - 1] === "\r")) to -= 1;
      if (to > from) ranges.push({ from, to });
      return;
    }

    for (const child of node.children ?? []) visit(child, nextPreservesLines);
  }

  visit(tree);
  paragraphCache.set(doc, ranges);
  return ranges;
}

function isOrgHardBreak(line: string): boolean {
  let trailingBackslashes = 0;
  for (let index = line.length - 1; index >= 0 && line[index] === "\\"; index -= 1) {
    trailingBackslashes += 1;
  }
  return trailingBackslashes >= 2;
}

export function collectOrgLineUnwrapRanges(state: Pick<EditorState, "doc">): MarkdownLineUnwrapRange[] {
  return collectParagraphLineUnwrapRanges(
    state,
    paragraphRanges(state.doc),
    isOrgHardBreak,
    leadingWhitespaceOffset,
  );
}

function decorations(state: EditorState): DecorationSet {
  getOrgSyntaxForState(state);
  return buildLineUnwrapDecorations(collectOrgLineUnwrapRanges(state));
}

const unwrapField = StateField.define<DecorationSet>({
  create: decorations,
  update(value, transaction) {
    return transaction.docChanged ? decorations(transaction.state) : value;
  },
  provide: (field) => EditorView.decorations.from(field),
});

export function createOrgLineUnwrapExtension(): Extension {
  return [orgSyntaxExtension, unwrapField];
}
