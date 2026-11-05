import { scales, scalarDisplay } from "./numeric.ts";
import { calcUnitSymbols, requireCalcUnit } from "./units.ts";

export type CalcDiscoveryType =
  | "number"
  | "quantity"
  | "complex"
  | "expression"
  | "list"
  | "string"
  | "function"
  | "boolean"
  | "null"
  | "plot";
export interface CalcExample {
  readonly source: string;
  readonly expected?: string;
}
export interface CalcCatalogEntry {
  readonly name: string;
  readonly category: string;
  readonly kind: "function" | "constant" | "syntax" | "presenter";
  readonly summary: string;
  readonly keywords: readonly string[];
  readonly signatures: readonly (readonly string[])[];
  readonly accepts: readonly CalcDiscoveryType[];
  readonly examples: readonly CalcExample[];
  readonly snippet?: string;
  readonly aliases?: readonly string[];
  readonly arity?: readonly [number, number];
}
function signatureParameters(source: string): string[] {
  if (!source) return [];
  const params: string[] = [];
  let quote = "",
    start = 0;
  for (let index = 0; index < source.length; index++) {
    const char = source[index]!;
    if (quote) {
      if (char === "\\") index++;
      else if (char === quote) quote = "";
    } else if (char === '"' || char === "'") quote = char;
    else if (char === ",") {
      params.push(source.slice(start, index).trim());
      start = index + 1;
    }
  }
  params.push(source.slice(start).trim());
  return params;
}
const numeric: CalcDiscoveryType[] = ["number", "quantity", "complex", "expression"];
function fn(
  name: string,
  params: string | readonly string[],
  arity: readonly [number, number],
  summary: string,
  source: string,
  expected: string | undefined,
  accepts: readonly CalcDiscoveryType[] = numeric,
  keywords: readonly string[] = [],
  aliases: readonly string[] = [],
): CalcCatalogEntry {
  return {
    name,
    category: (
      {
        math: "Numbers",
        stats: "Statistics",
        list: "Lists",
        str: "Strings",
        core: "Values",
        algebra: "Symbols",
        present: "Presenters",
      } as Record<string, string>
    )[name.split(".")[0]!]!,
    kind: name.startsWith("present.") ? "presenter" : "function",
    summary,
    keywords,
    arity,
    accepts,
    aliases,
    signatures: (typeof params === "string" ? [params] : params).map((p) => signatureParameters(p)),
    examples: [{ source, expected }],
  };
}
const operations: CalcCatalogEntry[] = [
  fn(
    "math.abs",
    "value",
    [1, 1],
    "Absolute value or complex magnitude; compatible units are preserved.",
    "abs(-3)",
    "3",
    numeric,
    ["magnitude", "distance"],
  ),
  fn("math.sign", "value", [1, 1], "Return -1, 0, or 1 for a real scalar.", "sign(-3)", "-1", [
    "number",
  ]),
  fn(
    "math.sqrt",
    "value",
    [1, 1],
    "Square root. Quantities need even unit powers; use complex(...) for negative inputs.",
    "sqrt(9m^2)",
    "3m",
    numeric,
    ["root"],
  ),
  fn("math.exp", "value", [1, 1], "Exponential e^value for dimensionless values.", "exp(0)", "1", [
    "number",
    "complex",
    "expression",
  ]),
  fn(
    "math.ln",
    "value",
    [1, 1],
    "Natural logarithm; real inputs must be positive.",
    "ln(1)",
    "0",
    ["number", "complex", "expression"],
    ["logarithm"],
  ),
  fn(
    "math.log10",
    "value",
    [1, 1],
    "Base-10 logarithm of a positive real scalar.",
    "log10(100)",
    "2",
    ["number", "expression"],
    ["logarithm"],
  ),
  ...(["sin", "cos", "tan"] as const).map((name) =>
    fn(
      `math.${name}`,
      "angle",
      [1, 1],
      "Trigonometric function accepting radians or explicit angle units, and complex or symbolic values.",
      `${name}(0)`,
      name === "cos" ? "1" : "0",
      numeric,
      ["angle", "trigonometry", "degrees", "radians"],
    ),
  ),
  ...(["asin", "acos", "atan"] as const).map((name) =>
    fn(
      `math.${name}`,
      "value",
      [1, 1],
      "Inverse trigonometric function. Real results are dimensionless radians.",
      `${name}(${name === "acos" ? "1" : "0"})`,
      "0",
      ["number", "expression"],
      ["angle", "trigonometry"],
    ),
  ),
  fn(
    "math.floor",
    "value",
    [1, 1],
    "Round a real scalar down to an integer.",
    "floor(1//3)",
    "0",
    ["number"],
    ["round"],
  ),
  fn(
    "math.ceil",
    "value",
    [1, 1],
    "Round a real scalar up to an integer.",
    "ceil(1//3)",
    "1",
    ["number"],
    ["round"],
  ),
  fn(
    "math.re",
    "value",
    [1, 1],
    "Real component of a complex value, or the input for a real value.",
    "(3+4i) @re",
    "3",
    numeric,
    ["complex", "real"],
  ),
  fn(
    "math.im",
    "value",
    [1, 1],
    "Imaginary component of a complex value; zero for a real value.",
    "(3+4i) @im",
    "4",
    numeric,
    ["complex", "imaginary"],
  ),
  fn(
    "math.conj",
    "value",
    [1, 1],
    "Complex conjugate; real inputs retain their value.",
    "(3+4i) @conj",
    "3 - 4i",
    numeric,
    ["complex", "conjugate"],
  ),
  fn(
    "math.approx",
    "value",
    [1, 1],
    "Convert exact numeric components to approximate machine numbers.",
    "(1//2) @approx",
    "0.5",
    numeric,
    ["decimal", "approximate", "float"],
  ),
  fn(
    "math.round",
    "value, digits = 0",
    [1, 2],
    "Round a real value or quantity. Negative digits round to tens, hundreds, and beyond.",
    "1234 @round(-2)",
    "1200",
    ["number", "quantity"],
    ["precision"],
  ),
  fn(
    "math.complex",
    "real, imaginary = 0",
    [1, 2],
    "Construct a complex number from real scalar components.",
    "complex(3,4) @abs",
    "5",
    ["number"],
    ["imaginary"],
  ),
  fn(
    "math.fraction",
    "numerator, denominator",
    [2, 2],
    "Construct an exact rational from two integers; // is equivalent.",
    "fraction(2,4)",
    "1//2",
    ["number"],
    ["rational", "exact"],
  ),
  fn(
    "math.log",
    "value, base = e",
    [1, 2],
    "Logarithm with an optional base; positive real inputs and base other than one are required.",
    "log(8,2)",
    "3",
    ["number", "expression"],
    ["logarithm"],
  ),
  fn(
    "math.gcd",
    "first, second, ...values",
    [2, 10000],
    "Greatest common divisor of integer arguments.",
    "gcd(18,24)",
    "6",
    ["number"],
    ["divisor", "integer"],
  ),
  fn(
    "math.lcm",
    "first, second, ...values",
    [2, 10000],
    "Least common multiple of integer arguments.",
    "lcm(6,8)",
    "24",
    ["number"],
    ["multiple", "integer"],
  ),
  fn(
    "math.factorial",
    "integer",
    [1, 1],
    "Factorial of an integer from 0 through 1000.",
    "5 @factorial",
    "120",
    ["number"],
    ["permutation"],
  ),
  fn(
    "math.min",
    ["values", "first, ...values"],
    [1, 10000],
    "Smallest real value or compatible quantity in a list or argument sequence.",
    "min([3,1,2])",
    "1",
    ["list", "number", "quantity"],
    ["minimum"],
    ["stats.min"],
  ),
  fn(
    "math.max",
    ["values", "first, ...values"],
    [1, 10000],
    "Largest real value or compatible quantity in a list or argument sequence.",
    "max([3,1,2])",
    "3",
    ["list", "number", "quantity"],
    ["maximum"],
    ["stats.max"],
  ),
  fn(
    "math.clamp",
    "value, minimum, maximum",
    [3, 3],
    "Limit a real value or quantity to compatible lower and upper bounds.",
    "clamp(12,0,10)",
    "10",
    ["number", "quantity"],
    ["limit", "bounds"],
  ),
  fn(
    "stats.sum",
    ["values", "first, ...values"],
    [1, 10000],
    "Add numeric values, retaining compatible units and exact arithmetic.",
    "[1//3,1//6] @sum",
    "1//2",
    ["list", "number", "quantity", "complex"],
    ["total", "add"],
    ["list.sum"],
  ),
  fn(
    "stats.count",
    ["values", "first, ...values"],
    [1, 10000],
    "Count numeric items in a list or argument sequence. Use list.len for arbitrary lists.",
    "count([1,2,3])",
    "3",
    ["list", "number", "quantity", "complex"],
    ["length", "size"],
  ),
  fn(
    "stats.mean",
    ["values", "first, ...values"],
    [1, 10000],
    "Arithmetic mean of numeric values, retaining compatible units.",
    "[1kg,500g] @mean",
    "0.75kg",
    ["list", "number", "quantity", "complex"],
    ["average"],
  ),
  fn(
    "stats.median",
    ["values", "first, ...values"],
    [1, 10000],
    "Middle of sorted real values; average the middle pair for an even count.",
    "median([1,3,8])",
    "3",
    ["list", "number", "quantity"],
    ["average", "middle"],
  ),
  fn(
    "stats.variance",
    'values, mode = "sample"',
    [1, 2],
    'Variance of compatible real values. Mode is "sample" or "population"; units are squared.',
    'variance([1,2,3],"population")',
    "0.666666666667",
    ["list"],
    ["spread", "statistics"],
  ),
  fn(
    "stats.std",
    'values, mode = "sample"',
    [1, 2],
    'Standard deviation, using "sample" or "population" normalization. Compatible units are retained.',
    "std([1,2,3])",
    "1",
    ["list"],
    ["standard deviation", "spread", "statistics"],
    ["stats.stddev"],
  ),
  fn(
    "stats.quantile",
    "values, probability",
    [2, 2],
    "Interpolated quantile at a probability between zero and one.",
    "quantile([0,10],0.25)",
    "2.5",
    ["list"],
    ["percentile", "quartile", "statistics"],
  ),
  fn(
    "list.len",
    "values",
    [1, 1],
    "Number of elements in a list.",
    "list.len([1,2,3])",
    "3",
    ["list"],
    ["length", "size", "count"],
  ),
  fn(
    "list.first",
    "values",
    [1, 1],
    "First list element, or null when empty.",
    "first([3,4])",
    "3",
    ["list"],
  ),
  fn("list.last", "values", [1, 1], "Last list element, or null when empty.", "last([3,4])", "4", [
    "list",
  ]),
  fn(
    "list.reverse",
    "values",
    [1, 1],
    "Return a reversed copy of the list.",
    "reverse([1,2,3])",
    "[3, 2, 1]",
    ["list"],
  ),
  fn(
    "list.join",
    'values, separator = ", "',
    [1, 2],
    "Join formatted list elements into a string.",
    'list.join([1,2]," / ")',
    "1 / 2",
    ["list"],
    ["text", "combine"],
  ),
  fn(
    "list.map",
    "values, function",
    [2, 2],
    "Transform each list element with a function accepting the item and optional index.",
    "[1,4,9] @map(sqrt)",
    "[1, 2, 3]",
    ["list"],
    ["transform", "comprehension"],
  ),
  fn(
    "list.filter",
    "values, predicate",
    [2, 2],
    "Keep elements for which a predicate returns a truthy value; it accepts the item and optional index.",
    "positive(n) = n > 0\n[-1,2,3] @filter(positive)",
    "[2, 3]",
    ["list"],
    ["select", "where", "comprehension"],
  ),
  fn(
    "list.range",
    ["stop", "start, stop, step = 1"],
    [1, 3],
    "Generate numbers up to, excluding, stop. Step can be negative and must advance the sequence. Limit: 10000 items.",
    "range(0,5)",
    "[0, 1, 2, 3, 4]",
    ["number"],
    ["sequence", "interval", "generate"],
  ),
  fn(
    "list.slice",
    "values, start, end?",
    [2, 3],
    "Copy a portion of a list using zero-based indices; the optional end is excluded.",
    "[1,2,3,4] @slice(1,3)",
    "[2, 3]",
    ["list"],
    ["subset", "take"],
  ),
  fn(
    "list.sort",
    "values, comparator?",
    [1, 2],
    "Return a sorted copy. An optional comparator returns a negative, zero, or positive number.",
    "sort([3,1,2])",
    "[1, 2, 3]",
    ["list"],
    ["order"],
  ),
  fn(
    "list.reduce",
    "values, function, initial",
    [3, 3],
    "Fold elements into an accumulator. The callback accepts accumulator, item, and optional index.",
    "add(a,b) = a+b\n[1,2,3] @reduce(add,0)",
    "6",
    ["list"],
    ["fold", "accumulate"],
  ),
  fn(
    "str.len",
    "text",
    [1, 1],
    "Number of UTF-16 code units in a string.",
    'str.len("hello")',
    "5",
    ["string"],
    ["length", "size"],
  ),
  fn(
    "str.trim",
    "text",
    [1, 1],
    "Remove whitespace at both ends of a string.",
    'trim(" hello ")',
    "hello",
    ["string"],
    ["space"],
  ),
  fn(
    "str.lower",
    "text",
    [1, 1],
    "Convert text to lowercase.",
    'lower("HELLO")',
    "hello",
    ["string"],
    ["case"],
  ),
  fn(
    "str.upper",
    "text",
    [1, 1],
    "Convert text to uppercase.",
    'upper("hello")',
    "HELLO",
    ["string"],
    ["case"],
  ),
  fn(
    "str.split",
    "text, separator?",
    [1, 2],
    "Split a string into a list. Omit the separator to split into UTF-16 code units.",
    'split("a,b",",") @list.len',
    "2",
    ["string"],
    ["words", "text"],
  ),
  fn(
    "str.join",
    'values, separator = ""',
    [1, 2],
    "Join formatted list elements into text with an optional separator.",
    'str.join([1,2],"-")',
    "1-2",
    ["list"],
    ["combine", "text"],
  ),
  fn(
    "str.includes",
    "text, search",
    [2, 2],
    "Whether text contains the search string.",
    'includes("hello","ell")',
    "true",
    ["string"],
    ["contains", "find"],
  ),
  fn(
    "str.replace",
    "text, search, replacement",
    [3, 3],
    "Replace every occurrence of a literal search string.",
    'replace("aba","a","x")',
    "xbx",
    ["string"],
    ["substitute"],
  ),
  fn(
    "core.if",
    "condition, yes, no = null",
    [2, 3],
    "Choose a value using calc truth rules. Arguments are evaluated eagerly; guard unsafe calculations with a comprehension filter.",
    "if(1<2,10,20)",
    "10",
    [],
    ["conditional", "choose"],
  ),
  fn(
    "core.coalesce",
    "first, ...values",
    [1, 10000],
    "First argument that is neither null nor an empty string. Arguments are evaluated eagerly.",
    'coalesce(null,"",3)',
    "3",
    [],
    ["default", "fallback"],
  ),
  fn(
    "core.type",
    "value",
    [1, 1],
    "Return the value's type name without converting it.",
    "(1//3) @type",
    "rational",
    [],
    ["typeof", "inspect"],
    ["core.typeof"],
  ),
  fn(
    "algebra.simplify",
    "expression",
    [1, 1],
    "Simplify a symbolic expression conservatively, including polynomial arithmetic.",
    "symbol x\n(x+x) @simplify",
    "2*x",
    ["expression", "number"],
    ["algebra"],
  ),
  fn(
    "algebra.expand",
    "expression",
    [1, 1],
    "Expand polynomial products and powers within the term limit.",
    "symbol x\n((x+1)*(x+2)) @expand",
    "x^2 + 3*x + 2",
    ["expression", "number"],
    ["algebra", "polynomial"],
  ),
  fn(
    "algebra.factor",
    "expression",
    [1, 1],
    "Extract supported polynomial factors. Unsupported factorizations retain the expression.",
    "symbol x\n(x^2-1) @factor",
    "(x + 1)*(x - 1)",
    ["expression", "number"],
    ["algebra", "polynomial"],
  ),
  fn(
    "algebra.diff",
    "expression, symbol",
    [2, 2],
    "Differentiate a supported symbolic expression with respect to a declared symbol.",
    "symbol x\n(x^2) @diff(x)",
    "2*x",
    ["expression", "number"],
    ["derivative", "differentiate", "calculus"],
  ),
  fn(
    "algebra.subs",
    "expression, symbol, value",
    [3, 3],
    "Replace a declared symbol and evaluate supported numeric calls.",
    "symbol x\n(x^2) @subs(x,3)",
    "9",
    ["expression", "number"],
    ["substitute", "algebra"],
  ),
  fn(
    "present.plot",
    [
      'data, kind = "line"',
      'function, from, to, kind = "line", samples = 201',
      'expression, symbol, from, to, kind = "line", samples = 201',
    ],
    [1, 6],
    "Draw a line, scatter, or bar plot. Data lists use indices or [x,y] pairs; functions and symbols require bounds. At most 2000 samples.",
    '[3,7,4] as plot("bar")',
    "[plot: bar, 3 points]",
    ["list", "function", "expression"],
    ["graph", "chart", "visualize", "scatter", "bar"],
  ),
  fn(
    "present.decimal",
    "value, digits = 2",
    [1, 2],
    "Render a real scalar with a fixed number of decimal places, retaining its original value when used with as.",
    "1//3 as decimal(2)",
    "0.33",
    ["number"],
    ["precision", "round", "format"],
  ),
  fn(
    "present.percent",
    "value, digits?",
    [1, 2],
    "Multiply by 100 and append %. Optional precision fixes the number of fractional places; as retains the numeric value.",
    "0.375 as %(2)",
    "37.50%",
    ["number"],
    ["percentage", "rate", "format"],
  ),
  fn(
    "present.unit",
    "value, unit, digits?",
    [2, 3],
    "Render a quantity in compatible target units. Precision is optional; use as kg or as km/h for short forms.",
    'present.unit(10m/s,"km/h",1)',
    "36.0km/h",
    ["quantity"],
    ["convert", "conversion", "units", "format"],
  ),
  fn(
    "present.scale",
    "value, scale, digits?",
    [2, 3],
    "Divide a scalar by a registered multiplier and append its suffix. Precision is optional; L is lakh and Cr is crore.",
    'present.scale(25000000,"Cr",2)',
    "2.50Cr",
    ["number"],
    ["multiplier", "lakh", "crore", "million", "format"],
  ),
];
const syntax = (
  name: string,
  summary: string,
  snippet: string,
  source: string,
  expected: string,
  keywords: string[] = [],
): CalcCatalogEntry => ({
  name,
  category: "Constructions",
  kind: "syntax",
  summary,
  snippet,
  keywords,
  signatures: [],
  accepts: [],
  examples: [{ source, expected }],
});
export const calcCatalog: readonly CalcCatalogEntry[] = Object.freeze([
  ...operations,
  ...(
    [
      ["math.pi", Math.PI, "Circle constant. Angles without units use radians."],
      ["math.e", Math.E, "Base of the natural logarithm."],
    ] as const
  ).map(
    ([name, value, summary]): CalcCatalogEntry => ({
      name,
      category: "Numbers",
      kind: "constant",
      summary,
      keywords: ["constant"],
      signatures: [],
      accepts: [],
      examples: [{ source: name, expected: scalarDisplay(value) }],
    }),
  ),
  syntax(
    "List comprehension",
    "Build a list with one for clause and an optional if filter. The loop variable stays local; filtered bodies are skipped.",
    "[${1:n}^2 for ${1:n} in range(${2:5}) if ${1:n} > ${3:0}]",
    "[n^2 for n in range(5) if n > 1]",
    "[4, 9, 16]",
    ["filter", "transform", "loop", "list", "generate"],
  ),
  syntax(
    "Function definition",
    "Define a pure named function. Parameters are local; free names come from the calc block.",
    "${1:double}(${2:x}) = ${2:x} * ${3:2}",
    "double(x) = x*2\ndouble(3)",
    "6",
    ["function", "define", "helper"],
  ),
  syntax(
    "Reactive assignment",
    "Bind a computed value and keep the output after the arrow up to date. Trailing comments are preserved.",
    "${1:total} = ${2:25 * 4} -> ",
    "total = 25*4 -> 100 # calculate total\ntotal",
    "100",
    ["variable", "formula", "result", "comment"],
  ),
  syntax(
    "Exact fraction",
    "Use // between integer expressions for an exact rational. Ordinary division also retains exactness for exact inputs.",
    "${1:1}//${2:3}",
    "1//3 + 1//6",
    "1//2",
    ["rational", "divide", "number"],
  ),
  syntax(
    "Complex number",
    "An attached i coefficient constructs an imaginary value. i is reserved.",
    "${1:3} + ${2:4}i",
    "(3+4i) @abs",
    "5",
    ["imaginary", "number"],
  ),
  syntax(
    "Quantity",
    "Attach a unit to a number and combine units dimensionally. Legacy L means lakh; use l or litre for volume.",
    "${1:10}kg * ${2:3}",
    "10m/s * 20s",
    "200m",
    ["units", "convert", "mass", "length", "time", "speed"],
  ),
  syntax(
    "Symbol declaration",
    "Declare symbolic names before algebraic operations. Separate declared symbols with commas.",
    "symbol ${1:x}",
    "symbol x\n(x+x) @simplify",
    "2*x",
    ["algebra", "expression", "symbolic"],
  ),
  syntax(
    "Postfix operation",
    "Pass a value as the first argument of a function using @. Pipelines run left to right.",
    "${1:[1,2,3]} @${2:sum}",
    "[1,2,3] @sum",
    "6",
    ["method", "pipe", "chain"],
  ),
  syntax(
    "Presenter",
    "Use as to render a result while keeping the original computed value in its binding.",
    "${1:0.375} as ${2:%}",
    "0.375 as %",
    "37.5%",
    ["percentage", "display", "format", "render"],
  ),
  syntax(
    "Function plot",
    "Plot a single-argument function over increasing bounds. Shift-drag pans the existing samples; double-click resets.",
    "${1:f}(${2:x}) = ${2:x}^2\n${1:f} as plot(${3:-5}, ${4:5})",
    "f(x) = x^2\nf as plot(-5,5)",
    "[plot: line, 201 points]",
    ["graph", "chart", "visualize", "draw"],
  ),
  syntax(
    "Data plot",
    "Plot a list by index or [x,y] pairs. Choose line, scatter, or bar; null y values leave gaps.",
    '${1:[3,7,4,9]} as plot("${2:bar}")',
    '[3,7,4,9] as plot("bar")',
    "[plot: bar, 4 points]",
    ["graph", "chart", "scatter", "bar"],
  ),
]);
const byName = new Map(
  calcCatalog.flatMap((entry) =>
    [entry.name, ...(entry.aliases ?? [])].map((name) => [name, entry] as const),
  ),
);
export function calcEntry(name: string): CalcCatalogEntry | undefined {
  const exact = byName.get(name);
  if (exact) return exact;
  if (name === "%") return byName.get("present.percent");
  const matches = operations.filter((entry) =>
    [entry.name, ...(entry.aliases ?? [])].some((n) => n.split(".").at(-1) === name),
  );
  return matches.length === 1 ? matches[0] : undefined;
}
export function calcEntriesNamed(name: string): readonly CalcCatalogEntry[] {
  const exact = byName.get(name);
  if (exact) return [exact];
  return operations.filter((entry) =>
    [entry.name, ...(entry.aliases ?? [])].some((n) => n.split(".").at(-1) === name),
  );
}
export function searchCalcCatalog(query: string): CalcCatalogEntry[] {
  const words = query.toLowerCase().trim().split(/\s+/).filter(Boolean);
  return calcCatalog
    .map((entry) => {
      const label = `${entry.name} ${(entry.aliases ?? []).join(" ")}`.toLowerCase();
      const terms =
        `${label} ${entry.category} ${entry.summary} ${entry.keywords.join(" ")} ${entry.examples.map((e) => e.source).join(" ")}`.toLowerCase();
      return {
        entry,
        score: words.every((w) => terms.includes(w))
          ? words.reduce((s, w) => s + (label.startsWith(w) ? 10 : label.includes(w) ? 5 : 1), 0)
          : -1,
      };
    })
    .filter(({ score }) => score >= 0)
    .sort((a, b) => b.score - a.score)
    .map(({ entry }) => entry);
}
export function calcSignature(
  entry: CalcCatalogEntry,
  name = entry.name,
  implicit = false,
  variant = 0,
): string {
  return `${name}(${(entry.signatures[variant] ?? []).slice(implicit ? 1 : 0).join(", ")})`;
}
let presenterAliases: CalcCatalogEntry[] | undefined;
export function calcPresenterAliases(): CalcCatalogEntry[] {
  if (presenterAliases) return presenterAliases;
  return (presenterAliases = [
    {
      ...calcEntry("present.percent")!,
      name: "%",
      signatures: [["value", "digits?"]],
      examples: [{ source: "0.375 as %", expected: "37.5%" }],
    },
    ...Object.keys(scales).map(
      (name): CalcCatalogEntry => ({
        ...calcEntry("present.scale")!,
        name,
        category: "Multipliers",
        signatures: [["value", "digits?"]],
        summary: `Render with the ${name} multiplier (${scales[name]}).`,
        examples: [{ source: `${scales[name]} as ${name}`, expected: `1${name}` }],
      }),
    ),
    ...calcUnitSymbols()
      .filter((name) => !name.includes("µ"))
      .map((name): CalcCatalogEntry => {
        const dimensions = requireCalcUnit(name).dimensions;
        const keywords = [
          name,
          "unit",
          "convert",
          "conversion",
          ...(dimensions.kg ? ["mass", "weight", "kilogram", "gram"] : []),
          ...(dimensions.s ? ["time", "duration", "second", "hour", "minute"] : []),
          ...(dimensions.m === 3
            ? ["volume", "litre", "liter"]
            : dimensions.m
              ? ["length", "distance", "meter", "metre"]
              : []),
          ...(dimensions.rad ? ["angle", "radian", "degree"] : []),
        ];
        return {
          ...calcEntry("present.unit")!,
          name,
          category: "Units",
          keywords,
          signatures: [["value", "digits?"]],
          summary: `Render a compatible quantity in ${name}. Use compound units such as m/s or km/h for rates.`,
          examples: [{ source: `1${name} as ${name}`, expected: `1${name}` }],
        };
      }),
  ]);
}

