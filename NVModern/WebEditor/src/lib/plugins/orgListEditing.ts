/**
 * Org list editing follows Markdown's subtree and sibling-numbering policy.
 * Org retains two-space nesting, alphabetic markers, and explicit counters.
 * The Uniorg tree owns list boundaries, including empty items and loose lists.
 */
import {
  EditorSelection,
  EditorState,
  Prec,
  type Extension,
  type StateCommand,
  type Transaction,
  type TransactionSpec,
} from "@codemirror/state";
import { keymap } from "@codemirror/view";
import type { List, ListItem, OrgNode } from "uniorg";
import { getOrgSyntaxForState, orgSyntaxExtension } from "../org/orgSyntax.ts";

const LIST_INDENT = "  ";
const PREFIX = /^([ \t]*)([-+*]|\d+[.)]|[A-Za-z][.)])([ \t]+|$)(?:\[@(?:start:)?(\d+|[A-Za-z])\][ \t]*)?(?:\[([ xX-])\](?:[ \t]+|$))?/;
const literalBlocks = new Set(["src-block", "example-block", "export-block", "comment-block", "fixed-width"]);
type ListChange = { from: number; to?: number; insert?: string };

interface Prefix {
  leading: string;
  marker: string;
  spacing: string;
  counter: string | null;
  checkbox: boolean;
  contentFrom: number;
  markerFrom: number;
}

interface ListContext {
  node: List;
  parent: ItemContext | null;
  items: ItemContext[];
}

interface ItemContext {
  node: ListItem;
  list: ListContext;
  prefix: Prefix;
  fromLine: number;
  toLine: number;
}

function prefixAt(state: EditorState, from: number): Prefix | null {
  const line = state.doc.lineAt(from);
  const match = PREFIX.exec(line.text);
  if (!match) return null;
  return {
    leading: match[1] ?? "",
    marker: match[2] ?? "",
    spacing: match[3] || " ",
    counter: match[4] ?? null,
    checkbox: match[5] !== undefined,
    contentFrom: line.from + match[0].length,
    markerFrom: line.from + (match[1]?.length ?? 0),
  };
}

function listContexts(state: EditorState) {
  const lists: ListContext[] = [];
  const items: ItemContext[] = [];
  const blocked: Array<{ from: number; to: number }> = [];
  function visit(node: OrgNode, list: ListContext | null, parent: ItemContext | null): void {
    const from = node.position?.start.offset;
    const to = node.position?.end.offset;
    if (from === undefined || to === undefined) return;
    if (literalBlocks.has(node.type)) {
      blocked.push({ from, to });
      return;
    }
    if (node.type === "plain-list") {
      list = { node, parent, items: [] };
      lists.push(list);
    } else if (node.type === "list-item" && list) {
      const prefix = prefixAt(state, from);
      if (!prefix) return;
      const item: ItemContext = {
        node, list, prefix,
        fromLine: state.doc.lineAt(from).number,
        toLine: state.doc.lineAt(to === state.doc.length ? to : Math.max(from, to - 1)).number,
      };
      list.items.push(item);
      items.push(item);
      parent = item;
    }
    if ("children" in node) for (const child of node.children) visit(child, list, parent);
  }
  visit(getOrgSyntaxForState(state).tree, null, null);
  return { lists, items, blocked };
}

function itemAt(state: EditorState, context: ReturnType<typeof listContexts>, pos: number): ItemContext | null {
  if (context.blocked.some(range => pos >= range.from && (pos < range.to || pos === state.doc.length && pos === range.to))) return null;
  const line = state.doc.lineAt(pos).number;
  // Children occur after their parents in the walk, so keep the innermost item.
  let result: ItemContext | null = null;
  for (const item of context.items) if (line >= item.fromLine && line <= item.toLine) result = item;
  return result;
}

function ordering(marker: string) {
  const match = /^(\d+|[A-Za-z])([.)])$/.exec(marker);
  if (!match) return null;
  const token = match[1]!;
  const kind = /^\d/.test(token) ? "number" : token === token.toUpperCase() ? "upper" : "lower";
  return { kind, delimiter: match[2]!, value: ordinal(token), family: `${kind}${match[2]}` };
}

