import { describe, expect, it } from "bun:test";
import { detectStandaloneTransclusions } from "./transclusion.ts";

async function fixture(name: string): Promise<string> {
  return Bun.file(`test-files/fixtures/transclusion/${name}`).text();
}

describe("detectStandaloneTransclusions", () => {
  it("detects standalone ![[...]] lines", async () => {
    const input = await fixture("standalone.md");
    const matches = detectStandaloneTransclusions(input);

    expect(matches.length).toBe(1);
    expect(matches[0]?.target).toBe("notes.org");
    expect(matches[0]?.line).toBe(3);
  });

  it("ignores inline ![[...]] occurrences", async () => {
    const input = await fixture("inline.md");
    const matches = detectStandaloneTransclusions(input);

    expect(matches).toHaveLength(0);
  });

  it("ignores transclusion-like text inside frontmatter", async () => {
    const input = await fixture("frontmatter.md");
    const matches = detectStandaloneTransclusions(input);

    expect(matches).toHaveLength(1);
    expect(matches[0]?.target).toBe("test-files/notes.org");
    expect(matches[0]?.line).toBe(5);
  });

  it("ignores fenced code and keeps standalone token outside fence", async () => {
    const input = await fixture("fence.md");
    const matches = detectStandaloneTransclusions(input);

    expect(matches).toHaveLength(1);
    expect(matches[0]?.target).toBe("notes.org");
    expect(matches[0]?.line).toBe(5);
  });
});
