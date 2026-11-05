import { highlightingFor } from "@codemirror/language";
import { RangeSet, StateField, type EditorState, type Extension } from "@codemirror/state";
import { Decoration, EditorView, type DecorationSet } from "@codemirror/view";
import { highlightTree, type Highlighter } from "@lezer/highlight";
import { codeLanguageForInfo } from "../codeLanguages.ts";
import { getNv3OrgParseResult } from "../plugins/orgIndex.ts";
import { parseOrgText } from "./parser.ts";

function buildOrgSourceHighlightDecorations(state: EditorState): DecorationSet {
  const parsed = getNv3OrgParseResult(state) ?? parseOrgText(state.doc);
  const ranges: Array<{ from: number; to: number; decoration: Decoration }> = [];
  const highlighter: Highlighter = {
    style(tags) {
      return highlightingFor(state, tags);
    },
  };

  for (const block of parsed.sourceBlocks) {
    if (!block.language) continue;
    const language = codeLanguageForInfo(block.language);
    if (!language) continue;

    const openingLine = state.doc.line(block.fromLine);
    const bodyFrom = Math.min(openingLine.to + 1, state.doc.length);
    const bodyTo = block.closed
      ? state.doc.line(block.toLine).from
      : Math.min(block.to, state.doc.length);
    if (bodyTo <= bodyFrom) continue;

    const source = state.doc.sliceString(bodyFrom, bodyTo);
    highlightTree(language.parser.parse(source), highlighter, (from, to, classes) => {
      if (!classes || to <= from) return;
      ranges.push({
        from: bodyFrom + from,
        to: bodyFrom + to,
        decoration: Decoration.mark({ class: classes }),
      });
    });
  }

  ranges.sort((left, right) => left.from - right.from || left.to - right.to);
  return RangeSet.of(ranges.map((range) => range.decoration.range(range.from, range.to)), true);
}

export const orgSourceHighlightField = StateField.define<DecorationSet>({
  create: buildOrgSourceHighlightDecorations,
  update(value, transaction) {
    return transaction.docChanged ? buildOrgSourceHighlightDecorations(transaction.state) : value;
  },
  provide: (field) => EditorView.decorations.from(field),
});

export function createOrgSourceHighlightExtension(): Extension {
  return orgSourceHighlightField;
}
