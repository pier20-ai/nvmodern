import type { CalcPlot } from "./plot.ts";

export const CALC_PLOT_HEIGHT = 280;
const escape = (text: string): string =>
  text.replace(
    /[&<>"']/g,
    (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" })[char]!,
  );
export const formatPlotCoordinate = (value: number): string => {
  const text = value.toPrecision(5);
  const rounded = Number(text);
  return Number.isFinite(rounded) ? String(rounded) : text;
};
function extent(values: readonly number[], zero = false): [number, number] {
  let low = zero ? Math.min(0, ...values) : Math.min(...values),
    high = zero ? Math.max(0, ...values) : Math.max(...values);
  if (low === high) {
    const padding = Math.max(Math.abs(low) * 0.1, 1);
    const a = low - padding,
      b = high + padding;
    low = Number.isFinite(a) ? a : low;
    high = Number.isFinite(b) ? b : high;
  } else {
    const padding = high / 20 - low / 20;
    if (Number.isFinite(low - padding)) low -= padding;
    if (Number.isFinite(high + padding)) high += padding;
  }
  return [low, high];
}
function fraction(value: number, [low, high]: readonly [number, number]): number {
  const scale = Math.max(Math.abs(low), Math.abs(high), Number.MIN_VALUE);
  return (value / scale - low / scale) / (high / scale - low / scale);
}
function lerp(low: number, high: number, t: number): number {
  return low * (1 - t) + high * t;
}

export interface CalcPlotViewport {
  readonly x: readonly [number, number];
  readonly y: readonly [number, number];
}
export function calcPlotViewport(plot: CalcPlot): CalcPlotViewport {
  return {
    x: extent(plot.points.map((p) => p.x)),
    y: extent(
      plot.points.filter((p) => p.y !== null).map((p) => p.y!),
      plot.plotKind === "bar",
    ),
  };
}
export function calcPlotGeometry(width: number, viewport: CalcPlotViewport) {
  width = Math.max(280, Math.min(2000, width));
  const height = CALC_PLOT_HEIGHT,
    left = 72,
    right = width - 20,
    top = 20,
    bottom = height - 48;
  return {
    width,
    height,
    left,
    right,
    top,
    bottom,
    x: (value: number) => left + fraction(value, viewport.x) * (right - left),
    y: (value: number) => bottom - fraction(value, viewport.y) * (bottom - top),
  };
}
export function panCalcPlot(
  viewport: CalcPlotViewport,
  width: number,
  dx: number,
  dy: number,
): CalcPlotViewport {
  const { left, right, top, bottom } = calcPlotGeometry(width, viewport);
  const shift = (
    [low, high]: readonly [number, number],
    amount: number,
  ): readonly [number, number] => {
    const scale = Math.max(Math.abs(low), Math.abs(high), Number.MIN_VALUE);
    const delta = (high / scale - low / scale) * amount * scale;
    const next = [low + delta, high + delta] as const;
    return next.every(Number.isFinite) && next[0] < next[1] ? next : [low, high];
  };
  return { x: shift(viewport.x, -dx / (right - left)), y: shift(viewport.y, dy / (bottom - top)) };
}
export function nearestCalcPlotPoint(
  plot: CalcPlot,
  viewport: CalcPlotViewport,
  width: number,
  px: number,
  py: number,
) {
  const { left, right, top, bottom, x, y } = calcPlotGeometry(width, viewport);
  if (px < left || px > right || py < top || py > bottom) return null;
  let nearest: { point: (typeof plot.points)[number]; x: number; y: number } | null = null;
  let distance = Infinity;
  for (const point of plot.points) {
    if (point.y === null) continue;
    const sx = x(point.x),
      sy = y(point.y);
    if (sx < left || sx > right || sy < top || sy > bottom) continue;
    // Lines are read by x so hovering anywhere in a column finds the sampled value.
    const d = plot.plotKind === "scatter" ? Math.hypot(sx - px, sy - py) : Math.abs(sx - px);
    if (d < distance) {
      distance = d;
      nearest = { point, x: sx, y: sy };
    }
  }
  return nearest;
}

export function renderCalcPlotSvg(
  plot: CalcPlot,
  width = 640,
  id = "calc-plot",
  viewport = calcPlotViewport(plot),
): string {
  const {
    width: svgWidth,
    height,
    left,
    right,
    top,
    bottom,
    x,
    y,
  } = calcPlotGeometry(width, viewport);
  width = svgWidth;
  const valid = plot.points.filter((point) => point.y !== null),
    xs = viewport.x,
    ys = viewport.y;
  const clip = escape(id + "-clip"),
    title = `${plot.plotKind[0]!.toUpperCase()}${plot.plotKind.slice(1)} plot, ${plot.points.length} points`;
  const svg = [
    `<svg xmlns="http://www.w3.org/2000/svg" class="nv3-calc-plot-svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="${escape(title)}">`,
    `<desc>${escape(`${title}. ${plot.xLabel} versus ${plot.yLabel}${plot.gaps ? `; ${plot.gaps} missing or undefined samples` : ""}. Hover for coordinates. Shift-drag to pan. Double-click or press Home to reset.`)}</desc>`,
    `<defs><clipPath id="${clip}"><rect x="${left}" y="${top}" width="${right - left}" height="${bottom - top}"/></clipPath></defs>`,
  ];
  const ticks = width < 440 ? 3 : 5;
  for (let index = 0; index <= ticks; index++) {
    const t = index / ticks,
      px = lerp(left, right, t),
      py = lerp(bottom, top, t);
    svg.push(
      `<path class="nv3-calc-plot-grid" d="M${px},${top}V${bottom}M${left},${py}H${right}"/>`,
    );
    svg.push(
      `<text class="nv3-calc-plot-tick" x="${px}" y="${bottom + 20}" text-anchor="middle">${formatPlotCoordinate(lerp(xs[0], xs[1], t))}</text>`,
    );
    svg.push(
      `<text class="nv3-calc-plot-tick" x="${left - 10}" y="${py}" text-anchor="end" dominant-baseline="middle">${formatPlotCoordinate(lerp(ys[0], ys[1], t))}</text>`,
    );
  }
  const baselineX = xs[0] <= 0 && xs[1] >= 0 ? x(0) : left;
  const baselineY = ys[0] <= 0 && ys[1] >= 0 ? y(0) : bottom;
  svg.push(
    `<path class="nv3-calc-plot-axis" d="M${left},${baselineY}H${right}M${baselineX},${top}V${bottom}"/>`,
  );
  svg.push(
    `<text class="nv3-calc-plot-label" x="${(left + right) / 2}" y="${height - 6}" text-anchor="middle">${escape(plot.xLabel)}</text>`,
  );
  svg.push(
    `<text class="nv3-calc-plot-label" transform="translate(15 ${(top + bottom) / 2}) rotate(-90)" text-anchor="middle">${escape(plot.yLabel)}</text>`,
  );
  svg.push(`<g clip-path="url(#${clip})">`);
  if (plot.plotKind === "line") {
    let path = "",
      connected = false;
    for (const point of plot.points) {
      if (point.y === null) {
        connected = false;
        continue;
      }
      path += `${connected ? "L" : "M"}${x(point.x)},${y(point.y)}`;
      connected = true;
    }
    svg.push(`<path class="nv3-calc-plot-line" d="${path}"/>`);
  }
  const positions = [...new Set(valid.map((p) => x(p.x)))].sort((a, b) => a - b);
  const spacing =
    positions.length > 1
      ? Math.min(...positions.slice(1).map((p, i) => p - positions[i]!))
      : (right - left) / 2;
  const original = calcPlotGeometry(width, calcPlotViewport(plot));
  const edgeSpace = Math.min(
    ...valid.map((point) => Math.min(original.x(point.x) - left, right - original.x(point.x))),
  );
  const barWidth = Math.max(1, Math.min(40, spacing * 0.7, edgeSpace * 2));
  for (const point of valid) {
    const px = x(point.x),
      py = y(point.y!);
    if (plot.plotKind === "bar")
      svg.push(
        `<rect class="nv3-calc-plot-bar" x="${px - barWidth / 2}" y="${Math.min(py, y(0))}" width="${barWidth}" height="${Math.abs(y(0) - py)}"/>`,
      );
    else
      svg.push(
        `<circle class="${plot.plotKind === "scatter" || valid.length === 1 ? "nv3-calc-plot-dot" : "nv3-calc-plot-hit"}" cx="${px}" cy="${py}" r="${plot.plotKind === "scatter" || valid.length === 1 ? 3.5 : 5}"/>`,
      );
  }
  svg.push(
    '<g class="nv3-calc-plot-hover" visibility="hidden"><path class="nv3-calc-plot-guide"/><circle class="nv3-calc-plot-marker" r="4"/></g></g></svg>',
  );
  return svg.join("");
}
