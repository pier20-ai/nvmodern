import { EditorState, RangeSetBuilder, StateField, Text, type Extension } from "@codemirror/state";
import {
  Decoration,
  EditorView,
  hoverTooltip,
  type DecorationSet,
} from "@codemirror/view";
import katex from "katex";
import {
  createMarkdownScannerContext,
  isMarkdownLineScannable,
} from "./scannerContext.ts";
import {
  hasRangeOverlap,
  isEscaped,
  resetIfStalled,
  type TextRange,
} from "./scanUtils.ts";

const FOOTNOTE_REFERENCE_PATTERN = /\[\^([^\]\s]+)\]/g;
const FOOTNOTE_DEFINITION_PATTERN = /^( {0,3})\[\^([^\]\s]+)\]:[ \t]*(.*)$/;
const FOOTNOTE_CONTINUATION_PATTERN = /^  (.*)$/;

const resolvedFootnoteDecoration = Decoration.mark({ class: "nv3-footnote-ref" });
const unresolvedFootnoteDecoration = Decoration.mark({
  class: "nv3-footnote-ref nv3-footnote-ref-unresolved",
});

export interface Nv3MarkdownFootnoteReference {
  id: string;
  from: number;
  to: number;
  line: number;
  resolved: boolean;
}

export interface Nv3MarkdownFootnoteDefinition {
  id: string;
  line: number;
  toLine: number;
  from: number;
  to: number;
  labelFrom: number;
  labelTo: number;
  content: string;
}

export interface Nv3MarkdownFootnoteIndex {
  references: Nv3MarkdownFootnoteReference[];
  definitions: Nv3MarkdownFootnoteDefinition[];
  unresolvedReferenceIds: string[];
}

interface Nv3MarkdownFootnoteState {
  index: Nv3MarkdownFootnoteIndex;
  definitionById: ReadonlyMap<string, Nv3MarkdownFootnoteDefinition>;
  decorations: DecorationSet;
}

function buildDefinitionLookup(
  definitions: readonly Nv3MarkdownFootnoteDefinition[],
): Map<string, Nv3MarkdownFootnoteDefinition> {
  const lookup = new Map<string, Nv3MarkdownFootnoteDefinition>();

  for (const definition of definitions) {
    if (!lookup.has(definition.id)) {
      lookup.set(definition.id, definition);
    }
  }

  return lookup;
}

