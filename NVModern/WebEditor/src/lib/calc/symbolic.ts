import {
  addScalar,
  arithmetic,
  compareScalar,
  fail,
  formatNumeric,
  gcd,
  isNumeric,
  isScalar,
  mulScalar,
  negScalar,
  numeric,
  parts,
  rational,
  type Numeric,
  type Scalar,
} from "./numeric.ts";

export interface CalcSymbol {
  kind: "symbol";
  name: string;
}
export interface SymbolicExpression {
  kind: "expression";
  operator: string;
  args: SymbolicValue[];
}
export type Symbolic = CalcSymbol | SymbolicExpression;
export type SymbolicValue = Symbolic | Numeric;
export function isSymbolic(value: unknown): value is Symbolic {
  return (
    !!value &&
    typeof value === "object" &&
    "kind" in value &&
    (value.kind === "symbol" || value.kind === "expression")
  );
}
export function symbol(name: string): CalcSymbol {
  return { kind: "symbol", name };
}
export function symbolicValue(value: unknown): SymbolicValue {
  return isSymbolic(value) || isNumeric(value)
    ? value
    : fail("Symbolic arithmetic requires numeric or expression values.");
}
export function expression(operator: string, ...args: SymbolicValue[]): SymbolicValue {
  if (
    ["+", "-", "*", "/", "^", "//"].includes(operator) &&
    args.length === 2 &&
    args.every(isNumeric)
  )
    return arithmetic(operator, args[0] as Numeric, args[1] as Numeric);
  return { kind: "expression", operator, args };
}

interface Term {
  powers: Record<string, number>;
  coefficient: bigint | Exclude<Scalar, number | bigint>;
}
type Polynomial = Map<string, Term>;
const keyOf = (powers: Record<string, number>) =>
  JSON.stringify(
    Object.entries(powers)
      .filter(([, n]) => n)
      .sort(([a], [b]) => a.localeCompare(b)),
  );
