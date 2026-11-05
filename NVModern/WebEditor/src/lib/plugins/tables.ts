import {
  EditorSelection,
  Prec,
  StateEffect,
  StateField,
  type EditorState,
  type Extension,
  type Line,
} from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  ViewPlugin,
  WidgetType,
  type ViewUpdate,
} from "@codemirror/view";
import {
  renderBasicInlineMarkdown,
  type Nv3InlineMarkdownRenderNode,
} from "./inlineMarkdown.ts";
import { wikilinkAnchorAttributes } from "./links.ts";
import { focusEditorWithoutScroll, resolveEventElement } from "./viewUtils.ts";

/**
 * Embedded Markdown / Org table editor.
 *
 * Historical context:
 * - This file started as a measured-decoration renderer that kept raw pipe-table text in the
 *   normal CodeMirror content flow and aligned columns by DOM measurement + padding.
 * - That approach was source-faithful, but it was also a dead end for richer UX. Once we
 *   wanted Obsidian-style table interaction (real table chrome, in-cell caret, tab/arrow
 *   navigation, stable horizontal scrolling), the decorate-the-source strategy became too
 *   fragile and too expensive.
 * - The current implementation therefore uses a block widget backed by the original markdown
 *   source ranges. The markdown remains the source of truth; the widget is only the view.
 *
 * Current model:
 * - Parse a contiguous GFM pipe table block into `TableBlock` / `TableRow` / `ParsedTableCell`.
 * - Replace the source range with a block widget (`MarkdownTableWidget`).
 * - Keep a persistent `TableDomController` per visible table id. The controller owns:
 *   - a stable root / wrapper / HTML `<table>` DOM tree
 *   - persistent cell display DOM
 *   - a single overlay input used for active-cell editing
 * - Structural doc changes patch the existing DOM when the table shape is unchanged and only
 *   rebuild rows when row/column topology changes.
 * - Interaction-only changes (active cell moves) must *not* rebuild the DOM. They only move
 *   the overlay input / active classes.
 *
 * Why the controller architecture matters:
 * - Rebuilding the whole widget DOM on every active-cell change caused severe jank:
 *   x-scroll resets, focus churn, browser auto-scroll, and accidental double-commit races.
 * - A persistent controller fixes that by keeping the scroll container and table DOM stable
 *   while the active editor moves within that DOM.
 *
 * CodeMirror geometry lessons learned the hard way:
 * - For multi-line replaced content, `WidgetType.lineBreaks` is essential. Without it,
 *   vertical cursor movement around the table is catastrophically wrong because CM thinks the
 *   replaced block has zero internal document line structure.
 * - External margin on block widgets is dangerous. A previous version used margin around the
 *   table widget, which produced click-placement and ArrowUp/ArrowDown offsets on following
 *   prose lines. Keep table spacing *inside* the widget box via padding instead.
 * - `estimatedHeight()` helps CM approximate the block height for viewport / reveal logic.
 *   It should stay conservative and roughly match the actual styled row height.
 * - If future geometry changes regress cursor motion, first re-check:
 *   1) `lineBreaks`
 *   2) widget external margin
 *   3) `estimatedHeight()` vs actual CSS row height
 *   4) whether active-cell transitions accidentally rebuild structure
 *
 * Interaction invariants:
 * - The source markdown is always canonical.
 * - Focusing / editing a cell must not rebuild rows.
 * - Focusing / editing a cell must not reset horizontal scroll.
 * - Focused viewing cells keep a visible blue outline and use table-style navigation:
 *   ArrowLeft / ArrowRight move within the row, ArrowUp / ArrowDown move within the column,
 *   and arrows do not wrap across row/column boundaries.
 * - Edited cells use a wrapping textarea. Arrow keys move within the cell text; Escape leaves
 *   editing mode and returns to focused viewing mode.
 * - Tab / Shift-Tab traverse cells in row-major order. Tab on the last cell appends a new
 *   Markdown body row and focuses its first cell. Shift-Tab on the first cell does nothing.
 * - Exiting the table should hand focus back to the editor via `focusEditorWithoutScroll(...)`.
 * - Blur after a key-driven transition is suppressed so it does not overwrite the intended
 *   next-cell target with a second stray commit.
 *
 * Structural invariants:
 * - Cell writes serialize the *entire row*, not just the active cell slice. Updating only a
 *   subrange proved too fragile and can corrupt surrounding `|` delimiters.
 * - Structural commands serialize the entire Markdown table block because column changes must
 *   rewrite header, delimiter, and body rows together.
 * - For now, structural commands are driven by the existing native context menu bridge. Do not
 *   add visible table chrome unless the CM geometry implications are re-audited.
 * - `cellRefs` are keyed by source row index, not rendered-row index. Delimiter rows are not
 *   rendered, so mixing source and rendered indexes breaks active-cell lookup after the header.
 * - When the table shape is unchanged, patch display text in place. Do not throw away cell DOM
 *   if a text update can be handled with simple textContent updates.
 *
 * Remaining caveat / known issue:
 * - There is still an unresolved scroll-reveal issue where ArrowDown can move the selection to
 *   prose below the viewport without always scrolling that prose into view. This appears to be
 *   a remaining CM/widget geometry interaction rather than table navigation logic itself.
 *   If you work on that, avoid hacky manual scroll-restoration/event-listener fixes; prefer
 *   supplying CM with more accurate geometry information.
 *
 * Hard regression guardrails:
 * - Do not reintroduce scrollLeft save/restore hacks as the primary solution for focus jank.
 * - Do not reintroduce full widget rerenders on active-cell changes.
 * - Do not use external widget margin for vertical spacing.
 * - Do not remove `lineBreaks` unless you have an alternative, proven CM geometry fix.
 * - If you change row height / padding in CSS, keep `estimatedHeight()` in sync.
 * - If a change breaks ArrowUp / ArrowDown around prose near the table, back it out and audit
 *   CM geometry assumptions before adding more behavior.
 */
const TABLE_DELIMITER_CELL_PATTERN = /^:?-{3,}:?$/;
const TABLE_COLUMN_MIN_WIDTH_PX = 80;
const TABLE_COLUMN_MAX_WIDTH_PX = 360;
const TABLE_CELL_HORIZONTAL_PADDING_PX = 16;
const TABLE_CELL_VERTICAL_PADDING_PX = 12;
const TABLE_TEXT_LINE_HEIGHT_PX = 19;
const TABLE_ROW_MIN_HEIGHT_PX = 34;
const TABLE_ROW_DIVIDER_PX = 1;
const TABLE_WRAPPER_BORDER_PX = 2;
const TABLE_WIDGET_VERTICAL_PADDING_PX = 10;
const TABLE_AVERAGE_CHAR_WIDTH_PX = 7.4;

export interface ParsedTableCell {
  from: number;
  to: number;
  column: number;
  text: string;
}

export interface ParsedTableRow {
  lineNo: number;
  from: number;
  to: number;
  lineText: string;
  cells: ParsedTableCell[];
  delimiterPositions: number[];
}

export type TableRowKind = "header" | "delimiter" | "body";

export interface TableRow extends ParsedTableRow {
  kind: TableRowKind;
}

export interface TableLayout {
  columnWidthsPx: number[];
  rowHeightsPx: number[];
  tableWidthPx: number;
  estimatedHeightPx: number;
}

export interface TableBlock {
  id: string;
  from: number;
  to: number;
  signature: string;
  rows: TableRow[];
  layout: TableLayout;
}

export type TableParser = (state: import("@codemirror/state").EditorState) => TableBlock[];

interface ActiveTableCellTarget {
  anchorPos: number;
  rowIndex: number;
  column: number;
  caretOffset?: number;
  editing?: boolean;
}

interface ActiveTableCellRef {
  rowIndex: number;
  column: number;
  caretOffset?: number;
  editing: boolean;
}

interface TableCellDomRef {
  cell: HTMLTableCellElement;
  content: HTMLDivElement;
  display: HTMLDivElement;
  renderedSource: string | null;
}