export function scanMarkdownFootnotes(doc: Text | string): Nv3MarkdownFootnoteIndex {
  const source = typeof doc === "string" ? Text.of(doc.split(/\r?\n/)) : doc;
  const context = createMarkdownScannerContext(source);
  const definitions: Nv3MarkdownFootnoteDefinition[] = [];
  const definitionLabelRangesByLine = new Map<number, TextRange[]>();

  for (let index = 0; index < context.lines.length; index += 1) {
    const line = context.lines[index];
    if (!line || !isMarkdownLineScannable(line)) continue;

    const definitionMatch = line.text.match(FOOTNOTE_DEFINITION_PATTERN);
    if (!definitionMatch) continue;

    const indent = definitionMatch[1] ?? "";
    const id = definitionMatch[2] ?? "";
    const firstContentLine = definitionMatch[3] ?? "";
    const label = `[^${id}]`;
    const contentLines = firstContentLine ? [firstContentLine] : [];
    const labelFrom = line.from + indent.length;
    const labelTo = labelFrom + label.length;

    let toLine = line.lineNo;
    let to = line.to;
    let lastIndex = index;

    for (let nextIndex = index + 1; nextIndex < context.lines.length; nextIndex += 1) {
      const nextLine = context.lines[nextIndex];
      if (!nextLine || !isMarkdownLineScannable(nextLine)) break;
      if (FOOTNOTE_DEFINITION_PATTERN.test(nextLine.text)) break;

      const continuationMatch = nextLine.text.match(FOOTNOTE_CONTINUATION_PATTERN);
      if (!continuationMatch) break;

      contentLines.push(continuationMatch[1] ?? "");
      toLine = nextLine.lineNo;
      to = nextLine.to;
      lastIndex = nextIndex;
    }

    definitions.push({
      id,
      line: line.lineNo,
      toLine,
      from: line.from,
      to,
      labelFrom,
      labelTo,
      content: contentLines.join("\n"),
    });

    definitionLabelRangesByLine.set(line.lineNo, [
      {
        from: indent.length,
        to: indent.length + label.length,
      },
    ]);

    index = lastIndex;
  }

  const definitionById = buildDefinitionLookup(definitions);
  const references: Nv3MarkdownFootnoteReference[] = [];
  const unresolvedReferenceIds = new Set<string>();

  for (const line of context.lines) {
    if (!isMarkdownLineScannable(line)) continue;

    const labelRanges = definitionLabelRangesByLine.get(line.lineNo) ?? [];
    FOOTNOTE_REFERENCE_PATTERN.lastIndex = 0;
    let match: RegExpExecArray | null;

    while ((match = FOOTNOTE_REFERENCE_PATTERN.exec(line.text)) !== null) {
      const raw = match[0] ?? "";
      const id = match[1] ?? "";
      if (!raw || !id) {
        resetIfStalled(FOOTNOTE_REFERENCE_PATTERN, match);
        continue;
      }

      const startOffset = match.index;
      const endOffset = startOffset + raw.length;
      if (isEscaped(line.text, startOffset)) {
        resetIfStalled(FOOTNOTE_REFERENCE_PATTERN, match);
        continue;
      }
      if (hasRangeOverlap(line.inlineCodeRanges, startOffset, endOffset)) {
        resetIfStalled(FOOTNOTE_REFERENCE_PATTERN, match);
        continue;
      }
      if (hasRangeOverlap(labelRanges, startOffset, endOffset)) {
        resetIfStalled(FOOTNOTE_REFERENCE_PATTERN, match);
        continue;
      }

      const previousChar = startOffset > 0 ? line.text[startOffset - 1] ?? "" : "";
      const nextChar = line.text[endOffset] ?? "";
      if (previousChar === "!" || nextChar === "(") {
        resetIfStalled(FOOTNOTE_REFERENCE_PATTERN, match);
        continue;
      }

      const resolved = definitionById.has(id);
      if (!resolved) unresolvedReferenceIds.add(id);

      references.push({
        id,
        from: line.from + startOffset,
        to: line.from + endOffset,
        line: line.lineNo,
        resolved,
      });

      resetIfStalled(FOOTNOTE_REFERENCE_PATTERN, match);
    }
  }

  references.sort((left, right) => left.from - right.from);

  return {
    references,
    definitions,
    unresolvedReferenceIds: [...unresolvedReferenceIds].sort((left, right) =>
      left.localeCompare(right),
    ),
  };
}

function buildFootnoteState(state: EditorState): Nv3MarkdownFootnoteState {
  const index = scanMarkdownFootnotes(state.doc);
  const definitionById = buildDefinitionLookup(index.definitions);
  const builder = new RangeSetBuilder<Decoration>();

  for (const reference of index.references) {
    builder.add(
      reference.from,
      reference.to,
      reference.resolved ? resolvedFootnoteDecoration : unresolvedFootnoteDecoration,
    );
  }

  return {
    index,
    definitionById,
    decorations: builder.finish(),
  };
}

const markdownFootnoteStateField = StateField.define<Nv3MarkdownFootnoteState>({
  create(state) {
    return buildFootnoteState(state);
  },

  update(value, transaction) {
    if (!transaction.docChanged) return value;
    return buildFootnoteState(transaction.state);
  },

  provide(field) {
    return EditorView.decorations.from(field, (value) => value.decorations);
  },
});

function findFootnoteReferenceAtPosition(
  references: readonly Nv3MarkdownFootnoteReference[],
  position: number,
): Nv3MarkdownFootnoteReference | null {
  let low = 0;
  let high = references.length - 1;

  while (low <= high) {
    const mid = (low + high) >> 1;
    const reference = references[mid];
    if (!reference) break;

    if (position < reference.from) {
      high = mid - 1;
      continue;
    }

    if (position >= reference.to) {
      low = mid + 1;
      continue;
    }

    return reference;
  }

  return null;
}

