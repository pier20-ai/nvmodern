/**
 * Org-mode table support — adapter for the shared table rendering engine.
 *
 * Converts Nv3OrgTable data from the org parser into the TableBlock format
 * that the shared tables.ts measurement/rendering engine expects, then
 * installs the same measured-alignment ViewPlugin used for markdown tables.
 */
import type { Extension } from "@codemirror/state";
import { getNv3OrgParseResult } from "./orgIndex.ts";
import {
  computeTableLayout,
  createTablesExtension,
  parseTableRow,
  type TableBlock,
  type TableRow,
  type TableParser,
} from "./tables.ts";

/**
 * Parses org tables from the org parse result state field.
 * Converts Nv3OrgTable[] → TableBlock[] for the shared table engine.
 */
function parseOrgTables(state: import("@codemirror/state").EditorState): TableBlock[] {
  const result = getNv3OrgParseResult(state);
  if (!result || !result.tables.length) return [];

  const tables: TableBlock[] = [];

  for (const orgTable of result.tables) {
    if (!orgTable.rows.length) continue;

    // Determine column count from first non-rule data row
    const firstDataRow = orgTable.rows.find((r) => !r.isRule);
    if (!firstDataRow) continue;
    const columnCount = firstDataRow.cells.length;
    if (columnCount === 0) continue;

    const rows: TableRow[] = [];
    let isFirstDataRow = true;

    for (const orgRow of orgTable.rows) {
      const line = state.doc.line(orgRow.line);

      if (orgRow.isRule) {
        // Org rule rows use + between columns: |---+---+---|
        // Synthesize cells and delimiter positions to match the data row column count.
        const text = line.text;
        const firstPipe = text.indexOf("|");
        const lastPipe = text.lastIndexOf("|");
        if (firstPipe < 0 || lastPipe <= firstPipe) continue;

        const segment = text.slice(firstPipe + 1, lastPipe);
        // Split on + to get cell segments (e.g. "---+---+---" → ["---","---","---"])
        const parts = segment.split("+");
        const delimiterPositions = [line.from + firstPipe];
        const cells: import("./tables.ts").ParsedTableCell[] = [];
        let cursor = firstPipe + 1;

        for (let i = 0; i < parts.length; i++) {
          const part = parts[i] ?? "";
          const cellFrom = line.from + cursor;
          const cellTo = cellFrom + part.length;
          if (cellTo > cellFrom) {
            cells.push({ from: cellFrom, to: cellTo, column: i, text: part });
          }
          cursor += part.length;
          if (i < parts.length - 1) {
            delimiterPositions.push(line.from + cursor); // the + position
            cursor += 1; // skip the +
          }
        }
        delimiterPositions.push(line.from + lastPipe);

        rows.push({
          lineNo: orgRow.line,
          from: line.from,
          to: line.to,
          lineText: text,
          cells,
          delimiterPositions,
          kind: "delimiter",
        });
        continue;
      }

      // Data rows: use the pipe-based parser for accurate delimiter positions
      const parsed = parseTableRow(line);
      if (!parsed || parsed.cells.length !== columnCount) continue;

      rows.push({
        ...parsed,
        kind: isFirstDataRow ? "header" : "body",
      });
      isFirstDataRow = false;
    }

    if (rows.length < 1) continue;

    const from = rows[0]!.from;
    const to = rows[rows.length - 1]!.to;
    const signature = rows.map((r) => `${r.kind}:${r.lineText}`).join("\n");

    tables.push({
      id: `t-${from}-${to}`,
      from,
      to,
      signature,
      rows,
      layout: computeTableLayout(rows),
    });
  }

  return tables;
}

export function createOrgTablesExtension(): Extension {
  return createTablesExtension(parseOrgTables);
}
