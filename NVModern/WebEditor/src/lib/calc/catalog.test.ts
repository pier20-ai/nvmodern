import { describe, expect, it } from "bun:test";
import { calcCatalog, calcEntry, calcPresenterAliases, searchCalcCatalog } from "./catalog.ts";
import {
  evaluateCalcBlock,
  formatCalcRuntimeValue,
  getCalcBuiltinDocumentation,
} from "./runtime.ts";
import { formatCalcPresentation } from "./plot.ts";
import { parseCalcBlock } from "./parser.ts";

describe("calc discovery catalog", () => {
  it("documents every registered builtin with matching arity and canonical aliases", () => {
    const registered = getCalcBuiltinDocumentation();
    expect(registered.map((e) => e.name).sort()).toEqual(
      calcCatalog
        .filter((e) => e.arity)
        .map((e) => e.name)
        .sort(),
    );
    expect(new Set(calcCatalog.map((e) => e.name)).size).toBe(calcCatalog.length);
    for (const entry of registered) {
      expect(entry.signatures.length).toBeGreaterThan(0);
      expect(entry.examples.length).toBeGreaterThan(0);
      for (const alias of entry.aliases ?? []) expect(calcEntry(alias)).toBe(entry);
    }
    expect(calcEntry("len")).toBeUndefined();
    expect(calcEntry("sum")?.name).toBe("stats.sum");
  });
  for (const entry of [...calcCatalog, ...calcPresenterAliases()])
    for (const example of entry.examples)
      it(`${entry.name}: ${example.source}`, () => {
        const parsed = parseCalcBlock(example.source);
        expect(parsed.diagnostics).toEqual([]);
        const result = evaluateCalcBlock(parsed).statementResults.at(-1)?.result;
        if (!result?.ok) throw new Error(result && !result.ok ? result.error.message : "No result");
        if (result.presentationError) throw new Error(result.presentationError.message);
        const output =
          result.presentation !== undefined
            ? formatCalcPresentation(result.presentation)
            : formatCalcRuntimeValue(result.value);
        if (example.expected !== undefined) expect(output).toBe(example.expected);
      });
  it("finds tasks and constructions by intent instead of requiring function names", () => {
    expect(searchCalcCatalog("percentage").some((e) => e.name === "present.percent")).toBe(true);
    expect(
      searchCalcCatalog("convert units").some(
        (e) => e.name === "Quantity" || e.name === "present.unit",
      ),
    ).toBe(true);
    expect(searchCalcCatalog("graph").some((e) => e.name === "present.plot")).toBe(true);
    expect(searchCalcCatalog("filter list").some((e) => e.name === "List comprehension")).toBe(
      true,
    );
    expect(searchCalcCatalog("nonsense-no-match")).toEqual([]);
  });
});