function hoveredFootnoteReference(
  state: EditorState,
  pos: number,
  side: number,
): Nv3MarkdownFootnoteReference | null {
  const footnotes = state.field(markdownFootnoteStateField, false);
  if (!footnotes) return null;

  const candidatePositions = side < 0 ? [pos - 1, pos] : [pos, pos - 1];
  for (const candidate of candidatePositions) {
    if (candidate < 0) continue;
    const reference = findFootnoteReferenceAtPosition(footnotes.index.references, candidate);
    if (reference) return reference;
  }

  return null;
}

const FOOTNOTE_MATH_PATTERN = /\$\$([\s\S]+?)\$\$|(?<!\\)\$([^\n$]+?)(?<!\\)\$/g;

function appendMathNode(parent: HTMLElement, expression: string, displayMode: boolean): void {
  const span = document.createElement(displayMode ? "div" : "span");
  span.className = displayMode
    ? "nv3-footnote-tooltip-math nv3-footnote-tooltip-math-block"
    : "nv3-footnote-tooltip-math nv3-footnote-tooltip-math-inline";
  try {
    span.innerHTML = katex.renderToString(expression, {
      throwOnError: false,
      displayMode,
    });
  } catch {
    span.textContent = displayMode ? `$$${expression}$$` : `$${expression}$`;
  }
  parent.appendChild(span);
}

function renderFootnoteContent(parent: HTMLElement, content: string): void {
  FOOTNOTE_MATH_PATTERN.lastIndex = 0;
  let cursor = 0;
  let match: RegExpExecArray | null;

  while ((match = FOOTNOTE_MATH_PATTERN.exec(content)) !== null) {
    const start = match.index;
    const end = start + match[0].length;

    if (start > cursor) {
      parent.appendChild(document.createTextNode(content.slice(cursor, start)));
    }

    const blockExpression = match[1];
    const inlineExpression = match[2];
    if (blockExpression !== undefined) {
      appendMathNode(parent, blockExpression.trim(), true);
    } else if (inlineExpression !== undefined) {
      appendMathNode(parent, inlineExpression, false);
    }

    cursor = end;
  }

  if (cursor < content.length) {
    parent.appendChild(document.createTextNode(content.slice(cursor)));
  }
}

function createFootnoteTooltip(
  reference: Nv3MarkdownFootnoteReference,
  definition: Nv3MarkdownFootnoteDefinition,
): import("@codemirror/view").Tooltip {
  return {
    pos: reference.from,
    end: reference.to,
    above: true,
    create() {
      const dom = document.createElement("div");
      dom.className = "nv3-footnote-tooltip";

      const label = document.createElement("div");
      label.className = "nv3-footnote-tooltip-label";
      label.textContent = `[^${reference.id}]`;

      const body = document.createElement("div");
      body.className = "nv3-footnote-tooltip-body";
      if (definition.content) {
        renderFootnoteContent(body, definition.content);
      } else {
        body.textContent = "Empty footnote";
      }

      dom.append(label, body);
      return { dom };
    },
  };
}

const markdownFootnoteHoverTooltip = hoverTooltip(
  (view, pos, side) => {
    const footnotes = view.state.field(markdownFootnoteStateField, false);
    if (!footnotes) return null;

    const reference = hoveredFootnoteReference(view.state, pos, side);
    if (!reference?.resolved) return null;

    const definition = footnotes.definitionById.get(reference.id);
    if (!definition) return null;

    return createFootnoteTooltip(reference, definition);
  },
  { hoverTime: 1 },
);

export function getMarkdownFootnoteIndex(state: EditorState): Nv3MarkdownFootnoteIndex {
  return state.field(markdownFootnoteStateField).index;
}

export function createMarkdownFootnoteExtension(): Extension {
  return [markdownFootnoteStateField, markdownFootnoteHoverTooltip];
}
