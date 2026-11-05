import { describe, expect, it } from "bun:test";
import {
  parseCalcBlock,
  parseCalcExpression,
  parseCalcStatement,
} from "./parser.ts";

describe("calc parser", () => {
  it("parses pipe expressions with namespaced call stages", () => {
    const result = parseCalcExpression("value |> math.round(2)");
    expect(result.diagnostics).toHaveLength(0);
    expect(result.expression?.kind).toBe("PipeExpression");

    const expression = result.expression;
    if (!expression || expression.kind !== "PipeExpression") {
      throw new Error("expected PipeExpression");
    }

    expect(expression.input.kind).toBe("Identifier");
    expect(expression.stage.callee.kind).toBe("MemberExpression");
    expect(expression.stage.args).toHaveLength(1);
    expect(expression.stage.args[0]?.kind).toBe("NumberLiteral");
  });

  it("parses function definitions", () => {
    const result = parseCalcStatement("payment(p, r, n) = p * r");
    expect(result.diagnostics).toHaveLength(0);
    expect(result.statement?.kind).toBe("FunctionDefinition");

    const statement = result.statement;
    if (!statement || statement.kind !== "FunctionDefinition") {
      throw new Error("expected FunctionDefinition");
    }

    expect(statement.name).toBe("payment");
    expect(statement.params.map((param) => param.name)).toEqual(["p", "r", "n"]);
  });

  it("keeps block line diagnostics and statement offsets", () => {
    const result = parseCalcBlock([
      "# comment",
      "principal = 400000",
      "monthly = principal |> math.round(2)",
      "broken =",
    ].join("\n"));

    expect(result.statements).toHaveLength(2);
    expect(result.lines).toHaveLength(4);
    expect(result.lines[0]?.kind).toBe("comment");
    expect(result.lines[3]?.diagnostics[0]?.line).toBe(4);
    expect(result.lines[1]?.statement?.range.from).toBeGreaterThan(0);
  });

  it("reports invalid pipe targets", () => {
    const result = parseCalcExpression("value |> 2");
    expect(result.expression).toBeNull();
    expect(result.diagnostics.some((diag) => diag.code === "calc.invalid-pipe-target")).toBe(true);
  });

  it("ignores whole-line hash and semicolon comments, including arrows and invalid syntax", () => {
    const result = parseCalcBlock([
      "  # total = ??? -> ignored",
      "\t; total = ??? → ignored",
      'label = "#;"',
      "label",
    ].join("\n"));

    expect(result.diagnostics).toEqual([]);
    expect(result.lines.map((line) => line.kind)).toEqual(["comment", "comment", "statement", "statement"]);
    expect(result.lines.slice(0, 2).every((line) => line.reactiveOutput === null)).toBe(true);
    expect(result.statements).toHaveLength(2);
  });

  it("parses reactive value definitions with either arrow and preserves source ranges", () => {
    const source = ["# heading", "total = 2 * 3 -> ", "next = total + 1 → stale"].join("\n");
    const result = parseCalcBlock(source);

    expect(result.diagnostics).toEqual([]);
    expect(result.statements.map((statement) => statement.kind)).toEqual(["ValueDefinition", "ValueDefinition"]);
    for (const line of result.lines.slice(1)) {
      expect(source.slice(line.statement!.range.from, line.statement!.range.to)).toBe(line.reactiveOutput!.expressionSource.trim());
      const output = line.reactiveOutput!;
      expect(source.slice(output.separatorRange.from, output.separatorRange.to)).toBe(output.separator);
      expect(source.slice(output.outputRange.from, output.outputRange.to)).toBe(output.outputSource);
    }
  });

  it("reports incomplete reactive assignments and rejects arrows on function definitions", () => {
    const result = parseCalcBlock("total = ->\nf(x) = x + 1 ->");
    expect(result.lines[0]?.diagnostics.length).toBeGreaterThan(0);
    expect(result.lines[1]?.diagnostics[0]?.code).toBe("calc.invalid-reactive-statement");
    expect(result.lines[1]?.statement).toBeNull();
  });

  it("ignores trailing comments after definitions, functions, queries, and reactive outputs", () => {
    const source = [
      "price = 25 # input -> not an output",
      "double(x) = x * 2 ; helper → ignored",
      "total = double(price) * 2 -> 100 # calculate total",
      "total → 100 ; show total",
      "total + 1 # query",
    ].join("\n");
    const result = parseCalcBlock(source);

    expect(result.diagnostics).toEqual([]);
    expect(result.statements).toHaveLength(5);
    expect(result.lines.slice(0, 2).every((line) => line.reactiveOutput === null)).toBe(true);
    for (const line of result.lines.slice(2, 4)) {
      const output = line.reactiveOutput!;
      expect(output.outputSource).toBe("100");
      expect(source.slice(output.outputRange.from, output.outputRange.to)).toBe("100");
    }
    expect(result.lines[2]?.text).toBe("total = double(price) * 2 -> 100 # calculate total");
  });

  it("keeps comment markers inside quoted strings, including escaped quotes and backslashes", () => {
    const source = [
      String.raw`label = "say \"#hello;\"" # comment`,
      String.raw`other = 'it\'s #; fine' ; comment`,
      String.raw`path = "C:\\" # comment`,
      String.raw`items = ["#", ';'] -> ["#", ";"] # comment`,
    ].join("\n");
    const result = parseCalcBlock(source);

    expect(result.diagnostics).toEqual([]);
    expect(result.statements).toHaveLength(4);
    expect(result.lines[3]?.reactiveOutput?.outputSource).toBe('["#", ";"]');
  });

  it("keeps incomplete expression diagnostics before the trailing comment", () => {
    const source = "price = 25\ntotal = # needs a value -> not an output";
    const result = parseCalcBlock(source);
    const brokenLine = result.lines[1]!;

    expect(brokenLine.reactiveOutput).toBeNull();
    expect(brokenLine.diagnostics.length).toBeGreaterThan(0);
    expect(brokenLine.diagnostics[0]?.line).toBe(2);
    expect(brokenLine.diagnostics[0]?.from).toBeLessThanOrEqual(source.indexOf("#"));
  });

  it("parses scientific notation and percent literals", () => {
    const sci = parseCalcExpression("1e7");
    expect(sci.diagnostics).toHaveLength(0);
    expect(sci.expression?.kind).toBe("NumberLiteral");
    if (!sci.expression || sci.expression.kind !== "NumberLiteral") {
      throw new Error("expected NumberLiteral");
    }
    expect(sci.expression.value).toBe(10000000);

    const percent = parseCalcExpression("10%");
    expect(percent.diagnostics).toHaveLength(0);
    expect(percent.expression?.kind).toBe("NumberLiteral");
    if (!percent.expression || percent.expression.kind !== "NumberLiteral") {
      throw new Error("expected NumberLiteral");
    }
    expect(percent.expression.value).toBe(0.1);
  });

  it("parses scale suffixes", () => {
    const samples: Array<[string, number]> = [
      ["10k", 10000],
      ["2M", 2000000],
      ["3B", 30000000],
      ["4T", 4000000000],
      ["5Cr", 50000000],
      ["6L", 600000],
      ["10k%", 100],
    ];

    for (const [source, expected] of samples) {
      const result = parseCalcExpression(source);
      expect(result.diagnostics).toHaveLength(0);
      expect(result.expression?.kind).toBe("NumberLiteral");
      if (!result.expression || result.expression.kind !== "NumberLiteral") {
        throw new Error(`expected NumberLiteral for ${source}`);
      }
      expect(result.expression.value).toBe(expected);
    }
  });
});
