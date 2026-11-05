import type { ChangeSpec, StateCommand } from "@codemirror/state";

type BlockquoteSelectionOperation = "quote" | "unquote";

export interface MarkdownSelectionLinePrefixOptions {
  firstPrefix: string;
  continuationPrefix?: string;
}

function selectedLineNumbers(target: Parameters<StateCommand>[0]): number[] {
  const lineNumbers = new Set<number>();

  for (const range of target.state.selection.ranges) {
    if (range.empty) continue;

    const startLine = target.state.doc.lineAt(range.from).number;
    const endLine = target.state.doc.lineAt(Math.max(range.from, range.to - 1)).number;
    for (let lineNumber = startLine; lineNumber <= endLine; lineNumber += 1) {
      lineNumbers.add(lineNumber);
    }
  }

  return [...lineNumbers].sort((left, right) => left - right);
}

function changeBlockquoteSelection(
  target: Parameters<StateCommand>[0],
  operation: BlockquoteSelectionOperation,
): boolean {
  const lineNumbers = selectedLineNumbers(target);
  if (lineNumbers.length === 0) return false;

  const changes: ChangeSpec[] = [];
  for (const lineNumber of lineNumbers) {
    const line = target.state.doc.line(lineNumber);
    if (operation === "quote") {
      changes.push({ from: line.from, insert: "> " });
      continue;
    }

    if (line.text.startsWith("> ")) {
      changes.push({ from: line.from, to: line.from + 2 });
    } else if (line.text.startsWith(">")) {
      changes.push({ from: line.from, to: line.from + 1 });
    }
  }

  if (changes.length === 0) return false;
  target.dispatch(target.state.update({ changes, scrollIntoView: true }));
  return true;
}

export const quoteMarkdownSelection: StateCommand = (target) =>
  changeBlockquoteSelection(target, "quote");

export const unquoteMarkdownSelection: StateCommand = (target) =>
  changeBlockquoteSelection(target, "unquote");

/**
 * Prefix every line touched by a non-empty selection in one CodeMirror
 * transaction. Each selection range starts a new block, so disjoint ranges
 * each receive `firstPrefix` on their first line.
 */
export function prefixMarkdownSelectionLines(
  target: Parameters<StateCommand>[0],
  options: MarkdownSelectionLinePrefixOptions,
): boolean {
  const continuationPrefix = options.continuationPrefix ?? options.firstPrefix;
  if (!options.firstPrefix && !continuationPrefix) return false;

  const prefixes = new Map<number, { prefix: string; startsRange: boolean }>();
  for (const range of target.state.selection.ranges) {
    if (range.empty) continue;

    const startLine = target.state.doc.lineAt(range.from).number;
    const endLine = target.state.doc.lineAt(Math.max(range.from, range.to - 1)).number;
    for (let lineNumber = startLine; lineNumber <= endLine; lineNumber += 1) {
      const startsRange = lineNumber === startLine;
      const existing = prefixes.get(lineNumber);
      if (!existing || (startsRange && !existing.startsRange)) {
        prefixes.set(lineNumber, {
          prefix: startsRange ? options.firstPrefix : continuationPrefix,
          startsRange,
        });
      }
    }
  }

  const changes: ChangeSpec[] = [...prefixes.entries()]
    .sort(([left], [right]) => left - right)
    .flatMap(([lineNumber, entry]) => {
      if (!entry.prefix) return [];
      return [{ from: target.state.doc.line(lineNumber).from, insert: entry.prefix }];
    });

  if (changes.length === 0) return false;
  target.dispatch(target.state.update({ changes, scrollIntoView: true }));
  return true;
}
