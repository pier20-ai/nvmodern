import { EditorSelection, EditorState, type TransactionSpec } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import { describe, expect, it } from "bun:test";
import {
  buildShiftMarkdownTimestampsTransaction,
  createNv3MarkdownExtensions,
  formatMarkdownTimestamp,
  parseMarkdownTimestamp,
  scanMarkdownTimestamps,
  shiftISODate,
} from "../index.ts";
import { createMarkdownDatesExtension, openOrInsertMarkdownTimestamp, type Nv3MarkdownDatePickerRequest } from "./dates.ts";
import { todayISODateLocal } from "./dateUtils.ts";

describe("markdown dates", () => {
  for (const syntax of ["markdown", "org"] as const) {
    it(`inserts a new ${syntax} date with the appropriate brackets and existing date format`, () => {
      let request: Nv3MarkdownDatePickerRequest | undefined;
      let state = EditorState.create({
        doc: "Before selected after",
        selection: { anchor: 7, head: 15 },
        extensions: [createMarkdownDatesExtension({
          syntax,
          pickDate: async (input) => { request = input; return null; },
        })],
      });
      const view = {
        get state() { return state; },
        dispatch(spec: TransactionSpec) { state = state.update(spec).state; },
        contentDOM: { focus() {} },
      } as unknown as EditorView;
      expect(openOrInsertMarkdownTimestamp(view)).toBe(true);
      const kind = syntax === "org" ? "active" : "inactive";
      const expected = formatMarkdownTimestamp({ kind, syntax, isoDate: todayISODateLocal() });
      expect(state.doc.toString()).toBe(`Before ${expected} after`);
      expect(state.selection.main.head).toBe(7 + expected.length);
      expect(request).toMatchObject({ kind, raw: expected });
      expect(expected.startsWith(syntax === "org" ? "<" : "[")).toBe(true);
      expect(expected.endsWith(syntax === "org" ? ">" : "]")).toBe(true);
    });
  }

  it("formats timestamps using a readable month name and parses them back", () => {
    const inactive = formatMarkdownTimestamp({
      kind: "inactive",
      isoDate: "2026-03-08",
    });
    const active = formatMarkdownTimestamp({
      kind: "active",
      isoDate: "2026-03-09",
    });

    expect(inactive).toBe("[Mar 8, 2026 Sun]");
    expect(active).toBe("<Mar 9, 2026 Mon>");
    expect(parseMarkdownTimestamp(inactive)).toEqual({
      kind: "inactive",
      isoDate: "2026-03-08",
      weekday: "Sun",
      startTime: null,
      endTime: null,
      raw: "[Mar 8, 2026 Sun]",
    });
  });

  it("formats and parses date-times and time ranges for Markdown and org", () => {
    expect(formatMarkdownTimestamp({
      kind: "inactive",
      isoDate: "2026-03-08",
      startTime: "09:05",
      endTime: "10:30",
    })).toBe("[Mar 8, 2026 Sun 09:05-10:30]");

    const org = formatMarkdownTimestamp({
      kind: "active",
      syntax: "org",
      isoDate: "2026-03-08",
      startTime: "09:05",
      endTime: "10:30",
    });
    expect(org).toBe("<2026-03-08 Sun 09:05-10:30>");
    expect(parseMarkdownTimestamp(org)).toEqual({
      kind: "active",
      isoDate: "2026-03-08",
      weekday: "Sun",
      startTime: "09:05",
      endTime: "10:30",
      raw: org,
    });
  });

  it("parses multiple human-readable timestamp styles", () => {
    expect(parseMarkdownTimestamp("[2026-03-08 Sun]")?.isoDate).toBe("2026-03-08");
    expect(parseMarkdownTimestamp("[2026/03/08]")?.isoDate).toBe("2026-03-08");
    expect(parseMarkdownTimestamp("[Mar 8, 2026]")?.isoDate).toBe("2026-03-08");
    expect(parseMarkdownTimestamp("[March 8 2026]")?.isoDate).toBe("2026-03-08");
    expect(parseMarkdownTimestamp("[8 Mar 2026]")?.isoDate).toBe("2026-03-08");
    expect(parseMarkdownTimestamp("[Sun, Mar 8, 2026]")?.isoDate).toBe("2026-03-08");
    expect(parseMarkdownTimestamp("[Mar 8th, 2026 Sun]")?.isoDate).toBe("2026-03-08");
    expect(parseMarkdownTimestamp("[03/08/2026]")?.isoDate).toBe("2026-03-08");
    expect(parseMarkdownTimestamp("[13/08/2026]")?.isoDate).toBe("2026-08-13");
    expect(parseMarkdownTimestamp("<8 March 2026>" )?.isoDate).toBe("2026-03-08");
  });

  it("shifts ISO dates by calendar days", () => {
    expect(shiftISODate("2026-03-08", 1)).toBe("2026-03-09");
    expect(shiftISODate("2026-03-08", -1)).toBe("2026-03-07");
    expect(shiftISODate("2024-02-29", 1)).toBe("2024-03-01");
  });

  it("scans timestamps while skipping links, wikilinks, fences, frontmatter, and inline code", () => {
    const input = [
      "---",
      "date: [March 8, 2026 Sun]",
      "---",
      "Body [Mar 8, 2026 Sun] and <9 Mar 2026>",
      "[Mar 10, 2026 Tue](https://example.com)",
      "[[Mar 11, 2026 Wed]]",
      "`[Mar 12, 2026 Thu]`",
      "```md",
      "<Mar 13, 2026 Fri>",
      "```",
      "\\[Mar 14, 2026 Sat]",
    ].join("\n");

    const occurrences = scanMarkdownTimestamps(input);

    expect(occurrences.map((occurrence) => occurrence.raw)).toEqual([
      "[Mar 8, 2026 Sun]",
      "<9 Mar 2026>",
    ]);
    expect(occurrences.map((occurrence) => occurrence.kind)).toEqual(["inactive", "active"]);
    expect(occurrences.map((occurrence) => occurrence.isoDate)).toEqual([
      "2026-03-08",
      "2026-03-09",
    ]);
  });

  it("adjusts touched timestamps while preserving active/inactive delimiters", () => {
    const doc = "Start [Mar 8, 2026 Sun 09:00-10:00] middle <9 Mar 2026> end";
    const state = EditorState.create({
      doc,
      // `EditorState.create` only reads `anchor`/`head` off a plain selection
      // object; a `{ranges: [...]}` literal leaves both undefined and yields a
      // single broken range, so this never actually placed a cursor on either
      // timestamp.
      selection: EditorSelection.create([
        EditorSelection.cursor(doc.indexOf("Mar 8") + 2),
        EditorSelection.cursor(doc.indexOf("9 Mar 2026") + 2),
      ]),
      extensions: createNv3MarkdownExtensions(),
    });

    const transaction = buildShiftMarkdownTimestampsTransaction(state, 1);
    expect(transaction).not.toBeNull();

    const nextState = state.update(transaction ?? {}).state;
    expect(nextState.doc.toString()).toBe("Start [Mar 9, 2026 Mon 09:00-10:00] middle <Mar 10, 2026 Tue> end");
  });
});
