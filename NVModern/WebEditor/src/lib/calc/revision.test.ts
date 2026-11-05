import { describe, expect, it } from "bun:test";
import { parseCalcBlock, parseCalcExpression, parseCalcStatement } from "./parser.ts";
import {
  evaluateCalcBlock,
  evaluateCalcExpression,
  formatCalcRuntimeValue,
  type CalcEvaluationResult,
} from "./runtime.ts";
import { formatCalcPresentation } from "./plot.ts";

function evaluate(source: string): CalcEvaluationResult {
  const parsed = parseCalcExpression(source);
  expect(parsed.diagnostics).toEqual([]);
  expect(parsed.expression).not.toBeNull();
  return evaluateCalcExpression(parsed.expression!);
}
function output(result: CalcEvaluationResult): string {
  if (!result.ok) throw new Error(`${result.error.code}: ${result.error.message}`);
  if (result.presentationError) throw new Error(result.presentationError.message);
  return result.presentation !== undefined
    ? formatCalcPresentation(result.presentation)
    : formatCalcRuntimeValue(result.value);
}
function block(source: string): CalcEvaluationResult[] {
  const parsed = parseCalcBlock(source);
  expect(parsed.diagnostics).toEqual([]);
  return evaluateCalcBlock(parsed).queryResults.map((entry) => entry.result);
}

