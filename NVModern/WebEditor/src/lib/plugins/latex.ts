import katex, { type KatexOptions } from "katex";
import { type Extension } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  ViewPlugin,
  WidgetType,
  type ViewUpdate,
} from "@codemirror/view";
import {
  resolveDocumentScanIndex,
  type DocumentScanIndex,
  type LatexFragmentOccurrence,
} from "./documentIndex.ts";
import { scanMarkdownText } from "./markdownScanner.ts";
import { selectionTouchesRange } from "./viewUtils.ts";

export type Nv3LatexFragmentKind =
  | "inline-dollar"
  | "inline-paren"
  | "block-dollar"
  | "block-bracket";

export interface Nv3LatexFragment {
  kind: Nv3LatexFragmentKind;
  source: string;
  from: number;
  to: number;
  line: number;
  toLine?: number;
}

export interface Nv3LatexIndex {
  count: number;
  inlineCount: number;
  blockCount: number;
  fragments: Nv3LatexFragment[];
}

export type Nv3LatexPreviewMode = "none" | "katex";

export interface MarkdownLatexOptions {
  onChange?: (index: Nv3LatexIndex) => void;
  previewMode?: Nv3LatexPreviewMode;
  katexOptions?: KatexOptions;
  renderCacheLimit?: number;
}

export type Nv3InlineLatexRenderSegment =
  | { kind: "text"; text: string }
  | { kind: "latex"; source: string; html: string };

// ── Decorations ───────────────────────────────────────────────────────────

const inlineMathDecoration = Decoration.mark({ class: "nv3-latex-fragment" });
const blockMathDecoration = Decoration.mark({ class: "nv3-latex-block" });
const blockStartLineDecoration = Decoration.line({ class: "nv3-math-block-line nv3-math-block-start" });
const blockBodyLineDecoration = Decoration.line({ class: "nv3-math-block-line nv3-math-block-body" });
const blockEndLineDecoration = Decoration.line({ class: "nv3-math-block-line nv3-math-block-end" });
const blockSingleLineDecoration = Decoration.line({ class: "nv3-math-block-line nv3-math-block-start nv3-math-block-end" });
const hiddenSourceDecoration = Decoration.mark({ class: "nv3-latex-source-hidden" });

// ── KaTeX render cache ────────────────────────────────────────────────────

const DEFAULT_RENDER_CACHE_LIMIT = 4_000;
const renderCache = new Map<string, string | null>();

function lruGet(key: string): string | null | undefined {
  const cached = renderCache.get(key);
  if (cached === undefined) return undefined;
  renderCache.delete(key);
  renderCache.set(key, cached);
  return cached;
}

