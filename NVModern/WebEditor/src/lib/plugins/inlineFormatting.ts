import { EditorSelection, Prec, type Extension, type SelectionRange, type StateCommand } from "@codemirror/state";
import { keymap } from "@codemirror/view";

export interface Nv3InlineMarkupDelimiters {
  open: string;
  close: string;
}

export interface Nv3InlineFormattingKeymapOptions {
  bold: Nv3InlineMarkupDelimiters;
  italic: Nv3InlineMarkupDelimiters;
  highlight?: Nv3InlineMarkupDelimiters;
}

function selectionHasWrappedMarkup(
  state: import("@codemirror/state").EditorState,
  range: SelectionRange,
  delimiters: Nv3InlineMarkupDelimiters,
): boolean {
  if (range.empty) return false;

  const { from, to } = range;
  const { open, close } = delimiters;

  if (from < open.length) return false;
  if (to + close.length > state.doc.length) return false;

  return (
    state.doc.sliceString(from - open.length, from) === open &&
    state.doc.sliceString(to, to + close.length) === close
  );
}

function wrapRangeSelection(
  range: SelectionRange,
  openLength: number,
): SelectionRange {
  const anchor = range.anchor === range.from ? range.from + openLength : range.to + openLength;
  const head = range.head === range.from ? range.from + openLength : range.to + openLength;
  return EditorSelection.range(anchor, head);
}

function unwrapRangeSelection(
  range: SelectionRange,
  openLength: number,
): SelectionRange {
  const anchor = range.anchor === range.from ? range.from - openLength : range.to - openLength;
  const head = range.head === range.from ? range.from - openLength : range.to - openLength;
  return EditorSelection.range(anchor, head);
}

export function createToggleDelimitedMarkupCommand(
  delimiters: Nv3InlineMarkupDelimiters,
): StateCommand {
  return ({ state, dispatch }) => {
    let handled = false;

    const transaction = state.changeByRange((range) => {
      if (range.empty) {
        return { range };
      }

      handled = true;

      if (selectionHasWrappedMarkup(state, range, delimiters)) {
        return {
          changes: [
            { from: range.from - delimiters.open.length, to: range.from },
            { from: range.to, to: range.to + delimiters.close.length },
          ],
          range: unwrapRangeSelection(range, delimiters.open.length),
        };
      }

      return {
        changes: [
          { from: range.from, insert: delimiters.open },
          { from: range.to, insert: delimiters.close },
        ],
        range: wrapRangeSelection(range, delimiters.open.length),
      };
    });

    if (!handled) return false;

    dispatch(state.update(transaction, { scrollIntoView: true }));
    return true;
  };
}

export function createInlineFormattingKeymap(
  options: Nv3InlineFormattingKeymapOptions,
): Extension {
  return Prec.high(
    keymap.of([
      {
        key: "Mod-b",
        run: createToggleDelimitedMarkupCommand(options.bold),
      },
      {
        key: "Mod-i",
        run: createToggleDelimitedMarkupCommand(options.italic),
      },
      ...(options.highlight
        ? [{
            key: "Mod-Shift-h",
            run: createToggleDelimitedMarkupCommand(options.highlight),
          }]
        : []),
    ]),
  );
}

export const toggleMarkdownBold = createToggleDelimitedMarkupCommand({
  open: "**",
  close: "**",
});

export const toggleMarkdownItalic = createToggleDelimitedMarkupCommand({
  open: "*",
  close: "*",
});

export const toggleMarkdownHighlight = createToggleDelimitedMarkupCommand({
  open: "==",
  close: "==",
});

export function createMarkdownInlineFormattingExtension(): Extension {
  return createInlineFormattingKeymap({
    bold: { open: "**", close: "**" },
    italic: { open: "*", close: "*" },
    highlight: { open: "==", close: "==" },
  });
}