function ordinal(token: string): number {
  return /^\d/.test(token) ? Number(token) : token.toLowerCase().charCodeAt(0) - 96;
}

function ordinalText(value: number, kind: string): string {
  return kind === "number" ? String(value) : String.fromCharCode((kind === "upper" ? 65 : 97) + (Math.max(1, value) - 1) % 26);
}

function continuedPrefix(prefix: Prefix): string {
  const order = ordering(prefix.marker);
  const marker = order ? ordinalText(order.value + 1, order.kind) + order.delimiter : prefix.marker;
  return prefix.leading + marker + prefix.spacing + (prefix.checkbox ? "[ ] " : "");
}

function isLooseList(state: EditorState, list: ListContext): boolean {
  return list.items.slice(1).some(item => !state.doc.line(item.fromLine - 1).text.trim());
}

export const continueOrgList: StateCommand = ({ state, dispatch }) => {
  if (state.readOnly || state.selection.ranges.some(range => !range.empty)) return false;
  const context = listContexts(state);
  let unsupported = false;
  const changes = state.changeByRange(range => {
    const item = itemAt(state, context, range.head);
    const line = state.doc.lineAt(range.head);
    if (!item || line.number === item.fromLine && range.head < item.prefix.contentFrom
      || line.number !== item.fromLine && !line.text.trim()) {
      unsupported = true;
      return { range };
    }
    if (line.number === item.fromLine && !state.doc.sliceString(item.prefix.contentFrom, line.to).trim()) {
      // Match Markdown's non-tight-list policy: an empty second item first
      // introduces a blank separator; another Enter then removes a level.
      if (item.list.items.indexOf(item) === 1 && state.doc.line(line.number - 1).text.trim()) {
        return {
          changes: { from: line.from, insert: state.lineBreak },
          range: EditorSelection.cursor(range.head + state.lineBreak.length),
        };
      }
      const parent = item.list.parent;
      const insert = parent ? continuedPrefix(parent.prefix) : "";
      return {
        changes: { from: line.from, to: line.to, insert },
        range: EditorSelection.cursor(line.from + insert.length),
      };
    }
    const prefix = line.number === item.fromLine ? continuedPrefix(item.prefix) : line.text.match(/^[ \t]*/)?.[0] ?? "";
    let from = range.head;
    const floor = line.number === item.fromLine ? item.prefix.contentFrom : line.from;
    while (from > floor && /[ \t]/.test(state.doc.sliceString(from - 1, from))) from--;
    const insert = state.lineBreak + (isLooseList(state, item.list) ? state.lineBreak : "") + prefix;
    return { changes: { from, to: range.head, insert }, range: EditorSelection.cursor(from + insert.length) };
  });
  if (unsupported) return false;
  dispatch(state.update(changes, { scrollIntoView: true, userEvent: "input" }));
  return true;
};

function applyIndentation(state: EditorState, dispatch: (transaction: Transaction) => void, outdent: boolean): boolean {
  if (state.readOnly) return false;
  const context = listContexts(state);
  const selected = state.selection.ranges.map(range => itemAt(state, context, range.head))
    .filter((item): item is ItemContext => item !== null)
    .sort((a, b) => a.fromLine - b.fromLine || b.toLine - a.toLine);
  const items: ItemContext[] = [];
  for (const item of selected) {
    if (!items.some(existing => item.fromLine >= existing.fromLine && item.toLine <= existing.toLine)) items.push(item);
  }
  const changes: ListChange[] = [];
  for (const item of items) {
    const index = item.list.items.indexOf(item);
    if (outdent ? !item.list.parent : index === 0) continue;
    const previous = item.list.items[index - 1];
    const existingChildren = previous && context.lists.find(list => list.parent === previous
      && (list.items[0]?.prefix.leading.length ?? 0) > item.prefix.leading.length);
    const leading = outdent ? item.list.parent!.prefix.leading
      : existingChildren?.items[0]?.prefix.leading ?? item.prefix.leading + LIST_INDENT;
    const subtree: ListChange[] = [];
    for (let number = item.fromLine; number <= item.toLine; number++) {
      const line = state.doc.line(number);
      if (!line.length) continue;
      const whitespace = /^[ \t]*/.exec(line.text)![0].length;
      const remove = Math.min(item.prefix.leading.length, whitespace);
      if (remove < item.prefix.leading.length && line.text.trim()) { subtree.length = 0; break; }
      subtree.push({ from: line.from, to: line.from + remove, insert: leading });
    }
    changes.push(...subtree);
  }
  if (!changes.length) return false;
  dispatch(state.update({ changes, scrollIntoView: true, userEvent: outdent ? "delete.dedent" : "input.indent" }));
  return true;
}

