import type {
  CalcBlockParseResult,
  CalcExpression,
  CalcExpressionStatement,
  CalcFunctionDefinitionStatement,
  CalcPresenter,
  CalcReferenceExpression,
  CalcStatement,
  CalcValueDefinitionStatement,
} from "./parser.ts";
import { calcEntry, type CalcCatalogEntry } from "./catalog.ts";
import {
  CalcError,
  addScalar,
  arithmetic,
  canonicalUnit,
  compareNumeric,
  compareScalar,
  complexFunction,
  decimal,
  divScalar,
  equalNumeric,
  fail,
  finite,
  formatNumeric,
  integer,
  isComplex,
  isNumeric,
  isQuantity,
  isRational,
  isScalar,
  mulScalar,
  negate,
  numeric,
  parts,
  parseNumeric,
  precision,
  quantity,
  rational,
  roundScalar,
  scalar,
  scalarDisplay,
  scales,
  smallInteger,
  toNumber,
  gcd,
  type Numeric,
  type Scalar,
} from "./numeric.ts";
import { convertMagnitude, requireCalcUnit, type CalcUnit } from "./units.ts";
import {
  derivative,
  expand,
  expression,
  factor,
  formatSymbolic,
  isSymbolic,
  simplify,
  substitute,
  symbol,
  symbolicValue,
  type CalcSymbol,
  type Symbolic,
  type SymbolicValue,
} from "./symbolic.ts";

import {
  createCalcPlot,
  isCalcPlot,
  plotKind,
  plotSummary,
  sampleCalcPlot,
  type CalcPlot,
  type CalcPresentation,
} from "./plot.ts";

export type CalcRuntimeValue =
  | Numeric
  | CalcPlot
  | Symbolic
  | RuntimeCallable
  | boolean
  | string
  | null
  | CalcRuntimeValue[];
export interface CalcRuntimeError {
  code: string;
  message: string;
}
export interface CalcEvaluationSuccess {
  ok: true;
  value: CalcRuntimeValue;
  presentation?: CalcPresentation;
  presentationError?: CalcRuntimeError;
}
export interface CalcEvaluationFailure {
  ok: false;
  error: CalcRuntimeError;
}
export type CalcEvaluationResult = CalcEvaluationSuccess | CalcEvaluationFailure;
export interface CalcBlockQueryResult {
  statement: CalcExpressionStatement;
  result: CalcEvaluationResult;
}
export interface CalcRuntimeScope {
  readonly valueNames: readonly string[];
  readonly functionNames: readonly string[];
}
export interface CalcBlockEvaluation {
  scope: CalcRuntimeScope;
  queryResults: CalcBlockQueryResult[];
  statementResults: {
    statement: CalcValueDefinitionStatement | CalcExpressionStatement;
    result: CalcEvaluationResult;
  }[];
}
interface RuntimeNamespace {
  kind: "namespace";
  name: string;
  members: Record<string, RuntimeResolved>;
}
interface RuntimeCallable {
  kind: "callable";
  name: string;
  arity?: number;
  documentation?: CalcCatalogEntry;
  invoke(args: RuntimeResolved[], state: RuntimeState): RuntimeResolved;
}
type RuntimeResolved = CalcRuntimeValue | RuntimeNamespace;
interface RuntimeState {
  rootMembers: Record<string, RuntimeResolved>;
  aliases: Map<string, RuntimeCallable[]>;
  valueDefs: Map<string, CalcValueDefinitionStatement>;
  functionDefs: Map<string, CalcFunctionDefinitionStatement>;
  symbols: Map<string, CalcSymbol>;
  valueCache: Map<string, RuntimeResolved>;
  activeValues: Set<string>;
  activeFunctions: Set<string>;
  error?: CalcRuntimeError;
  steps: number;
  depth: number;
}
const errorValue = (error: unknown): CalcRuntimeError => ({
  code: error instanceof CalcError ? error.code : "calc.runtime-error",
  message: error instanceof Error ? error.message : String(error),
});
const isCallable = (v: unknown): v is RuntimeCallable =>
  !!v && typeof v === "object" && "kind" in v && v.kind === "callable";
const isNamespace = (v: unknown): v is RuntimeNamespace =>
  !!v && typeof v === "object" && "kind" in v && v.kind === "namespace";
