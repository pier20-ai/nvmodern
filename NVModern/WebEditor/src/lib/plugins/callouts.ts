/**
 * CM-safe markdown callout rendering.
 *
 * Historical context:
 * - nvModern wants Obsidian-style callouts such as:
 *     > [!note]
 *     > body
 *   but the underlying markdown parser does not have native callout syntax.
 * - We first implemented this as a styling-focused feature layered on top of blockquotes.
 *   That part worked, but more aggressive line box styling (`margin-top`, vertical padding,
 *   and horizontal padding on `.cm-line`) caused CodeMirror vertical cursor movement to
 *   become unstable. In particular, `ArrowUp` from lines below a callout could jump to a
 *   position before the callout instead of into it.
 * - The lesson was the same as for list rendering: keep the document's text geometry close
 *   to what CodeMirror expects, and prefer conservative visual treatment over layout tricks.
 *
 * Current strategy:
 * - Parse callouts from raw markdown lines, not from custom syntax nodes.
 * - Build decorations once for the whole document at state creation time, and rebuild only
 *   on `docChanged`.
 * - Avoid any viewport-scoped work. Initial render can do more work; scrolling and editing
 *   should stay smooth.
 * - Use only `Decoration.line(...)` and `Decoration.mark(...)`.
 * - Keep the source markdown in normal flow. Do not replace or hide structural text.
 * - Keep line-level styling conservative: tint/background, subtle accenting, and inline
 *   marker/title styling are fine; spacing changes that alter line geometry are not.
 *
 * Supported syntax:
 * - Header line:
 *     > [!type]
 *     > [!type] Optional title
 * - Body:
 *   continues through subsequent quoted lines whose blockquote depth is the same as or
 *   deeper than the header's depth.
 * - Example:
 *     > [!info] Title
 *     > body
 *     > > nested quote still inside
 *
 * Important invariants / regression guardrails:
 * - Do not use widgets for the callout container.
 * - Do not use `Decoration.replace(...)`.
 * - Do not hide or rewrite the `>` prefix or `[!type]` marker structurally (visual
 *   treatment via CSS — e.g. transparent until active line — is fine).
 * - Do not add `margin-top`, vertical padding, or other line box-model changes to
 *   `.cm-line.nv3-callout-*` / `.cm-line.nv3-blockquote-*` without re-testing `ArrowUp` /
 *   `ArrowDown` carefully.
 * - Emit ranges into `RangeSetBuilder` strictly in document order. If header decorations are
 *   added after later line decorations, CM will throw because ranges must be sorted.
 * - Keep parsing independent of the markdown parser's native link handling. Bare `[!note]`
 *   must remain available for callouts, while nvModern's own scanner/decorator path continues
 *   to own `[[...]]`, `![[...]]`, `[...] (...)`, and `![...](...)` behavior.
 *
 * If you modify this later, preserve the main invariant:
 *   cursor movement and scroll correctness beat visual cleverness.
 */
import { EditorState, StateField, type Extension, type Text } from "@codemirror/state";
import {
  Decoration,
  EditorView,
  highlightActiveLine,
  type DecorationSet,
  ViewPlugin,
  type ViewUpdate,
} from "@codemirror/view";
import { RangeSetBuilder } from "@codemirror/state";
import { createMarkdownScannerContext, isMarkdownLineScannable } from "./scannerContext.ts";

const BLOCKQUOTE_PREFIX_PATTERN = /^(?:[\t ]{0,3}> ?)+/;
const CALLOUT_HEADER_PATTERN = /^\[!([A-Za-z][\w-]*)\](?:[ \t]+(.*?))?[ \t]*$/;

const lineDecorationCache = new Map<string, Decoration>();
const markDecorationCache = new Map<string, Decoration>();

export interface Nv3MarkdownCalloutBlock {
  type: string;
  title: string | null;
  depth: number;
  fromLine: number;
  toLine: number;
  headerFrom: number;
  headerTo: number;
  markerFrom: number;
  markerTo: number;
  titleFrom: number | null;
  titleTo: number | null;
}

interface BlockquoteLineMeta {
  prefix: string;
  prefixLength: number;
  depth: number;
  content: string;
}

interface Nv3MarkdownCalloutState {
  blocks: readonly Nv3MarkdownCalloutBlock[];
  decorations: DecorationSet;
}

export interface MarkdownCalloutExtensionOptions {
  onChange?: (blocks: readonly Nv3MarkdownCalloutBlock[]) => void;
}

function blockquoteLineMeta(text: string): BlockquoteLineMeta | null {
  const prefix = text.match(BLOCKQUOTE_PREFIX_PATTERN)?.[0] ?? "";
  if (!prefix) return null;

  return {
    prefix,
    prefixLength: prefix.length,
    depth: [...prefix].filter((char) => char === ">").length,
    content: text.slice(prefix.length),
  };
}