export function renderCalcCatalogReference(): string {
  const lines = [
    "# Calc reference",
    "",
    "Generated from the discovery catalog. Run `make calc-reference` after changing catalog entries.",
    "",
    "In the editor, use **Explore calc** or **F1** inside calc to search these functions and constructions. Completion, hover help, and argument hints use the same entries.",
    "",
    "Short callable names work when unambiguous. Use qualified names such as `list.len` and `str.len` when a short name has multiple meanings. Parameters ending in `?` are optional; defaults are shown after `=`.",
    "",
  ];
  for (const category of new Set(calcCatalog.map((entry) => entry.category))) {
    lines.push(`## ${category}`, "");
    for (const entry of calcCatalog.filter((entry) => entry.category === category)) {
      lines.push(`### ${entry.name}`, "", entry.summary, "");
      if (entry.aliases?.length)
        lines.push(`Aliases: ${entry.aliases.map((name) => "`" + name + "`").join(", ")}.`, "");
      for (let variant = 0; variant < entry.signatures.length; variant++)
        lines.push("`" + calcSignature(entry, entry.name, false, variant) + "`", "");
      for (const example of entry.examples)
        lines.push(
          "```calc",
          example.source,
          ...(example.expected === undefined ? [] : ["# Result: " + example.expected]),
          "```",
          "",
        );
    }
  }
  lines.push(
    "## Unit and multiplier presenters",
    "",
    "Use `as kg`, `as km/h`, `as Cr`, or `as %(2)` to render a compatible value while retaining the original value. Each accepts optional decimal precision. The editor suggests units from the unit registry, with `u` for the micro prefix. Compound unit expressions such as `kg/(m*s^2)` can be entered directly.",
    "",
    "Registered discovery spellings:",
    "",
    calcPresenterAliases()
      .map((entry) => "`" + entry.name + "`")
      .join(", ") + ".",
    "",
  );
  return lines.join("\n");
}
