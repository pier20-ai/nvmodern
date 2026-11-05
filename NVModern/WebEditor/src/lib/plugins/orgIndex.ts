/**
 * Org-mode document scanning — CM6 integration.
 *
 * Parses org documents via `parseOrgText`, converts the result to a
 * `DocumentScanIndex` so generic plugins (tags, code blocks, LaTeX,
 * links, tasks) work for org files, and exposes the full
 * `Nv3OrgParseResult` through a StateField for org-specific consumers.
 */
import { StateField, type EditorState, type Extension, type Text } from "@codemirror/state";
import { ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { parseOrgText, type Nv3OrgParseResult } from "../org/parser.ts";
import {
  type DocumentScanIndex,
  type TagOccurrence,
  type HeadingOccurrence,
  type LinkOccurrence,
  type CodeBlockOccurrence,
  type TaskOccurrence,
  type LatexFragmentOccurrence,
} from "./documentIndex.ts";

// ── Adapter: Nv3OrgParseResult → DocumentScanIndex ────────────────────────

function toDocumentScanIndex(org: Nv3OrgParseResult): DocumentScanIndex {
  // Heading tags → tags (org uses :tag: syntax on heading lines)
  const headingTags: TagOccurrence[] = [];
  for (const heading of org.headings) {
    for (const tagRange of heading.tagRanges) {
      headingTags.push({
        tag: tagRange.tag,
        from: tagRange.from,
        to: tagRange.to,
        line: heading.line,
      });
    }
  }

  // Headings
  const headings: HeadingOccurrence[] = org.headings.map((h) => ({
    text: h.title,
    from: h.from,
    to: h.to,
    line: h.line,
    level: h.level,
  }));

  // Links → generic link occurrences
  const links: LinkOccurrence[] = org.links.map((l) => ({
    kind: "wikilink" as const,
    target: l.target,
    from: l.from,
    to: l.to,
    line: l.line,
  }));

  // Source blocks → code blocks
  const codeBlocks: CodeBlockOccurrence[] = org.sourceBlocks.map((b) => ({
    fromLine: b.fromLine,
    toLine: b.toLine,
    language: b.language,
    closed: b.closed,
  }));

  // List items with checklists → tasks
  const tasks: TaskOccurrence[] = [];
  for (const item of org.listItems) {
    if (item.checklist === null || item.checklistFrom === null || item.checklistTo === null) continue;
    tasks.push({
      from: item.checklistFrom,
      to: item.checklistTo,
      line: item.line,
      checked: item.checklist === "checked",
    });
  }

  // Org markups with latex kinds → LaTeX fragments
  const latexFragments: LatexFragmentOccurrence[] = [];
  for (const m of org.markups) {
    if (m.kind === "latex-dollar") {
      latexFragments.push({
        kind: "inline-dollar",
        source: m.raw,
        from: m.from,
        to: m.to,
        line: m.line,
      });
    } else if (m.kind === "latex-paren") {
      latexFragments.push({
        kind: "inline-paren",
        source: m.raw,
        from: m.from,
        to: m.to,
        line: m.line,
      });
    }
  }

  return {
    tags: [],           // org doesn't have #hashtags
    headingTags,
    mentions: [],       // org doesn't have @mentions (yet)
    tasks,
    headings,
    blockIDs: [],       // org custom IDs could be mapped here in the future
    links,
    inlineLinks: [],    // org links are all bracket-style
    codeBlocks,
    transclusions: [],  // org doesn't have ![[transclusion]] syntax
    latexFragments,
  };
}

/** Scanner function compatible with `documentScannerFacet`. */
export function orgDocumentScanner(doc: Text): DocumentScanIndex {
  return toDocumentScanIndex(parseOrgText(doc));
}

// ── Org-specific StateField (full parse result) ───────────────────────────

export const nv3OrgParseStateField = StateField.define<Nv3OrgParseResult>({
  create(state) {
    return parseOrgText(state.doc);
  },
  update(value, transaction) {
    if (!transaction.docChanged) return value;
    return parseOrgText(transaction.state.doc);
  },
});

export function getNv3OrgParseResult(state: EditorState): Nv3OrgParseResult | null {
  return state.field(nv3OrgParseStateField, false) ?? null;
}

// ── Extension ─────────────────────────────────────────────────────────────

export interface Nv3OrgParserExtensionOptions {
  onChange?: (result: Nv3OrgParseResult) => void;
}

export function createNv3OrgParserExtension(
  options: Nv3OrgParserExtensionOptions = {},
): Extension {
  const extensions: Extension[] = [nv3OrgParseStateField];

  if (options.onChange) {
    const { onChange } = options;
    extensions.push(
      ViewPlugin.fromClass(
        class {
          constructor(view: import("@codemirror/view").EditorView) {
            const result = getNv3OrgParseResult(view.state);
            if (result) onChange(result);
          }
          update(update: ViewUpdate) {
            if (!update.docChanged) return;
            const result = getNv3OrgParseResult(update.state);
            if (result) onChange(result);
          }
        },
      ),
    );
  }

  return extensions;
}
