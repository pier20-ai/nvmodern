import { describe, expect, it } from "bun:test";
import { renderHelpMarkdown } from "./markdown.ts";
import type { HelpProvider } from "./model.ts";
import { createCalcHelpProvider } from "../calc/help.ts";

const provider: HelpProvider = {
  id: "demo", title: "Demo",
  topics: [{
    id: "t", title: "Indent", category: "Editing", summary: "Moves a node right.", keywords: [], signatures: [], aliases: ["nest"],
    examples: [{ code: "a ``` b", result: "ok" }], insertions: [], shortcuts: [{ keys: "Tab", action: "Indent" }],
  }],
};

describe("renderHelpMarkdown", () => {
  it("renders summary, aliases, shortcuts, and examples with safe fences", () => {
    const md = renderHelpMarkdown(provider);
    expect(md).toContain("# Demo help\n\n## Editing\n\n### Indent");
    expect(md).toContain("Also available as `nest`.");
    expect(md).toContain("- `Tab`: Indent");
    expect(md).toContain("````\na ``` b\n````");
    expect(md).toContain("Result: `ok`");
  });
  it("renders every calc topic", () => {
    const calc = createCalcHelpProvider();
    const md = renderHelpMarkdown(calc);
    for (const topic of calc.topics) expect(md).toContain(`### ${topic.title}\n`);
  });
});
