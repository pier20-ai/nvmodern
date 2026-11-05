import { describe, expect, it } from "bun:test";
import { scanMarkdownText, toDocumentScanIndex } from "./markdownScanner.ts";
import { buildTagDataFromScanIndex } from "./markdownTags.ts";

describe("buildTagDataFromScanIndex", () => {
  it("does not throw when heading tags appear before hash tags", () => {
    const scanIndex = toDocumentScanIndex(scanMarkdownText(["## Heading :alpha:", "text #todo"].join("\n")));

    const data = buildTagDataFromScanIndex(scanIndex);

    expect(data.index.headingTags).toEqual(["alpha"]);
    expect(data.index.hashTags).toEqual(["todo"]);
    expect(data.index.occurrences.map((occurrence) => `${occurrence.kind}:${occurrence.tag}`)).toEqual([
      "heading:alpha",
      "hash:todo",
    ]);
  });

  it("adds decorations in global document order across heading/hash tag kinds", () => {
    const scanIndex = toDocumentScanIndex(scanMarkdownText(
      ["## One :alpha:", "row #todo", "### Two :beta:", "row #now"].join("\n"),
    ));

    const data = buildTagDataFromScanIndex(scanIndex);

    expect(data.index.occurrences.map((occurrence) => `${occurrence.kind}:${occurrence.tag}`)).toEqual([
      "heading:alpha",
      "hash:todo",
      "heading:beta",
      "hash:now",
    ]);
  });
});