function normalizeCalloutType(type: string): string {
  return type.trim().toLowerCase();
}

function calloutTypeClass(type: string): string {
  return normalizeCalloutType(type).replace(/[^a-z0-9_-]+/g, "-");
}

export function scanMarkdownCallouts(doc: Text | string): Nv3MarkdownCalloutBlock[] {
  const textDoc = typeof doc === "string" ? EditorState.create({ doc }).doc : doc;
  const context = createMarkdownScannerContext(textDoc);
  const blocks: Nv3MarkdownCalloutBlock[] = [];

  for (let index = 0; index < context.lines.length; index += 1) {
    const line = context.lines[index];
    if (!isMarkdownLineScannable(line)) continue;

    const meta = blockquoteLineMeta(line.text);
    if (!meta) continue;

    const headerMatch = meta.content.match(CALLOUT_HEADER_PATTERN);
    if (!headerMatch) continue;

    const rawType = headerMatch[1] ?? "note";
    const type = normalizeCalloutType(rawType);
    const markerText = `[!${rawType}]`;
    const markerFrom = line.from + meta.prefixLength;
    const markerTo = markerFrom + markerText.length;

    const titleText = headerMatch[2] ?? "";
    const title = titleText.trim() || null;
    const titleStartInContent = titleText ? meta.content.indexOf(titleText, markerText.length) : -1;
    const titleFrom = titleStartInContent >= 0 ? line.from + meta.prefixLength + titleStartInContent : null;
    const titleTo = titleFrom !== null ? titleFrom + titleText.length : null;

    let toLine = line.lineNo;
    for (let nextIndex = index + 1; nextIndex < context.lines.length; nextIndex += 1) {
      const nextLine = context.lines[nextIndex];
      if (!isMarkdownLineScannable(nextLine)) break;

      const nextMeta = blockquoteLineMeta(nextLine.text);
      if (!nextMeta || nextMeta.depth < meta.depth) break;

      toLine = nextLine.lineNo;
      index = nextIndex;
    }

    blocks.push({
      type,
      title,
      depth: meta.depth,
      fromLine: line.lineNo,
      toLine,
      headerFrom: line.from + meta.prefixLength,
      headerTo: line.to,
      markerFrom,
      markerTo,
      titleFrom,
      titleTo,
    });
  }

  return blocks;
}

function lineDecoration(className: string, style = ""): Decoration {
  const key = style ? `${className}@@${style}` : className;
  const cached = lineDecorationCache.get(key);
  if (cached) return cached;

  const decoration = Decoration.line({
    attributes: {
      class: className,
      style,
    },
  });
  lineDecorationCache.set(key, decoration);
  return decoration;
}

function markDecoration(className: string): Decoration {
  const cached = markDecorationCache.get(className);
  if (cached) return cached;

  const decoration = Decoration.mark({ class: className });
  markDecorationCache.set(className, decoration);
  return decoration;
}

interface DecorationChunk {
  from: number;
  to: number;
  decoration: Decoration;
}

