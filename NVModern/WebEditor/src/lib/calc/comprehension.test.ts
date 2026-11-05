import { describe, expect, it } from "bun:test";
import {
  offsetExpression,
  parseCalcBlock,
  parseCalcExpression,
  parseCalcStatement,
} from "./parser.ts";
import {
  evaluateCalcBlock,
  evaluateCalcExpression,
  formatCalcRuntimeValue,
  type CalcEvaluationResult,
} from "./runtime.ts";
import { isCalcPlot } from "./plot.ts";

function evaluate(source: string): CalcEvaluationResult {
  const parsed = parseCalcExpression(source);
  expect(parsed.diagnostics).toEqual([]);
  return evaluateCalcExpression(parsed.expression!);
}
function output(source: string): string {
  const result = evaluate(source);
  if (!result.ok) throw new Error(result.error.message);
  return formatCalcRuntimeValue(result.value);
}
function block(source: string): CalcEvaluationResult[] {
  const parsed = parseCalcBlock(source);
  expect(parsed.diagnostics).toEqual([]);
  return evaluateCalcBlock(parsed).queryResults.map((query) => query.result);
}

describe("list comprehension syntax", () => {
  it("parses the body, binding, iterable, and optional filter with exact source ranges", () => {
    const source = "[n^2 for n in range(5) if n > 1]";
    const parsed = parseCalcExpression(source);
    expect(parsed.diagnostics).toEqual([]);
    expect(parsed.expression?.kind).toBe("ListComprehension");
    const ast = parsed.expression!;
    if (ast.kind !== "ListComprehension") throw new Error("Expected comprehension");
    const slice = (range: { from: number; to: number }) => source.slice(range.from, range.to);
    expect(slice(ast.range)).toBe(source);
    expect(slice(ast.element.range)).toBe("n^2");
    expect(slice(ast.binding.range)).toBe("n");
    expect(slice(ast.iterable.range)).toBe("range(5)");
    expect(slice(ast.condition!.range)).toBe("n > 1");
    expect([ast.forRange, ast.inRange, ast.ifRange!].map(slice)).toEqual(["for", "in", "if"]);
    const shifted = offsetExpression(ast, 30);
    if (shifted.kind !== "ListComprehension") throw new Error("Expected shifted comprehension");
    expect(shifted.range.from).toBe(ast.range.from + 30);
    expect(shifted.binding.range.from).toBe(ast.binding.range.from + 30);
    expect(shifted.forRange.from).toBe(ast.forRange.from + 30);
    expect(shifted.inRange.from).toBe(ast.inRange.from + 30);
    expect(shifted.ifRange!.from).toBe(ast.ifRange!.from + 30);
    expect(shifted.condition!.range.from).toBe(ast.condition!.range.from + 30);
    expect(shifted.iterable.range.from).toBe(ast.iterable.range.from + 30);
    expect(shifted.element.range.from).toBe(ast.element.range.from + 30);
  });
  it("keeps plain lists and expressions containing keyword-like names valid", () => {
    for (const source of [
      "[]",
      "[1, 2]",
      "[[1, 2], [3, 4]]",
      "[for, in, if]",
      '["for", "in", "if"]',
    ]) {
      const parsed = parseCalcExpression(source);
      expect(parsed.diagnostics).toEqual([]);
      expect(parsed.expression?.kind).toBe("ListExpression");
    }
    expect(parseCalcExpression("[n for n in []]").expression).toMatchObject({
      condition: null,
      ifRange: null,
    });
  });
  for (const source of [
    "[n for]",
    "[n for n]",
    "[n for n in]",
    "[n for n in [] if]",
    "[n for n in []",
    "[n for n in [1],]",
    "[n, 2 for n in [1]]",
    "[n for n, m in [1]]",
    "[n for [n, m] in []]",
    "[n for n in [1] for m in [2]]",
    "[n for n in [1] if n > 0 if n < 2]",
    "[n if n > 0 else 0 for n in [1]]",
    "[i for i in [1]]",
    "[as for as in [1]]",
    "[n for symbol in [1]]",
    "[1,]",
  ])
    it(`rejects unsupported or incomplete syntax: ${source}`, () => {
      const parsed = parseCalcExpression(source);
      expect(parsed.expression).toBeNull();
      expect(parsed.diagnostics.length).toBeGreaterThan(0);
    });
  it("explains why multiple clauses are rejected", () => {
    expect(parseCalcExpression("[n for n in [1] for m in [2]]").diagnostics[0]).toMatchObject({
      code: "calc.unsupported-comprehension",
      message: "A comprehension supports one 'for' clause and one optional 'if' filter.",
    });
    expect(parseCalcStatement("for n in [1]").diagnostics.length).toBeGreaterThan(0);
  });
});