export type MarkdownTableCommand =
  | "insertRowAbove"
  | "insertRowBelow"
  | "deleteRow"
  | "moveRowUp"
  | "moveRowDown"
  | "insertColumnLeft"
  | "insertColumnRight"
  | "deleteColumn"
  | "moveColumnLeft"
  | "moveColumnRight"
  | "alignColumnLeft"
  | "alignColumnCenter"
  | "alignColumnRight"
  | "clearCell";

export interface MarkdownTableCommandTarget {
  tableId?: string;
  rowIndex: number;
  column: number;
}

export interface MarkdownTableDomContext extends MarkdownTableCommandTarget {
  rowKind: TableRowKind;
  rowCount: number;
  columnCount: number;
}

const pendingFocusTargetByView = new WeakMap<EditorView, ActiveTableCellTarget | null>();
const tableControllersByView = new WeakMap<EditorView, Map<string, TableDomController>>();

const setActiveTableCellEffect = StateEffect.define<ActiveTableCellTarget | null>();

const activeTableCellField = StateField.define<ActiveTableCellTarget | null>({
  create() {
    return null;
  },

  update(value, transaction) {
    if (value) {
      value = {
        ...value,
        anchorPos: transaction.changes.mapPos(value.anchorPos, 1),
      };
    }

    for (const effect of transaction.effects) {
      if (effect.is(setActiveTableCellEffect)) {
        value = effect.value
          ? {
              ...effect.value,
              anchorPos: transaction.changes.mapPos(effect.value.anchorPos, 1),
            }
          : null;
      }
    }

    return value;
  },
});

function sameActiveTableCellTarget(
  left: ActiveTableCellTarget | null,
  right: ActiveTableCellTarget | null,
): boolean {
  return (
    left?.anchorPos === right?.anchorPos &&
    left?.rowIndex === right?.rowIndex &&
    left?.column === right?.column &&
    left?.caretOffset === right?.caretOffset &&
    Boolean(left?.editing) === Boolean(right?.editing)
  );
}

function activeCellRefForTable(
  state: import("@codemirror/state").EditorState,
  table: TableBlock,
): ActiveTableCellRef | null {
  const target = state.field(activeTableCellField, false) ?? null;
  if (!target) return null;
  if (target.anchorPos < table.from || target.anchorPos > table.to) return null;

  const row = table.rows[target.rowIndex];
  if (!row || row.kind === "delimiter") return null;
  if (target.column < 0 || target.column >= row.cells.length) return null;

  return {
    rowIndex: target.rowIndex,
    column: target.column,
    caretOffset: target.caretOffset,
    editing: Boolean(target.editing),
  };
}

function lastNonWhitespaceIndex(text: string): number {
  for (let index = text.length - 1; index >= 0; index -= 1) {
    if (!/\s/.test(text.charAt(index))) {
      return index;
    }
  }

  return -1;
}

export function pipeOffsetsForTableRow(text: string): number[] {
  const result: number[] = [];
  let activeCodeTicks = 0;

  for (let index = 0; index < text.length; index += 1) {
    const char = text.charAt(index);

    if (char === "\\") {
      index += 1;
      continue;
    }

    if (activeCodeTicks === 0 && char === "[" && text.charAt(index + 1) === "[") {
      const close = text.indexOf("]]", index + 2);
      if (close >= 0 && !/[\]\n]/.test(text.slice(index + 2, close))) {
        index = close + 1;
        continue;
      }
    }

    if (char === "`") {
      let tickCount = 1;
      while (index + tickCount < text.length && text.charAt(index + tickCount) === "`") {
        tickCount += 1;
      }

      if (activeCodeTicks === 0) {
        activeCodeTicks = tickCount;
      } else if (activeCodeTicks === tickCount) {
        activeCodeTicks = 0;
      }

      index += tickCount - 1;
      continue;
    }

    if (char === "|" && activeCodeTicks === 0) {
      result.push(index);
    }
  }

  return result;
}

export function parseTableRow(line: Line): ParsedTableRow | null {
  const firstContent = line.text.search(/\S/);
  const lastContent = lastNonWhitespaceIndex(line.text);
  if (firstContent < 0 || lastContent < 0) return null;

  if (line.text.charAt(firstContent) !== "|" || line.text.charAt(lastContent) !== "|") {
    return null;
  }

  const pipeOffsets = pipeOffsetsForTableRow(line.text).filter(
    (offset) => offset >= firstContent && offset <= lastContent,
  );

  if (
    pipeOffsets.length < 2 ||
    pipeOffsets[0] !== firstContent ||
    pipeOffsets[pipeOffsets.length - 1] !== lastContent
  ) {
    return null;
  }

  const cells: ParsedTableCell[] = [];
  for (let index = 0; index < pipeOffsets.length - 1; index += 1) {
    const leftPipe = pipeOffsets[index]!;
    const rightPipe = pipeOffsets[index + 1]!;
    cells.push({
      from: line.from + leftPipe + 1,
      to: line.from + rightPipe,
      column: index,
      text: line.text.slice(leftPipe + 1, rightPipe),
    });
  }

  return {
    lineNo: line.number,
    from: line.from,
    to: line.to,
    lineText: line.text,
    cells,
    delimiterPositions: pipeOffsets.map((offset) => line.from + offset),
  };
}

function isDelimiterRow(row: ParsedTableRow): boolean {
  return row.cells.length > 0 && row.cells.every((cell) => TABLE_DELIMITER_CELL_PATTERN.test(cell.text.trim()));
}

function normalizeBodyRowToColumnCount(row: ParsedTableRow, columnCount: number): ParsedTableRow | null {
  if (row.cells.length === columnCount) {
    return row;
  }

  if (row.cells.length > columnCount) {
    return {
      ...row,
      cells: row.cells.slice(0, columnCount),
    };
  }

  const lastDelimiter = row.delimiterPositions[row.delimiterPositions.length - 1] ?? row.to;
  const cells = [...row.cells];

  for (let column = cells.length; column < columnCount; column += 1) {
    cells.push({
      from: lastDelimiter,
      to: lastDelimiter,
      column,
      text: "",
    });
  }

  return {
    ...row,
    cells,
  };
}

export function parseMarkdownTables(state: import("@codemirror/state").EditorState): TableBlock[] {
  const tables: TableBlock[] = [];
  let lineNo = 1;

  while (lineNo < state.doc.lines) {
    const header = parseTableRow(state.doc.line(lineNo));
    const delimiter = parseTableRow(state.doc.line(lineNo + 1));

    if (!header || !delimiter || header.cells.length !== delimiter.cells.length || !isDelimiterRow(delimiter)) {
      lineNo += 1;
      continue;
    }

    const rows: TableRow[] = [
      { ...header, kind: "header" },
      { ...delimiter, kind: "delimiter" },
    ];

    let nextLineNo = lineNo + 2;
    while (nextLineNo <= state.doc.lines) {
      const parsedBody = parseTableRow(state.doc.line(nextLineNo));
      const body = parsedBody ? normalizeBodyRowToColumnCount(parsedBody, header.cells.length) : null;
      if (!body) {
        break;
      }

      rows.push({ ...body, kind: "body" });
      nextLineNo += 1;
    }

    const from = rows[0]!.from;
    const to = rows[rows.length - 1]!.to;
    const signature = rows.map((row) => `${row.kind}:${row.lineText}`).join("\n");

    tables.push({
      id: `t-${from}-${to}`,
      from,
      to,
      signature,
      rows,
      layout: computeTableLayout(rows),
    });

    lineNo = nextLineNo;
  }

  return tables;
}

function editableRowIndexes(table: TableBlock): number[] {
  const result: number[] = [];

  for (let index = 0; index < table.rows.length; index += 1) {
    const row = table.rows[index];
    if (row && row.kind !== "delimiter") {
      result.push(index);
    }
  }

  return result;
}

function normalizedCellText(text: string): string {
  return text.trim();
}

