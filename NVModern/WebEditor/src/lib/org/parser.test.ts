import { describe, expect, it } from "bun:test";
import { parseOrgDocument } from "./parser.ts";

async function fixture(name: string): Promise<string> {
  return Bun.file(`test-files/${name}`).text();
}

describe("parseOrgDocument", () => {
  it("parses heading structure, TODO states, planning lines, links, and tables", async () => {
    const input = await fixture("org-comprehensive.org");
    const result = parseOrgDocument(input);

    expect(result.counts.headingCount).toBeGreaterThanOrEqual(6);
    expect(result.counts.listItemCount).toBe(15);
    expect(result.counts.tableCount).toBe(1);
    expect(result.counts.sourceBlockCount).toBe(2);

    const firstHeading = result.headings[0];
    expect(firstHeading?.level).toBe(1);
    expect(firstHeading?.todoKeyword).toBe("TODO");
    expect(firstHeading?.tags).toEqual(["project", "urgent"]);

    const doneHeading = result.headings.find((heading) => heading.todoKeyword === "DONE");
    expect(doneHeading).toBeTruthy();
    expect(doneHeading?.scheduledTimestampIndex).not.toBeNull();
    expect(doneHeading?.deadlineTimestampIndex).not.toBeNull();

    const httpsLink = result.links.find((link) => link.type === "https");
    const fileLink = result.links.find((link) => link.type === "file");
    expect(httpsLink?.supported).toBe(true);
    expect(fileLink?.supported).toBe(true);

    expect(result.counts.timestampCount).toBeGreaterThanOrEqual(4);
    expect(result.counts.markupCount).toBeGreaterThan(0);
  });

  it("parses top-level properties drawer only", () => {
    const input = [
      ":PROPERTIES:",
      ":ID: abc-123",
      ":OWNER: alex",
      ":END:",
      "",
      "* Heading",
      ":PROPERTIES:",
      ":ID: nested-ignored",
      ":END:",
    ].join("\n");

    const result = parseOrgDocument(input);

    expect(result.counts.propertiesDrawerCount).toBe(1);
    expect(result.topLevelProperties[0]?.entries.map((entry) => entry.key)).toEqual([
      "ID",
      "OWNER",
    ]);
  });

  it("classifies org link types and reports unsupported schemes", () => {
    const input = [
      "[[file:docs/note.org]]",
      "[[http://example.com]]",
      "[[https://example.com]]",
      "[[id:abc123]]",
      "[[shell:echo hello]]",
      "[[ftp://unsupported.example]]",
    ].join("\n");

    const result = parseOrgDocument(input);

    expect(result.counts.linkCount).toBe(6);
    expect(result.counts.supportedLinkCount).toBe(5);
    expect(result.links.find((link) => link.target.startsWith("ftp:"))?.type).toBe("unknown");
    expect(result.diagnostics.some((diag) => diag.code === "org.unsupported-link-type")).toBe(
      true,
    );
  });

  it("tracks source blocks and emits diagnostics for unclosed blocks", () => {
    const input = ["#+BEGIN_SRC python", "print('hello')"].join("\n");
    const result = parseOrgDocument(input);

    expect(result.counts.sourceBlockCount).toBe(1);
    expect(result.sourceBlocks[0]?.closed).toBe(false);
    expect(result.diagnostics.some((diag) => diag.code === "org.unclosed-source-block")).toBe(
      true,
    );
    expect(result.excludedRanges[0]?.reason).toBe("source-block");
  });

  it("parses org timestamps with a time and a time range", () => {
    const result = parseOrgDocument([
      "Meeting <2026-03-08 Sun 09:05>",
      "Workshop [2026-03-09 Mon 10:00-12:30]",
    ].join("\n"));

    expect(result.timestamps.map((timestamp) => ({
      date: timestamp.date,
      time: timestamp.time,
      endTime: timestamp.endTime,
    }))).toEqual([
      { date: "2026-03-08", time: "09:05", endTime: null },
      { date: "2026-03-09", time: "10:00", endTime: "12:30" },
    ]);
  });

  it("indexes footnote definitions/references and unresolved names", () => {
    const input = [
      "[fn:one] First definition",
      "Paragraph with [fn:one] and [fn:missing].",
    ].join("\n");

    const result = parseOrgDocument(input);

    expect(result.counts.footnoteDefinitionCount).toBe(1);
    expect(result.counts.footnoteReferenceCount).toBe(2);
    expect(result.unresolvedFootnotes).toEqual(["missing"]);
  });

  it("builds heading hierarchy with parent relationships", () => {
    const input = ["* H1", "** H1.1", "*** H1.1.1", "* H2"].join("\n");
    const result = parseOrgDocument(input);

    expect(result.headings).toHaveLength(4);
    expect(result.headings[0]?.parentIndex).toBeNull();
    expect(result.headings[1]?.parentIndex).toBe(0);
    expect(result.headings[2]?.parentIndex).toBe(1);
    expect(result.headings[3]?.parentIndex).toBeNull();
  });

  it("parses nested list items with depth, multi-line bodies, and all list kinds", () => {
    const input = [
      "- bullet top",
      "  - nested bullet",
      "    continuation of nested",
      "  - sibling",
      "- back to top",
      "",
      "1. ordered first",
      "2. ordered second",
      "",
      "- [ ] unchecked task",
      "- [X] checked task",
      "- [-] partial task",
      "",
      "- term :: description list item",
    ].join("\n");

    const result = parseOrgDocument(input);

    // Bullet items
    const bullets = result.listItems.filter((i) => i.kind === "bullet" && i.checklist === null && !i.descriptionTerm);
    expect(bullets.length).toBeGreaterThanOrEqual(4);

    const top = bullets.find((i) => i.content.includes("bullet top"));
    expect(top?.depth).toBe(0);
    expect(top?.parentIndex).toBeNull();

    const nested = bullets.find((i) => i.content.includes("nested bullet"));
    expect(nested?.depth).toBe(1);
    expect(nested?.parentIndex).toBe(top?.index);
    // Nested item spans 2 lines (marker + continuation)
    expect(nested!.toLine).toBe(nested!.line + 1);

    // Ordered items
    const ordered = result.listItems.filter((i) => i.kind === "ordered");
    expect(ordered).toHaveLength(2);
    expect(ordered[0]?.order).toBe("1");
    expect(ordered[1]?.order).toBe("2");

    // Checklists
    const tasks = result.listItems.filter((i) => i.checklist !== null);
    expect(tasks).toHaveLength(3);
    expect(tasks[0]?.checklist).toBe("unchecked");
    expect(tasks[1]?.checklist).toBe("checked");
    expect(tasks[2]?.checklist).toBe("partial");

    // Description list
    const desc = result.listItems.filter((i) => i.kind === "description");
    expect(desc).toHaveLength(1);
    expect(desc[0]?.descriptionTerm).toBe("term");
  });
});
