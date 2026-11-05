import { RangeSetBuilder, type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { findInlineCodeRanges, isEscaped, rangeContainsIndex } from "./scanUtils.ts";
import { selectionTouchesRange } from "./viewUtils.ts";

interface MarkdownHighlightOccurrence {
  from: number;
  to: number;
  bodyFrom: number;
  bodyTo: number;
}

const highlightDecoration = Decoration.mark({ class: "nv3-md-highlight" });
const hiddenMarkDecoration = Decoration.mark({ class: "nv3-hidden-mark" });

function isValidHighlightBoundary(char: string | undefined): boolean {
  return char !== "=";
}

function scanMarkdownHighlightsInLine(lineText: string, lineFrom: number): MarkdownHighlightOccurrence[] {
  const occurrences: MarkdownHighlightOccurrence[] = [];
  const codeRanges = findInlineCodeRanges(lineText);

  for (let index = 0; index < lineText.length - 1; index += 1) {
    if (lineText[index] !== "=" || lineText[index + 1] !== "=") continue;
    if (rangeContainsIndex(codeRanges, index)) {
      index += 1;
      continue;
    }
    if (isEscaped(lineText, index)) {
      index += 1;
      continue;
    }

    const previousChar = lineText[index - 1];
    const firstBodyChar = lineText[index + 2];
    if (!isValidHighlightBoundary(previousChar) || !firstBodyChar || /\s/.test(firstBodyChar) || firstBodyChar === "=") {
      index += 1;
      continue;
    }

    let closeIndex = -1;
    for (let cursor = index + 2; cursor < lineText.length - 1; cursor += 1) {
      if (lineText[cursor] !== "=" || lineText[cursor + 1] !== "=") continue;
      if (rangeContainsIndex(codeRanges, cursor)) {
        cursor += 1;
        continue;
      }
      if (isEscaped(lineText, cursor)) {
        cursor += 1;
        continue;
      }

      const lastBodyChar = lineText[cursor - 1];
      const nextChar = lineText[cursor + 2];
      if (!lastBodyChar || /\s/.test(lastBodyChar) || lastBodyChar === "=") continue;
      if (!isValidHighlightBoundary(nextChar)) continue;

      closeIndex = cursor;
      break;
    }

    if (closeIndex === -1) continue;

    const bodyFrom = lineFrom + index + 2;
    const bodyTo = lineFrom + closeIndex;
    if (bodyFrom >= bodyTo) {
      index = closeIndex + 1;
      continue;
    }

    occurrences.push({
      from: lineFrom + index,
      to: lineFrom + closeIndex + 2,
      bodyFrom,
      bodyTo,
    });
    index = closeIndex + 1;
  }

  return occurrences;
}

function buildMarkdownHighlightDecorations(view: import("@codemirror/view").EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const selectionRanges = view.state.selection.ranges;
  const seenLines = new Set<number>();

  for (const visible of view.visibleRanges) {
    let line = view.state.doc.lineAt(visible.from);
    while (true) {
      if (!seenLines.has(line.number)) {
        seenLines.add(line.number);

        for (const occurrence of scanMarkdownHighlightsInLine(line.text, line.from)) {
          const active = selectionTouchesRange(selectionRanges, occurrence.from, occurrence.to);

          if (!active) {
            builder.add(occurrence.from, occurrence.bodyFrom, hiddenMarkDecoration);
          }

          builder.add(occurrence.bodyFrom, occurrence.bodyTo, highlightDecoration);

          if (!active) {
            builder.add(occurrence.bodyTo, occurrence.to, hiddenMarkDecoration);
          }
        }
      }

      if (line.to >= visible.to || line.number >= view.state.doc.lines) break;
      line = view.state.doc.line(line.number + 1);
    }
  }

  return builder.finish();
}

export function createMarkdownHighlightExtension(): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;

      constructor(view: import("@codemirror/view").EditorView) {
        this.decorations = buildMarkdownHighlightDecorations(view);
      }

      update(update: ViewUpdate) {
        if (!update.docChanged && !update.viewportChanged && !update.selectionSet) return;
        this.decorations = buildMarkdownHighlightDecorations(update.view);
      }
    },
    { decorations: (value) => value.decorations },
  );
}