function appendTableInlineNodes(
  parent: HTMLElement | DocumentFragment,
  nodes: readonly Nv3InlineMarkdownRenderNode[],
): void {
  for (const node of nodes) {
    if (node.kind === "text") {
      parent.append(document.createTextNode(node.text));
      continue;
    }

    if (node.kind === "latex") {
      const preview = document.createElement("span");
      preview.className = "nv3-latex-preview nv3-latex-preview-inline nv3-table-latex-preview";
      preview.innerHTML = node.html;
      preview.setAttribute("data-nv3-table-latex-source", node.source);
      parent.append(preview);
      continue;
    }

    if (node.kind === "code") {
      const code = document.createElement("code");
      code.className = "nv3-inline-code nv3-table-inline-code";
      code.textContent = node.text;
      parent.append(code);
      continue;
    }

    if (node.kind === "wikilink") {
      const anchor = document.createElement("a");
      anchor.className = "nv3-link nv3-link-wikilink";
      anchor.textContent = node.text;
      anchor.title = node.target;
      anchor.dataset.nv3Wikilink = "true";
      anchor.dataset.nv3Target = node.target;
      anchor.dataset.nv3TableLinkFrom = String(node.from);
      anchor.dataset.nv3TableLinkTo = String(node.to);
      parent.append(anchor);
      continue;
    }

    const markup = document.createElement(node.kind === "strong" ? "strong" : "em");
    markup.className = node.kind === "strong" ? "nv3-table-strong" : "nv3-table-emphasis";
    appendTableInlineNodes(markup, node.children);
    parent.append(markup);
  }
}

/**
 * Publish where a cell's text comes from, relative to the table's start, so
 * plugins that decorate source ranges (annotations) can find it in the widget.
 */
function stampTableCellSource(
  ref: TableCellDomRef,
  cell: ParsedTableCell,
  table: TableBlock,
  view: EditorView,
): void {
  ref.display.dataset.nv3SourceFrom = String(cell.from - table.from);
  ref.display.dataset.nv3SourceTo = String(cell.to - table.from);
  // Refresh positions even when persistent cell DOM survives edits above it.
  for (const anchor of ref.display.querySelectorAll<HTMLAnchorElement>("a[data-nv3-wikilink='true']")) {
    const attributes = tableWikilinkAttributes(view.state, cell, {
      target: anchor.dataset.nv3Target ?? "",
      from: Number(anchor.dataset.nv3TableLinkFrom),
      to: Number(anchor.dataset.nv3TableLinkTo),
    });
    for (const [name, value] of Object.entries(attributes)) anchor.setAttribute(name, value);
  }
}

export function tableWikilinkAttributes(
  state: EditorState,
  cell: ParsedTableCell,
  link: { target: string; from: number; to: number },
): Record<string, string> {
  const sourceFrom = cell.from + cell.text.length - cell.text.trimStart().length;
  const from = sourceFrom + link.from;
  return wikilinkAnchorAttributes(state, {
    kind: "wikilink",
    target: link.target,
    from,
    to: sourceFrom + link.to,
    line: state.doc.lineAt(from).number,
  });
}

function renderTableCellDisplay(ref: TableCellDomRef, text: string): void {
  const source = normalizedCellText(text);
  if (ref.renderedSource === source) return;

  const fragment = document.createDocumentFragment();
  appendTableInlineNodes(fragment, renderBasicInlineMarkdown(source));

  if (!fragment.hasChildNodes()) {
    fragment.append(document.createTextNode(" "));
  }
  ref.display.replaceChildren(fragment);
  ref.renderedSource = source;
}

function serializeCellValue(value: string): string {
  const singleLine = value.replace(/\r?\n/g, " ");
  const delimiters = new Set(pipeOffsetsForTableRow(singleLine));
  const escapedPipes = singleLine.split("").map((char, index) =>
    delimiters.has(index) ? `\\${char}` : char,
  ).join("");
  const normalized = escapedPipes.trim();
  return normalized.length ? ` ${normalized} ` : " ";
}

function serializeTableDataRow(
  row: TableRow,
  overrides: Partial<Record<number, string>> = {},
): string {
  const firstPipe = row.lineText.indexOf("|");
  const lastPipe = row.lineText.lastIndexOf("|");
  const prefix = firstPipe >= 0 ? row.lineText.slice(0, firstPipe) : "";
  const suffix = lastPipe >= 0 ? row.lineText.slice(lastPipe + 1) : "";
  const parts = row.cells.map((cell) => serializeCellValue(overrides[cell.column] ?? cell.text));
  return `${prefix}|${parts.join("|")}|${suffix}`;
}

type TableAlignment = "left" | "center" | "right" | null;

interface EditableTableData {
  header: string[];
  alignments: TableAlignment[];
  body: string[][];
}

function delimiterAlignment(text: string): TableAlignment {
  const trimmed = text.trim();
  const starts = trimmed.startsWith(":");
  const ends = trimmed.endsWith(":");
  if (starts && ends) return "center";
  if (ends) return "right";
  if (starts) return "left";
  return null;
}

function serializeDelimiterCell(alignment: TableAlignment): string {
  switch (alignment) {
    case "left":
      return " :--- ";
    case "center":
      return " :---: ";
    case "right":
      return " ---: ";
    default:
      return " --- ";
  }
}

function tableDataFromBlock(table: TableBlock): EditableTableData | null {
  const header = table.rows.find((row) => row.kind === "header");
  const delimiter = table.rows.find((row) => row.kind === "delimiter");
  if (!header || !delimiter || header.cells.length === 0) return null;

  const columnCount = header.cells.length;
  return {
    header: header.cells.map((cell) => normalizedCellText(cell.text)),
    alignments: Array.from({ length: columnCount }, (_, column) =>
      delimiterAlignment(delimiter.cells[column]?.text ?? ""),
    ),
    body: table.rows
      .filter((row) => row.kind === "body")
      .map((row) => Array.from({ length: columnCount }, (_, column) => normalizedCellText(row.cells[column]?.text ?? ""))),
  };
}

function emptyTableRow(columnCount: number): string[] {
  return Array.from({ length: columnCount }, () => "");
}

function serializeTableData(data: EditableTableData): string {
  const header = `|${data.header.map(serializeCellValue).join("|")}|`;
  const delimiter = `|${data.alignments.map(serializeDelimiterCell).join("|")}|`;
  const body = data.body.map((row) => `|${row.map(serializeCellValue).join("|")}|`);
  return [header, delimiter, ...body].join("\n");
}

function sourceRowToBodyIndex(rowIndex: number): number {
  return rowIndex - 2;
}

function clampColumn(column: number, columnCount: number): number {
  return Math.max(0, Math.min(columnCount - 1, column));
}

function focusTargetForTableEdit(table: TableBlock, rowIndex: number, column: number, editing = false): ActiveTableCellTarget {
  const row = table.rows[Math.max(0, Math.min(table.rows.length - 1, rowIndex))];
  const cell = row?.cells[clampColumn(column, row?.cells.length ?? 1)];
  return {
    anchorPos: cell?.from ?? row?.from ?? table.from,
    rowIndex,
    column,
    editing,
  };
}

function findTableByTarget(
  state: import("@codemirror/state").EditorState,
  tableParser: TableParser,
  target?: MarkdownTableCommandTarget | null,
): { table: TableBlock; rowIndex: number; column: number } | null {
  const tables = tableParser(state);
  if (target) {
    const table = target.tableId
      ? tables.find((candidate) => candidate.id === target.tableId)
      : tables.find((candidate) => target.rowIndex >= 0 && target.rowIndex < candidate.rows.length);
    if (table) {
      return {
        table,
        rowIndex: target.rowIndex,
        column: target.column,
      };
    }
  }

  const active = state.field(activeTableCellField, false) ?? null;
  if (!active) return null;

  for (const table of tables) {
    if (active.anchorPos < table.from || active.anchorPos > table.to) continue;
    return {
      table,
      rowIndex: active.rowIndex,
      column: active.column,
    };
  }

  return null;
}

