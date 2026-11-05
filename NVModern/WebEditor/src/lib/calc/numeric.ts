export class CalcError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export interface Rational {
  kind: "rational";
  numerator: bigint;
  denominator: bigint;
}
export type Scalar = number | bigint | Rational;
export interface Complex {
  kind: "complex";
  re: Scalar;
  im: Scalar;
}
export type Dimensions = Readonly<Record<string, number>>;
export interface Quantity {
  kind: "quantity";
  magnitude: Scalar;
  dimensions: Dimensions;
}
export type Numeric = Scalar | Complex | Quantity;
export const scales: Record<string, bigint> = {
  k: 1000n,
  M: 1000000n,
  B: 10000000n,
  T: 1000000000n,
  Cr: 10000000n,
  L: 100000n,
};

export function fail(message: string, code = "calc.type-error"): never {
  throw new CalcError(code, message);
}
export function gcd(a: bigint, b: bigint): bigint {
  a = a < 0n ? -a : a;
  b = b < 0n ? -b : b;
  while (b) [a, b] = [b, a % b];
  return a;
}
export function rational(n: bigint, d: bigint): Scalar {
  if (!d) fail("Division by zero.", "calc.divide-by-zero");
  if (d < 0n) {
    n = -n;
    d = -d;
  }
  const divisor = gcd(n, d);
  n /= divisor;
  d /= divisor;
  if (Math.max(bits(n), bits(d)) > 65536)
    fail("Exact arithmetic exceeds 65536 bits.", "calc.resource-limit");
  return d === 1n ? n : { kind: "rational", numerator: n, denominator: d };
}
export function isRational(v: unknown): v is Rational {
  return !!v && typeof v === "object" && "kind" in v && v.kind === "rational";
}
export function isComplex(v: unknown): v is Complex {
  return !!v && typeof v === "object" && "kind" in v && v.kind === "complex";
}
export function isQuantity(v: unknown): v is Quantity {
  return !!v && typeof v === "object" && "kind" in v && v.kind === "quantity";
}
export function isScalar(v: unknown): v is Scalar {
  return typeof v === "number" || typeof v === "bigint" || isRational(v);
}
export function isNumeric(v: unknown): v is Numeric {
  return isScalar(v) || isComplex(v) || isQuantity(v);
}
export function scalar(v: unknown, label = "Value"): Scalar {
  return isScalar(v) ? v : fail(`${label} must be a dimensionless real number.`);
}
export function numeric(v: unknown, label = "Value"): Numeric {
  return isNumeric(v) ? v : fail(`${label} must be numeric.`);
}
export function finite(v: number): number {
  return Number.isFinite(v)
    ? v
    : fail("Calculation is outside the finite real domain.", "calc.domain-error");
}
export function toNumber(v: Scalar): number {
  if (typeof v === "number") return finite(v);
  if (typeof v === "bigint") return finite(Number(v));
  const numerator = Number(v.numerator),
    denominator = Number(v.denominator);
  if (Number.isFinite(numerator) && Number.isFinite(denominator))
    return finite(numerator / denominator);
  const sign = v.numerator < 0n ? -1 : 1;
  const n = (v.numerator < 0n ? -v.numerator : v.numerator).toString(),
    d = v.denominator.toString();
  const head = (s: string) => Number(s.slice(0, 16)) / 10 ** (Math.min(16, s.length) - 1);
  return finite(((sign * head(n)) / head(d)) * 10 ** (n.length - d.length));
}
export function integer(v: unknown, label = "Value"): bigint {
  return typeof v === "bigint" ? v : fail(`${label} must be an Integer.`);
}
export function smallInteger(v: unknown, label = "Value"): number {
  const n = integer(v, label);
  return n <= BigInt(Number.MAX_SAFE_INTEGER) && n >= BigInt(Number.MIN_SAFE_INTEGER)
    ? Number(n)
    : fail(`${label} is too large.`, "calc.resource-limit");
}
export function parts(v: bigint | Rational): [bigint, bigint] {
  return typeof v === "bigint" ? [v, 1n] : [v.numerator, v.denominator];
}
function bits(n: bigint): number {
  return (n < 0n ? -n : n).toString(2).length;
}
function checkProduct(a: bigint, b: bigint): void {
  if (bits(a) + bits(b) > 65536)
    fail("Exact arithmetic exceeds 65536 bits.", "calc.resource-limit");
}
export function parseNumeric(raw: string): Scalar {
  const percent = raw.endsWith("%");
  let text = percent ? raw.slice(0, -1) : raw;
  const suffix = Object.keys(scales).find((s) => text.endsWith(s));
  if (suffix) text = text.slice(0, -suffix.length);
  text = text.replace(/_/g, "");
  const n: Scalar = /^\d+$/.test(text) ? BigInt(text) : finite(Number(text));
  const result = suffix ? mulScalar(n, scales[suffix]!) : n;
  return percent ? toNumber(result) / 100 : result;
}
export function addScalar(a: Scalar, b: Scalar): Scalar {
  if (typeof a === "number" || typeof b === "number") return finite(toNumber(a) + toNumber(b));
  const [an, ad] = parts(a),
    [bn, bd] = parts(b);
  return rational(an * bd + bn * ad, ad * bd);
}
export function negScalar(a: Scalar): Scalar {
  return typeof a === "object" ? rational(-a.numerator, a.denominator) : -a;
}
export function mulScalar(a: Scalar, b: Scalar): Scalar {
  if (typeof a === "number" || typeof b === "number") return finite(toNumber(a) * toNumber(b));
  let [an, ad] = parts(a),
    [bn, bd] = parts(b);
  const left = gcd(an, bd),
    right = gcd(bn, ad);
  an /= left;
  bd /= left;
  bn /= right;
  ad /= right;
  checkProduct(an, bn);
  checkProduct(ad, bd);
  return rational(an * bn, ad * bd);
}
export function divScalar(a: Scalar, b: Scalar, exact = false): Scalar {
  if (compareScalar(b, 0n) === 0) fail("Division by zero.", "calc.divide-by-zero");
  if (
    typeof a === "number" ||
    typeof b === "number" ||
    (!exact && typeof a === "bigint" && typeof b === "bigint")
  )
    return finite(toNumber(a) / toNumber(b));
  const [bn, bd] = parts(b as bigint | Rational);
  return mulScalar(a, rational(bd, bn));
}
export function compareScalar(a: Scalar, b: Scalar): number {
  if (typeof a === "number" && typeof b === "number") return Math.sign(a - b);
  const [an, ad] = parts(typeof a === "number" ? exactFloat(a) : a),
    [bn, bd] = parts(typeof b === "number" ? exactFloat(b) : b),
    delta = an * bd - bn * ad;
  return delta < 0n ? -1 : delta > 0n ? 1 : 0;
}
export function powScalar(a: Scalar, b: Scalar): Scalar {
  if (typeof b !== "bigint" || typeof a === "number")
    return finite(Math.pow(toNumber(a), toNumber(b)));
  if (b > 10000n || b < -10000n) fail("Exact exponent exceeds 10000.", "calc.resource-limit");
  const [n, d] = parts(a);
  if (Math.max(bits(n), bits(d)) * Number(b < 0n ? -b : b) > 65536)
    fail("Exact power exceeds 65536 bits.", "calc.resource-limit");
  if (b < 0n) return rational(d ** -b, n ** -b);
  return rational(n ** b, d ** b);
}
export function dimensions(a: Dimensions, b: Dimensions = {}, sign = 1): Dimensions {
  const out: Record<string, number> = { ...a };
  for (const [key, power] of Object.entries(b)) {
    out[key] = (out[key] ?? 0) + sign * power;
    if (Math.abs(out[key]!) > 32) fail("Unit dimension power exceeds 32.", "calc.resource-limit");
    if (!out[key]) delete out[key];
  }
  return out;
}
export function sameDimensions(a: Dimensions, b: Dimensions): boolean {
  return [...new Set([...Object.keys(a), ...Object.keys(b)])].every(
    (key) => (a[key] ?? 0) === (b[key] ?? 0),
  );
}
export function quantity(magnitude: Scalar, dims: Dimensions): Scalar | Quantity {
  if (Object.values(dims).some((power) => Math.abs(power) > 32))
    fail("Unit dimension power exceeds 32.", "calc.resource-limit");
  return Object.keys(dims).length ? { kind: "quantity", magnitude, dimensions: dims } : magnitude;
}
function complexParts(v: Scalar | Complex): Complex {
  return isComplex(v) ? v : { kind: "complex", re: v, im: 0n };
}
export function negate(v: Numeric): Numeric {
  if (isQuantity(v)) return { ...v, magnitude: negScalar(v.magnitude) };
  if (isComplex(v)) return { ...v, re: negScalar(v.re), im: negScalar(v.im) };
  return negScalar(v);
}
export function arithmetic(op: string, a: Numeric, b: Numeric): Numeric {
  if (op === "//") return rational(integer(a, "Numerator"), integer(b, "Denominator"));
  if (isQuantity(a) || isQuantity(b)) {
    if (isComplex(a) || isComplex(b)) return fail("Complex quantity magnitudes are not supported.");
    const am = isQuantity(a) ? a.magnitude : a,
      bm = isQuantity(b) ? b.magnitude : b;
    const ad = isQuantity(a) ? a.dimensions : {},
      bd = isQuantity(b) ? b.dimensions : {};
    if (op === "+" || op === "-") {
      if (!sameDimensions(ad, bd)) fail("Incompatible dimensions.", "calc.incompatible-dimensions");
      return quantity(addScalar(am, op === "-" ? negScalar(bm) : bm), ad);
    }
    if (op === "*") return quantity(mulScalar(am, bm), dimensions(ad, bd));
    if (op === "/") return quantity(divScalar(am, bm), dimensions(ad, bd, -1));
    if (op === "^" && isQuantity(a) && isScalar(b)) {
      const exponent = smallInteger(b, "Quantity exponent");
      if (Math.abs(exponent) > 32) fail("Unit exponent exceeds 32.", "calc.resource-limit");
      return quantity(
        powScalar(am, b),
        Object.fromEntries(
          Object.entries(ad)
            .map(([k, p]) => [k, p * exponent])
            .filter(([, p]) => p !== 0),
        ),
      );
    }
    return fail("Invalid quantity operation.");
  }
  if (isComplex(a) || isComplex(b)) {
    const x = complexParts(a as Scalar | Complex),
      y = complexParts(b as Scalar | Complex);
    if (op === "+" || op === "-")
      return {
        kind: "complex",
        re: addScalar(x.re, op === "-" ? negScalar(y.re) : y.re),
        im: addScalar(x.im, op === "-" ? negScalar(y.im) : y.im),
      };
    if (op === "*")
      return {
        kind: "complex",
        re: addScalar(mulScalar(x.re, y.re), negScalar(mulScalar(x.im, y.im))),
        im: addScalar(mulScalar(x.re, y.im), mulScalar(x.im, y.re)),
      };
    if (op === "/") {
      if ([x.re, x.im, y.re, y.im].some((part) => typeof part === "number")) {
        const scale = Math.max(Math.abs(toNumber(y.re)), Math.abs(toNumber(y.im)));
        if (!scale) fail("Division by zero.", "calc.divide-by-zero");
        const xr = toNumber(x.re) / scale,
          xi = toNumber(x.im) / scale,
          yr = toNumber(y.re) / scale,
          yi = toNumber(y.im) / scale;
        const denominator = yr * yr + yi * yi;
        return {
          kind: "complex",
          re: finite((xr * yr + xi * yi) / denominator),
          im: finite((xi * yr - xr * yi) / denominator),
        };
      }
      const ac = mulScalar(x.re, y.re),
        bd = mulScalar(x.im, y.im),
        ad = mulScalar(x.re, y.im),
        bc = mulScalar(x.im, y.re);
      const denominator = addScalar(mulScalar(y.re, y.re), mulScalar(y.im, y.im));
      return {
        kind: "complex",
        re: divScalar(addScalar(ac, bd), denominator),
        im: divScalar(addScalar(bc, negScalar(ad)), denominator),
      };
    }
    if (op === "^") {
      if (isScalar(b) && typeof b === "bigint") {
        if (b > 10000n || b < -10000n)
          fail("Complex exponent exceeds 10000.", "calc.resource-limit");
        let base: Numeric = x,
          result: Numeric = 1n,
          power = b < 0n ? -b : b;
        while (power) {
          if (power & 1n) result = arithmetic("*", result, base);
          power >>= 1n;
          if (power) base = arithmetic("*", base, base);
        }
        return b < 0n ? arithmetic("/", 1n, result) : result;
      }
      return complexFunction("exp", arithmetic("*", y, complexFunction("ln", x)) as Complex);
    }
    return fail("Invalid complex operation.");
  }
  switch (op) {
    case "+":
      return addScalar(a, b);
    case "-":
      return addScalar(a, negScalar(b));
    case "*":
      return mulScalar(a, b);
    case "/":
      return divScalar(a, b);
    case "^":
      return powScalar(a, b);
    default:
      return fail(`Unknown numeric operator '${op}'.`);
  }
}
export function compareNumeric(a: Numeric, b: Numeric): number {
  if (isComplex(a) || isComplex(b)) return fail("Complex values cannot be ordered.");
  if (isQuantity(a) || isQuantity(b)) {
    if (!isQuantity(a) || !isQuantity(b) || !sameDimensions(a.dimensions, b.dimensions))
      fail("Incompatible dimensions.", "calc.incompatible-dimensions");
    return compareScalar((a as Quantity).magnitude, (b as Quantity).magnitude);
  }
  return compareScalar(a, b);
}
export function equalNumeric(a: Numeric, b: Numeric): boolean {
  if (isComplex(a) || isComplex(b)) {
    if (isQuantity(a) || isQuantity(b)) return false;
    const x = complexParts(a),
      y = complexParts(b);
    return compareScalar(x.re, y.re) === 0 && compareScalar(x.im, y.im) === 0;
  }
  if (isQuantity(a) || isQuantity(b))
    return (
      isQuantity(a) &&
      isQuantity(b) &&
      sameDimensions(a.dimensions, b.dimensions) &&
      compareScalar(a.magnitude, b.magnitude) === 0
    );
  return compareScalar(a, b) === 0;
}
export function complexFunction(name: string, z: Complex): Numeric {
  const x = toNumber(z.re),
    y = toNumber(z.im),
    r = Math.hypot(x, y),
    theta = Math.atan2(y, x);
  const make = (re: number, im: number): Complex => ({
    kind: "complex",
    re: finite(re),
    im: finite(im),
  });
  switch (name) {
    case "abs":
      return r;
    case "conj":
      return { ...z, im: negScalar(z.im) };
    case "re":
      return z.re;
    case "im":
      return z.im;
    case "sqrt":
      return make(Math.sqrt((r + x) / 2), (y < 0 ? -1 : 1) * Math.sqrt((r - x) / 2));
    case "exp":
      return make(Math.exp(x) * Math.cos(y), Math.exp(x) * Math.sin(y));
    case "ln":
      return make(Math.log(r), theta);
    case "sin":
      return make(Math.sin(x) * Math.cosh(y), Math.cos(x) * Math.sinh(y));
    case "cos":
      return make(Math.cos(x) * Math.cosh(y), -Math.sin(x) * Math.sinh(y));
    case "tan":
      return arithmetic("/", complexFunction("sin", z), complexFunction("cos", z));
    default:
      return fail(`'${name}' does not support complex inputs.`);
  }
}
export function precision(value: unknown = 2n): number {
  const n = smallInteger(value, "Precision");
  return n >= 0 && n <= 100 ? n : fail("Precision must be between 0 and 100.");
}
export function roundScalar(value: Scalar, digits = 0): Scalar {
  if (typeof value === "number") {
    const factor = 10 ** digits;
    return finite(Math.round(value * factor) / factor);
  }
  if (digits < 0) {
    const factor = 10n ** BigInt(-digits);
    return mulScalar(roundScalar(divScalar(value, factor, true), 0), factor);
  }
  const [n, d] = parts(value),
    factor = 10n ** BigInt(digits),
    negative = n < 0n;
  const scaled = (negative ? -n : n) * factor,
    result = scaled / d + ((scaled % d) * 2n >= d ? 1n : 0n);
  return rational(negative ? -result : result, factor);
}
export function decimal(value: Scalar, digits = 2): string {
  const exact: bigint | Rational = typeof value === "number" ? exactFloat(value) : value;
  const [n, d] = parts(exact),
    negative = n < 0n,
    factor = 10n ** BigInt(digits);
  const scaled = (negative ? -n : n) * factor,
    rounded = scaled / d + ((scaled % d) * 2n >= d ? 1n : 0n);
  const text = rounded.toString().padStart(digits + 1, "0");
  return (
    (negative && rounded !== 0n ? "-" : "") +
    (digits ? `${text.slice(0, -digits)}.${text.slice(-digits)}` : text)
  );
}
function exactFloat(value: number): bigint | Rational {
  finite(value);
  const view = new DataView(new ArrayBuffer(8));
  view.setFloat64(0, value);
  const word = view.getBigUint64(0),
    exponent = Number((word >> 52n) & 2047n);
  let significand = word & ((1n << 52n) - 1n);
  if (exponent) significand |= 1n << 52n;
  if (word >> 63n) significand = -significand;
  const shift = exponent ? exponent - 1023 - 52 : -1074;
  return (
    shift < 0 ? rational(significand, 1n << BigInt(-shift)) : significand << BigInt(shift)
  ) as bigint | Rational;
}
export function formatScalar(value: Scalar): string {
  if (typeof value === "bigint") return String(value);
  if (isRational(value)) return `${value.numerator}//${value.denominator}`;
  return String(Number.parseFloat(finite(value).toPrecision(12)));
}
export function scalarDisplay(value: Scalar): string {
  return isRational(value) ? formatScalar(toNumber(value)) : formatScalar(value);
}
export function canonicalUnit(dims: Dimensions): string {
  const positive: string[] = [],
    negative: string[] = [];
  for (const key of ["kg", "m", "s", "rad"]) {
    const power = dims[key] ?? 0;
    if (!power) continue;
    (power > 0 ? positive : negative).push(
      key + (Math.abs(power) === 1 ? "" : `^${Math.abs(power)}`),
    );
  }
  if (!positive.length && negative.length)
    return negative
      .map((unit) => (unit.includes("^") ? unit.replace("^", "^-") : `${unit}^-1`))
      .join("*");
  const numerator = positive.join("*") || "1";
  return negative.length
    ? `${numerator}/${negative.length > 1 ? `(${negative.join("*")})` : negative[0]}`
    : numerator;
}
export function formatNumeric(value: Numeric): string {
  if (isQuantity(value)) return scalarDisplay(value.magnitude) + canonicalUnit(value.dimensions);
  if (isComplex(value)) {
    const sign = compareScalar(value.im, 0n),
      re = formatScalar(value.re);
    if (!sign) return re;
    const magnitude = sign < 0 ? negScalar(value.im) : value.im;
    const imaginary = isRational(magnitude)
      ? `(${formatScalar(magnitude)})*i`
      : (compareScalar(magnitude, 1n) === 0 ? "" : formatScalar(magnitude)) + "i";
    return compareScalar(value.re, 0n) === 0
      ? (sign < 0 ? "-" : "") + imaginary
      : `${re} ${sign < 0 ? "-" : "+"} ${imaginary}`;
  }
  return formatScalar(value);
}
