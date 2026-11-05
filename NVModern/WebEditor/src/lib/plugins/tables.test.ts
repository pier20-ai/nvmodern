import { describe, expect, it } from "bun:test";
import { EditorState } from "@codemirror/state";
import { renderBasicInlineMarkdown } from "./inlineMarkdown.ts";
import { createMarkdownLinkExtension } from "./links.ts";
import { parseMarkdownTables, pipeOffsetsForTableRow, tableWikilinkAttributes, transformMarkdownTableBlock } from "./tables.ts";

const wikilinkTable = [
  "| Interpretation | Why it matters |",
  "|---|---|",
  "| [[papers/context/portfolio-balance-and-term-premium|Portfolio rebalancing]] | Removing duration can lower yields and ease financing. |",
  "| [[papers/context/consolidated-government-balance-sheet|Government refinancing]] | Treasury purchases replace bonds with reserves, preserving public liabilities. |",
  "| Stock versus flow | Holding purchased assets sustains accommodation after purchases stop. |",
  "| [[papers/context/bank-money-creation|Lending and inflation]] | Banks create deposits through lending; reserves don't mechanically multiply into loans or runaway inflation. |",
  "| Exit | Sales or maturities shrink holdings; rate increases needn't wait. |",
].join("\n");

describe("parseMarkdownTables", () => {
  it("resolves clickable cell links with current source positions after edits above a table", () => {
    let state = EditorState.create({
      doc: "Before\n\n| A | B |\n|---|---|\n|   😀 [[note#Heading|Title]] and [[other|Title]] | value |",
      extensions: [createMarkdownLinkExtension({
        filePath: "workspace/current.md",
        resolveWikilinkHref: ({ target, occurrence, filePath }) => `${filePath}:${occurrence.from}:${target}`,
      })],
    });
    for (let edit = 0; edit < 2; edit++) {
      const cell = parseMarkdownTables(state)[0]!.rows[2]!.cells[0]!;
      const links = renderBasicInlineMarkdown(cell.text.trim()).filter((node) => node.kind === "wikilink");
      expect(links).toHaveLength(2);
      for (const link of links) {
        const attributes = tableWikilinkAttributes(state, cell, link);
        const from = Number(attributes["data-nv3-from"]);
        const to = Number(attributes["data-nv3-to"]);
        expect(state.sliceDoc(from, to)).toBe(`[[${link.target}]]`);
        expect(attributes["data-nv3-wikilink"]).toBe("true");
        expect(attributes["data-nv3-target"]).toBe(link.target);
        expect(attributes.href).toBe(`workspace/current.md:${from}:${link.target}`);
      }
      state = state.update({ changes: { from: 0, insert: "New paragraph\n\n" } }).state;
    }
  });

  it("keeps wikilink title separators inside their cells without losing the next column", () => {
    const state = EditorState.create({ doc: wikilinkTable });
    const tables = parseMarkdownTables(state);
    expect(tables).toHaveLength(1);
    const table = tables[0]!;
    expect(table.rows).toHaveLength(7);
    expect(table.rows.every((row) => row.cells.length === 2)).toBe(true);
    expect(table.rows[2]?.cells.map((cell) => cell.text.trim())).toEqual([
      "[[papers/context/portfolio-balance-and-term-premium|Portfolio rebalancing]]",
      "Removing duration can lower yields and ease financing.",
    ]);
    expect(table.rows[5]?.cells[1]?.text.trim()).toBe(
      "Banks create deposits through lending; reserves don't mechanically multiply into loans or runaway inflation.",
    );
    for (const row of table.rows) {
      expect(row.delimiterPositions).toHaveLength(3);
      for (const cell of row.cells) expect(state.sliceDoc(cell.from, cell.to)).toBe(cell.text);
    }
  });

  it("preserves titled wikilinks through structural table edits", () => {
    const table = parseMarkdownTables(EditorState.create({ doc: wikilinkTable }))[0]!;
    const result = transformMarkdownTableBlock(table, "insertColumnRight", 2, 0)!;
    expect(result.text).toContain("[[papers/context/portfolio-balance-and-term-premium|Portfolio rebalancing]]");
    expect(result.text).not.toContain("\\|");
    const roundTrip = parseMarkdownTables(EditorState.create({ doc: result.text }))[0]!;
    expect(roundTrip.rows.every((row) => row.cells.length === 3)).toBe(true);
    expect(roundTrip.rows[2]?.cells[0]?.text).toBe(table.rows[2]?.cells[0]?.text);
    expect(roundTrip.rows[2]?.cells[2]?.text).toBe(table.rows[2]?.cells[1]?.text);
  });

  it("distinguishes wikilinks, code, escaped pipes, and incomplete wikilinks", () => {
    for (const text of [
      "| [[note#Heading|Title]] and [[other#^block|Other]] | value |",
      "| [[note\\|Title]] | value |",
      "| `[[literal|link]]` and ``a|b`` | value |",
      "| escaped \\| pipe | value |",
      "| [[incomplete | value |",
    ]) {
      expect(pipeOffsetsForTableRow(text)).toHaveLength(3);
    }
  });

  it("escapes literal pipes after non-BMP text without changing wikilink separators", () => {
    const input = "| A | B |\n|---|---|\n| 😀 [[note|Title]] \\| literal | `x|y` |";
    const table = parseMarkdownTables(EditorState.create({ doc: input }))[0]!;
    const result = transformMarkdownTableBlock(table, "insertRowBelow", 2, 0)!;
    expect(result.text).toContain("😀 [[note|Title]] \\| literal");
    expect(result.text).toContain("`x|y`");
    expect(parseMarkdownTables(EditorState.create({ doc: result.text }))[0]?.rows[2]?.cells).toHaveLength(2);
  });

  it("keeps shorter GFM body rows in the table and pads trailing cells", () => {
    const input = [
      "| Option | Form | Role | Evaluation | Valid on |",
      "|---|---|---|---|---|",
      "| `as <name>` | Binds the scope's runtime instance to a local name | Runtime | `strategy`, `trade` |",
      "| `on <expr>` | Associates the scope with a value (typically a trigger symbol) | Compile-time | `strategy` |",
      "| `every <expr>` | Cadence specifier for timer-driven scopes | Compile-time | `strategy` |",
      "| `with <expr>` | Comptime scope composition (§6.5) | Compile-time | any scope admitting body items |",
    ].join("\n");

    const state = EditorState.create({ doc: input });
    const tables = parseMarkdownTables(state);

    expect(tables).toHaveLength(1);

    const table = tables[0];
    expect(table?.rows).toHaveLength(6);

    const bodyRows = table?.rows.filter((row) => row.kind === "body") ?? [];
    expect(bodyRows).toHaveLength(4);
    expect(bodyRows.every((row) => row.cells.length === 5)).toBe(true);

    expect(bodyRows[0]?.cells[0]?.text.trim()).toBe("`as <name>`");
    expect(bodyRows[0]?.cells[3]?.text.trim()).toBe("`strategy`, `trade`");
    expect(bodyRows[0]?.cells[4]?.text).toBe("");

    expect(table?.layout.columnWidthsPx).toHaveLength(5);
    expect(table?.layout.columnWidthsPx[1]).toBeGreaterThan(table?.layout.columnWidthsPx[0] ?? 0);
    expect(table?.layout.estimatedHeightPx).toBeGreaterThan(200);
  });

  it("keeps longer GFM body rows in the table and ignores extra trailing cells", () => {
    const input = [
      "| A | B | C |",
      "|---|---|---|",
      "| 1 | 2 | 3 | 4 | 5 |",
    ].join("\n");

    const state = EditorState.create({ doc: input });
    const tables = parseMarkdownTables(state);

    expect(tables).toHaveLength(1);

    const table = tables[0];
    const bodyRow = table?.rows.find((row) => row.kind === "body");

    expect(bodyRow?.cells).toHaveLength(3);
    expect(bodyRow?.cells.map((cell) => cell.text.trim())).toEqual(["1", "2", "3"]);
    expect(table?.layout.columnWidthsPx).toHaveLength(3);
  });

  it("computes stable whole-table fixed widths from all rows", () => {
    const input = [
      "| Name | Description | Status |",
      "|---|---|---|",
      "| short | some much longer prose that should widen the description column | ok |",
      "| much-longer-name | tiny | pending |",
    ].join("\n");

    const state = EditorState.create({ doc: input });
    const table = parseMarkdownTables(state)[0];

    expect(table?.layout.columnWidthsPx).toHaveLength(3);
    expect(table?.layout.columnWidthsPx[1]).toBeGreaterThan(table?.layout.columnWidthsPx[0] ?? 0);
    expect(table?.layout.tableWidthPx).toBe(
      (table?.layout.columnWidthsPx ?? []).reduce((sum, width) => sum + width, 0),
    );
  });

  it("serializes row and column structural edits", () => {
    const input = [
      "| Name | Status |",
      "|:---|---:|",
      "| Alpha | Done |",
      "| Beta | Todo |",
    ].join("\n");
    const state = EditorState.create({ doc: input });
    const table = parseMarkdownTables(state)[0];
    expect(table).toBeTruthy();

    const insertedColumn = transformMarkdownTableBlock(table!, "insertColumnRight", 2, 0);
    expect(insertedColumn?.text).toBe(
      [
        "| Name | | Status |",
        "| :--- | --- | ---: |",
        "| Alpha | | Done |",
        "| Beta | | Todo |",
      ].join("\n"),
    );
    expect(insertedColumn?.nextColumn).toBe(1);

    const movedRow = transformMarkdownTableBlock(table!, "moveRowDown", 2, 1);
    expect(movedRow?.text).toBe(
      [
        "| Name | Status |",
        "| :--- | ---: |",
        "| Beta | Todo |",
        "| Alpha | Done |",
      ].join("\n"),
    );
    expect(movedRow?.nextRowIndex).toBe(3);
  });

  it("adds a body row below the header for table growth", () => {
    const input = ["| Name | Status |", "|---|---|"].join("\n");
    const state = EditorState.create({ doc: input });
    const table = parseMarkdownTables(state)[0];
    expect(table).toBeTruthy();

    const result = transformMarkdownTableBlock(table!, "insertRowBelow", 0, 0);
    expect(result?.text).toBe(["| Name | Status |", "| --- | --- |", "| | |"].join("\n"));
    expect(result?.nextRowIndex).toBe(2);
    expect(result?.nextColumn).toBe(0);
    expect(result?.editing).toBe(true);
  });
});