function transformTableData(
  table: TableBlock,
  command: MarkdownTableCommand,
  rowIndex: number,
  column: number,
): { data: EditableTableData; nextRowIndex: number; nextColumn: number; editing?: boolean } | null {
  const data = tableDataFromBlock(table);
  if (!data) return null;

  const columnCount = data.header.length;
  const safeColumn = clampColumn(column, columnCount);
  const bodyIndex = sourceRowToBodyIndex(rowIndex);
  const isHeader = rowIndex === 0;
  const isBody = bodyIndex >= 0 && bodyIndex < data.body.length;

  switch (command) {
    case "insertRowAbove": {
      if (isHeader) return null;
      const insertAt = Math.max(0, Math.min(data.body.length, bodyIndex));
      data.body.splice(insertAt, 0, emptyTableRow(columnCount));
      return { data, nextRowIndex: insertAt + 2, nextColumn: safeColumn, editing: true };
    }

    case "insertRowBelow": {
      const insertAt = isHeader ? 0 : Math.max(0, Math.min(data.body.length, bodyIndex + 1));
      data.body.splice(insertAt, 0, emptyTableRow(columnCount));
      return { data, nextRowIndex: insertAt + 2, nextColumn: safeColumn, editing: true };
    }

    case "deleteRow": {
      if (!isBody) return null;
      data.body.splice(bodyIndex, 1);
      const nextBodyIndex = Math.min(bodyIndex, data.body.length - 1);
      const nextRowIndex = nextBodyIndex >= 0 ? nextBodyIndex + 2 : 0;
      return { data, nextRowIndex, nextColumn: safeColumn };
    }

    case "moveRowUp": {
      if (!isBody || bodyIndex <= 0) return null;
      const [row] = data.body.splice(bodyIndex, 1);
      data.body.splice(bodyIndex - 1, 0, row ?? emptyTableRow(columnCount));
      return { data, nextRowIndex: rowIndex - 1, nextColumn: safeColumn };
    }

    case "moveRowDown": {
      if (!isBody || bodyIndex >= data.body.length - 1) return null;
      const [row] = data.body.splice(bodyIndex, 1);
      data.body.splice(bodyIndex + 1, 0, row ?? emptyTableRow(columnCount));
      return { data, nextRowIndex: rowIndex + 1, nextColumn: safeColumn };
    }

    case "insertColumnLeft":
    case "insertColumnRight": {
      const insertAt = command === "insertColumnLeft" ? safeColumn : safeColumn + 1;
      data.header.splice(insertAt, 0, "");
      data.alignments.splice(insertAt, 0, null);
      for (const row of data.body) {
        row.splice(insertAt, 0, "");
      }
      return { data, nextRowIndex: rowIndex, nextColumn: insertAt, editing: true };
    }

    case "deleteColumn": {
      if (columnCount <= 1) return null;
      data.header.splice(safeColumn, 1);
      data.alignments.splice(safeColumn, 1);
      for (const row of data.body) {
        row.splice(safeColumn, 1);
      }
      return { data, nextRowIndex: rowIndex, nextColumn: Math.min(safeColumn, columnCount - 2) };
    }

    case "moveColumnLeft": {
      if (safeColumn <= 0) return null;
      const move = <T>(row: T[]) => {
        const [value] = row.splice(safeColumn, 1);
        if (value === undefined) return;
        row.splice(safeColumn - 1, 0, value);
      };
      move(data.header);
      move(data.alignments);
      data.body.forEach(move);
      return { data, nextRowIndex: rowIndex, nextColumn: safeColumn - 1 };
    }

    case "moveColumnRight": {
      if (safeColumn >= columnCount - 1) return null;
      const move = <T>(row: T[]) => {
        const [value] = row.splice(safeColumn, 1);
        if (value === undefined) return;
        row.splice(safeColumn + 1, 0, value);
      };
      move(data.header);
      move(data.alignments);
      data.body.forEach(move);
      return { data, nextRowIndex: rowIndex, nextColumn: safeColumn + 1 };
    }

    case "alignColumnLeft":
      data.alignments[safeColumn] = "left";
      return { data, nextRowIndex: rowIndex, nextColumn: safeColumn };

    case "alignColumnCenter":
      data.alignments[safeColumn] = "center";
      return { data, nextRowIndex: rowIndex, nextColumn: safeColumn };

    case "alignColumnRight":
      data.alignments[safeColumn] = "right";
      return { data, nextRowIndex: rowIndex, nextColumn: safeColumn };

    case "clearCell": {
      if (isHeader) {
        data.header[safeColumn] = "";
      } else if (isBody) {
        data.body[bodyIndex]![safeColumn] = "";
      } else {
        return null;
      }
      return { data, nextRowIndex: rowIndex, nextColumn: safeColumn, editing: true };
    }
  }
}

function activateTransformedTableCell(
  view: EditorView,
  tableFrom: number,
  rowIndex: number,
  column: number,
  editing = false,
): void {
  requestAnimationFrame(() => {
    if (!view.dom.isConnected) return;
    const table = parseMarkdownTables(view.state).find((candidate) => candidate.from === tableFrom);
    if (!table) return;

    const row = table.rows[Math.max(0, Math.min(table.rows.length - 1, rowIndex))];
    const targetColumn = clampColumn(column, row?.cells.length ?? 1);
    const cell = row?.cells[targetColumn];
    if (!row || !cell || row.kind === "delimiter") return;

    view.dispatch({
      effects: [
        setActiveTableCellEffect.of({
          anchorPos: cell.from,
          rowIndex: table.rows.indexOf(row),
          column: targetColumn,
          editing,
        }),
      ],
      userEvent: "select.pointer",
    });
  });
}

function applyMarkdownTableTransform(
  view: EditorView,
  table: TableBlock,
  command: MarkdownTableCommand,
  rowIndex: number,
  column: number,
): boolean {
  const result = transformMarkdownTableBlock(table, command, rowIndex, column);
  if (!result) return false;

  view.dispatch({
    changes: {
      from: table.from,
      to: table.to,
      insert: result.text,
    },
    effects: [setActiveTableCellEffect.of(null)],
    scrollIntoView: false,
    userEvent: "input.table",
  });
  activateTransformedTableCell(
    view,
    table.from,
    result.nextRowIndex,
    result.nextColumn,
    Boolean(result.editing),
  );
  return true;
}

export function transformMarkdownTableBlock(
  table: TableBlock,
  command: MarkdownTableCommand,
  rowIndex: number,
  column: number,
): { text: string; nextRowIndex: number; nextColumn: number; editing?: boolean } | null {
  const result = transformTableData(table, command, rowIndex, column);
  if (!result) return null;
  return {
    text: serializeTableData(result.data),
    nextRowIndex: result.nextRowIndex,
    nextColumn: result.nextColumn,
    editing: result.editing,
  };
}

export function runMarkdownTableCommand(
  view: EditorView,
  command: MarkdownTableCommand,
  target?: MarkdownTableCommandTarget | null,
): boolean {
  const located = findTableByTarget(view.state, parseMarkdownTables, target);
  if (!located) return false;
  return applyMarkdownTableTransform(view, located.table, command, located.rowIndex, located.column);
}

export function markdownTableContextFromEventTarget(target: EventTarget | null): MarkdownTableDomContext | null {
  const element = target instanceof Element ? target : null;
  const cell = element?.closest<HTMLElement>("[data-nv3-table-row-index][data-nv3-table-column]");
  const root = cell?.closest<HTMLElement>("[data-nv3-table-id]");
  if (!cell || !root) return null;

  const rowIndex = Number.parseInt(cell.dataset.nv3TableRowIndex ?? "", 10);
  const column = Number.parseInt(cell.dataset.nv3TableColumn ?? "", 10);
  const rowCount = Number.parseInt(root.dataset.nv3TableRowCount ?? "", 10);
  const columnCount = Number.parseInt(root.dataset.nv3TableColumnCount ?? "", 10);
  const rowKind = cell.dataset.nv3TableRowKind;

  if (
    !Number.isFinite(rowIndex) ||
    !Number.isFinite(column) ||
    !Number.isFinite(rowCount) ||
    !Number.isFinite(columnCount) ||
    (rowKind !== "header" && rowKind !== "body")
  ) {
    return null;
  }

  return {
    tableId: root.dataset.nv3TableId,
    rowIndex,
    column,
    rowKind,
    rowCount,
    columnCount,
  };
}