function value(v: RuntimeResolved): CalcRuntimeValue {
  return isNamespace(v) ? fail("A namespace is not a value.") : v;
}
function text(v: RuntimeResolved, label = "Value"): string {
  return typeof v === "string" ? v : fail(`${label} must be a string.`);
}
function list(v: RuntimeResolved): CalcRuntimeValue[] {
  return Array.isArray(v) ? v : fail("Value must be a list.");
}
function callableValue(v: RuntimeResolved): RuntimeCallable {
  return isCallable(v) ? v : fail("Value must be callable.");
}
function truth(v: RuntimeResolved): boolean {
  if (isNumeric(v))
    return isComplex(v)
      ? !equalNumeric(v, 0n)
      : isQuantity(v)
        ? compareScalar(v.magnitude, 0n) !== 0
        : compareScalar(v, 0n) !== 0;
  if (Array.isArray(v)) return v.length !== 0;
  return Boolean(v);
}
function tick(state: RuntimeState): void {
  if (++state.steps > 100000)
    fail("Calculation exceeds 100000 evaluation steps.", "calc.resource-limit");
}
function call(fn: RuntimeResolved, args: RuntimeResolved[], state: RuntimeState): RuntimeResolved {
  tick(state);
  return callableValue(fn).invoke(args, state);
}
function builtin(
  name: string,
  min: number,
  max: number,
  fn: (args: RuntimeResolved[], state: RuntimeState) => RuntimeResolved,
): RuntimeCallable {
  const documentation = name.includes(".") ? calcEntry(name) : undefined;
  if (documentation?.arity && (documentation.arity[0] !== min || documentation.arity[1] !== max))
    throw new Error(`Catalog arity for '${name}' disagrees with its implementation.`);
  return {
    kind: "callable",
    name,
    ...(documentation ? { documentation } : {}),
    ...(min === max ? { arity: min } : {}),
    invoke(args, state) {
      if (args.length < min || args.length > max)
        fail(
          `Function '${name}' expects ${min === max ? min : `${min}–${max}`} argument(s), got ${args.length}.`,
          "calc.arity-mismatch",
        );
      return fn(args, state);
    },
  };
}
function resolveIdentifier(
  name: string,
  state: RuntimeState,
  locals: Map<string, RuntimeResolved>,
): RuntimeResolved {
  if (locals.has(name)) return locals.get(name)!;
  if (name === "i") return { kind: "complex", re: 0n, im: 1n };
  if (state.valueDefs.has(name)) return resolveDefinition(name, state);
  if (state.functionDefs.has(name)) return userFunction(name, state);
  if (state.symbols.has(name)) return state.symbols.get(name)!;
  if (Object.hasOwn(state.rootMembers, name)) return state.rootMembers[name]!;
  const aliases = state.aliases.get(name);
  if (aliases?.length === 1) return aliases[0]!;
  if (aliases?.length)
    fail(`Ambiguous operation '${name}'. Use a qualified name.`, "calc.ambiguous-operation");
  return fail(`Unknown identifier '${name}'.`, "calc.unknown-identifier");
}
function resolveReference(
  ref: CalcReferenceExpression,
  state: RuntimeState,
  locals: Map<string, RuntimeResolved>,
): RuntimeResolved {
  if (ref.kind === "Identifier") return resolveIdentifier(ref.name, state, locals);
  const object = resolveReference(ref.object, state, locals);
  if (!isNamespace(object))
    fail(
      `Only namespaces support member access; '${ref.property}' is not available here.`,
      "calc.invalid-member-access",
    );
  if (!Object.hasOwn(object.members, ref.property))
    fail(`Namespace '${object.name}' has no member '${ref.property}'.`, "calc.unknown-member");
  return object.members[ref.property]!;
}
function resolveDefinition(name: string, state: RuntimeState): RuntimeResolved {
  if (state.valueCache.has(name)) return state.valueCache.get(name)!;
  if (state.activeValues.has(name))
    fail(`Circular value definition detected for '${name}'.`, "calc.circular-value");
  if (state.activeValues.size >= 128)
    fail("Definition nesting exceeds 128.", "calc.resource-limit");
  state.activeValues.add(name);
  try {
    const result = evaluateResolved(state.valueDefs.get(name)!.value, state, new Map());
    state.valueCache.set(name, result);
    return result;
  } finally {
    state.activeValues.delete(name);
  }
}
function userFunction(name: string, state: RuntimeState): RuntimeCallable {
  const definition = state.functionDefs.get(name)!;
  return builtin(name, definition.params.length, definition.params.length, (args, runtime) => {
    if (runtime.activeFunctions.has(name))
      fail(`Recursive call detected for '${name}'.`, "calc.circular-function");
    if (runtime.activeFunctions.size >= 128)
      fail("Function nesting exceeds 128.", "calc.resource-limit");
    runtime.activeFunctions.add(name);
    try {
      return evaluateResolved(
        definition.body,
        runtime,
        new Map(definition.params.map((p, i) => [p.name, args[i]!])),
      );
    } finally {
      runtime.activeFunctions.delete(name);
    }
  });
}
function equal(a: RuntimeResolved, b: RuntimeResolved): boolean {
  if (isNumeric(a) && isNumeric(b)) return equalNumeric(a, b);
  if (isSymbolic(a) && isSymbolic(b)) return formatSymbolic(a) === formatSymbolic(b);
  if (Array.isArray(a) && Array.isArray(b))
    return a.length === b.length && a.every((item, i) => equal(item, b[i]!));
  return a === b;
}
function binary(op: string, a: RuntimeResolved, b: RuntimeResolved): RuntimeResolved {
  if (op === "==" || op === "!=") return op === "==" ? equal(a, b) : !equal(a, b);
  if (["<", "<=", ">", ">="].includes(op)) {
    const comparison = compareNumeric(numeric(a), numeric(b));
    return op === "<"
      ? comparison < 0
      : op === "<="
        ? comparison <= 0
        : op === ">"
          ? comparison > 0
          : comparison >= 0;
  }
  if (op === "+" && (typeof a === "string" || typeof b === "string"))
    return formatCalcRuntimeValue(value(a)) + formatCalcRuntimeValue(value(b));
  if (isSymbolic(a) || isSymbolic(b)) return expression(op, symbolicValue(a), symbolicValue(b));
  return arithmetic(op, numeric(a), numeric(b));
}
function evaluateResolved(
  ast: CalcExpression,
  state: RuntimeState,
  locals: Map<string, RuntimeResolved>,
): RuntimeResolved {
  tick(state);
  if (state.depth >= 128) fail("Evaluation nesting exceeds 128.", "calc.resource-limit");
  state.depth++;
  try {
    return evaluateNode(ast, state, locals);
  } finally {
    state.depth--;
  }
}
function evaluateNode(
  ast: CalcExpression,
  state: RuntimeState,
  locals: Map<string, RuntimeResolved>,
): RuntimeResolved {
  switch (ast.kind) {
    case "NumberLiteral":
      return parseNumeric(ast.raw);
    case "ImaginaryLiteral":
      return { kind: "complex", re: 0n, im: parseNumeric(ast.raw) };
    case "QuantityLiteral":
      return quantity(mulScalar(parseNumeric(ast.raw), ast.unit.factor), ast.unit.dimensions);
    case "BooleanLiteral":
    case "StringLiteral":
    case "NullLiteral":
      return ast.value;
    case "Identifier":
      return resolveIdentifier(ast.name, state, locals);
    case "MemberExpression":
      return resolveReference(ast, state, locals);
    case "ListExpression":
      return ast.elements.map((item) => value(evaluateResolved(item, state, locals)));
    case "ListComprehension": {
      const input = list(evaluateResolved(ast.iterable, state, locals));
      const iteration = new Map(locals);
      const output: CalcRuntimeValue[] = [];
      for (const item of input) {
        tick(state);
        iteration.set(ast.binding.name, item);
        if (ast.condition && !truth(evaluateResolved(ast.condition, state, iteration))) continue;
        if (output.length >= 10000)
          fail("Comprehension exceeds 10000 values.", "calc.resource-limit");
        output.push(value(evaluateResolved(ast.element, state, iteration)));
      }
      return output;
    }
    case "PresentationExpression":
      return evaluateResolved(ast.input, state, locals);
    case "UnaryExpression": {
      const operand = evaluateResolved(ast.operand, state, locals);
      return isSymbolic(operand) ? expression("*", -1n, operand) : negate(numeric(operand));
    }
    case "BinaryExpression":
      return binary(
        ast.operator,
        evaluateResolved(ast.left, state, locals),
        evaluateResolved(ast.right, state, locals),
      );
    case "CallExpression":
      return call(
        evaluateResolved(ast.callee, state, locals),
        ast.args.map((arg) => evaluateResolved(arg, state, locals)),
        state,
      );
    case "PipeExpression":
      return call(
        resolveReference(ast.stage.callee, state, locals),
        [
          evaluateResolved(ast.input, state, locals),
          ...ast.stage.args.map((arg) => evaluateResolved(arg, state, locals)),
        ],
        state,
      );
  }
}
function integerSqrt(n: bigint): bigint {
  if (n < 0n) fail("Square root requires a nonnegative real input.", "calc.domain-error");
  if (n < 2n) return n;
  let x = n,
    y = (x + 1n) / 2n;
  while (y < x) {
    x = y;
    y = (x + n / x) / 2n;
  }
  return x;
}
function unaryMath(name: string, input: RuntimeResolved): RuntimeResolved {
  if (isSymbolic(input)) return expression(name, input);
  const n = numeric(input);
  if (isComplex(n)) return complexFunction(name, n);
  if (name === "re" || name === "conj") return n;
  if (name === "im") return 0n;
  if (isQuantity(n)) {
    if (name === "abs")
      return quantity(
        compareScalar(n.magnitude, 0n) < 0 ? mulScalar(n.magnitude, -1n) : n.magnitude,
        n.dimensions,
      );
    if (name === "sqrt") {
      if (Object.values(n.dimensions).some((power) => power % 2 !== 0))
        fail("Square root requires even unit powers.", "calc.incompatible-dimensions");
      return quantity(
        scalar(unaryMath("sqrt", n.magnitude)),
        Object.fromEntries(Object.entries(n.dimensions).map(([key, power]) => [key, power / 2])),
      );
    }
    if (["sin", "cos", "tan"].includes(name) && canonicalUnit(n.dimensions) === "rad")
      return unaryMath(name, n.magnitude);
    if (name === "approx") return quantity(toNumber(n.magnitude), n.dimensions);
    return fail(`'${name}' requires a dimensionless input.`, "calc.incompatible-dimensions");
  }
  if (name === "approx") return toNumber(n);
  if (name === "abs") return compareScalar(n, 0n) < 0 ? negate(n) : n;
  if (name === "sign") return BigInt(compareScalar(n, 0n));
  if (name === "floor" || name === "ceil") {
    if (typeof n === "number") return finite(name === "floor" ? Math.floor(n) : Math.ceil(n));
    const [a, b] = parts(n),
      q = a / b,
      remainder = a % b;
    return (
      q + (name === "floor" && remainder < 0n ? -1n : name === "ceil" && remainder > 0n ? 1n : 0n)
    );
  }
  if (name === "sqrt" && typeof n !== "number") {
    const [a, b] = parts(n),
      an = integerSqrt(a),
      bn = integerSqrt(b);
    if (an * an === a && bn * bn === b) return rational(an, bn);
  }
  const functions: Record<string, (x: number) => number> = {
    sqrt: Math.sqrt,
    exp: Math.exp,
    ln: Math.log,
    log10: Math.log10,
    sin: Math.sin,
    cos: Math.cos,
    tan: Math.tan,
    asin: Math.asin,
    acos: Math.acos,
    atan: Math.atan,
  };
  return finite(functions[name]!(toNumber(n)));
}
function numericItems(args: RuntimeResolved[]): Numeric[] {
  return (args.length === 1 && Array.isArray(args[0]) ? args[0] : args).map((item) =>
    numeric(item),
  );
}
function sum(items: Numeric[]): Numeric {
  return items.length ? items.slice(1).reduce((a, b) => arithmetic("+", a, b), items[0]!) : 0n;
}
function orderedItems(items: Numeric[]): Numeric[] {
  if (items.some(isComplex)) fail("Complex values cannot be ordered.");
  return items;
}
function nonempty(items: Numeric[]): Numeric[] {
  return items.length ? items : fail("Statistic requires at least one value.", "calc.domain-error");
}
function mean(items: Numeric[]): Numeric {
  nonempty(items);
  return arithmetic("/", sum(items), BigInt(items.length));
}
function compareValues(a: RuntimeResolved, b: RuntimeResolved): number {
  return typeof a === "string" && typeof b === "string"
    ? a < b
      ? -1
      : a > b
        ? 1
        : 0
    : compareNumeric(numeric(a), numeric(b));
}
function asSymbol(v: RuntimeResolved): CalcSymbol {
  return isSymbolic(v) && v.kind === "symbol" ? v : fail("Argument must be a declared symbol.");
}
function invokeCallback(
  fn: RuntimeCallable,
  args: RuntimeResolved[],
  state: RuntimeState,
): RuntimeResolved {
  return call(fn, fn.arity === undefined ? args : args.slice(0, fn.arity), state);
}
function formatUnit(value: RuntimeResolved, unit: CalcUnit, digits?: RuntimeResolved): string {
  if (!isQuantity(value))
    fail("Unit presentation requires a quantity.", "calc.incompatible-dimensions");
  const magnitude = convertMagnitude(value.magnitude, value.dimensions, unit);
  return (
    (digits === undefined ? scalarDisplay(magnitude) : decimal(magnitude, precision(digits))) +
    unit.symbol
  );
}
function formatScale(value: RuntimeResolved, name: string, digits?: RuntimeResolved): string {
  const magnitude = divScalar(scalar(value), scales[name]!, true);
  return (
    (digits === undefined ? scalarDisplay(magnitude) : decimal(magnitude, precision(digits))) + name
  );
}
function roots(state: RuntimeState): Record<string, RuntimeResolved> {
  const math: Record<string, RuntimeResolved> = { pi: Math.PI, e: Math.E };
  const stats: Record<string, RuntimeResolved> = {},
    lists: Record<string, RuntimeResolved> = {},
    strings: Record<string, RuntimeResolved> = {},
    core: Record<string, RuntimeResolved> = {},
    algebra: Record<string, RuntimeResolved> = {},
    present: Record<string, RuntimeResolved> = {};
  for (const name of [
    "abs",
    "sign",
    "sqrt",
    "exp",
    "ln",
    "log10",
    "sin",
    "cos",
    "tan",
    "asin",
    "acos",
    "atan",
    "floor",
    "ceil",
    "re",
    "im",
    "conj",
    "approx",
  ])
    math[name] = builtin(`math.${name}`, 1, 1, ([v]) => unaryMath(name, v!));
  math.round = builtin("math.round", 1, 2, ([v, digits]) => {
    const d = smallInteger(digits ?? 0n, "Rounding precision");
    if (d < -100 || d > 100) fail("Rounding precision must be between -100 and 100.");
    if (isQuantity(v)) return quantity(roundScalar(v.magnitude, d), v.dimensions);
    return roundScalar(scalar(v), d);
  });
  math.complex = builtin("math.complex", 1, 2, ([re, im]) => ({
    kind: "complex",
    re: scalar(re),
    im: im === undefined ? 0n : scalar(im),
  }));
  math.fraction = builtin("math.fraction", 2, 2, ([n, d]) =>
    rational(integer(n, "Numerator"), integer(d, "Denominator")),
  );
  math.log = builtin("math.log", 1, 2, ([v, base]) => {
    if (isSymbolic(v))
      return base === undefined
        ? expression("ln", v)
        : expression("/", expression("ln", v), expression("ln", symbolicValue(base)));
    const x = toNumber(scalar(v)),
      b = base === undefined ? Math.E : toNumber(scalar(base));
    if (x <= 0 || b <= 0 || b === 1)
      fail(
        "Logarithm requires a positive input and a positive base other than one.",
        "calc.domain-error",
      );
    return finite(Math.log(x) / Math.log(b));
  });
  math.gcd = builtin("math.gcd", 2, 10000, (args) => args.map((v) => integer(v)).reduce(gcd));
  math.lcm = builtin("math.lcm", 2, 10000, (args) =>
    args
      .map((v) => integer(v))
      .reduce((a, b) => {
        if (!a || !b) return 0n;
        const result = (a / gcd(a, b)) * b;
        return result < 0n ? -result : result;
      }),
  );
  math.factorial = builtin("math.factorial", 1, 1, ([v]) => {
    const n = integer(v);
    if (n < 0n || n > 1000n)
      fail("Factorial input must be between 0 and 1000.", "calc.domain-error");
    let result = 1n;
    for (let i = 2n; i <= n; i++) result *= i;
    return result;
  });
  const minimum = builtin("math.min", 1, 10000, (args) =>
    nonempty(orderedItems(numericItems(args))).reduce((a, b) =>
      compareNumeric(a, b) <= 0 ? a : b,
    ),
  );
  const maximum = builtin("math.max", 1, 10000, (args) =>
    nonempty(orderedItems(numericItems(args))).reduce((a, b) =>
      compareNumeric(a, b) >= 0 ? a : b,
    ),
  );
  math.min = stats.min = minimum;
  math.max = stats.max = maximum;
  math.clamp = builtin("math.clamp", 3, 3, ([v, low, high]) => {
    const n = numeric(v),
      a = numeric(low),
      b = numeric(high);
    if (compareNumeric(a, b) > 0) fail("Clamp minimum exceeds maximum.", "calc.domain-error");
    return compareNumeric(n, a) < 0 ? a : compareNumeric(n, b) > 0 ? b : n;
  });
  const sumFn = builtin("stats.sum", 1, 10000, (args) => sum(numericItems(args)));
  stats.sum = lists.sum = sumFn;
  stats.count = builtin("stats.count", 1, 10000, (args) => BigInt(numericItems(args).length));
  stats.mean = builtin("stats.mean", 1, 10000, (args) => mean(numericItems(args)));
  stats.median = builtin("stats.median", 1, 10000, (args) => {
    const items = nonempty(orderedItems(numericItems(args)))
        .slice()
        .sort(compareNumeric),
      middle = Math.floor(items.length / 2);
    return items.length % 2
      ? items[middle]!
      : arithmetic("/", arithmetic("+", items[middle - 1]!, items[middle]!), 2n);
  });
  function variance(args: RuntimeResolved[]): Numeric {
    const items = nonempty(orderedItems(numericItems([args[0]!]))),
      mode = args[1] === undefined ? "sample" : text(args[1]);
    if (mode !== "sample" && mode !== "population")
      fail("Variance normalization must be 'sample' or 'population'.");
    const denominator = items.length - (mode === "sample" ? 1 : 0);
    if (!denominator) fail("Sample variance requires at least two values.", "calc.domain-error");
    const average = mean(items),
      squared = items.map((v) => arithmetic("^", arithmetic("-", v, average), 2n));
    return arithmetic("/", sum(squared), BigInt(denominator));
  }
  stats.variance = builtin("stats.variance", 1, 2, variance);
  stats.std = builtin("stats.std", 1, 2, (args) => unaryMath("sqrt", variance(args)));
  stats.stddev = stats.std;
  stats.quantile = builtin("stats.quantile", 2, 2, ([values, probability]) => {
    const items = nonempty(orderedItems(numericItems([values!])))
        .slice()
        .sort(compareNumeric),
      p = toNumber(scalar(probability));
    if (p < 0 || p > 1)
      fail("Quantile probability must be between zero and one.", "calc.domain-error");
    const index = (items.length - 1) * p,
      low = Math.floor(index),
      weight = index - low;
    return weight === 0
      ? items[low]!
      : arithmetic(
          "+",
          items[low]!,
          arithmetic("*", arithmetic("-", items[low + 1]!, items[low]!), weight),
        );
  });
  lists.len = builtin("list.len", 1, 1, ([v]) => BigInt(list(v!).length));
  lists.first = builtin("list.first", 1, 1, ([v]) => list(v!)[0] ?? null);
  lists.last = builtin("list.last", 1, 1, ([v]) => list(v!).at(-1) ?? null);
  lists.reverse = builtin("list.reverse", 1, 1, ([v]) => list(v!).slice().reverse());
  lists.join = builtin("list.join", 1, 2, ([v, separator]) =>
    list(v!)
      .map(formatCalcRuntimeValue)
      .join(separator === undefined ? ", " : text(separator)),
  );
  lists.map = builtin("list.map", 2, 2, ([v, fn], runtime) => {
    const callback = callableValue(fn!);
    return list(v!).map((item, i) => value(invokeCallback(callback, [item, BigInt(i)], runtime)));
  });
  lists.filter = builtin("list.filter", 2, 2, ([v, fn], runtime) => {
    const callback = callableValue(fn!);
    return list(v!).filter((item, i) =>
      truth(invokeCallback(callback, [item, BigInt(i)], runtime)),
    );
  });
  lists.range = builtin("list.range", 1, 3, ([start, stop, step]) => {
    let a = scalar(stop === undefined ? 0n : start),
      b = scalar(stop === undefined ? start : stop),
      increment = scalar(step ?? 1n);
    const direction = compareScalar(increment, 0n);
    if (!direction) fail("Range step cannot be zero.", "calc.domain-error");
    const result: CalcRuntimeValue[] = [];
    while (compareScalar(a, b) * direction < 0) {
      if (result.length >= 10000) fail("Range exceeds 10000 values.", "calc.resource-limit");
      result.push(a);
      const next = addScalar(a, increment);
      if (compareScalar(next, a) === 0)
        fail("Range step is too small to advance.", "calc.domain-error");
      a = next;
    }
    return result;
  });
  lists.slice = builtin("list.slice", 2, 3, ([v, from, to]) =>
    list(v!).slice(smallInteger(from), to === undefined ? undefined : smallInteger(to)),
  );
  lists.sort = builtin("list.sort", 1, 2, ([v, comparator], runtime) => {
    const items = list(v!).slice();
    if (comparator === undefined && items.some(isComplex))
      fail("Complex values cannot be ordered.");
    return items.sort(
      comparator === undefined
        ? compareValues
        : (a, b) => toNumber(scalar(call(comparator, [a, b], runtime))),
    );
  });
  lists.reduce = builtin("list.reduce", 3, 3, ([v, fn, initial], runtime) => {
    const callback = callableValue(fn!);
    return list(v!).reduce<RuntimeResolved>(
      (accumulator, item, index) =>
        invokeCallback(callback, [accumulator, item, BigInt(index)], runtime),
      initial!,
    );
  });
  strings.len = builtin("str.len", 1, 1, ([v]) => BigInt(text(v!).length));
  strings.trim = builtin("str.trim", 1, 1, ([v]) => text(v!).trim());
  strings.lower = builtin("str.lower", 1, 1, ([v]) => text(v!).toLowerCase());
  strings.upper = builtin("str.upper", 1, 1, ([v]) => text(v!).toUpperCase());
  strings.split = builtin("str.split", 1, 2, ([v, separator]) =>
    text(v!).split(separator === undefined ? "" : text(separator)),
  );
  strings.join = builtin("str.join", 1, 2, ([v, separator]) =>
    list(v!)
      .map(formatCalcRuntimeValue)
      .join(separator === undefined ? "" : text(separator)),
  );
  strings.includes = builtin("str.includes", 2, 2, ([v, needle]) =>
    text(v!).includes(text(needle!)),
  );
  strings.replace = builtin("str.replace", 3, 3, ([v, from, to]) =>
    text(v!).replaceAll(text(from!), text(to!)),
  );
  core.if = builtin("core.if", 2, 3, ([condition, yes, no]) =>
    truth(condition!) ? yes! : (no ?? null),
  );
  core.coalesce = builtin(
    "core.coalesce",
    1,
    10000,
    (args) => args.find((v) => v !== null && v !== "") ?? null,
  );
  core.type = core.typeof = builtin("core.type", 1, 1, ([v]) => {
    if (v === null) return "null";
    if (Array.isArray(v)) return "list";
    if (typeof v === "bigint") return "integer";
    if (typeof v === "number") return "real";
    if (isSymbolic(v)) return "expression";
    if (isRational(v)) return "rational";
    if (isQuantity(v)) return "quantity";
    if (isComplex(v)) return "complex";
    if (isCallable(v)) return "function";
    if (isCalcPlot(v)) return "plot";
    return typeof v;
  });
  algebra.simplify = builtin("algebra.simplify", 1, 1, ([v]) => simplify(symbolicValue(v)));
  algebra.expand = builtin("algebra.expand", 1, 1, ([v]) => expand(symbolicValue(v)));
  algebra.factor = builtin("algebra.factor", 1, 1, ([v]) => factor(symbolicValue(v)));
  algebra.diff = builtin("algebra.diff", 2, 2, ([v, variable]) =>
    derivative(symbolicValue(v), asSymbol(variable!)),
  );
  algebra.subs = builtin("algebra.subs", 3, 3, ([v, variable, replacement], runtime) =>
    substitute(symbolicValue(v), asSymbol(variable!), symbolicValue(replacement), (name, args) =>
      symbolicValue(call(resolveIdentifier(name, runtime, new Map()), args, runtime)),
    ),
  );
  present.plot = builtin("present.plot", 1, 6, ([input, ...args], runtime) => {
    if (Array.isArray(input)) {
      if (args.length > 1)
        fail("Data plots accept only an optional plot kind.", "calc.arity-mismatch");
      return createCalcPlot(input, plotKind(args[0]));
    }
    if (isCallable(input)) {
      if (args.length < 2 || args.length > 4)
        fail(
          "Function plots require lower and upper bounds, with optional kind and sample count.",
          "calc.arity-mismatch",
        );
      return sampleCalcPlot(
        args[0],
        args[1],
        (x) => call(input, [x], runtime),
        plotKind(args[2]),
        args[3],
      );
    }
    if (
      isSymbolic(input) ||
      (isNumeric(input) && isSymbolic(args[0]) && args[0].kind === "symbol")
    ) {
      if (args.length < 3 || args.length > 5)
        fail(
          "Symbolic plots require a symbol and lower and upper bounds, with optional kind and sample count.",
          "calc.arity-mismatch",
        );
      const variable = asSymbol(args[0]!);
      return sampleCalcPlot(
        args[1],
        args[2],
        (x) => {
          tick(runtime);
          const result = substitute(input, variable, x, (name, values) =>
            symbolicValue(call(resolveIdentifier(name, runtime, new Map()), values, runtime)),
          );
          if (isSymbolic(result))
            fail(
              "Plot contains unbound symbols. Substitute values for the other symbols first.",
              "calc.plot-data",
            );
          return result;
        },
        plotKind(args[3]),
        args[4],
        variable.name,
      );
    }
    return fail("Plot input must be a function, symbolic expression, or list.", "calc.plot-data");
  });
  present.decimal = builtin("present.decimal", 1, 2, ([v, digits]) =>
    decimal(scalar(v), precision(digits ?? 2n)),
  );
  present.percent = builtin("present.percent", 1, 2, ([v, digits]) => {
    const n = mulScalar(scalar(v), 100n);
    return (digits === undefined ? scalarDisplay(n) : decimal(n, precision(digits))) + "%";
  });
  present.unit = builtin("present.unit", 2, 3, ([v, unit, digits]) =>
    formatUnit(v!, requireCalcUnit(text(unit!)), digits),
  );
  present.scale = builtin("present.scale", 2, 3, ([v, name, digits]) => {
    const s = text(name!);
    if (!Object.hasOwn(scales, s)) fail(`Unknown scale '${s}'.`);
    return formatScale(v!, s, digits);
  });
  const result: Record<string, RuntimeResolved> = {};
  for (const [name, members] of Object.entries({
    math,
    stats,
    list: lists,
    str: strings,
    core,
    algebra,
    present,
  })) {
    result[name] = { kind: "namespace", name, members };
    for (const [short, member] of Object.entries(members))
      if (isCallable(member)) {
        const aliases = state.aliases.get(short) ?? [];
        if (!aliases.includes(member)) aliases.push(member);
        state.aliases.set(short, aliases);
      }
  }
  return result;
}
class CalcScope implements CalcRuntimeScope {
  readonly valueNames: readonly string[];
  readonly functionNames: readonly string[];
  readonly state: RuntimeState;
  constructor(statements: readonly CalcStatement[] = []) {
    this.state = {
      rootMembers: {},
      aliases: new Map(),
      valueDefs: new Map(),
      functionDefs: new Map(),
      symbols: new Map(),
      valueCache: new Map(),
      activeValues: new Set(),
      activeFunctions: new Set(),
      steps: 0,
      depth: 0,
    };
    const state = this.state;
    for (const statement of statements) {
      if (statement.kind === "ValueDefinition") state.valueDefs.set(statement.name, statement);
      else if (statement.kind === "FunctionDefinition")
        state.functionDefs.set(statement.name, statement);
      else if (statement.kind === "SymbolDeclaration")
        for (const item of statement.symbols) {
          if (state.symbols.has(item.name))
            state.error = {
              code: "calc.conflicting-symbol",
              message: `Symbol '${item.name}' is already declared.`,
            };
          state.symbols.set(item.name, symbol(item.name));
        }
    }
    for (const name of state.symbols.keys())
      if (state.valueDefs.has(name) || state.functionDefs.has(name))
        state.error = {
          code: "calc.conflicting-symbol",
          message: `Symbol '${name}' conflicts with a definition.`,
        };
    state.rootMembers = roots(state);
    this.valueNames = [...state.valueDefs.keys()];
    this.functionNames = [...state.functionDefs.keys()];
  }
}
function asScope(scope?: CalcRuntimeScope): CalcScope {
  return scope instanceof CalcScope ? scope : new CalcScope();
}
export function createCalcRuntimeScope(
  statements: readonly CalcStatement[] = [],
): CalcRuntimeScope {
  return new CalcScope(statements);
}
export function getCalcBuiltinDocumentation(): readonly CalcCatalogEntry[] {
  const scope = new CalcScope();
  const entries = new Set<CalcCatalogEntry>();
  for (const namespace of Object.values(scope.state.rootMembers)) {
    if (!isNamespace(namespace)) continue;
    for (const member of Object.values(namespace.members))
      if (isCallable(member)) {
        if (!member.documentation) throw new Error(`Missing catalog entry for '${member.name}'.`);
        entries.add(member.documentation);
      }
  }
  return [...entries];
}
function presentedValue(
  presenter: CalcPresenter,
  result: RuntimeResolved,
  state: RuntimeState,
): CalcPresentation {
  const target = presenter.target;
  let fn: RuntimeResolved;
  if (target.kind === "UnitPresenter")
    fn = builtin(`present.${target.unit.symbol}`, 1, 2, ([v, digits]) =>
      formatUnit(v!, target.unit, digits),
    );
  else if (target.kind === "Identifier" && target.name === "%")
    fn = (state.rootMembers.present as RuntimeNamespace).members.percent!;
  else if (target.kind === "Identifier" && Object.hasOwn(scales, target.name))
    fn = builtin(`present.${target.name}`, 1, 2, ([v, digits]) =>
      formatScale(v!, target.name, digits),
    );
  else fn = resolveReference(target, state, new Map());
  const output = call(
    fn,
    [result, ...presenter.args.map((arg) => evaluateResolved(arg, state, new Map()))],
    state,
  );
  return typeof output === "string" || isCalcPlot(output)
    ? output
    : fail("Presenter must return a string or plot.", "calc.presentation-error");
}
function publicValue(v: CalcRuntimeValue): CalcRuntimeValue {
  if (
    typeof v === "bigint" &&
    v <= BigInt(Number.MAX_SAFE_INTEGER) &&
    v >= BigInt(Number.MIN_SAFE_INTEGER)
  )
    return Number(v);
  return Array.isArray(v) ? v.map(publicValue) : v;
}
function evaluate(
  ast: CalcExpression,
  scope: CalcRuntimeScope,
  definition?: string,
): CalcEvaluationResult {
  const state = asScope(scope).state;
  if (state.error) return { ok: false, error: state.error };
  state.steps = 0;
  state.depth = 0;
  try {
    const raw = definition
      ? resolveDefinition(definition, state)
      : evaluateResolved(ast, state, new Map());
    const result: CalcEvaluationSuccess = { ok: true, value: publicValue(value(raw)) };
    if (ast.kind === "PresentationExpression") {
      try {
        result.presentation = presentedValue(ast.presenter, raw, state);
      } catch (error) {
        result.presentationError = errorValue(error);
      }
    }
    return result;
  } catch (error) {
    return { ok: false, error: errorValue(error) };
  }
}
export function evaluateCalcExpression(
  ast: CalcExpression,
  scope?: CalcRuntimeScope,
): CalcEvaluationResult {
  return evaluate(ast, scope ?? createCalcRuntimeScope());
}
export function evaluateCalcStatement(
  statement: CalcValueDefinitionStatement | CalcExpressionStatement,
  scope: CalcRuntimeScope,
): CalcEvaluationResult {
  return statement.kind === "ValueDefinition"
    ? evaluate(statement.value, scope, statement.name)
    : evaluate(statement.expression, scope);
}
export function evaluateCalcBlock(
  block: CalcBlockParseResult | readonly CalcStatement[],
): CalcBlockEvaluation {
  const parsed = Array.isArray(block) ? null : (block as CalcBlockParseResult);
  const statements: readonly CalcStatement[] = parsed
    ? parsed.statements
    : (block as readonly CalcStatement[]);
  const queryResults: CalcBlockQueryResult[] = [],
    statementResults: CalcBlockEvaluation["statementResults"] = [];
  const reactive = new Set(
    parsed?.lines
      .filter((line) => line.reactiveOutput && line.statement && line.diagnostics.length === 0)
      .map((line) => line.statement!.range.from),
  );
  const invalid = new Set(
    parsed?.lines
      .filter((line) => line.diagnostics.length)
      .map((line) => line.statement?.range.from),
  );
  const scope = createCalcRuntimeScope(
    statements.filter((statement) => !invalid.has(statement.range.from)),
  );
  for (const statement of statements) {
    if (invalid.has(statement.range.from)) continue;
    if (statement.kind === "ExpressionStatement") {
      const result = evaluateCalcStatement(statement, scope);
      queryResults.push({ statement, result });
      statementResults.push({ statement, result });
    } else if (
      statement.kind === "ValueDefinition" &&
      (reactive.has(statement.range.from) || statement.value.kind === "PresentationExpression")
    )
      statementResults.push({ statement, result: evaluateCalcStatement(statement, scope) });
  }
  return { scope, queryResults, statementResults };
}
export function formatCalcRuntimeValue(v: CalcRuntimeValue): string {
  if (isCalcPlot(v)) return plotSummary(v);
  if (isNumeric(v)) return formatNumeric(v);
  if (isSymbolic(v)) return formatSymbolic(v);
  if (isCallable(v)) return `<function ${v.name}>`;
  if (Array.isArray(v)) return `[${v.map(formatCalcRuntimeValue).join(", ")}]`;
  return v === null ? "null" : String(v);
}
