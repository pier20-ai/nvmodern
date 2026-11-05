import {
  CalcError,
  arithmetic,
  canonicalUnit,
  compareNumeric,
  fail,
  isQuantity,
  isScalar,
  rational,
  sameDimensions,
  smallInteger,
  toNumber,
  type Dimensions,
  type Quantity,
  type Scalar,
} from "./numeric.ts";

export type CalcPlotKind = "line" | "scatter" | "bar";
export interface CalcPlotPoint {
  readonly x: number;
  readonly y: number | null;
}
export interface CalcPlot {
  readonly kind: "plot";
  readonly plotKind: CalcPlotKind;
  readonly points: readonly CalcPlotPoint[];
  readonly xLabel: string;
  readonly yLabel: string;
  readonly gaps: number;
}
export type CalcPresentation = string | CalcPlot;
export const MAX_PLOT_POINTS = 2000;
export const DEFAULT_PLOT_SAMPLES = 201;
export function isCalcPlot(value: unknown): value is CalcPlot {
  return !!value && typeof value === "object" && "kind" in value && value.kind === "plot";
}
export function plotKind(value: unknown = "line"): CalcPlotKind {
  return value === "line" || value === "scatter" || value === "bar"
    ? value
    : fail("Plot kind must be 'line', 'scatter', or 'bar'.", "calc.plot-data");
}
type Coordinate = Scalar | Quantity;
function coordinate(value: unknown): Coordinate {
  return isScalar(value) || isQuantity(value)
    ? value
    : fail("Plot coordinates must be real numbers or compatible quantities.", "calc.plot-data");
}
class Axis {
  private units: Dimensions | undefined;
  constructor(readonly name: string) {}
  read(value: unknown): number {
    const number = coordinate(value),
      units = isQuantity(number) ? number.dimensions : {};
    if (this.units && !sameDimensions(this.units, units))
      fail(
        `Plot ${this.name} coordinates have incompatible dimensions.`,
        "calc.incompatible-dimensions",
      );
    this.units = units;
    return toNumber(isQuantity(number) ? number.magnitude : number);
  }
  label(): string {
    return this.units && Object.keys(this.units).length
      ? `${this.name} (${canonicalUnit(this.units)})`
      : this.name;
  }
}
export function createCalcPlot(
  data: readonly unknown[],
  kind: CalcPlotKind = "line",
  xName?: string,
): CalcPlot {
  if (!data.length) fail("Plot data cannot be empty.", "calc.plot-data");
  if (data.length > MAX_PLOT_POINTS)
    fail(`Plot exceeds ${MAX_PLOT_POINTS} points.`, "calc.resource-limit");
  const pairs = data.some(Array.isArray),
    x = new Axis(xName ?? (pairs ? "x" : "Index")),
    y = new Axis("y");
  let gaps = 0;
  const points = data.map((item, index) => {
    if (pairs && (!Array.isArray(item) || item.length !== 2))
      fail("Plot data must contain only [x, y] pairs or only y values.", "calc.plot-data");
    const point = pairs ? (item as [unknown, unknown]) : [BigInt(index), item];
    const px = x.read(point[0]);
    const py = point[1] === null ? (gaps++, null) : y.read(point[1]);
    return Object.freeze({ x: px, y: py });
  });
  if (gaps === points.length) fail("Plot has no finite samples.", "calc.plot-data");
  return Object.freeze({
    kind: "plot",
    plotKind: kind,
    points: Object.freeze(points),
    xLabel: x.label(),
    yLabel: y.label(),
    gaps,
  });
}
export function sampleCalcPlot(
  from: unknown,
  to: unknown,
  sample: (x: Coordinate) => unknown,
  kind: CalcPlotKind = "line",
  samples: unknown = BigInt(DEFAULT_PLOT_SAMPLES),
  xName = "x",
): CalcPlot {
  const start = coordinate(from),
    end = coordinate(to),
    count = smallInteger(samples, "Plot sample count");
  if (count < 2 || count > MAX_PLOT_POINTS)
    fail(`Plot sample count must be between 2 and ${MAX_PLOT_POINTS}.`, "calc.resource-limit");
  if (compareNumeric(start, end) >= 0)
    fail("Plot lower bound must be less than its upper bound.", "calc.plot-data");
  const points: unknown[] = [];
  for (let index = 0; index < count; index++) {
    const weight = rational(BigInt(index), BigInt(count - 1));
    const x =
      index === 0
        ? start
        : index === count - 1
          ? end
          : coordinate(
              arithmetic(
                "+",
                arithmetic("*", start, rational(BigInt(count - 1 - index), BigInt(count - 1))),
                arithmetic("*", end, weight),
              ),
            );
    let y: unknown;
    try {
      y = sample(x);
    } catch (error) {
      if (
        !(error instanceof CalcError) ||
        !["calc.domain-error", "calc.divide-by-zero"].includes(error.code)
      )
        throw error;
      y = null;
    }
    points.push([x, y]);
  }
  return createCalcPlot(points, kind, xName);
}
export function plotSummary(plot: CalcPlot): string {
  return `[plot: ${plot.plotKind}, ${plot.points.length} points${plot.gaps ? `, ${plot.gaps} gaps` : ""}]`;
}
export function formatCalcPresentation(value: CalcPresentation): string {
  return typeof value === "string" ? value : plotSummary(value);
}