function nextEditableCellTarget(
  table: TableBlock,
  rowIndex: number,
  column: number,
  direction: -1 | 1,
  caretOffset?: number,
): ActiveTableCellTarget | null {
  const rows = editableRowIndexes(table);
  const rowOrderIndex = rows.indexOf(rowIndex);
  if (rowOrderIndex < 0) return null;

  let nextRowOrderIndex = rowOrderIndex;
  let nextColumn = column + direction;

  while (true) {
    const sourceRowIndex = rows[nextRowOrderIndex];
    if (sourceRowIndex == null) return null;

    const row = table.rows[sourceRowIndex];
    if (!row) return null;

    if (nextColumn >= 0 && nextColumn < row.cells.length) {
      return {
        anchorPos: row.cells[nextColumn]?.from ?? table.from,
        rowIndex: sourceRowIndex,
        column: nextColumn,
        caretOffset,
      };
    }

    if (direction > 0) {
      nextRowOrderIndex += 1;
      const nextRow = table.rows[rows[nextRowOrderIndex] ?? -1];
      if (!nextRow) return null;
      nextColumn = 0;
    } else {
      nextRowOrderIndex -= 1;
      const previousRow = table.rows[rows[nextRowOrderIndex] ?? -1];
      if (!previousRow) return null;
      nextColumn = previousRow.cells.length - 1;
    }
  }
}

function moveVerticalCellTarget(
  table: TableBlock,
  rowIndex: number,
  column: number,
  direction: -1 | 1,
  caretOffset?: number,
): ActiveTableCellTarget | null {
  const rows = editableRowIndexes(table);
  const rowOrderIndex = rows.indexOf(rowIndex);
  if (rowOrderIndex < 0) return null;

  const targetRowIndex = rows[rowOrderIndex + direction];
  if (targetRowIndex == null) return null;

  const targetRow = table.rows[targetRowIndex];
  if (!targetRow) return null;

  const targetColumn = Math.max(0, Math.min(column, targetRow.cells.length - 1));
  const targetCell = targetRow.cells[targetColumn];
  if (!targetCell) return null;

  return {
    anchorPos: targetCell.from,
    rowIndex: targetRowIndex,
    column: targetColumn,
    caretOffset,
  };
}

function dispatchTableUpdate(
  view: EditorView,
  spec: Parameters<EditorView["dispatch"]>[0],
  after?: () => void,
): void {
  requestAnimationFrame(() => {
    if (!view.dom.isConnected) return;
    view.dispatch(spec);
    after?.();
  });
}

function clampCaretOffset(value: number | null | undefined, text: string): number {
  if (!Number.isFinite(value)) return text.length;
  return Math.max(0, Math.min(text.length, value ?? text.length));
}

function selectionBeforeTable(table: TableBlock): EditorSelection {
  return EditorSelection.cursor(table.from, -1);
}

function selectionAfterTable(table: TableBlock): EditorSelection {
  return EditorSelection.cursor(table.to, 1);
}

function setPendingFocusTarget(view: EditorView, target: ActiveTableCellTarget | null): void {
  pendingFocusTargetByView.set(view, target);
}

function consumePendingFocusTarget(view: EditorView): ActiveTableCellTarget | null {
  const target = pendingFocusTargetByView.get(view) ?? null;
  pendingFocusTargetByView.delete(view);
  return target;
}

function tableControllerMapForView(view: EditorView): Map<string, TableDomController> {
  let map = tableControllersByView.get(view);
  if (!map) {
    map = new Map<string, TableDomController>();
    tableControllersByView.set(view, map);
  }
  return map;
}

function getTableController(view: EditorView, table: TableBlock, structuralEditing: boolean): TableDomController {
  const map = tableControllerMapForView(view);
  let controller = map.get(table.id);
  if (!controller) {
    controller = new TableDomController(view, table, structuralEditing);
    map.set(table.id, controller);
  }
  return controller;
}

function cleanupStaleTableControllers(view: EditorView, tables: readonly TableBlock[]): void {
  const keep = new Set(tables.map((table) => table.id));
  const map = tableControllerMapForView(view);

  for (const [id, controller] of map) {
    if (keep.has(id)) continue;
    controller.destroy();
    map.delete(id);
  }
}

function tableRenderableRows(table: Pick<TableBlock, "rows">): TableRow[] {
  return table.rows.filter((row) => row.kind !== "delimiter");
}

function collapseTableCellWhitespace(text: string): string {
  return normalizedCellText(text).replace(/\s+/g, " ");
}

function longestTableCellSegmentLength(text: string): number {
  const segments = collapseTableCellWhitespace(text).split(/\s+/).filter(Boolean);
  let longest = 0;

  for (const segment of segments) {
    longest = Math.max(longest, segment.length);
  }

  return longest;
}

function estimatePreferredColumnWidthPx(text: string): number {
  const collapsed = collapseTableCellWhitespace(text);
  if (!collapsed.length) {
    return TABLE_COLUMN_MIN_WIDTH_PX;
  }

  const longestSegmentLength = longestTableCellSegmentLength(collapsed);
  const balancedLineLength = Math.ceil(Math.sqrt(collapsed.length * 10));
  const targetCharacters = Math.max(8, Math.min(36, Math.max(longestSegmentLength, balancedLineLength)));
  const width = Math.ceil(targetCharacters * TABLE_AVERAGE_CHAR_WIDTH_PX + TABLE_CELL_HORIZONTAL_PADDING_PX);

  return Math.max(TABLE_COLUMN_MIN_WIDTH_PX, Math.min(TABLE_COLUMN_MAX_WIDTH_PX, width));
}

function estimateWrappedLineCount(text: string, charactersPerLine: number): number {
  const paragraphs = text
    .split(/\r?\n/g)
    .map((paragraph) => paragraph.trim())
    .filter((paragraph) => paragraph.length > 0);

  if (!paragraphs.length) {
    return 1;
  }

  let lines = 0;

  for (const paragraph of paragraphs) {
    const words = paragraph.split(/\s+/).filter(Boolean);
    if (!words.length) {
      lines += 1;
      continue;
    }

    let currentLineLength = 0;
    lines += 1;

    for (const word of words) {
      if (currentLineLength === 0) {
        currentLineLength = word.length;
        continue;
      }

      if (currentLineLength + 1 + word.length <= charactersPerLine) {
        currentLineLength += 1 + word.length;
        continue;
      }

      lines += 1;
      currentLineLength = word.length;
    }
  }

  return Math.max(1, lines);
}

function estimateRowHeightPx(row: TableRow, columnWidthsPx: readonly number[]): number {
  let lineCount = 1;

  for (let column = 0; column < row.cells.length; column += 1) {
    const cell = row.cells[column];
    const width = columnWidthsPx[column] ?? TABLE_COLUMN_MIN_WIDTH_PX;
    const charactersPerLine = Math.max(
      6,
      Math.floor((width - TABLE_CELL_HORIZONTAL_PADDING_PX) / TABLE_AVERAGE_CHAR_WIDTH_PX),
    );
    lineCount = Math.max(lineCount, estimateWrappedLineCount(collapseTableCellWhitespace(cell?.text ?? ""), charactersPerLine));
  }

  return Math.max(
    TABLE_ROW_MIN_HEIGHT_PX,
    TABLE_CELL_VERTICAL_PADDING_PX + lineCount * TABLE_TEXT_LINE_HEIGHT_PX,
  );
}