describe("typed calc revision", () => {
  const examples: [string, string][] = [
    ["1//3 + 1//6", "1//2"],
    ["1//3 * 3", "1"],
    ["(1 + 2)//(3 + 4)", "3//7"],
    ["1//-3", "-1//3"],
    ["2//4 == 1//2", "true"],
    ["9007199254740993 + 2", "9007199254740995"],
    ["999999999999999999999999999999999999//3", "333333333333333333333333333333333333"],
    ["1//3 @round(2)", "33//100"],
    ["1234 @round(-2)", "1200"],
    ["1//3 @type", "rational"],
    ["1//3 + 0.1 @type", "real"],
    ["42 @type", "integer"],
    ["1e7 @type", "real"],
    ["1//3 as decimal(4)", "0.3333"],
    ["0.375 as %", "37.5%"],
    ["0.375 as %(2)", "37.50%"],
    ["10% * ((1 - 0.125) / (1 - 0.3)) + 25% as %", "37.5%"],
    ["100 + 3%", "100.03"],
    ["0.375 as decimal(2)", "0.38"],
    ["-0.375 as decimal(2)", "-0.38"],
    ["1//8 as decimal(2)", "0.13"],
    ["1.005 as decimal(2)", "1.00"],
    ["9007199254740993 == 9007199254740992.0", "false"],
    ["1//10 == 0.1", "false"],
    ["25000000 as Cr", "2.5Cr"],
    ["25000000 as Cr(2)", "2.50Cr"],
    ["3 + 4i @abs", "5"],
    ["3 + 4i @conj", "3 - 4i"],
    ["(3 + 4i) * (3 - 4i)", "25"],
    ["i^2", "-1"],
    ["complex(-4) @sqrt", "2i"],
    ["complex(1e200, 1e200) + complex(1e200, 1e200)", "2e+200 + 2e+200i"],
    ["complex(1e308, 1e308) / complex(1e308, 1e308)", "1"],
    ["1//3 + 4i @re", "1//3"],
    ["i * (1//3)", "(1//3)*i"],
    ["[i, 3i] @mean", "2i"],
    ["10kg * 3", "30kg"],
    ["10 kg * 3", "30kg"],
    ["10m/s * 20s", "200m"],
    ["1kg + 250g", "1.25kg"],
    ["1km / 500m", "2"],
    ["10m/s as km/h", "36km/h"],
    ["10m/s as km/h(1)", "36.0km/h"],
    ["2500g as kg", "2.5kg"],
    ["2500g as kg(2)", "2.50kg"],
    ["10mm as m", "0.01m"],
    ["2Cr * 1kg", "20000000kg"],
    ["10L", "1000000"],
    ["2litre as l", "2l"],
    ["10m^2", "10m^2"],
    ["(10m)^2", "100m^2"],
    ["10kg/(m*s^2)", "10kg/(m*s^2)"],
    ["10s^-1", "10s^-1"],
    ["(10m)^-2", "0.01m^-2"],
    ["sqrt((3m)^2)", "3m"],
    ["sin(90deg)", "1"],
    ["[1kg, 500g] @mean", "0.75kg"],
    ['[1kg, 500g] @variance("population")', "0.0625kg^2"],
    ['[1kg, 500g] @std("population")', "0.25kg"],
    ["[1, 2, 3, 4] @mean @round(1)", "2.5"],
    ["[1, 2, 3] @sum", "6"],
    ["[1, 2, 3] @map(math.sqrt) @list.len", "3"],
    ["[1, 2, 3] @variance", "1"],
    ["[0, 10] @quantile(0.25)", "2.5"],
    ["range(1, 5) @sum", "10"],
    ["[3, 1, 2] @sort @slice(1)", "[2, 3]"],
    ["gcd(18, 24)", "6"],
    ["lcm(6, 8)", "24"],
    ["5 @factorial", "120"],
    ["log(8, 2)", "3"],
  ];
  for (const [source, expected] of examples)
    it(source, () => expect(output(evaluate(source))).toBe(expected));

  it("retains exact values and quantities after presenting assignments", () => {
    expect(
      block(
        [
          "third = 1//3 as decimal(4)",
          "third * 3",
          "speed = 10m/s as km/h",
          "speed * 20s",
          "third @type",
          "speed @type",
        ].join("\n"),
      ).map(output),
    ).toEqual(["1", "200m", "rational", "quantity"]);
  });
  it("runs custom presenters and ordinary postfix calls through the same functions", () => {
    expect(
      block(
        [
          "money(value, prefix) = prefix + decimal(value, 2)",
          'salary = 2500 as money("$")',
          "salary * 2",
          'percent(value) = decimal(value * 100, 1) + "%"',
          "ratio = 0.375 as percent",
          "ratio * 1000",
          "ratio @percent",
          "ratio as percent",
          "double(n) = n * 2",
          "3 @double",
          "3 |> double @double",
        ].join("\n"),
      ).map(output),
    ).toEqual(["5000", "375", "37.5%", "37.5%", "6", "12"]);
  });
  it("preserves a binding when only its presenter fails", () => {
    const parsed = parseCalcBlock("bad(v) = v + 1\nx = 2 as bad -> stale\nx * 3");
    const evaluation = evaluateCalcBlock(parsed),
      first = evaluation.statementResults[0]!.result;
    expect(first).toMatchObject({
      ok: true,
      value: 2,
      presentationError: { code: "calc.presentation-error" },
    });
    expect(output(evaluation.queryResults[0]!.result)).toBe("6");
  });
  it("supports higher-order functions without leaking parameter bindings into definitions", () => {
    expect(
      block("x = 2\nv = x\nf(x) = v\nf(8)\nv\nadd(a, b) = a + b\n[1, 2, 3] @reduce(add, 0)").map(
        output,
      ),
    ).toEqual(["2", "2", "6"]);
  });
  it("builds typed symbolic values and applies explicit transformations", () => {
    expect(
      block(
        [
          "symbol x, y",
          "2*x + 3*x @simplify",
          "(x + y)^2 @expand",
          "p = x^2 + 3*x",
          "p @diff(x)",
          "p @subs(x, 2)",
          "x^2 + 2*x + 1 @factor",
          "sin(x) @subs(x, 0)",
          "x/x @simplify",
          "0 * (1/x) @simplify",
          "p @type",
        ].join("\n"),
      ).map(output),
    ).toEqual([
      "5*x",
      "x^2 + 2*x*y + y^2",
      "2*x + 3",
      "10",
      "(x + 1)^2",
      "0",
      "x/x",
      "0*1/x",
      "expression",
    ]);
  });
  it("keeps symbol declarations separate from ordinary definitions", () => {
    const results = block("symbol x\nx = 2\nx + 1");
    expect(results[0]).toMatchObject({ ok: false, error: { code: "calc.conflicting-symbol" } });
    expect(block("symbol x\nf(x) = x + 1\nf(2)").map(output)).toEqual(["3"]);
  });
  it("prints numeric symbolic operands with parentheses that preserve their meaning", () => {
    expect(block("symbol x\n(-2)^x\n(1//2)^x\n(3 + 4i)*x\n(3m)*x").map(output)).toEqual([
      "(-2)^x",
      "(1//2)^x",
      "(3 + 4i)*x",
      "(3m)*x",
    ]);
  });
  const invalid = [
    "1//0",
    "1.5//3",
    "1kg + 2m",
    "1kg as %",
    "1kg as s",
    "ln(1kg)",
    "sqrt(-1)",
    "3i < 4i",
    "median([i])",
    "factorial(-1)",
    "range(0, 1, 0)",
    "decimal(1, 101)",
    "abs(1, 2)",
    "missing + 1",
    "[1, 2] @len",
  ];
  for (const source of invalid)
    it(`rejects ${source}`, () => {
      const result = evaluate(source);
      expect(!result.ok || !!result.presentationError).toBe(true);
    });
  it("reports reserved names and malformed stages before evaluation", () => {
    for (const source of [
      "i = 2",
      "as = 2",
      "symbol = 2",
      "f(i) = i",
      "symbol i",
      "1 @",
      "1 as",
      "1 as decimal(2) as %",
      "f(x) = x as %",
    ])
      expect(parseCalcStatement(source).diagnostics.length).toBeGreaterThan(0);
    for (const source of ["10foo", "10constructor", "2kkg", "1m^1000"])
      expect(parseCalcExpression(source).diagnostics.length).toBeGreaterThan(0);
  });
  it("bounds exact arithmetic, list generation, and nested syntax with diagnostics", () => {
    for (const source of [
      "99999999999999999999^10000",
      "range(0, 10001)",
      "1m^32 * 1m",
      "(1m^32)^2",
    ]) {
      expect(evaluate(source)).toMatchObject({ ok: false, error: { code: "calc.resource-limit" } });
    }
    const nested = parseCalcExpression("(".repeat(200) + "1" + ")".repeat(200));
    expect(nested.diagnostics.some((diagnostic) => diagnostic.code === "calc.resource-limit")).toBe(
      true,
    );
    expect(parseCalcStatement("f(x, x) = x").diagnostics[0]?.code).toBe("calc.duplicate-parameter");
    expect(block("symbol x\n(x + 1)^13 @expand")[0]).toMatchObject({
      ok: false,
      error: { code: "calc.resource-limit" },
    });
  });
  it("keeps large exact AST values and approximates large rational ratios safely", () => {
    const raw = "9".repeat(400);
    const parsed = parseCalcExpression(raw);
    expect(parsed.diagnostics).toEqual([]);
    expect(parsed.expression).toMatchObject({ kind: "NumberLiteral", value: BigInt(raw) });
    expect(output(evaluate(`(${raw}//${"8".repeat(400)}) @approx`))).toBe("1.125");
  });
});
