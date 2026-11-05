import { describe, expect, it } from "bun:test";
import { createArborHelpProvider } from "./help.ts";
import { renderHelpMarkdown } from "../lib/help/markdown.ts";

describe("arbor help", () => {
  const provider = createArborHelpProvider();
  it("has unique topic ids, summaries, and JSON-portable content", () => {
    expect(new Set(provider.topics.map((t) => t.id)).size).toBe(provider.topics.length);
    for (const t of provider.topics) {
      expect(t.summary.length).toBeGreaterThan(0);
      expect(t.shortcuts?.length).toBeGreaterThan(0);
    }
    expect(JSON.parse(JSON.stringify(provider))).toEqual(provider);
  });
  it("renders shortcuts into Markdown", () => {
    expect(renderHelpMarkdown(provider)).toContain("- `⌘ Enter`: Run and refresh results (when the block is a producer)");
  });
});