export function computeTableLayout(rows: readonly TableRow[]): TableLayout {
  const renderableRows = rows.filter((row) => row.kind !== "delimiter");
  const columnCount = renderableRows.reduce((max, row) => Math.max(max, row.cells.length), 0);
  const columnWidthsPx = Array.from({ length: columnCount }, () => TABLE_COLUMN_MIN_WIDTH_PX);

  for (const row of renderableRows) {
    for (let column = 0; column < row.cells.length; column += 1) {
      const cell = row.cells[column];
      if (!cell) continue;
      columnWidthsPx[column] = Math.max(columnWidthsPx[column] ?? TABLE_COLUMN_MIN_WIDTH_PX, estimatePreferredColumnWidthPx(cell.text));
    }
  }

  const rowHeightsPx = renderableRows.map((row) => estimateRowHeightPx(row, columnWidthsPx));
  const tableWidthPx = columnWidthsPx.reduce((sum, width) => sum + width, 0);
  const estimatedHeightPx = Math.max(
    40,
    TABLE_WIDGET_VERTICAL_PADDING_PX +
      TABLE_WRAPPER_BORDER_PX +
      rowHeightsPx.reduce((sum, height) => sum + height, 0) +
      Math.max(0, rowHeightsPx.length - 1) * TABLE_ROW_DIVIDER_PX,
  );

  return {
    columnWidthsPx,
    rowHeightsPx,
    tableWidthPx,
    estimatedHeightPx,
  };
}

function sameRenderableTableShape(left: TableBlock, right: TableBlock): boolean {
  const leftRows = tableRenderableRows(left);
  const rightRows = tableRenderableRows(right);
  if (leftRows.length !== rightRows.length) return false;

  for (let rowIndex = 0; rowIndex < leftRows.length; rowIndex += 1) {
    const leftRow = leftRows[rowIndex]!;
    const rightRow = rightRows[rowIndex]!;
    if (leftRow.kind !== rightRow.kind) return false;
    if (leftRow.cells.length !== rightRow.cells.length) return false;
  }

  return true;
}

function firstEditableCellTarget(table: TableBlock): ActiveTableCellTarget | null {
  for (let rowIndex = 0; rowIndex < table.rows.length; rowIndex += 1) {
    const row = table.rows[rowIndex];
    if (!row || row.kind === "delimiter") continue;
    const cell = row.cells[0];
    if (!cell) continue;
    return { anchorPos: cell.from, rowIndex, column: 0 };
  }
  return null;
}

function lastEditableCellTarget(table: TableBlock): ActiveTableCellTarget | null {
  for (let rowIndex = table.rows.length - 1; rowIndex >= 0; rowIndex -= 1) {
    const row = table.rows[rowIndex];
    if (!row || row.kind === "delimiter") continue;
    const column = row.cells.length - 1;
    const cell = row.cells[column];
    if (!cell) continue;
    return { anchorPos: cell.from, rowIndex, column };
  }
  return null;
}

function activateTableBoundaryCell(view: EditorView, tableParser: TableParser, direction: -1 | 1): boolean {
  const selection = view.state.selection;
  if (selection.ranges.length !== 1 || !selection.main.empty) {
    return false;
  }

  const head = selection.main.head;
  const headLine = view.state.doc.lineAt(head).number;

  for (const table of tableParser(view.state)) {
    const firstLine = table.rows[0]?.lineNo;
    const lastLine = table.rows[table.rows.length - 1]?.lineNo;

    if (
      direction > 0 &&
      (head === table.from || head === table.from - 1 || (firstLine != null && headLine === firstLine - 1))
    ) {
      const target = firstEditableCellTarget(table);
      if (!target) return false;
      view.dispatch({ effects: [setActiveTableCellEffect.of(target)], userEvent: "select.pointer" });
      return true;
    }

    if (
      direction < 0 &&
      (head === table.to || head === table.to + 1 || (lastLine != null && headLine === lastLine + 1))
    ) {
      const target = lastEditableCellTarget(table);
      if (!target) return false;
      view.dispatch({ effects: [setActiveTableCellEffect.of(target)], userEvent: "select.pointer" });
      return true;
    }
  }

  return false;
}

class TableDomController {
  readonly root: HTMLDivElement;
  private readonly wrapper: HTMLDivElement;
  private readonly tableElement: HTMLTableElement;
  private readonly colgroup: HTMLTableColElement;
  private readonly thead: HTMLTableSectionElement;
  private readonly tbody: HTMLTableSectionElement;
  private readonly input: HTMLTextAreaElement;
  private table: TableBlock;
  private activeCell: ActiveTableCellRef | null = null;
  private lastEditingKey: string | null = null;
  private cellRefs = new Map<string, TableCellDomRef>();
  private measureFrame: number | null = null;
  private destroyed = false;
  private finishing = false;
  private suppressNextBlur = false;

  constructor(
    private readonly view: EditorView,
    table: TableBlock,
    private readonly structuralEditing: boolean,
  ) {
    this.table = table;

    this.root = document.createElement("div");
    this.root.className = "nv3-table-widget";
    this.root.dataset.nv3TableId = table.id;
    this.root.dataset.nv3SourceRoot = "";

    this.wrapper = document.createElement("div");
    this.wrapper.className = "nv3-table-wrapper";

    this.tableElement = document.createElement("table");
    this.tableElement.className = "nv3-table-ui";
    this.tableElement.tabIndex = 0;
    this.tableElement.addEventListener("keydown", (event) => this.handleTableKeyDown(event));

    this.colgroup = document.createElement("colgroup");
    this.thead = document.createElement("thead");
    this.tbody = document.createElement("tbody");
    this.tableElement.append(this.colgroup, this.thead, this.tbody);
    this.applyLayout();
    this.wrapper.append(this.tableElement);
    this.root.append(this.wrapper);

    this.input = document.createElement("textarea");
    this.input.className = "nv3-table-ui-input";
    this.input.rows = 1;
    this.input.wrap = "soft";
    this.input.spellcheck = true;
    this.installInputHandlers();

    this.renderRows();
  }

  updateTable(table: TableBlock): void {
    const previousTable = this.table;
    this.table = table;
    this.root.dataset.nv3TableId = table.id;
    this.applyLayout();

    if (!sameRenderableTableShape(previousTable, table)) {
      this.renderRows();
      return;
    }

    this.patchRows();
  }

  syncActiveCell(activeCell: ActiveTableCellRef | null): void {
    this.setActiveCell(activeCell, true);
  }

  destroy(): void {
    this.destroyed = true;
    if (this.measureFrame != null) {
      cancelAnimationFrame(this.measureFrame);
      this.measureFrame = null;
    }
    this.input.remove();
    this.cellRefs.clear();
  }

  private installInputHandlers(): void {
    this.input.addEventListener("mousedown", (event) => {
      event.stopPropagation();
    });

    this.input.addEventListener("click", (event) => {
      event.stopPropagation();
    });

    this.input.addEventListener("input", () => {
      this.syncInputMirror();
      this.scheduleMeasure();
    });

    this.input.addEventListener("keydown", (event) => {
      const active = this.activeCell;
      if (!active) return;

      if (event.key === "Tab") {
        event.preventDefault();
        const direction = event.shiftKey ? -1 : 1;
        const nextTarget = nextEditableCellTarget(
          this.table,
          active.rowIndex,
          active.column,
          direction,
          this.input.selectionStart ?? this.input.value.length,
        );

        if (!nextTarget && direction < 0) {
          return;
        }

        this.suppressNextBlur = true;
        this.finishEditing({
          commit: true,
          nextTarget: nextTarget ? { ...nextTarget, editing: true } : null,
          afterCommit: !nextTarget && direction > 0 ? () => this.appendRowAfterEnd(true) : undefined,
        });
        return;
      }

      if (event.key === "Enter") {
        event.preventDefault();
        this.suppressNextBlur = true;
        this.finishEditing({
          commit: true,
          nextTarget: {
            anchorPos: this.table.rows[active.rowIndex]?.cells[active.column]?.from ?? this.table.from,
            rowIndex: active.rowIndex,
            column: active.column,
            editing: false,
          },
        });
        return;
      }

      if (event.key === "Escape") {
        event.preventDefault();
        this.suppressNextBlur = true;
        this.finishEditing({
          commit: false,
          nextTarget: {
            anchorPos: this.table.rows[active.rowIndex]?.cells[active.column]?.from ?? this.table.from,
            rowIndex: active.rowIndex,
            column: active.column,
            editing: false,
          },
        });
      }
    });

    this.input.addEventListener("blur", () => {
      if (this.suppressNextBlur) {
        this.suppressNextBlur = false;
        consumePendingFocusTarget(this.view);
        return;
      }

      const pendingTarget = consumePendingFocusTarget(this.view);
      this.finishEditing({ commit: true, nextTarget: pendingTarget });
    });
  }