export const indentOrgListItem: StateCommand = ({ state, dispatch }) => applyIndentation(state, dispatch, false);
export const outdentOrgListItem: StateCommand = ({ state, dispatch }) => applyIndentation(state, dispatch, true);

export const deleteOrgListItemBackward: StateCommand = ({ state, dispatch }) => {
  if (state.readOnly || state.selection.ranges.some(range => !range.empty)) return false;
  const context = listContexts(state);
  let unsupported = false;
  const changes = state.changeByRange(range => {
    const item = itemAt(state, context, range.head);
    const line = state.doc.lineAt(range.head);
    if (!item || line.number !== item.fromLine || range.head !== item.prefix.contentFrom) {
      unsupported = true;
      return { range };
    }
    const previous = item.list.items.indexOf(item) > 0;
    const parent = item.list.parent;
    const insert = previous ? item.prefix.leading + " ".repeat(item.prefix.contentFrom - line.from - item.prefix.leading.length)
      : parent ? " ".repeat(parent.prefix.contentFrom - state.doc.line(parent.fromLine).from) : "";
    return {
      changes: { from: line.from, to: range.head, insert },
      range: EditorSelection.cursor(line.from + insert.length),
    };
  });
  if (unsupported) return false;
  dispatch(state.update(changes, { scrollIntoView: true, userEvent: "delete" }));
  return true;
};

function normalizeOrderedLists(transaction: Transaction): TransactionSpec | readonly TransactionSpec[] {
  const original = transaction as unknown as TransactionSpec;
  if (!transaction.docChanged || transaction.isUserEvent("undo") || transaction.isUserEvent("redo")) return original;
  const state = transaction.state;
  if (state.readOnly) return original;
  const affected: Array<{ from: number; to: number }> = [];
  transaction.changes.iterChangedRanges((_from, _to, from, to) => {
    const first = state.doc.lineAt(from).number;
    const last = state.doc.lineAt(to > from ? to - 1 : to).number;
    affected.push({ from: state.doc.line(Math.max(1, first - 1)).from, to: state.doc.line(Math.min(state.doc.lines, last + 1)).to });
  });
  const changes: ListChange[] = [];
  for (const list of listContexts(state).lists) {
    if (!affected.some(range => list.node.position!.start.offset! <= range.to && list.node.position!.end.offset! >= range.from)) continue;
    let family = "";
    let expected = 1;
    for (const item of list.items) {
      const order = ordering(item.prefix.marker);
      if (!order) { family = ""; continue; }
      if (family !== order.family) { family = order.family; expected = 1; }
      if (item.prefix.counter !== null) expected = ordinal(item.prefix.counter);
      const digits = ordinalText(expected, order.kind);
      const differs = order.kind === "number" ? order.value !== expected : item.prefix.marker.slice(0, -1) !== digits;
      if (differs) changes.push({ from: item.prefix.markerFrom, to: item.prefix.markerFrom + item.prefix.marker.length - 1, insert: digits });
      expected++;
    }
  }
  if (!changes.length) return original;
  changes.sort((a, b) => a.from - b.from);
  return [original, { changes, sequential: true }];
}

export function createOrgListEditingExtension(): Extension {
  return [
    orgSyntaxExtension,
    Prec.high(keymap.of([
      { key: "Enter", run: continueOrgList },
      { key: "Tab", run: indentOrgListItem },
      { key: "Shift-Tab", run: outdentOrgListItem },
      { key: "Backspace", run: deleteOrgListItemBackward },
    ])),
    EditorState.transactionFilter.of(normalizeOrderedLists),
  ];
}
