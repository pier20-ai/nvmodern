import { describe, expect, it } from "bun:test";
import { parseCalcBlock, parseCalcExpression } from "./parser.ts";
import {
  createCalcRuntimeScope,
  evaluateCalcBlock,
  evaluateCalcExpression,
  formatCalcRuntimeValue,
} from "./runtime.ts";

describe("calc runtime", () => {
  it("evaluates value and function definitions inside a block", () => {
    const block = parseCalcBlock([
      "principal = 400000",
      "apr = 6.75 / 100",
      "rate = apr / 12",
      "months = 30 * 12",
      "payment(p, r, n) = p * r / (1 - (1 + r)^(-n))",
      "payment(principal, rate, months)",
    ].join("\n"));

    const evaluation = evaluateCalcBlock(block);
    expect(evaluation.queryResults).toHaveLength(1);
    expect(evaluation.queryResults[0]?.result.ok).toBe(true);
    if (!evaluation.queryResults[0]?.result.ok) {
      throw new Error("expected successful query result");
    }
    expect(formatCalcRuntimeValue(evaluation.queryResults[0].result.value)).toMatch(/^25/);
  });

  it("supports namespaced functions and pipes", () => {
    const parsed = parseCalcExpression("10 |> math.ln() |> math.round(4)");
    expect(parsed.expression).not.toBeNull();
    const result = evaluateCalcExpression(parsed.expression!, createCalcRuntimeScope());
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("expected successful evaluation");
    expect(result.value).toBe(2.3026);
  });

  it("keeps reactive assignments in the block scope for dependencies and queries", () => {
    const block = parseCalcBlock([
      "; Values may refer to definitions further down the block",
      "total = double(price) -> stale",
      "double(x) = x * 2",
      "price = 3 → 0",
      "total + 1",
    ].join("\n"));

    const evaluation = evaluateCalcBlock(block);
    expect(block.diagnostics).toEqual([]);
    expect(evaluation.scope.valueNames).toEqual(["total", "price"]);
    expect(evaluation.queryResults.map((query) => query.result)).toEqual([{ ok: true, value: 7 }]);
  });

  it("supports function references for list.map", () => {
    const block = parseCalcBlock([
      "square(x) = x ^ 2",
      "[1, 2, 3] |> list.map(square)",
    ].join("\n"));

    const evaluation = evaluateCalcBlock(block);
    expect(evaluation.queryResults[0]?.result.ok).toBe(true);
    if (!evaluation.queryResults[0]?.result.ok) throw new Error("expected successful evaluation");
    expect(evaluation.queryResults[0].result.value).toEqual([1, 4, 9]);
  });

  it("reports circular value definitions", () => {
    const block = parseCalcBlock([
      "a = b + 1",
      "b = a + 1",
      "a",
    ].join("\n"));

    const evaluation = evaluateCalcBlock(block);
    const result = evaluation.queryResults[0]!.result;
    expect(result.ok).toBe(false);
    if (result.ok) throw new Error("expected failed evaluation");
    expect(result.error.code).toBe("calc.circular-value");
  });

  it("evaluates scientific notation and percent literals", () => {
    const block = parseCalcBlock([
      "principal = 1e6",
      "rate = 10%",
      "principal * rate",
    ].join("\n"));

    const evaluation = evaluateCalcBlock(block);
    expect(evaluation.queryResults[0]?.result.ok).toBe(true);
    if (!evaluation.queryResults[0]?.result.ok) throw new Error("expected successful evaluation");
    expect(evaluation.queryResults[0].result.value).toBe(100000);
  });

  it("evaluates scale suffix literals", () => {
    const block = parseCalcBlock([
      "revenue = 2Cr",
      "growth = 10%",
      "target = revenue * (1 + growth)",
      "target",
    ].join("\n"));

    const evaluation = evaluateCalcBlock(block);
    expect(evaluation.queryResults[0]?.result.ok).toBe(true);
    if (!evaluation.queryResults[0]?.result.ok) throw new Error("expected successful evaluation");
    expect(evaluation.queryResults[0].result.value).toBe(22000000);
  });
});
