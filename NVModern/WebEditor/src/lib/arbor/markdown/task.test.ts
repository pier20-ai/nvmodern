import { describe, expect, it } from "bun:test";
import { parseArborMarkdownTask, setArborMarkdownTaskChecked } from "./task.ts";

describe("Arbor Markdown tasks", () => {
  it("recognizes unchecked and checked task markers", () => {
    expect(parseArborMarkdownTask("[ ] Write tests")).toEqual({
      checked: false,
      checkOffset: 1,
      contentOffset: 4,
    });
    expect(parseArborMarkdownTask("[X] Ship it")?.checked).toBe(true);
    expect(parseArborMarkdownTask("[x] Ship it")?.checked).toBe(true);
    expect(parseArborMarkdownTask("- [ ] Extra bullet")).toBeNull();
    expect(parseArborMarkdownTask("[ ]No separator")).toBeNull();
  });

  it("toggles only the task marker", () => {
    expect(setArborMarkdownTaskChecked("[ ] **Ship**", true)).toBe("[X] **Ship**");
    expect(setArborMarkdownTaskChecked("[X] **Ship**", false)).toBe("[ ] **Ship**");
  });
});
