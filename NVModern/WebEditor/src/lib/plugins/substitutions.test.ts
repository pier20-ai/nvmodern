import { describe, expect, it } from "bun:test";
import { applyNv3TextSubstitutions } from "./substitutions.ts";

describe("text substitutions", () => {
  it("applies the default replacement that overlaps a changed range", () => {
    expect(applyNv3TextSubstitutions("Go -> now", 4, 5).text).toBe("Go → now");
  });

  it("keeps unrelated existing patterns unchanged", () => {
    expect(applyNv3TextSubstitutions("Old -> and new ->", 15, 17).text)
      .toBe("Old -> and new →");
  });

  it("uses configured replacements alongside the defaults", () => {
    expect(applyNv3TextSubstitutions(";sig ->", 0, 7, [{ from: ";sig", to: "Best" }]).text)
      .toBe("Best →");
  });
});
