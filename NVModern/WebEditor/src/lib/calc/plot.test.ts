import { describe, expect, it } from "bun:test";
import { parseCalcBlock } from "./parser.ts";
import {
  evaluateCalcBlock,
  type CalcEvaluationSuccess,
  type CalcEvaluationResult,
} from "./runtime.ts";
import { createCalcPlot, isCalcPlot, sampleCalcPlot, plotSummary, type CalcPlot } from "./plot.ts";
import {
  calcPlotGeometry,
  calcPlotViewport,
  nearestCalcPlotPoint,
  panCalcPlot,
  renderCalcPlotSvg,
} from "./plotSvg.ts";
import { readFileSync } from "node:fs";

function result(source: string): CalcEvaluationResult {
  const parsed = parseCalcBlock(source);
  expect(parsed.diagnostics).toEqual([]);
  return evaluateCalcBlock(parsed).statementResults.at(-1)!.result;
}
function success(source: string): CalcEvaluationSuccess {
  const output = result(source);
  if (!output.ok) throw new Error(output.error.message);
  return output;
}
function plot(source: string): CalcPlot {
  const output = success(source);
  expect(output.presentationError).toBeUndefined();
  const value = output.presentation ?? output.value;
  if (!isCalcPlot(value)) throw new Error("Expected plot");
  return value;
}

describe("calc plot presenters", () => {
  it("plots functions over inclusive bounds without replacing the function binding", () => {
    const value = success("f(x) = x^2\nf as plot(-5, 5)");
    expect(value.value).toMatchObject({ kind: "callable", name: "f" });
    const chart = plot("f(x) = x^2\nf as plot(-5, 5)");
    expect(chart.points).toHaveLength(201);
    expect(chart.points[0]).toEqual({ x: -5, y: 25 });
    expect(chart.points[100]).toEqual({ x: 0, y: 0 });
    expect(chart.points[200]).toEqual({ x: 5, y: 25 });
    expect(chart.gaps).toBe(0);
    expect(Object.isFrozen(chart.points)).toBe(true);
  });
  it("plots symbolic expressions and their derivatives", () => {
    const chart = plot("symbol x\n(x^2 + 3*x) as plot(x, -5, 5)");
    expect(chart.points[100]).toEqual({ x: 0, y: 0 });
    expect(chart.points[200]).toEqual({ x: 5, y: 40 });
    const derivative = plot("symbol t\np = t^2 + 3*t\np @diff(t) as plot(t, -1, 1)");
    expect(derivative.xLabel).toBe("t");
    expect(derivative.points[0]?.y).toBe(1);
    expect(derivative.points[200]?.y).toBe(5);
    expect(
      plot("symbol x\n(x - x) @simplify as plot(x, -1, 1)").points.every((point) => point.y === 0),
    ).toBe(true);
  });
  it("plots lists by index and coordinate pairs in their original order", () => {
    expect(plot("[3, 7, 4, 9] as plot").points).toEqual([
      { x: 0, y: 3 },
      { x: 1, y: 7 },
      { x: 2, y: 4 },
      { x: 3, y: 9 },
    ]);
    const scatter = plot('[[2, 4], [0, 3], [1, 7]] as plot("scatter")');
    expect(scatter.plotKind).toBe("scatter");
    expect(scatter.points.map((point) => point.x)).toEqual([2, 0, 1]);
    expect(plot('[3, -2, 4] as plot("bar")').plotKind).toBe("bar");
  });
  it("supports custom plot presenters and plot values from ordinary calls", () => {
    const output = success('bars(data) = plot(data, "bar")\nvalues = [3, 7, 4]\nvalues as bars');
    expect(output.value).toEqual([3, 7, 4]);
    expect(output.presentation).toMatchObject({ kind: "plot", plotKind: "bar" });
    const direct = success("plot([1, 2, 3])");
    expect(isCalcPlot(direct.value)).toBe(true);
    expect(success("[1, 2, 3] @plot @type").value).toBe("plot");
    expect(plotSummary(plot("[1, 2] as plot"))).toBe("[plot: line, 2 points]");
  });
  it("preserves quantity dimensions on each axis and exact source values", () => {
    const chart = plot("[[1s, 1kg], [2s, 500g], [3s, 1//4 * 1kg]] as plot");
    expect(chart.xLabel).toBe("x (s)");
    expect(chart.yLabel).toBe("y (kg)");
    expect(chart.points[2]).toEqual({ x: 3, y: 0.25 });
    const sampled = plot("distance(t) = 2m/s * t\ndistance as plot(0s, 10s)");
    expect(sampled.points[200]).toEqual({ x: 10, y: 20 });
    expect(sampled.xLabel).toBe("x (s)");
    expect(sampled.yLabel).toBe("y (m)");
    expect(success("data = [1//3, 1//6] as plot\ndata @sum").value).toMatchObject({
      kind: "rational",
      numerator: 1n,
      denominator: 2n,
    });
  });
  it("leaves gaps at sampled domain errors and explicit null data", () => {
    const chart = plot("reciprocal(x) = 1/x\nreciprocal as plot(-1, 1)");
    expect(chart.gaps).toBe(1);
    expect(chart.points[100]).toEqual({ x: 0, y: null });
    expect(plot("[1, null, 3] as plot").gaps).toBe(1);
  });
  it("honors the requested kind and bounded sample count", () => {
    const chart = plot('f(x) = x\nf as plot(0, 10, "scatter", 11)');
    expect(chart.plotKind).toBe("scatter");
    expect(chart.points).toHaveLength(11);
    expect(chart.points[5]).toEqual({ x: 5, y: 5 });
    const wide = sampleCalcPlot(-1e308, 1e308, (x) => x);
    expect(wide.points.every((point) => Number.isFinite(point.x) && Number.isFinite(point.y))).toBe(
      true,
    );
  });
  for (const source of [
    "[] as plot",
    "[null, null] as plot",
    "[[0, 1], [2]] as plot",
    "[1, [2, 3]] as plot",
    "[i] as plot",
    '[[0, "bad"]] as plot',
    '[1, 2] as plot("pie")',
    "[1, 2] as plot(0, 1)",
    "f(x) = x\nf as plot(1, 1)",
    "f(x) = x\nf as plot(2, 1)",
    'f(x) = x\nf as plot(0, 1, "line", 1)',
    'f(x) = x\nf as plot(0, 1, "line", 2001)',
    "range(2001) as plot",
    "[[0s, 1], [1m, 2]] as plot",
    "[1kg, 1m] as plot",
    "f(x) = x\nf as plot(0s, 1m)",
    "f(x) = missing + x\nf as plot(0, 1)",
    "f(x, y) = x + y\nf as plot(0, 1)",
    "f(x) = true\nf as plot(0, 1)",
    "f(x) = sqrt(-1)\nf as plot(0, 1)",
    "symbol x, y\n(x + y) as plot(x, 0, 1)",
  ])
    it(`reports invalid plot: ${source.replace(/\n/g, "; ")}`, () => {
      const output = success(source);
      expect(output.presentationError).toBeDefined();
    });
  it("keeps normal function failures distinct from sampled domain gaps", () => {
    expect(success("f(x) = missing\nf as plot(0, 1)").presentationError?.code).toBe(
      "calc.unknown-identifier",
    );
    expect(success("f(x, y) = x\nf as plot(0, 1)").presentationError?.code).toBe(
      "calc.arity-mismatch",
    );
    expect(success("f(x) = true\nf as plot(0, 1)").presentationError?.code).toBe("calc.plot-data");
  });
});