describe("list comprehension evaluation", () => {
  const cases: [string, string][] = [
    ["[n^2 for n in range(5)]", "[0, 1, 4, 9, 16]"],
    ["[n for n in [3, -1, 0, 2] if n > 0]", "[3, 2]"],
    ["[1//n for n in [0, 1, 2, 3] if n != 0]", "[1, 1//2, 1//3]"],
    ["[n * 1kg for n in [1, 2, 3]] @sum", "6kg"],
    ["[z @conj for z in [1 + 2i, 3 - 4i]]", "[1 - 2i, 3 + 4i]"],
    ["[n//3 for n in [1, 2, 3]] @sum", "2"],
    ["[n @type for n in [1, 1//3, 2kg]]", "[integer, rational, quantity]"],
    ["[n * 2 for n in range(4) @reverse if n > 0] @sum", "12"],
    ["[n for n in range(5, 0, -2)]", "[5, 3, 1]"],
    ["[missing for n in [] if missing]", "[]"],
    ["[missing for n in [1, 2] if false]", "[]"],
    ['[n for n in [0, 1, null, false, true, "", "yes", []] if n]', "[1, true, yes]"],
    ["[[n for n in [n, n+1]] for n in [10, 20]]", "[[10, 11], [20, 21]]"],
    ["[[x*y for y in [1, 2]] for x in [3, 4]]", "[[3, 6], [4, 8]]"],
    ["[f(4) for f in [sqrt, abs]]", "[2, 4]"],
    ["[for for for in [1, 2] if for > 1]", "[2]"],
  ];
  for (const [source, expected] of cases) it(source, () => expect(output(source)).toBe(expected));
  it("shadows a binding locally and evaluates the source before binding the iteration variable", () => {
    expect(block("n = [2, 3]\n[n^2 for n in n]\nn")).toEqual([
      { ok: true, value: [4, 9] },
      { ok: true, value: [2, 3] },
    ]);
    expect(block("[n for n in [1]]\nn")[1]).toMatchObject({
      ok: false,
      error: { code: "calc.unknown-identifier" },
    });
    expect(block("n = 9\n[1//n for n in [0]]\nn")[1]).toEqual({ ok: true, value: 9 });
  });
  it("preserves enclosing function parameters and lexical function lookup", () => {
    expect(block("n = 100\ng(t) = n+t\nf(n) = [g(1)+x+n for x in [1, 2]]\nf(3)")[0]).toEqual({
      ok: true,
      value: [105, 106],
    });
    expect(block("f(n) = [n for n in range(n)]\nf(3)")[0]).toEqual({ ok: true, value: [0, 1, 2] });
    expect(block("for = [1, 2]\nin(n) = n*2\nif = 1\n[in(n) for n in for if n > if]")[0]).toEqual({
      ok: true,
      value: [4],
    });
  });
  it("produces ordinary typed plot data and preserves the original binding", () => {
    const results = block(
      'points = [[x, x^2] for x in [-2, -1, 0, 1, 2]] as plot("scatter")\npoints @type\npoints @list.len',
    );
    expect(results).toEqual([
      { ok: true, value: "list" },
      { ok: true, value: 5 },
    ]);
    const presented = evaluate('[[x, x^2] for x in [-2, -1, 0, 1, 2]] as plot("scatter")');
    if (!presented.ok || !isCalcPlot(presented.presentation)) throw new Error("Expected plot");
    expect(presented.presentation.points).toEqual([
      { x: -2, y: 4 },
      { x: -1, y: 1 },
      { x: 0, y: 0 },
      { x: 1, y: 1 },
      { x: 2, y: 4 },
    ]);
  });
  for (const source of [
    '[n for n in "abc"]',
    "[n for n in 3]",
    "[n for n in null]",
    "[n for n in math]",
    "[n for n in sqrt]",
  ])
    it(`requires a list source: ${source}`, () =>
      expect(evaluate(source)).toMatchObject({ ok: false, error: { code: "calc.type-error" } }));
  it("propagates filter and body failures without leaking a partial list", () => {
    expect(evaluate("[1//n for n in [1, 0, 2]]")).toMatchObject({
      ok: false,
      error: { code: "calc.divide-by-zero" },
    });
    expect(evaluate("[n for n in [1, 2] if missing]")).toMatchObject({
      ok: false,
      error: { code: "calc.unknown-identifier" },
    });
  });
  it("bounds generated lists, nesting, and total work", () => {
    expect(output("[n for n in range(10000)] @list.len")).toBe("10000");
    const largeSource = `[n for n in [${Array(10001).fill("1").join(",")}]]`;
    expect(evaluate(largeSource)).toMatchObject({
      ok: false,
      error: { code: "calc.resource-limit", message: "Comprehension exceeds 10000 values." },
    });
    expect(evaluate("[[x for x in range(1000)] for n in range(1000)]")).toMatchObject({
      ok: false,
      error: { code: "calc.resource-limit" },
    });
    // A nested source is built once; reevaluating it for every iteration would exceed the budget.
    expect(output("[n for n in [x for x in range(4000)]] @list.len")).toBe("4000");
    expect(
      parseCalcExpression("[x for x in ".repeat(140) + "[]" + "]".repeat(140)).diagnostics[0]?.code,
    ).toBe("calc.resource-limit");
  });
});