function term(coefficient: Term["coefficient"], powers: Record<string, number> = {}): Polynomial {
  return new Map(
    compareScalar(coefficient, 0n) === 0 ? [] : [[keyOf(powers), { powers, coefficient }]],
  );
}
function plus(a: Polynomial, b: Polynomial): Polynomial {
  const result = new Map(a);
  for (const [key, entry] of b) {
    const coefficient = addScalar(
      result.get(key)?.coefficient ?? 0n,
      entry.coefficient,
    ) as Term["coefficient"];
    if (compareScalar(coefficient, 0n) === 0) result.delete(key);
    else result.set(key, { powers: entry.powers, coefficient });
  }
  if (result.size > 512) fail("Symbolic expansion exceeds 512 terms.", "calc.resource-limit");
  return result;
}
function times(a: Polynomial, b: Polynomial): Polynomial {
  if (a.size * b.size > 4096)
    fail("Symbolic product exceeds its term budget.", "calc.resource-limit");
  let result: Polynomial = new Map();
  for (const x of a.values())
    for (const y of b.values()) {
      const powers = { ...x.powers };
      for (const [name, n] of Object.entries(y.powers)) powers[name] = (powers[name] ?? 0) + n;
      result = plus(
        result,
        term(mulScalar(x.coefficient, y.coefficient) as Term["coefficient"], powers),
      );
    }
  return result;
}
function polynomial(value: SymbolicValue): Polynomial | null {
  if (typeof value === "bigint" || (isScalar(value) && typeof value === "object"))
    return term(value);
  if (!isSymbolic(value)) return null;
  if (value.kind === "symbol") return term(1n, { [value.name]: 1 });
  const [left, right] = value.args;
  const a = left === undefined ? null : polynomial(left),
    b = right === undefined ? null : polynomial(right);
  if (value.operator === "^" && a && a.size > 1 && typeof right === "bigint" && right > 12n) {
    fail("Polynomial expansion power exceeds 12.", "calc.resource-limit");
  }
  if (value.operator === "+" && a && b) return plus(a, b);
  if (value.operator === "-" && a && b) return plus(a, times(term(-1n), b));
  if (value.operator === "*" && a && b) return times(a, b);
  if (
    value.operator === "/" &&
    a &&
    isScalar(right) &&
    typeof right !== "number" &&
    compareScalar(right, 0n) !== 0
  ) {
    const [n, d] = parts(right);
    return times(a, term(rational(d, n) as Term["coefficient"]));
  }
  if (value.operator === "^" && a && typeof right === "bigint" && right >= 0n && right <= 12n) {
    let result = term(1n);
    for (let i = 0n; i < right; i++) result = times(result, a);
    return result;
  }
  return null;
}
function fromPolynomial(poly: Polynomial): SymbolicValue {
  const variables = [
    ...new Set([...poly.values()].flatMap((entry) => Object.keys(entry.powers))),
  ].sort();
  const terms = [...poly.values()].sort((a, b) => {
    const degree = (t: Term) => Object.values(t.powers).reduce((sum, n) => sum + n, 0);
    return (
      degree(b) - degree(a) ||
      variables
        .map((name) => (b.powers[name] ?? 0) - (a.powers[name] ?? 0))
        .find((difference) => difference !== 0) ||
      0
    );
  });
  let result: SymbolicValue | undefined;
  for (const entry of terms) {
    const negative = compareScalar(entry.coefficient, 0n) < 0;
    const coefficient = negative ? negScalar(entry.coefficient) : entry.coefficient;
    let body: SymbolicValue = coefficient;
    for (const [name, power] of Object.entries(entry.powers).sort(([a], [b]) =>
      a.localeCompare(b),
    )) {
      if (!power) continue;
      const factor = power === 1 ? symbol(name) : expression("^", symbol(name), BigInt(power));
      body = body === 1n ? factor : expression("*", body, factor);
    }
    result =
      result === undefined
        ? negative
          ? expression("*", -1n, body)
          : body
        : expression(negative ? "-" : "+", result, body);
  }
  return result ?? 0n;
}
export function simplify(value: SymbolicValue): SymbolicValue {
  const poly = polynomial(value);
  if (poly) return fromPolynomial(poly);
  if (!isSymbolic(value) || value.kind === "symbol") return value;
  return expression(value.operator, ...value.args.map(simplify));
}
export function expand(value: SymbolicValue): SymbolicValue {
  return simplify(value);
}

export function factor(value: SymbolicValue): SymbolicValue {
  const poly = polynomial(value);
  if (!poly || poly.size < 2) return simplify(value);
  const entries = [...poly.values()];
  const common: Record<string, number> = { ...entries[0]!.powers };
  for (const entry of entries)
    for (const name of Object.keys(common)) {
      common[name] = Math.min(common[name]!, entry.powers[name] ?? 0);
      if (!common[name]) delete common[name];
    }
  let divisor = entries.every((t) => typeof t.coefficient === "bigint")
    ? entries.reduce((g, t) => gcd(g, t.coefficient as bigint), 0n)
    : 1n;
  if (compareScalar(entries[0]!.coefficient, 0n) < 0) divisor = -divisor;
  if (divisor !== 1n || Object.keys(common).length) {
    let remainder: Polynomial = new Map();
    for (const entry of entries) {
      const powers = { ...entry.powers };
      for (const [name, n] of Object.entries(common)) {
        powers[name] = (powers[name] ?? 0) - n;
        if (!powers[name]) delete powers[name];
      }
      const [n, d] = parts(entry.coefficient);
      remainder = plus(remainder, term(rational(n, d * divisor) as Term["coefficient"], powers));
    }
    return expression(
      "*",
      fromPolynomial(term(divisor, common)),
      factor(fromPolynomial(remainder)),
    );
  }
  const names = [...new Set(entries.flatMap((t) => Object.keys(t.powers)))];
  if (names.length === 1) {
    const name = names[0]!,
      coefficients = [0n, 0n, 0n];
    if (entries.every((t) => (t.powers[name] ?? 0) <= 2 && typeof t.coefficient === "bigint")) {
      for (const t of entries) coefficients[t.powers[name] ?? 0] = t.coefficient as bigint;
      const [c, b, a] = coefficients;
      if (a === 1n) {
        for (let root = -100n; root <= 100n; root++)
          if (root * root + b! * root + c! === 0n) {
            const other = -b! - root;
            const first = expression("-", symbol(name), root),
              second = expression("-", symbol(name), other);
            return root === other
              ? expression("^", simplify(first), 2n)
              : expression("*", simplify(first), simplify(second));
          }
      }
    }
  }
  return fromPolynomial(poly);
}

