import { describe, expect, it } from "bun:test";
import {
  insertOrReplaceArborTimestamp,
  updateInsertedArborTimestamp,
} from "./dateShortcuts.ts";

describe("Arbor date shortcuts", () => {
  it("inserts the Markdown inactive timestamp syntax at the selection", () => {
    expect(insertOrReplaceArborTimestamp("Due tomorrow", 4, 12, "2026-08-21")).toEqual({
      text: "Due [Aug 21, 2026 Fri]",
      from: 4,
      to: 22,
      raw: "[Aug 21, 2026 Fri]",
      kind: "inactive",
    });
  });

  it("updates a timestamp touched by the caret without changing its kind", () => {
    expect(insertOrReplaceArborTimestamp("Due <Aug 20, 2026 Thu>", 10, 10, "2026-08-21")).toEqual({
      text: "Due <Aug 21, 2026 Fri>",
      from: 4,
      to: 22,
      raw: "<Aug 21, 2026 Fri>",
      kind: "active",
    });
  });

  it("applies a picked date only while the inserted timestamp is unchanged", () => {
    const inserted = insertOrReplaceArborTimestamp("Due ", 4, 4, "2026-08-21");
    expect(updateInsertedArborTimestamp(inserted.text, inserted, "2026-08-22")?.text)
      .toBe("Due [Aug 22, 2026 Sat]");
    expect(updateInsertedArborTimestamp("Due edited", inserted, "2026-08-22")).toBeNull();
  });
});
