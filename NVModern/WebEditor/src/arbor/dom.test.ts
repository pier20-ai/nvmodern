import { describe, expect, it } from "bun:test";
import {
  isCaretOnVisualLineBoundary,
  scrollDeltaToReveal,
} from "./dom.ts";

describe("Arbor caret geometry", () => {
  const lines = [
    { top: 0, bottom: 20 },
    { top: 20, bottom: 40 },
    { top: 40, bottom: 60 },
  ];

  it("keeps vertical arrows inside wrapped visual lines", () => {
    expect(isCaretOnVisualLineBoundary("up", { top: 20, bottom: 40 }, lines)).toBe(false);
    expect(isCaretOnVisualLineBoundary("down", { top: 20, bottom: 40 }, lines)).toBe(false);
  });

  it("moves between blocks only from the outer visual lines", () => {
    expect(isCaretOnVisualLineBoundary("up", { top: 0, bottom: 20 }, lines)).toBe(true);
    expect(isCaretOnVisualLineBoundary("down", { top: 0, bottom: 20 }, lines)).toBe(false);
    expect(isCaretOnVisualLineBoundary("up", { top: 40, bottom: 60 }, lines)).toBe(false);
    expect(isCaretOnVisualLineBoundary("down", { top: 40, bottom: 60 }, lines)).toBe(true);
  });

  it("coalesces inline fragments that share one visual line", () => {
    expect(isCaretOnVisualLineBoundary("down", { top: 20, bottom: 40 }, [
      { top: 0, bottom: 20 },
      { top: 0.5, bottom: 20.5 },
      { top: 20, bottom: 40 },
    ])).toBe(true);
  });

  it("scrolls only enough to reveal the caret inside the viewport margin", () => {
    const viewport = { top: 100, bottom: 300 };
    expect(scrollDeltaToReveal({ top: 92, bottom: 112 }, viewport)).toBe(-16);
    expect(scrollDeltaToReveal({ top: 282, bottom: 308 }, viewport)).toBe(16);
    expect(scrollDeltaToReveal({ top: 108, bottom: 292 }, viewport)).toBe(0);
  });
});