  private handleTableKeyDown(event: KeyboardEvent): void {
    if (event.target === this.input) return;

    const active = this.activeCell;
    if (!active || active.editing) return;

    if (event.key === "Enter" || event.key === "F2") {
      event.preventDefault();
      this.focusCell(active.rowIndex, active.column, true);
      return;
    }

    if (event.key === "Tab") {
      event.preventDefault();
      const direction = event.shiftKey ? -1 : 1;
      const nextTarget = nextEditableCellTarget(this.table, active.rowIndex, active.column, direction);
      if (nextTarget) {
        this.focusCell(nextTarget.rowIndex, nextTarget.column, false);
        return;
      }
      if (direction > 0) {
        this.appendRowAfterEnd(false);
      }
      return;
    }

    let nextTarget: ActiveTableCellTarget | null = null;
    if (event.key === "ArrowLeft") {
      if (active.column > 0) {
        const row = this.table.rows[active.rowIndex];
        const cell = row?.cells[active.column - 1];
        if (cell) {
          nextTarget = { anchorPos: cell.from, rowIndex: active.rowIndex, column: active.column - 1 };
        }
      }
    } else if (event.key === "ArrowRight") {
      const row = this.table.rows[active.rowIndex];
      if (row && active.column < row.cells.length - 1) {
        const cell = row.cells[active.column + 1];
        if (cell) {
          nextTarget = { anchorPos: cell.from, rowIndex: active.rowIndex, column: active.column + 1 };
        }
      }
    } else if (event.key === "ArrowUp") {
      nextTarget = moveVerticalCellTarget(this.table, active.rowIndex, active.column, -1);
    } else if (event.key === "ArrowDown") {
      nextTarget = moveVerticalCellTarget(this.table, active.rowIndex, active.column, 1);
    }

    if (nextTarget) {
      event.preventDefault();
      this.focusCell(nextTarget.rowIndex, nextTarget.column, false);
    }
  }

  private focusCell(rowIndex: number, column: number, editing: boolean, caretOffset?: number): void {
    const row = this.table.rows[rowIndex];
    const cell = row?.cells[column];
    if (!row || !cell || row.kind === "delimiter") return;

    dispatchTableUpdate(this.view, {
      effects: [
        setActiveTableCellEffect.of({
          anchorPos: cell.from,
          rowIndex,
          column,
          caretOffset,
          editing,
        }),
      ],
      userEvent: "select.pointer",
    });
  }

  private appendRowAfterEnd(editing: boolean): void {
    if (!this.structuralEditing) {
      return;
    }
    const applied = applyMarkdownTableTransform(
      this.view,
      this.table,
      "insertRowBelow",
      this.table.rows.length - 1,
      0,
    );
    if (!applied) return;

    requestAnimationFrame(() => {
      const target = this.view.state.field(activeTableCellField, false) ?? null;
      if (!target) return;
      this.view.dispatch({
        effects: [setActiveTableCellEffect.of({ ...target, editing })],
        userEvent: "select.pointer",
      });
    });
  }

  private syncInputMirror(): void {
    if (!this.activeCell) return;
    const ref = this.cellRefs.get(`${this.activeCell.rowIndex}:${this.activeCell.column}`);
    if (!ref) return;
    ref.display.textContent = this.input.value.trim() || " ";
    ref.renderedSource = null;
  }

  private scheduleMeasure(): void {
    if (this.measureFrame != null) return;
    this.measureFrame = requestAnimationFrame(() => {
      this.measureFrame = null;
      if (!this.destroyed && this.root.isConnected) {
        this.view.requestMeasure();
      }
    });
  }

  private finishEditing(options?: {
    commit?: boolean;
    nextTarget?: ActiveTableCellTarget | null;
    nextSelection?: EditorSelection;
    focusEditor?: boolean;
    afterCommit?: () => void;
  }): void {
    if (this.destroyed) return;
    if (this.finishing) return;
    if (!this.activeCell) return;

    this.finishing = true;

    const row = this.table.rows[this.activeCell.rowIndex];
    const cell = row?.cells[this.activeCell.column];
    if (!row || !cell) {
      this.finishing = false;
      return;
    }

    const currentValue = normalizedCellText(cell.text);
    const nextValue = this.input.value;
    const changed = currentValue !== nextValue;

    const changes = options?.commit && changed
      ? {
          from: row.from,
          to: row.to,
          insert: serializeTableDataRow(row, { [cell.column]: nextValue }),
        }
      : undefined;

    dispatchTableUpdate(
      this.view,
      {
        changes,
        effects: [setActiveTableCellEffect.of(options?.nextTarget ?? null)],
        selection: options?.nextSelection,
        scrollIntoView: false,
        userEvent: options?.commit ? "input.type" : "select.pointer",
      },
      () => {
        this.finishing = false;
        options?.afterCommit?.();
        if (options?.focusEditor) {
          focusEditorWithoutScroll(this.view);
        }
      },
    );
  }

  private applyLayout(): void {
    this.colgroup.textContent = "";

    const intrinsicWidth = Math.max(this.table.layout.tableWidthPx, TABLE_COLUMN_MIN_WIDTH_PX);
    this.root.dataset.nv3TableRowCount = String(tableRenderableRows(this.table).length);
    this.root.dataset.nv3TableColumnCount = String(this.table.layout.columnWidthsPx.length);

    for (const width of this.table.layout.columnWidthsPx) {
      const column = document.createElement("col");
      column.style.width = `${(width / intrinsicWidth) * 100}%`;
      this.colgroup.append(column);
    }

    this.tableElement.style.width = "100%";
    this.tableElement.style.minWidth = `${intrinsicWidth}px`;
  }

  private patchRows(): void {
    const renderedRows = tableRenderableRows(this.table);

    for (const row of renderedRows) {
      const sourceRowIndex = this.table.rows.indexOf(row);
      for (const cell of row.cells) {
        const ref = this.cellRefs.get(`${sourceRowIndex}:${cell.column}`);
        if (!ref) continue;
        renderTableCellDisplay(ref, cell.text);
        stampTableCellSource(ref, cell, this.table, this.view);
      }
    }

    this.setActiveCell(this.activeCell, false);
  }

