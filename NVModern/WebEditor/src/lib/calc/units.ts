import {
  dimensions,
  divScalar,
  fail,
  mulScalar,
  powScalar,
  rational,
  sameDimensions,
  type Dimensions,
  type Scalar,
} from "./numeric.ts";

export interface CalcUnit {
  symbol: string;
  factor: Scalar;
  dimensions: Dimensions;
}
interface UnitDefinition {
  factor: Scalar;
  dimensions: Dimensions;
  prefixes?: boolean;
}
const definitions: Record<string, UnitDefinition> = {
  m: { factor: 1n, dimensions: { m: 1 }, prefixes: true },
  s: { factor: 1n, dimensions: { s: 1 }, prefixes: true },
  g: { factor: rational(1n, 1000n), dimensions: { kg: 1 }, prefixes: true },
  kg: { factor: 1n, dimensions: { kg: 1 } },
  min: { factor: 60n, dimensions: { s: 1 } },
  h: { factor: 3600n, dimensions: { s: 1 } },
  day: { factor: 86400n, dimensions: { s: 1 } },
  l: { factor: rational(1n, 1000n), dimensions: { m: 3 }, prefixes: true },
  litre: { factor: rational(1n, 1000n), dimensions: { m: 3 } },
  rad: { factor: 1n, dimensions: { rad: 1 }, prefixes: true },
  deg: { factor: Math.PI / 180, dimensions: { rad: 1 } },
};
const prefixes: Record<string, number> = {
  T: 12,
  G: 9,
  M: 6,
  k: 3,
  h: 2,
  da: 1,
  d: -1,
  c: -2,
  m: -3,
  u: -6,
  µ: -6,
  n: -9,
  p: -12,
};
export function calcUnitSymbols(): readonly string[] {
  return [
    ...new Set([
      ...Object.keys(definitions),
      ...Object.keys(prefixes).flatMap((prefix) =>
        Object.entries(definitions)
          .filter(([, unit]) => unit.prefixes)
          .map(([name]) => prefix + name),
      ),
    ]),
  ];
}
function lookup(symbol: string): CalcUnit | null {
  const direct = Object.hasOwn(definitions, symbol) ? definitions[symbol] : undefined;
  if (direct) return { ...direct, symbol };
  for (const prefix of Object.keys(prefixes).sort((a, b) => b.length - a.length)) {
    if (!symbol.startsWith(prefix)) continue;
    const base = symbol.slice(prefix.length);
    const unit = Object.hasOwn(definitions, base) ? definitions[base] : undefined;
    if (!unit?.prefixes) continue;
    const exponent = prefixes[prefix]!,
      factor = exponent >= 0 ? 10n ** BigInt(exponent) : rational(1n, 10n ** BigInt(-exponent));
    return { symbol, factor: mulScalar(factor, unit.factor), dimensions: unit.dimensions };
  }
  return null;
}

export function scanCalcUnit(source: string, start = 0): { unit: CalcUnit; to: number } | null {
  let cursor = start,
    depth = 0;
  const space = () => {
    while (source[cursor] === " " || source[cursor] === "\t") cursor++;
  };
  function factor(): CalcUnit | null {
    space();
    let result: CalcUnit | null;
    if (source[cursor] === "(") {
      if (++depth > 32) fail("Unit nesting exceeds 32.", "calc.resource-limit");
      cursor++;
      result = product();
      space();
      if (!result || source[cursor] !== ")") return null;
      cursor++;
      depth--;
    } else {
      const symbol = source.slice(cursor).match(/^[A-Za-zµ]+/)?.[0];
      if (!symbol || !(result = lookup(symbol))) return null;
      cursor += symbol.length;
    }
    const end = cursor;
    space();
    if (source[cursor] === "^") {
      cursor++;
      space();
      const exponent = source.slice(cursor).match(/^[+-]?\d[\d_]*/)?.[0];
      if (!exponent) {
        cursor = end;
        return result;
      }
      const power = Number(exponent.replace(/_/g, ""));
      if (Math.abs(power) > 32) fail("Unit exponent exceeds 32.", "calc.resource-limit");
      cursor += exponent.length;
      result = {
        symbol: "",
        factor: powScalar(result.factor, BigInt(power)),
        dimensions: Object.fromEntries(
          Object.entries(result.dimensions)
            .map(([k, v]) => [k, v * power])
            .filter(([, v]) => v !== 0),
        ),
      };
    } else cursor = end;
    return result;
  }
  function product(): CalcUnit | null {
    let result = factor();
    if (!result) return null;
    while (true) {
      const end = cursor;
      space();
      const op = source[cursor];
      if ((op !== "*" && op !== "/") || source[cursor + 1] === "/") {
        cursor = end;
        break;
      }
      cursor++;
      const next = factor();
      if (!next) {
        cursor = end;
        break;
      }
      result = {
        symbol: "",
        factor:
          op === "*"
            ? mulScalar(result.factor, next.factor)
            : divScalar(result.factor, next.factor, true),
        dimensions: dimensions(result.dimensions, next.dimensions, op === "*" ? 1 : -1),
      };
    }
    return result;
  }
  const unit = product();
  return unit
    ? {
        unit: { ...unit, symbol: source.slice(start, cursor).trim().replace(/\s+/g, "") },
        to: cursor,
      }
    : null;
}

export function requireCalcUnit(source: string): CalcUnit {
  const parsed = scanCalcUnit(source);
  return parsed && parsed.to === source.length
    ? parsed.unit
    : fail(`Unknown unit '${source}'.`, "calc.unknown-unit");
}

export function convertMagnitude(magnitude: Scalar, dims: Dimensions, target: CalcUnit): Scalar {
  if (!sameDimensions(dims, target.dimensions))
    fail("Incompatible dimensions.", "calc.incompatible-dimensions");
  return divScalar(magnitude, target.factor, true);
}