function buildCalloutState(state: EditorState): Nv3MarkdownCalloutState {
  const blocks = scanMarkdownCallouts(state.doc);
  const chunks: DecorationChunk[] = [];

  const calloutLines = new Set<number>();
  for (const block of blocks) {
    for (let lineNo = block.fromLine; lineNo <= block.toLine; lineNo += 1) {
      calloutLines.add(lineNo);
    }
  }

  for (const block of blocks) {
    const typeClass = `nv3-callout-type-${calloutTypeClass(block.type)}`;

    for (let lineNo = block.fromLine; lineNo <= block.toLine; lineNo += 1) {
      const line = state.doc.line(lineNo);
      const meta = blockquoteLineMeta(line.text);
      const hasPrefix = !!(meta && meta.prefixLength > 0);
      const className = [
        "nv3-md-quote-line",
        "nv3-callout-line",
        hasPrefix ? "nv3-quote-hang-probe-line" : "",
        typeClass,
        lineNo === block.fromLine ? "nv3-md-quote-start nv3-callout-start nv3-callout-header" : "nv3-callout-body",
        lineNo === block.toLine ? "nv3-md-quote-end nv3-callout-end" : "",
      ]
        .filter(Boolean)
        .join(" ");
      const style = hasPrefix ? "--nv3-quote-prefix-width:15px;" : "";

      chunks.push({ from: line.from, to: line.from, decoration: lineDecoration(className, style) });

      if (meta && meta.prefixLength > 0) {
        chunks.push({
          from: line.from,
          to: line.from + meta.prefixLength,
          decoration: markDecoration("nv3-blockquote-prefix nv3-quote-hang-probe-prefix"),
        });
      }

      if (lineNo === block.fromLine) {
        if (block.markerFrom < block.markerTo) {
          chunks.push({
            from: block.markerFrom,
            to: block.markerTo,
            decoration: markDecoration(`nv3-callout-marker ${typeClass}`),
          });
        }

        if (block.titleFrom !== null && block.titleTo !== null && block.titleFrom < block.titleTo) {
          chunks.push({
            from: block.titleFrom,
            to: block.titleTo,
            decoration: markDecoration("nv3-callout-title"),
          });
        }
      }
    }
  }

  const context = createMarkdownScannerContext(state.doc);
  for (let index = 0; index < context.lines.length; ) {
    const line = context.lines[index];
    if (!line || !isMarkdownLineScannable(line)) {
      index += 1;
      continue;
    }

    const meta = blockquoteLineMeta(line.text);
    if (!meta || calloutLines.has(line.lineNo)) {
      index += 1;
      continue;
    }

    const startDepth = meta.depth;
    let toLine = line.lineNo;
    let scanIdx = index;
    for (let nextIndex = index + 1; nextIndex < context.lines.length; nextIndex += 1) {
      const nextLine = context.lines[nextIndex];
      if (!nextLine || !isMarkdownLineScannable(nextLine)) break;
      if (calloutLines.has(nextLine.lineNo)) break;

      const nextMeta = blockquoteLineMeta(nextLine.text);
      if (!nextMeta || nextMeta.depth < startDepth) break;

      toLine = nextLine.lineNo;
      scanIdx = nextIndex;
    }

    const startLineNo = line.lineNo;
    for (let lineNo = startLineNo; lineNo <= toLine; lineNo += 1) {
      const docLine = state.doc.line(lineNo);
      const isFirst = lineNo === startLineNo;
      const isLast = lineNo === toLine;
      const lineMeta = blockquoteLineMeta(docLine.text);
      const hasPrefix = !!(lineMeta && lineMeta.prefixLength > 0);
      const className = [
        "nv3-md-quote-line",
        "nv3-blockquote-line",
        hasPrefix ? "nv3-quote-hang-probe-line" : "",
        isFirst ? "nv3-md-quote-start nv3-blockquote-start" : "nv3-blockquote-body",
        isLast ? "nv3-md-quote-end nv3-blockquote-end" : "",
      ]
        .filter(Boolean)
        .join(" ");
      const style = hasPrefix ? "--nv3-quote-prefix-width:15px;" : "";

      chunks.push({ from: docLine.from, to: docLine.from, decoration: lineDecoration(className, style) });

      if (lineMeta && lineMeta.prefixLength > 0) {
        chunks.push({
          from: docLine.from,
          to: docLine.from + lineMeta.prefixLength,
          decoration: markDecoration("nv3-blockquote-prefix nv3-quote-hang-probe-prefix"),
        });
      }
    }

    index = scanIdx + 1;
  }

  chunks.sort((a, b) => (a.from !== b.from ? a.from - b.from : a.to - b.to));

  const builder = new RangeSetBuilder<Decoration>();
  for (const chunk of chunks) {
    builder.add(chunk.from, chunk.to, chunk.decoration);
  }

  return {
    blocks,
    decorations: builder.finish(),
  };
}

const markdownCalloutStateField = StateField.define<Nv3MarkdownCalloutState>({
  create(state) {
    return buildCalloutState(state);
  },

  update(value, transaction) {
    if (!transaction.docChanged) return value;
    return buildCalloutState(transaction.state);
  },

  provide(field) {
    return EditorView.decorations.from(field, (value) => value.decorations);
  },
});

export function getMarkdownCalloutBlocks(state: EditorState): readonly Nv3MarkdownCalloutBlock[] {
  return state.field(markdownCalloutStateField).blocks;
}

function calloutSignature(blocks: readonly Nv3MarkdownCalloutBlock[]): string {
  return blocks
    .map((block) => `${block.type}:${block.fromLine}-${block.toLine}:${block.title ?? ""}:${block.depth}`)
    .join("|");
}

export function createMarkdownCalloutExtension(
  options: MarkdownCalloutExtensionOptions = {},
): Extension {
  // Enables `.cm-activeLine` so callout blockquote prefixes can reveal on the cursor line only.
  const extensions: Extension[] = [highlightActiveLine(), markdownCalloutStateField];

  if (options.onChange) {
    const { onChange } = options;

    extensions.push(
      ViewPlugin.fromClass(
        class {
          private signature: string;

          constructor(view: import("@codemirror/view").EditorView) {
            const blocks = getMarkdownCalloutBlocks(view.state);
            this.signature = calloutSignature(blocks);
            onChange(blocks);
          }

          update(update: ViewUpdate) {
            if (!update.docChanged) return;

            const blocks = getMarkdownCalloutBlocks(update.state);
            const nextSignature = calloutSignature(blocks);
            if (nextSignature === this.signature) return;

            this.signature = nextSignature;
            onChange(blocks);
          }
        },
      ),
    );
  }

  return extensions;
}
