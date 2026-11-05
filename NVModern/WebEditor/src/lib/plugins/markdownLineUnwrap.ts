import { syntaxTree } from "@codemirror/language";
import { StateField, type EditorState, type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, WidgetType } from "@codemirror/view";

export interface MarkdownLineUnwrapRange {
  from: number;
  to: number;
  replacement: "" | " ";
}

export interface LineUnwrapParagraphRange {
  from: number;
  to: number;
}

function isHardBreak(line: string): boolean {
  const trailingSpaces = line.match(/ *$/)?.[0].length ?? 0;
  if (trailingSpaces >= 2) return true;

  let trailingBackslashes = 0;
  for (let index = line.length - 1; index >= 0 && line[index] === "\\"; index -= 1) {
    trailingBackslashes += 1;
  }
  return trailingBackslashes % 2 === 1;
}

function isAlphaNumeric(character: string): boolean {
  return character.length > 0 && /[\p{L}\p{N}]/u.test(character);
}

function continuationPayloadOffset(line: string): number {
  let offset = 0;

  while (offset < line.length) {
    while (line[offset] === " " || line[offset] === "\t") offset += 1;
    if (line[offset] !== ">") break;
    offset += 1;
    if (line[offset] === " " || line[offset] === "\t") offset += 1;
  }

  while (line[offset] === " " || line[offset] === "\t") offset += 1;
  return offset;
}

export function leadingWhitespaceOffset(line: string): number {
  let offset = 0;
  while (line[offset] === " " || line[offset] === "\t") offset += 1;
  return offset;
}

export function collectParagraphLineUnwrapRanges(
  state: Pick<EditorState, "doc">,
  paragraphs: readonly LineUnwrapParagraphRange[],
  hardBreak: (line: string) => boolean,
  payloadOffset: (line: string) => number,
): MarkdownLineUnwrapRange[] {
  const ranges: MarkdownLineUnwrapRange[] = [];
  const doc = state.doc;

  for (const paragraph of paragraphs) {
    let line = doc.lineAt(paragraph.from);
    while (line.to < paragraph.to) {
      const nextLine = doc.line(line.number + 1);
      const previousContent = doc.sliceString(line.from, line.to);
      if (!hardBreak(previousContent)) {
        const nextText = doc.sliceString(nextLine.from, Math.min(nextLine.to, paragraph.to));
        const payloadFrom = nextLine.from + payloadOffset(nextText);
        const previous = previousContent.trimEnd();
        const payload = doc.sliceString(payloadFrom, Math.min(nextLine.to, paragraph.to));
        const joinsHyphenatedWord =
          previous.endsWith("-")
          && isAlphaNumeric(previous.at(-2) ?? "")
          && isAlphaNumeric(payload[0] ?? "");

        ranges.push({
          from: joinsHyphenatedWord ? line.to - 1 : line.to,
          to: payloadFrom,
          replacement: joinsHyphenatedWord ? "" : " ",
        });
      }
      line = nextLine;
    }
  }

  return ranges;
}

export function collectMarkdownLineUnwrapRanges(state: EditorState): MarkdownLineUnwrapRange[] {
  const paragraphs: LineUnwrapParagraphRange[] = [];

  syntaxTree(state).iterate({
    enter(node) {
      if (node.name !== "Paragraph") return;
      paragraphs.push({ from: node.from, to: node.to });
    },
  });

  return collectParagraphLineUnwrapRanges(
    state,
    paragraphs,
    isHardBreak,
    continuationPayloadOffset,
  );
}

class MarkdownSoftBreakWidget extends WidgetType {
  override eq(other: MarkdownSoftBreakWidget): boolean {
    return other instanceof MarkdownSoftBreakWidget;
  }

  override toDOM(): HTMLElement {
    const span = document.createElement("span");
    span.className = "nv3-markdown-soft-break";
    span.textContent = " ";
    return span;
  }

  override ignoreEvent(): boolean {
    return false;
  }
}

const softBreakWidget = new MarkdownSoftBreakWidget();

function buildDecorations(
  state: EditorState,
  collectRanges: (state: EditorState) => readonly MarkdownLineUnwrapRange[],
): DecorationSet {
  return buildLineUnwrapDecorations(collectRanges(state));
}

export function buildLineUnwrapDecorations(ranges: readonly MarkdownLineUnwrapRange[]): DecorationSet {
  return Decoration.set(
    ranges.map(({ from, to, replacement }) =>
      Decoration.replace({
        widget: replacement ? softBreakWidget : undefined,
      }).range(from, to),
    ),
    true,
  );
}

export function createLineUnwrapExtension(
  collectRanges: (state: EditorState) => readonly MarkdownLineUnwrapRange[],
  parserChanged?: (startState: EditorState, state: EditorState) => boolean,
): Extension {
  const field = StateField.define<DecorationSet>({
    create: (state) => buildDecorations(state, collectRanges),
    update(decorations, transaction) {
      if (
        !transaction.docChanged
        && !parserChanged?.(transaction.startState, transaction.state)
      ) {
        return decorations;
      }
      return buildDecorations(transaction.state, collectRanges);
    },
    provide: (source) => EditorView.decorations.from(source),
  });

  return field;
}

export function createMarkdownLineUnwrapExtension(): Extension {
  return createLineUnwrapExtension(
    collectMarkdownLineUnwrapRanges,
    (startState, state) => syntaxTree(startState) !== syntaxTree(state),
  );
}