describe("SVG plot drawing", () => {
  it("pans in the pointer direction without changing the data or axis scale", () => {
    const chart = createCalcPlot([
      [0, 0],
      [10, 10],
    ]);
    const viewport = calcPlotViewport(chart);
    const start = calcPlotGeometry(640, viewport);
    const moved = panCalcPlot(viewport, 640, 80, -30);
    const end = calcPlotGeometry(640, moved);
    expect(end.x(5) - start.x(5)).toBeCloseTo(80);
    expect(end.y(5) - start.y(5)).toBeCloseTo(-30);
    expect(moved.x[1] - moved.x[0]).toBeCloseTo(viewport.x[1] - viewport.x[0]);
    expect(chart.points).toEqual([
      { x: 0, y: 0 },
      { x: 10, y: 10 },
    ]);
    expect(panCalcPlot(moved, 640, -80, 30).x[0]).toBeCloseTo(viewport.x[0]);
    expect(renderCalcPlotSvg(chart, 640, "panned", moved)).not.toMatch(/NaN|Infinity/);
  });
  it("finds visible hover samples and skips gaps, offscreen points, and margins", () => {
    const chart = createCalcPlot([
      [0, 1],
      [1, null],
      [2, 5],
    ]);
    const viewport = calcPlotViewport(chart),
      geometry = calcPlotGeometry(640, viewport);
    expect(nearestCalcPlotPoint(chart, viewport, 640, geometry.x(2), geometry.y(3))?.point).toEqual(
      { x: 2, y: 5 },
    );
    expect(nearestCalcPlotPoint(chart, viewport, 640, geometry.left - 1, geometry.top)).toBeNull();
    const away = panCalcPlot(viewport, 640, 2000, 0);
    expect(nearestCalcPlotPoint(chart, away, 640, 300, 100)).toBeNull();
    const scatter = createCalcPlot(
      [
        [1, 1],
        [1, 5],
      ],
      "scatter",
    );
    const scatterViewport = calcPlotViewport(scatter),
      s = calcPlotGeometry(640, scatterViewport);
    expect(nearestCalcPlotPoint(scatter, scatterViewport, 640, s.x(1), s.y(5))?.point.y).toBe(5);
  });
  it("keeps the true zero baseline and bar widths when panning", () => {
    const chart = createCalcPlot([1, 2], "bar"),
      viewport = calcPlotViewport(chart);
    const moved = panCalcPlot(viewport, 280, 50, -20);
    const bars = (source: string) => [
      ...source.matchAll(
        /class="nv3-calc-plot-bar" x="([^"]+)" y="([^"]+)" width="([^"]+)" height="([^"]+)"/g,
      ),
    ];
    const initial = bars(renderCalcPlotSvg(chart, 280));
    const shifted = bars(renderCalcPlotSvg(chart, 280, "panned", moved));
    expect(shifted).toHaveLength(2);
    expect(Number(shifted[0]![1]) - Number(initial[0]![1])).toBeCloseTo(50);
    expect(Number(shifted[0]![2]) - Number(initial[0]![2])).toBeCloseTo(-20);
    expect(Number(shifted[0]![3])).toBeCloseTo(Number(initial[0]![3]));
    expect(Number(shifted[0]![4])).toBeCloseTo(Number(initial[0]![4]));
  });
  it("refuses pan overflow at extreme finite ranges", () => {
    const viewport = calcPlotViewport(createCalcPlot([-1e308, 1e308]));
    const moved = panCalcPlot(viewport, 640, 0, 1e6);
    expect(moved.y).toEqual(viewport.y);
    expect(renderCalcPlotSvg(createCalcPlot([-1e308, 1e308]), 640, "extreme", moved)).not.toMatch(
      /NaN|Infinity/,
    );
  });
  it("draws vector axes, labels, and series without embedding fixed theme colors", () => {
    const svg = renderCalcPlotSvg(createCalcPlot([1, 3, 2]), 640, "test");
    expect(svg).toContain('role="img"');
    expect(svg).toContain('viewBox="0 0 640 280"');
    expect(svg).toContain('class="nv3-calc-plot-line"');
    expect(svg).toContain('class="nv3-calc-plot-axis"');
    expect(svg).toContain('id="test-clip"');
    expect(svg).not.toMatch(/#[0-9a-fA-F]{3,8}(?:[";])/);
    expect(svg).not.toMatch(/NaN|Infinity/);
  });
  it("breaks line paths at gaps and draws scatter points and bars", () => {
    const line = renderCalcPlotSvg(createCalcPlot([1, null, 3]));
    expect(line.match(/class="nv3-calc-plot-line" d="([^"]+)"/)?.[1]?.match(/M/g)).toHaveLength(2);
    expect(renderCalcPlotSvg(createCalcPlot([1, 2], "scatter"))).toContain(
      'class="nv3-calc-plot-dot"',
    );
    expect(renderCalcPlotSvg(createCalcPlot([-2, 3], "bar"))).toContain(
      'class="nv3-calc-plot-bar"',
    );
  });
  it("handles constant, single-point, zero, negative, and extreme finite data", () => {
    for (const data of [[0], [5, 5], [-2, -1], [-1e308, 1e308], [Number.MAX_VALUE]]) {
      for (const kind of ["line", "scatter", "bar"] as const) {
        const svg = renderCalcPlotSvg(createCalcPlot(data, kind), 300);
        expect(svg).not.toMatch(/NaN|Infinity/);
      }
    }
  });
  it("keeps the first and last bars visible in narrow plots", () => {
    const svg = renderCalcPlotSvg(createCalcPlot([1, 2], "bar"), 280);
    for (const match of svg.matchAll(
      /class="nv3-calc-plot-bar" x="([^"]+)" y="[^"]+" width="([^"]+)"/g,
    )) {
      const x = Number(match[1]),
        width = Number(match[2]);
      expect(x).toBeGreaterThanOrEqual(72 - 1e-8);
      expect(x + width).toBeLessThanOrEqual(260 + 1e-8);
    }
  });
  it("escapes text and lets public editor theme tokens control plot colors", () => {
    const chart = { ...createCalcPlot([1, 2]), xLabel: '<script>&"', yLabel: "<bad>" };
    const svg = renderCalcPlotSvg(chart);
    expect(svg).not.toContain("<script>");
    expect(svg).toContain("&lt;script&gt;&amp;&quot;");
    const css = readFileSync(new URL("../../styles/editor.lib.css", import.meta.url), "utf8");
    for (const selector of [".nv3-calc-plot-line", ".nv3-calc-plot-dot", ".nv3-calc-plot-bar"])
      expect(css).toContain(selector);
    expect(css).toContain("stroke: var(--nv3-color-accent)");
    expect(css).toContain("fill: var(--nv3-color-text-muted)");
  });
});