export function derivative(value: SymbolicValue, variable: CalcSymbol): SymbolicValue {
  function diff(v: SymbolicValue): SymbolicValue {
    if (!isSymbolic(v)) return 0n;
    if (v.kind === "symbol") return v.name === variable.name ? 1n : 0n;
    const [a, b] = v.args,
      da = a === undefined ? 0n : diff(a),
      db = b === undefined ? 0n : diff(b);
    const op = v.operator;
    if (op === "+" || op === "-") return expression(op, da, db);
    if (op === "*") return expression("+", expression("*", da, b!), expression("*", a!, db));
    if (op === "/")
      return expression(
        "/",
        expression("-", expression("*", da, b!), expression("*", a!, db)),
        expression("^", b!, 2n),
      );
    if (op === "^" && typeof b === "bigint")
      return expression("*", expression("*", b, expression("^", a!, b - 1n)), da);
    const chain = (outer: SymbolicValue) => expression("*", outer, da);
    if (op === "sin") return chain(expression("cos", a!));
    if (op === "cos") return chain(expression("*", -1n, expression("sin", a!)));
    if (op === "exp") return chain(expression("exp", a!));
    if (op === "ln") return expression("/", da, a!);
    return fail(`Derivative of '${op}' is not supported.`, "calc.unsupported-symbolic-operation");
  }
  return simplify(diff(value));
}
export function substitute(
  value: SymbolicValue,
  variable: CalcSymbol,
  replacement: SymbolicValue,
  call: (name: string, args: SymbolicValue[]) => SymbolicValue,
): SymbolicValue {
  if (!isSymbolic(value)) return value;
  if (value.kind === "symbol") return value.name === variable.name ? replacement : value;
  const args = value.args.map((v) => substitute(v, variable, replacement, call));
  if (["+", "-", "*", "/", "^", "//"].includes(value.operator))
    return expression(value.operator, ...args);
  return args.some(isSymbolic) ? expression(value.operator, ...args) : call(value.operator, args);
}

export function formatSymbolic(value: SymbolicValue, parent = 0): string {
  if (isNumeric(value)) {
    const text = formatNumeric(value);
    const precedence = isScalar(value)
      ? typeof value === "object"
        ? 2
        : text.startsWith("-")
          ? 2
          : 4
      : 1;
    return parent > precedence ? `(${text})` : text;
  }
  if (value.kind === "symbol") return value.name;
  const [a, b] = value.args,
    precedence =
      value.operator === "+" || value.operator === "-"
        ? 1
        : value.operator === "*" || value.operator === "/"
          ? 2
          : value.operator === "^"
            ? 3
            : 4;
  let text: string;
  if (
    ["+", "-", "*", "/", "^", "//"].includes(value.operator) &&
    a !== undefined &&
    b !== undefined
  ) {
    const separator =
      value.operator === "+" || value.operator === "-" ? ` ${value.operator} ` : value.operator;
    text =
      formatSymbolic(a, value.operator === "^" ? precedence + 1 : precedence) +
      separator +
      formatSymbolic(
        b,
        value.operator === "-" || value.operator === "/" ? precedence + 1 : precedence,
      );
  } else text = `${value.operator}(${value.args.map((arg) => formatSymbolic(arg)).join(", ")})`;
  return precedence < parent ? `(${text})` : text;
}