  private renderRows(): void {
    this.cellRefs.clear();
    this.thead.textContent = "";
    this.tbody.textContent = "";

    for (let rowIndex = 0; rowIndex < this.table.rows.length; rowIndex += 1) {
      const row = this.table.rows[rowIndex]!;
      if (row.kind === "delimiter") continue;

      const sourceRowIndex = rowIndex;
      const rowElement = document.createElement("tr");
      rowElement.className = `nv3-table-ui-row nv3-table-ui-row-${row.kind}`;

      for (const cell of row.cells) {
        const isHeader = row.kind === "header";
        const cellElement = document.createElement(isHeader ? "th" : "td");
        cellElement.className = `nv3-table-ui-cell nv3-table-ui-cell-${row.kind}`;
        cellElement.dataset.nv3TableRowIndex = String(sourceRowIndex);
        cellElement.dataset.nv3TableColumn = String(cell.column);
        cellElement.dataset.nv3TableRowKind = row.kind;

        const content = document.createElement("div");
        content.className = "nv3-table-ui-cell-content";
        content.dataset.nv3TableRowIndex = String(sourceRowIndex);
        content.dataset.nv3TableColumn = String(cell.column);
        content.dataset.nv3TableRowKind = row.kind;

        const display = document.createElement("div");
        display.className = "nv3-table-ui-cell-display";
        display.setAttribute(
          "aria-label",
          `Edit ${isHeader ? "header" : "cell"} ${cell.column + 1}`,
        );

        const target: ActiveTableCellTarget = {
          anchorPos: cell.from,
          rowIndex: sourceRowIndex,
          column: cell.column,
        };

        content.addEventListener("mousedown", (event) => {
          event.preventDefault();
        });

        content.addEventListener("click", (event) => {
          if (resolveEventElement(event.target)?.closest("a[data-nv3-wikilink='true']")) return;
          event.preventDefault();
          const editing = event.detail > 1;
          if (this.activeCell?.editing) {
            setPendingFocusTarget(this.view, { ...target, editing });
            this.input.blur();
            return;
          }

          dispatchTableUpdate(this.view, {
            effects: [setActiveTableCellEffect.of({ ...target, editing })],
            userEvent: "select.pointer",
          });
        });

        content.append(display);
        cellElement.append(content);
        rowElement.append(cellElement);

        const cellRef: TableCellDomRef = {
          cell: cellElement,
          content,
          display,
          renderedSource: null,
        };
        renderTableCellDisplay(cellRef, cell.text);
        stampTableCellSource(cellRef, cell, this.table, this.view);
        this.cellRefs.set(`${sourceRowIndex}:${cell.column}`, cellRef);
      }

      if (row.kind === "header") {
        this.thead.append(rowElement);
      } else {
        this.tbody.append(rowElement);
      }
    }

    this.setActiveCell(this.activeCell, false);
  }

  private setActiveCell(activeCell: ActiveTableCellRef | null, focus: boolean): void {
    const previousKey = this.lastEditingKey;
    if (previousKey) {
      const previous = this.cellRefs.get(previousKey);
      const previousRow = this.activeCell ? this.table.rows[this.activeCell.rowIndex] : undefined;
      const previousCell = this.activeCell ? previousRow?.cells[this.activeCell.column] : undefined;
      if (previous && previousCell) {
        renderTableCellDisplay(previous, previousCell.text);
      }
      previous?.cell.classList.remove("is-active");
      if (previous) delete previous.display.dataset.nv3SourceActive;
      previous?.content.classList.remove("is-editing");
      previous?.display.classList.remove("is-measure-only");
    }

    this.input.remove();
    this.activeCell = activeCell;
    this.lastEditingKey = null;

    if (!activeCell) {
      return;
    }

    const key = `${activeCell.rowIndex}:${activeCell.column}`;
    const cellRef = this.cellRefs.get(key);
    const row = this.table.rows[activeCell.rowIndex];
    const cell = row?.cells[activeCell.column];
    if (!cellRef || !row || !cell || row.kind === "delimiter") {
      return;
    }

    this.lastEditingKey = key;
    cellRef.cell.classList.add("is-active");
    // Publish what the active cell and its editor show, for selection-aware
    // plugins (annotations); the editor's value is the cell's trimmed source.
    cellRef.display.dataset.nv3SourceActive = "";
    this.input.dataset.nv3SourceFrom = String(cell.from - this.table.from);
    this.input.dataset.nv3SourceTo = String(cell.to - this.table.from);
    this.input.value = normalizedCellText(cell.text);
    this.input.setAttribute("aria-label", `${row.kind === "header" ? "Header" : "Cell"} ${cell.column + 1}`);

    if (activeCell.editing) {
      cellRef.content.classList.add("is-editing");
      cellRef.display.classList.add("is-measure-only");
      cellRef.content.append(this.input);
      this.syncInputMirror();
    }

    if (focus) {
      requestAnimationFrame(() => {
        const target = activeCell.editing ? this.input : this.tableElement;
        if (!target.isConnected) return;
        try {
          target.focus({ preventScroll: true });
        } catch {
          target.focus();
        }
        if (activeCell.editing) {
          const offset = clampCaretOffset(activeCell.caretOffset, this.input.value);
          this.input.setSelectionRange(offset, offset);
        }
      });
    }
  }
}

class MarkdownTableWidget extends WidgetType {
  constructor(
    readonly table: TableBlock,
    private readonly structuralEditing: boolean,
  ) {
    super();
  }

  override get lineBreaks(): number {
    return Math.max(0, this.table.rows.length - 1);
  }

  override get estimatedHeight(): number {
    return this.table.layout.estimatedHeightPx;
  }

  override eq(other: MarkdownTableWidget): boolean {
    return other.table.signature === this.table.signature && other.table.id === this.table.id;
  }

  override toDOM(view: EditorView): HTMLElement {
    return getTableController(view, this.table, this.structuralEditing).root;
  }

  override updateDOM(dom: HTMLElement, view: EditorView): boolean {
    const controller = getTableController(view, this.table, this.structuralEditing);
    controller.updateTable(this.table);
    return dom === controller.root;
  }

  override ignoreEvent(event: Event): boolean {
    // Let the existing link plugin handle clicks, including Shift-click routing.
    return !(
      (event.type === "mousedown" || event.type === "click") &&
      resolveEventElement(event.target)?.closest("a[data-nv3-wikilink='true']")
    );
  }
}

function buildDecorations(tables: readonly TableBlock[], structuralEditing: boolean): DecorationSet {
  const ranges: Array<import("@codemirror/state").Range<Decoration>> = [];

  for (const table of tables) {
    ranges.push(
      Decoration.replace({
        block: true,
        widget: new MarkdownTableWidget(table, structuralEditing),
      }).range(table.from, table.to),
    );
  }

  ranges.sort((left, right) => left.from - right.from || left.to - right.to);
  return Decoration.set(ranges, true);
}

export function createTablesExtension(
  tableParser: TableParser,
  options: { structuralEditing?: boolean } = {},
): Extension {
  const structuralEditing = Boolean(options.structuralEditing);
  const tableDecorationsField = StateField.define<DecorationSet>({
    create(state) {
      return buildDecorations(tableParser(state), structuralEditing);
    },

    update(decorations, transaction) {
      if (!transaction.docChanged) {
        return decorations;
      }

      return buildDecorations(tableParser(transaction.state), structuralEditing);
    },

    provide(field) {
      return EditorView.decorations.from(field);
    },
  });

  const syncPluginWithView = ViewPlugin.fromClass(
    class {
      private tables: TableBlock[];
      private activeCell: ActiveTableCellTarget | null;
      constructor(private readonly view: EditorView) {
        this.tables = tableParser(view.state);
        this.activeCell = view.state.field(activeTableCellField, false) ?? null;
        this.sync(view.state, true);
      }

      update(update: ViewUpdate) {
        const nextActive = update.state.field(activeTableCellField, false) ?? null;
        const activeChanged = !sameActiveTableCellTarget(this.activeCell, nextActive);

        if (update.docChanged) {
          this.tables = tableParser(update.state);
        }

        if (!update.docChanged && !activeChanged) {
          return;
        }

        this.activeCell = nextActive;
        this.sync(update.state, update.docChanged);
      }

      destroy() {
        cleanupStaleTableControllers(this.view, []);
      }

      private sync(state: import("@codemirror/state").EditorState, structureChanged: boolean) {
        cleanupStaleTableControllers(this.view, this.tables);
        for (const table of this.tables) {
          const controller = getTableController(this.view, table, structuralEditing);
          if (structureChanged) {
            controller.updateTable(table);
          }
          controller.syncActiveCell(activeCellRefForTable(state, table));
        }
      }
    },
  );

  return [
    activeTableCellField,
    tableDecorationsField,
    syncPluginWithView,
    Prec.highest(EditorView.domEventHandlers({
      keydown(event, view) {
        if (event.key === "ArrowDown") {
          if (activateTableBoundaryCell(view, tableParser, 1)) {
            event.preventDefault();
            return true;
          }
        }

        if (event.key === "ArrowUp") {
          if (activateTableBoundaryCell(view, tableParser, -1)) {
            event.preventDefault();
            return true;
          }
        }

        return false;
      },
    })),
  ];
}

export function createMarkdownTablesExtension(): Extension {
  return createTablesExtension(parseMarkdownTables, { structuralEditing: true });
}