function lruSet(key: string, value: string | null, limit: number): void {
  if (renderCache.has(key)) renderCache.delete(key);
  renderCache.set(key, value);
  while (renderCache.size > limit) {
    const oldest = renderCache.keys().next().value;
    if (!oldest) break;
    renderCache.delete(oldest);
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────

function isBlockFragment(fragment: LatexFragmentOccurrence): boolean {
  return fragment.kind === "block-dollar" || fragment.kind === "block-bracket";
}

function stripDelimiters(fragment: LatexFragmentOccurrence): string {
  const source = fragment.source.trim();
  switch (fragment.kind) {
    case "inline-dollar":
      return source.startsWith("$") && source.endsWith("$") ? source.slice(1, -1) : source;
    case "inline-paren":
      return source.startsWith("\\(") && source.endsWith("\\)") ? source.slice(2, -2) : source;
    case "block-dollar":
      return source.startsWith("$$") && source.endsWith("$$") ? source.slice(2, -2).trim() : source;
    case "block-bracket":
      return source.startsWith("\\[") && source.endsWith("\\]") ? source.slice(2, -2).trim() : source;
    default:
      return source;
  }
}

function latexSignature(index: Nv3LatexIndex): string {
  const body = index.fragments
    .map((f) => `${f.kind}:${f.from}:${f.to}`)
    .join("|");
  return `${index.count}:${index.inlineCount}:${index.blockCount}:${body}`;
}

function latexIndexFromFragments(fragments: readonly LatexFragmentOccurrence[]): Nv3LatexIndex {
  const mapped: Nv3LatexFragment[] = fragments.map((f) => ({
    kind: f.kind,
    source: f.source,
    from: f.from,
    to: f.to,
    line: f.line,
    toLine: f.toLine,
  }));

  const inlineCount = mapped.filter(
    (f) => f.kind === "inline-dollar" || f.kind === "inline-paren",
  ).length;

  return {
    count: mapped.length,
    inlineCount,
    blockCount: mapped.length - inlineCount,
    fragments: mapped,
  };
}

function resolveLatexIndex(state: import("@codemirror/state").EditorState): Nv3LatexIndex {
  return latexIndexFromFragments(resolveDocumentScanIndex(state).latexFragments);
}

// ── KaTeX preview widget ──────────────────────────────────────────────────

class LatexPreviewWidget extends WidgetType {
  constructor(
    readonly html: string,
    readonly block: boolean,
    readonly from: number,
    readonly to: number,
  ) {
    super();
  }

  override eq(other: LatexPreviewWidget): boolean {
    return other.html === this.html && other.block === this.block && other.from === this.from && other.to === this.to;
  }

  override toDOM(): HTMLElement {
    const node = document.createElement(this.block ? "div" : "span");
    node.className = this.block ? "nv3-latex-preview nv3-latex-preview-block" : "nv3-latex-preview nv3-latex-preview-inline";
    node.innerHTML = this.html;
    node.setAttribute("data-nv3-latex-fragment", "true");
    node.setAttribute("data-nv3-latex-from", String(this.from));
    node.setAttribute("data-nv3-latex-to", String(this.to));
    return node;
  }

  override ignoreEvent(): boolean {
    return false;
  }
}

function renderKatexHtml(
  fragment: LatexFragmentOccurrence,
  options: MarkdownLatexOptions,
): string | null {
  const expression = stripDelimiters(fragment);
  if (!expression.trim()) return null;

  const displayMode = isBlockFragment(fragment);
  const key = `${displayMode ? "block" : "inline"}:${expression}`;
  const cached = lruGet(key);
  if (cached !== undefined) return cached;

  const limit = options.renderCacheLimit ?? DEFAULT_RENDER_CACHE_LIMIT;

  try {
    const html = katex.renderToString(expression, {
      throwOnError: false,
      displayMode,
      ...(options.katexOptions ?? {}),
    });
    lruSet(key, html, limit);
    return html;
  } catch {
    lruSet(key, null, limit);
    return null;
  }
}

/**
 * Renders inline LaTeX embedded in a plain-text surface such as a table cell.
 * The caller remains responsible for inserting prose as text nodes and may
 * insert the returned KaTeX HTML into a dedicated element.
 */
export function renderMarkdownInlineLatex(
  text: string,
  options: MarkdownLatexOptions = {},
): Nv3InlineLatexRenderSegment[] {
  if (!text.includes("$") && !text.includes("\\(")) {
    return text ? [{ kind: "text", text }] : [];
  }

  const fragments = scanMarkdownText(text).latexFragments.filter(
    (fragment) => fragment.kind === "inline-dollar" || fragment.kind === "inline-paren",
  );
  if (!fragments.length) {
    return text ? [{ kind: "text", text }] : [];
  }

  const segments: Nv3InlineLatexRenderSegment[] = [];
  let cursor = 0;

  for (const fragment of fragments) {
    if (fragment.from < cursor || fragment.to > text.length) continue;
    if (fragment.from > cursor) {
      segments.push({ kind: "text", text: text.slice(cursor, fragment.from) });
    }

    const html = renderKatexHtml(fragment, options);
    if (html) {
      segments.push({ kind: "latex", source: fragment.source, html });
    } else {
      segments.push({ kind: "text", text: fragment.source });
    }
    cursor = fragment.to;
  }

  if (cursor < text.length) {
    segments.push({ kind: "text", text: text.slice(cursor) });
  }

  return segments;
}

// ── Decoration building ───────────────────────────────────────────────────

function addBlockLineDecorations(
  doc: import("@codemirror/state").Text,
  fragment: LatexFragmentOccurrence,
  ranges: Array<import("@codemirror/state").Range<Decoration>>,
): void {
  if (!isBlockFragment(fragment)) return;

  const fromLine = fragment.line;
  const toLine = fragment.toLine ?? fragment.line;

  for (let lineNo = fromLine; lineNo <= toLine; lineNo++) {
    if (lineNo < 1 || lineNo > doc.lines) continue;
    const line = doc.line(lineNo);
    const isStart = lineNo === fromLine;
    const isEnd = lineNo === toLine;

    let dec = blockBodyLineDecoration;
    if (isStart && isEnd) dec = blockSingleLineDecoration;
    else if (isStart) dec = blockStartLineDecoration;
    else if (isEnd) dec = blockEndLineDecoration;

    ranges.push(dec.range(line.from));
  }
}

function addCollapsedBlockSourceLines(
  doc: import("@codemirror/state").Text,
  fragment: LatexFragmentOccurrence,
  ranges: Array<import("@codemirror/state").Range<Decoration>>,
): void {
  if (!isBlockFragment(fragment)) return;

  const fromLine = fragment.line;
  const toLine = fragment.toLine ?? fragment.line;

  for (let lineNo = fromLine + 1; lineNo <= toLine; lineNo++) {
    if (lineNo < 1 || lineNo > doc.lines) continue;
    const line = doc.line(lineNo);
    ranges.push(Decoration.line({ class: "nv3-latex-source-collapsed-line" }).range(line.from));
  }
}

function buildLatexDecorations(
  state: import("@codemirror/state").EditorState,
  index: Nv3LatexIndex,
  options: MarkdownLatexOptions,
): DecorationSet {
  const previewMode = options.previewMode ?? "none";
  const previewEnabled = previewMode === "katex";
  const ranges: Array<import("@codemirror/state").Range<Decoration>> = [];
  const selRanges = state.selection.ranges;

  for (const fragment of index.fragments) {
    const block = isBlockFragment(fragment);
    const selected = selectionTouchesRange(selRanges, fragment.from, fragment.to);

    if (!previewEnabled || selected) {
      if (block) addBlockLineDecorations(state.doc, fragment, ranges);
      ranges.push((block ? blockMathDecoration : inlineMathDecoration).range(fragment.from, fragment.to));
      continue;
    }

    const html = renderKatexHtml(fragment, options);
    if (!html) {
      if (block) addBlockLineDecorations(state.doc, fragment, ranges);
      ranges.push((block ? blockMathDecoration : inlineMathDecoration).range(fragment.from, fragment.to));
      continue;
    }

    if (!block) {
      ranges.push(Decoration.replace({ widget: new LatexPreviewWidget(html, false, fragment.from, fragment.to) }).range(fragment.from, fragment.to));
      continue;
    }

    ranges.push(hiddenSourceDecoration.range(fragment.from, fragment.to));
    addCollapsedBlockSourceLines(state.doc, fragment, ranges);
    ranges.push(Decoration.widget({ widget: new LatexPreviewWidget(html, true, fragment.from, fragment.to), side: -1 }).range(fragment.from));
  }

  return Decoration.set(ranges, true);
}

// ── Public API ────────────────────────────────────────────────────────────

export function scanMarkdownLatex(docText: string): Nv3LatexIndex {
  return latexIndexFromFragments(scanMarkdownText(docText).latexFragments);
}

export function createMarkdownLatexExtension(options: MarkdownLatexOptions = {}): Extension {
  const { onChange } = options;
  const previewEnabled = (options.previewMode ?? "none") === "katex";

  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      index: Nv3LatexIndex;
      private signature: string;

      constructor(view: import("@codemirror/view").EditorView) {
        this.index = resolveLatexIndex(view.state);
        this.decorations = buildLatexDecorations(view.state, this.index, options);
        this.signature = latexSignature(this.index);
        onChange?.(this.index);
      }

      update(update: ViewUpdate) {
        if (!update.docChanged && !(previewEnabled && update.selectionSet)) return;

        const nextIndex = update.docChanged ? resolveLatexIndex(update.state) : this.index;
        this.index = nextIndex;
        this.decorations = buildLatexDecorations(update.state, nextIndex, options);

        if (!update.docChanged) return;

        const nextSig = latexSignature(nextIndex);
        if (nextSig !== this.signature) {
          this.signature = nextSig;
          onChange?.(nextIndex);
        }
      }
    },
    {
      decorations: (v) => v.decorations,
      eventHandlers: {
        mousedown(event, view) {
          const target = event.target;
          if (!(target instanceof Element)) return;

          const node = target.closest("[data-nv3-latex-fragment='true']");
          if (!(node instanceof HTMLElement)) return;

          const from = Number(node.dataset.nv3LatexFrom ?? NaN);
          const to = Number(node.dataset.nv3LatexTo ?? NaN);
          if (!Number.isFinite(from) || !Number.isFinite(to)) return;

          event.preventDefault();
          view.focus();
          view.dispatch({ selection: { anchor: from, head: from }, scrollIntoView: true });
          return true;
        },
      },
    },
  );
}
