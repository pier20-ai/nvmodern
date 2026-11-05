import { scanCalcUnit, type CalcUnit } from "./units.ts";
import { CalcError, parseNumeric, scales, toNumber } from "./numeric.ts";

export interface CalcRange {
  from: number;
  to: number;
}

export interface CalcDiagnostic {
  code: string;
  message: string;
  severity: "error";
  from: number;
  to: number;
  line?: number;
  column?: number;
}

export interface CalcParameter {
  name: string;
  range: CalcRange;
}

export interface CalcNumberLiteral {
  kind: "NumberLiteral";
  value: number | bigint;
  raw: string;
  range: CalcRange;
}

export interface CalcBooleanLiteral {
  kind: "BooleanLiteral";
  value: boolean;
  range: CalcRange;
}

export interface CalcNullLiteral {
  kind: "NullLiteral";
  value: null;
  range: CalcRange;
}

export interface CalcStringLiteral {
  kind: "StringLiteral";
  value: string;
  raw: string;
  range: CalcRange;
}

export interface CalcIdentifierExpression {
  kind: "Identifier";
  name: string;
  range: CalcRange;
}

export interface CalcMemberExpression {
  kind: "MemberExpression";
  object: CalcReferenceExpression;
  property: string;
  propertyRange: CalcRange;
  range: CalcRange;
}

export interface CalcCallExpression {
  kind: "CallExpression";
  callee: CalcExpression;
  args: CalcExpression[];
  range: CalcRange;
}

export interface CalcUnaryExpression {
  kind: "UnaryExpression";
  operator: "-";
  operand: CalcExpression;
  range: CalcRange;
}

export interface CalcBinaryExpression {
  kind: "BinaryExpression";
  operator: "+" | "-" | "*" | "/" | "//" | "^" | "==" | "!=" | "<" | "<=" | ">" | ">=";
  left: CalcExpression;
  right: CalcExpression;
  range: CalcRange;
}

export interface CalcListExpression {
  kind: "ListExpression";
  elements: CalcExpression[];
  range: CalcRange;
}

export interface CalcListComprehensionExpression {
  kind: "ListComprehension";
  element: CalcExpression;
  binding: CalcParameter;
  iterable: CalcExpression;
  condition: CalcExpression | null;
  forRange: CalcRange;
  inRange: CalcRange;
  ifRange: CalcRange | null;
  range: CalcRange;
}

export interface CalcPipeStage {
  kind: "PipeStage";
  callee: CalcReferenceExpression;
  args: CalcExpression[];
  range: CalcRange;
}

export interface CalcPipeExpression {
  kind: "PipeExpression";
  input: CalcExpression;
  stage: CalcPipeStage;
  range: CalcRange;
}

export interface CalcQuantityLiteral {
  kind: "QuantityLiteral";
  raw: string;
  unit: CalcUnit;
  unitRange: CalcRange;
  range: CalcRange;
}

export interface CalcImaginaryLiteral {
  kind: "ImaginaryLiteral";
  raw: string;
  range: CalcRange;
}

export interface CalcPresenter {
  target: CalcReferenceExpression | { kind: "UnitPresenter"; unit: CalcUnit; range: CalcRange };
  args: CalcExpression[];
  range: CalcRange;
}

export interface CalcPresentationExpression {
  kind: "PresentationExpression";
  input: CalcExpression;
  presenter: CalcPresenter;
  range: CalcRange;
}

export interface CalcSymbolDeclaration {
  kind: "SymbolDeclaration";
  symbols: CalcParameter[];
  range: CalcRange;
}

export type CalcLiteralExpression =
  | CalcNumberLiteral
  | CalcQuantityLiteral
  | CalcImaginaryLiteral
  | CalcBooleanLiteral
  | CalcNullLiteral
  | CalcStringLiteral;

export type CalcReferenceExpression = CalcIdentifierExpression | CalcMemberExpression;

export type CalcExpression =
  | CalcLiteralExpression
  | CalcIdentifierExpression
  | CalcMemberExpression
  | CalcCallExpression
  | CalcUnaryExpression
  | CalcBinaryExpression
  | CalcListExpression
  | CalcListComprehensionExpression
  | CalcPipeExpression
  | CalcPresentationExpression;

export interface CalcValueDefinitionStatement {
  kind: "ValueDefinition";
  name: string;
  nameRange: CalcRange;
  value: CalcExpression;
  range: CalcRange;
}

export interface CalcFunctionDefinitionStatement {
  kind: "FunctionDefinition";
  name: string;
  nameRange: CalcRange;
  params: CalcParameter[];
  body: CalcExpression;
  range: CalcRange;
}

export interface CalcExpressionStatement {
  kind: "ExpressionStatement";
  expression: CalcExpression;
  range: CalcRange;
}

export type CalcStatement =
  | CalcValueDefinitionStatement
  | CalcSymbolDeclaration
  | CalcFunctionDefinitionStatement
  | CalcExpressionStatement;

export interface CalcExpressionParseResult {
  source: string;
  expression: CalcExpression | null;
  diagnostics: CalcDiagnostic[];
}

export interface CalcStatementParseResult {
  source: string;
  statement: CalcStatement | null;
  diagnostics: CalcDiagnostic[];
}

export type CalcBlockLineKind = "blank" | "comment" | "statement";

export interface CalcReactiveSourceSplit {
  expressionSource: string;
  outputSource: string;
  separator: "->" | "→";
  separatorRange: CalcRange;
  outputRange: CalcRange;
}

export interface CalcBlockLine {
  kind: CalcBlockLineKind;
  line: number;
  from: number;
  to: number;
  text: string;
  statement: CalcStatement | null;
  reactiveOutput: CalcReactiveSourceSplit | null;
  diagnostics: CalcDiagnostic[];
}

export interface CalcBlockParseResult {
  source: string;
  statements: CalcStatement[];
  lines: CalcBlockLine[];
  diagnostics: CalcDiagnostic[];
}

type CalcTokenKind =
  | "number"
  | "quantity"
  | "imaginary"
  | "string"
  | "identifier"
  | "true"
  | "false"
  | "null"
  | "("
  | ")"
  | "["
  | "]"
  | ","
  | "."
  | "+"
  | "-"
  | "*"
  | "/"
  | "//"
  | "^"
  | "@"
  | "%"
  | "="
  | "=="
  | "!="
  | "<"
  | "<="
  | ">"
  | ">="
  | "|>"
  | "eof";

interface CalcToken {
  unit?: CalcUnit;
  unitFrom?: number;
  kind: CalcTokenKind;
  value: string;
  from: number;
  to: number;
}

class ParseAbort extends Error {}

const CALC_SCALE_SUFFIXES = ["Cr", "k", "M", "B", "T", "L"] as const;

const CALC_SCALE_MULTIPLIERS = scales;

function range(from: number, to: number): CalcRange {
  return { from, to };
}

function diagnostic(code: string, message: string, from: number, to: number): CalcDiagnostic {
  return {
    code,
    message,
    severity: "error",
    from,
    to,
  };
}

export function splitReactiveCalcSource(source: string): CalcReactiveSourceSplit | null {
  let quote: "'" | '"' | null = null;
  let escaped = false;
  let parenDepth = 0;
  let bracketDepth = 0;

  for (let index = 0; index < source.length; index += 1) {
    const char = source[index]!;
    if (!char) continue;

    if (quote) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char === "\\") {
        escaped = true;
        continue;
      }
      if (char === quote) {
        quote = null;
      }
      continue;
    }

    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }

    if (char === "(") {
      parenDepth += 1;
      continue;
    }
    if (char === ")") {
      parenDepth = Math.max(0, parenDepth - 1);
      continue;
    }
    if (char === "[") {
      bracketDepth += 1;
      continue;
    }
    if (char === "]") {
      bracketDepth = Math.max(0, bracketDepth - 1);
      continue;
    }

    if (parenDepth !== 0 || bracketDepth !== 0) continue;

    const separator = char === "→" ? "→" : char === "-" && source[index + 1] === ">" ? "->" : null;
    if (!separator) continue;

    const separatorFrom = index;
    const separatorTo = index + separator.length;
    const tail = source.slice(separatorTo);
    const leadingWhitespaceLength = tail.match(/^\s*/)?.[0].length ?? 0;
    const trailingWhitespaceLength = tail.match(/\s*$/)?.[0].length ?? 0;
    const outputFrom = separatorTo + leadingWhitespaceLength;
    const outputTo = Math.max(outputFrom, source.length - trailingWhitespaceLength);

    return {
      expressionSource: source.slice(0, separatorFrom),
      outputSource: source.slice(outputFrom, outputTo),
      separator,
      separatorRange: range(separatorFrom, separatorTo),
      outputRange: range(outputFrom, outputTo),
    };
  }

  return null;
}

function isIdentifierStart(char: string | undefined): boolean {
  return Boolean(char && /[A-Za-z_]/.test(char));
}

function isIdentifierContinue(char: string | undefined): boolean {
  return Boolean(char && /[A-Za-z0-9_]/.test(char));
}

function isDigit(char: string | undefined): boolean {
  return Boolean(char && char >= "0" && char <= "9");
}

function calcScaleSuffixAt(
  source: string,
  index: number,
): (typeof CALC_SCALE_SUFFIXES)[number] | null {
  for (const suffix of CALC_SCALE_SUFFIXES) {
    if (!source.startsWith(suffix, index)) continue;
    const next = source[index + suffix.length];
    if (isIdentifierContinue(next)) continue;
    return suffix;
  }
  return null;
}

function parseCalcNumericLiteral(raw: string): number | bigint {
  if (raw.length > 4096) return NaN;
  try {
    const numeric = parseNumeric(raw);
    if (typeof numeric === "bigint") {
      return numeric <= BigInt(Number.MAX_SAFE_INTEGER) &&
        numeric >= BigInt(Number.MIN_SAFE_INTEGER)
        ? Number(numeric)
        : numeric;
    }
    return toNumber(numeric);
  } catch (error) {
    if (!(error instanceof CalcError)) throw error;
    return NaN;
  }
}

function tokenizeCalcSource(source: string): {
  tokens: CalcToken[];
  diagnostics: CalcDiagnostic[];
} {
  const tokens: CalcToken[] = [];
  const diagnostics: CalcDiagnostic[] = [];
  let index = 0;

  while (index < source.length) {
    const char = source[index]!;

    if (/\s/.test(char)) {
      index += 1;
      continue;
    }

    const two = source.slice(index, index + 2);
    if (
      two === "//" ||
      two === "|>" ||
      two === "==" ||
      two === "!=" ||
      two === "<=" ||
      two === ">="
    ) {
      tokens.push({ kind: two as CalcTokenKind, value: two, from: index, to: index + 2 });
      index += 2;
      continue;
    }

    if (isDigit(char)) {
      const start = index;
      index += 1;
      while (index < source.length) {
        const next = source[index];
        if (isDigit(next) || next === "_") {
          index += 1;
          continue;
        }
        break;
      }

      if (source[index] === ".") {
        const dotIndex = index;
        index += 1;
        let sawFractionDigit = false;
        while (index < source.length) {
          const next = source[index];
          if (isDigit(next) || next === "_") {
            sawFractionDigit = true;
            index += 1;
            continue;
          }
          break;
        }

        if (!sawFractionDigit) {
          diagnostics.push(
            diagnostic(
              "calc.invalid-number",
              "Expected digits after decimal point.",
              dotIndex,
              index,
            ),
          );
        }
      }

      if (source[index] === "e" || source[index] === "E") {
        const expStart = index;
        index += 1;

        if (source[index] === "+" || source[index] === "-") {
          index += 1;
        }

        let sawExponentDigit = false;
        while (index < source.length) {
          const next = source[index];
          if (isDigit(next) || next === "_") {
            sawExponentDigit = true;
            index += 1;
            continue;
          }
          break;
        }

        if (!sawExponentDigit) {
          diagnostics.push(
            diagnostic(
              "calc.invalid-number",
              "Expected digits after exponent marker.",
              expStart,
              index,
            ),
          );
        }
      }

      const scaleSuffix = calcScaleSuffixAt(source, index);
      if (scaleSuffix) {
        index += scaleSuffix.length;
      }

      const hasPercent = source[index] === "%";
      if (hasPercent) {
        index += 1;
      }

      const raw = source.slice(start, index);
      const value = parseCalcNumericLiteral(raw);
      if ((typeof value === "number" && !Number.isFinite(value)) || raw.length > 4096) {
        diagnostics.push(
          diagnostic("calc.invalid-number", `Invalid number literal '${raw}'.`, start, index),
        );
      }
      if (
        !scaleSuffix &&
        !hasPercent &&
        source[index] === "i" &&
        !isIdentifierContinue(source[index + 1])
      ) {
        index++;
        tokens.push({ kind: "imaginary", value: raw, from: start, to: index });
        continue;
      }
      if (!scaleSuffix && !hasPercent) {
        const unitFrom = index + (source.slice(index).match(/^[ \t]*/)?.[0].length ?? 0);
        try {
          const parsed = scanCalcUnit(source, unitFrom);
          if (parsed) {
            index = parsed.to;
            tokens.push({
              kind: "quantity",
              value: raw,
              unit: parsed.unit,
              unitFrom,
              from: start,
              to: index,
            });
            continue;
          }
        } catch (error) {
          if (!(error instanceof CalcError)) throw error;
          diagnostics.push(diagnostic(error.code, error.message, unitFrom, source.length));
        }
      }
      tokens.push({ kind: "number", value: raw, from: start, to: index });
      continue;
    }

    if (char === '"' || char === "'") {
      const quote = char;
      const start = index;
      index += 1;
      let value = "";
      let closed = false;

      while (index < source.length) {
        const next = source[index];
        if (next === "\\") {
          const escaped = source[index + 1];
          if (escaped === undefined) {
            diagnostics.push(
              diagnostic("calc.invalid-string", "Unterminated string literal.", start, index + 1),
            );
            index += 1;
            break;
          }
          switch (escaped) {
            case "n":
              value += "\n";
              break;
            case "r":
              value += "\r";
              break;
            case "t":
              value += "\t";
              break;
            case "\\":
              value += "\\";
              break;
            case '"':
              value += '"';
              break;
            case "'":
              value += "'";
              break;
            default:
              value += escaped;
              break;
          }
          index += 2;
          continue;
        }

        if (next === quote) {
          index += 1;
          closed = true;
          break;
        }

        value += next;
        index += 1;
      }

      if (!closed) {
        diagnostics.push(
          diagnostic("calc.invalid-string", "Unterminated string literal.", start, index),
        );
      }

      tokens.push({ kind: "string", value, from: start, to: index });
      continue;
    }

    if (isIdentifierStart(char)) {
      const start = index;
      index += 1;
      while (index < source.length && isIdentifierContinue(source[index])) {
        index += 1;
      }
      const value = source.slice(start, index);
      if (value === "true" || value === "false" || value === "null") {
        tokens.push({ kind: value, value, from: start, to: index } as CalcToken);
      } else {
        tokens.push({ kind: "identifier", value, from: start, to: index });
      }
      continue;
    }

    if (
      ["(", ")", "[", "]", ",", ".", "+", "-", "*", "/", "^", "=", "<", ">", "@", "%"].includes(
        char,
      )
    ) {
      tokens.push({ kind: char as CalcTokenKind, value: char, from: index, to: index + 1 });
      index += 1;
      continue;
    }

    diagnostics.push(
      diagnostic("calc.unexpected-character", `Unexpected character '${char}'.`, index, index + 1),
    );
    index += 1;
  }

  tokens.push({ kind: "eof", value: "", from: source.length, to: source.length });
  return { tokens, diagnostics };
}

class CalcParser {
  private index = 0;
  private depth = 0;
  readonly diagnostics: CalcDiagnostic[];

  constructor(
    private readonly source: string,
    private readonly tokens: CalcToken[],
    lexerDiagnostics: CalcDiagnostic[],
  ) {
    this.diagnostics = [...lexerDiagnostics];
  }

  parseExpressionRoot(): CalcExpression | null {
    try {
      if (this.peek().kind === "eof") {
        this.pushExpectedExpression(this.peek());
        return null;
      }
      const expression = this.parsePresentedExpression();
      this.expect("eof", "Expected end of expression.");
      return expression;
    } catch (error) {
      if (error instanceof ParseAbort) return null;
      throw error;
    }
  }

  parseStatementRoot(): CalcStatement | null {
    try {
      if (this.peek().kind === "eof") {
        this.pushExpectedExpression(this.peek());
        return null;
      }

      const first = this.peek();
      if (first.kind === "identifier" && first.value === "symbol" && this.peek(1).kind !== "=") {
        this.consume();
        const symbols: CalcParameter[] = [];
        do {
          const token = this.expect("identifier", "Expected a symbol name.");
          this.checkBindingName(token);
          if (symbols.some((symbol) => symbol.name === token.value)) {
            this.pushDiagnostic(
              "calc.conflicting-symbol",
              `Symbol '${token.value}' is repeated.`,
              token.from,
              token.to,
            );
            throw new ParseAbort();
          }
          symbols.push({ name: token.value, range: range(token.from, token.to) });
        } while (this.match(","));
        this.expect("eof", "Expected end of symbol declaration.");
        return {
          kind: "SymbolDeclaration",
          symbols,
          range: range(first.from, symbols[symbols.length - 1]!.range.to),
        };
      }
      if (first.kind === "identifier") {
        if (this.peek(1).kind === "=") {
          const name = this.consume();
          this.checkBindingName(name);
          this.consume();
          const value = this.parsePresentedExpression();
          this.expect("eof", "Expected end of definition.");
          return {
            kind: "ValueDefinition",
            name: name.value,
            nameRange: range(name.from, name.to),
            value,
            range: range(name.from, value.range.to),
          };
        }

        if (this.looksLikeFunctionDefinition()) {
          const name = this.consume();
          this.checkBindingName(name);
          this.expect("(", "Expected '(' after function name.");
          const params = this.parseParameterList();
          this.expect(")", "Expected ')' after function parameters.");
          this.expect("=", "Expected '=' after function signature.");
          const body = this.parseExpression();
          this.expect("eof", "Expected end of function definition.");
          return {
            kind: "FunctionDefinition",
            name: name.value,
            nameRange: range(name.from, name.to),
            params,
            body,
            range: range(name.from, body.range.to),
          };
        }
      }

      const expression = this.parsePresentedExpression();
      this.expect("eof", "Expected end of expression.");
      return {
        kind: "ExpressionStatement",
        expression,
        range: expression.range,
      };
    } catch (error) {
      if (error instanceof ParseAbort) return null;
      throw error;
    }
  }

  private checkBindingName(token: CalcToken): void {
    if (["i", "as", "symbol"].includes(token.value)) {
      this.pushDiagnostic(
        "calc.reserved-name",
        `'${token.value}' is reserved. Rename this binding.`,
        token.from,
        token.to,
      );
      throw new ParseAbort();
    }
  }

  private parsePresentedExpression(): CalcExpression {
    const input = this.parseExpression();
    if (this.peek().kind !== "identifier" || this.peek().value !== "as") return input;
    this.consume();
    const first = this.peek();
    let target: CalcPresenter["target"];
    if (first.kind === "%") {
      this.consume();
      target = { kind: "Identifier", name: "%", range: range(first.from, first.to) };
    } else {
      let unit: ReturnType<typeof scanCalcUnit> = null;
      if (!(first.kind === "identifier" && first.value in CALC_SCALE_MULTIPLIERS)) {
        try {
          unit = scanCalcUnit(this.source, first.from);
        } catch (error) {
          if (!(error instanceof CalcError)) throw error;
          this.pushDiagnostic(error.code, error.message, first.from, first.to);
          throw new ParseAbort();
        }
      }
      if (unit) {
        while (this.peek().kind !== "eof" && this.peek().from < unit.to) this.consume();
        target = { kind: "UnitPresenter", unit: unit.unit, range: range(first.from, unit.to) };
      } else target = this.parseReferenceExpression();
    }
    let args: CalcExpression[] = [],
      to = target.range.to;
    if (this.match("(")) {
      args = this.parseArgumentList(")");
      to = this.expect(")", "Expected ')' after presenter arguments.").to;
    }
    return {
      kind: "PresentationExpression",
      input,
      presenter: { target, args, range: range(first.from, to) },
      range: range(input.range.from, to),
    };
  }

  private parseParameterList(): CalcParameter[] {
    const params: CalcParameter[] = [];
    if (this.peek().kind === ")") return params;

    while (true) {
      const token = this.peek();
      if (token.kind !== "identifier") {
        this.pushDiagnostic(
          "calc.invalid-parameter-list",
          "Expected a parameter name.",
          token.from,
          token.to,
        );
        throw new ParseAbort();
      }
      this.checkBindingName(token);
      if (params.some((param) => param.name === token.value)) {
        this.pushDiagnostic(
          "calc.duplicate-parameter",
          `Parameter '${token.value}' is repeated.`,
          token.from,
          token.to,
        );
        throw new ParseAbort();
      }
      this.consume();
      params.push({ name: token.value, range: range(token.from, token.to) });
      if (!this.match(",")) break;
    }

    return params;
  }

  private looksLikeFunctionDefinition(): boolean {
    if (this.peek().kind !== "identifier" || this.peek(1).kind !== "(") return false;

    let cursor = this.index + 2;
    const first = this.tokens[cursor];
    if (!first) return false;

    if (first.kind === ")") {
      cursor += 1;
      return this.tokens[cursor]?.kind === "=";
    }

    while (true) {
      const token = this.tokens[cursor];
      if (!token || token.kind !== "identifier") return false;
      cursor += 1;
      const separator = this.tokens[cursor];
      if (!separator) return false;
      if (separator.kind === ",") {
        cursor += 1;
        continue;
      }
      if (separator.kind === ")") {
        cursor += 1;
        break;
      }
      return false;
    }

    return this.tokens[cursor]?.kind === "=";
  }

  private nested<T>(parse: () => T): T {
    if (this.depth >= 128) {
      const token = this.peek();
      this.pushDiagnostic(
        "calc.resource-limit",
        "Expression nesting exceeds 128.",
        token.from,
        token.to,
      );
      throw new ParseAbort();
    }
    this.depth++;
    try {
      return parse();
    } finally {
      this.depth--;
    }
  }

  private parseExpression(): CalcExpression {
    return this.nested(() => this.parsePipeExpression());
  }

  private parsePipeExpression(): CalcExpression {
    let expression = this.parseComparisonExpression();

    while (this.peek().kind === "|>" || this.peek().kind === "@") {
      this.consume();
      const operator = this.tokens[this.index - 1]!;
      const stage = this.parsePipeStage();
      expression = {
        kind: "PipeExpression",
        input: expression,
        stage,
        range: range(expression.range.from, stage.range.to),
      };

      if (stage.range.from === operator.to) {
        continue;
      }
    }

    return expression;
  }

  private parsePipeStage(): CalcPipeStage {
    const callee = this.parseReferenceExpression();
    let args: CalcExpression[] = [];
    let to = callee.range.to;

    if (this.match("(")) {
      args = this.parseArgumentList(")");
      const closing = this.expect(")", "Expected ')' after pipe stage arguments.");
      to = closing.to;
    }

    return {
      kind: "PipeStage",
      callee,
      args,
      range: range(callee.range.from, to),
    };
  }

  private parseComparisonExpression(): CalcExpression {
    let expression = this.parseAdditiveExpression();

    while (true) {
      const token = this.peek();
      if (!["==", "!=", "<", "<=", ">", ">="].includes(token.kind)) break;
      this.consume();
      const right = this.parseAdditiveExpression();
      expression = {
        kind: "BinaryExpression",
        operator: token.kind as CalcBinaryExpression["operator"],
        left: expression,
        right,
        range: range(expression.range.from, right.range.to),
      };
    }

    return expression;
  }

  private parseAdditiveExpression(): CalcExpression {
    let expression = this.parseMultiplicativeExpression();

    while (true) {
      const token = this.peek();
      if (token.kind !== "+" && token.kind !== "-") break;
      this.consume();
      const right = this.parseMultiplicativeExpression();
      expression = {
        kind: "BinaryExpression",
        operator: token.kind,
        left: expression,
        right,
        range: range(expression.range.from, right.range.to),
      };
    }

    return expression;
  }

  private parseMultiplicativeExpression(): CalcExpression {
    let expression = this.parseUnaryExpression();

    while (true) {
      const token = this.peek();
      if (token.kind !== "*" && token.kind !== "/" && token.kind !== "//") break;
      this.consume();
      const right = this.parseUnaryExpression();
      expression = {
        kind: "BinaryExpression",
        operator: token.kind,
        left: expression,
        right,
        range: range(expression.range.from, right.range.to),
      };
    }

    return expression;
  }

  private parseUnaryExpression(): CalcExpression {
    return this.nested(() => this.parseUnaryOperand());
  }

  private parseUnaryOperand(): CalcExpression {
    const token = this.peek();
    if (token.kind === "-") {
      this.consume();
      const operand = this.parseUnaryExpression();
      return {
        kind: "UnaryExpression",
        operator: "-",
        operand,
        range: range(token.from, operand.range.to),
      };
    }

    return this.parsePowerExpression();
  }

  private parsePowerExpression(): CalcExpression {
    const left = this.parsePostfixExpression();
    if (!this.match("^")) return left;

    const operator = this.tokens[this.index - 1]!;
    const right = this.parseUnaryExpression();
    return {
      kind: "BinaryExpression",
      operator: "^",
      left,
      right,
      range: range(left.range.from, right.range.to),
    };
  }

  private parsePostfixExpression(): CalcExpression {
    let expression = this.parsePrimaryExpression();

    while (true) {
      if (this.match(".")) {
        const property = this.expect("identifier", "Expected property name after '.'.");
        expression = {
          kind: "MemberExpression",
          object: this.ensureReferenceExpression(expression, property),
          property: property.value,
          propertyRange: range(property.from, property.to),
          range: range(expression.range.from, property.to),
        };
        continue;
      }

      if (this.match("(")) {
        const args = this.parseArgumentList(")");
        const closing = this.expect(")", "Expected ')' after function arguments.");
        expression = {
          kind: "CallExpression",
          callee: expression,
          args,
          range: range(expression.range.from, closing.to),
        };
        continue;
      }

      break;
    }

    return expression;
  }

  private parsePrimaryExpression(): CalcExpression {
    const token = this.peek();

    switch (token.kind) {
      case "quantity": {
        this.consume();
        return {
          kind: "QuantityLiteral",
          raw: token.value,
          unit: token.unit!,
          unitRange: range(token.unitFrom!, token.to),
          range: range(token.from, token.to),
        };
      }
      case "imaginary": {
        this.consume();
        return { kind: "ImaginaryLiteral", raw: token.value, range: range(token.from, token.to) };
      }
      case "number": {
        this.consume();
        return {
          kind: "NumberLiteral",
          value: parseCalcNumericLiteral(token.value),
          raw: token.value,
          range: range(token.from, token.to),
        };
      }

      case "string": {
        this.consume();
        return {
          kind: "StringLiteral",
          value: token.value,
          raw: this.source.slice(token.from, token.to),
          range: range(token.from, token.to),
        };
      }

      case "true":
      case "false": {
        this.consume();
        return {
          kind: "BooleanLiteral",
          value: token.kind === "true",
          range: range(token.from, token.to),
        };
      }

      case "null": {
        this.consume();
        return {
          kind: "NullLiteral",
          value: null,
          range: range(token.from, token.to),
        };
      }

      case "identifier": {
        if (token.value === "as" || token.value === "symbol") {
          this.pushExpectedExpression(token);
          throw new ParseAbort();
        }
        this.consume();
        return {
          kind: "Identifier",
          name: token.value,
          range: range(token.from, token.to),
        };
      }

      case "[": {
        return this.parseListExpression();
      }

      case "(": {
        const open = this.consume();
        const expression = this.parseExpression();
        const close = this.expect(")", "Expected ')' after expression.");
        return {
          ...expression,
          range: range(open.from, close.to),
        };
      }

      default:
        this.pushExpectedExpression(token);
        throw new ParseAbort();
    }
  }

  private word(word: string): boolean {
    return this.peek().kind === "identifier" && this.peek().value === word;
  }

  private parseListExpression(): CalcListExpression | CalcListComprehensionExpression {
    const open = this.consume();
    if (this.match("]"))
      return {
        kind: "ListExpression",
        elements: [],
        range: range(open.from, this.tokens[this.index - 1]!.to),
      };
    const element = this.parseExpression();
    if (this.word("for")) {
      const forToken = this.consume();
      const binding = this.expect("identifier", "Expected one variable name after 'for'.");
      this.checkBindingName(binding);
      if (!this.word("in")) {
        const token = this.peek();
        this.pushDiagnostic(
          "calc.expected-token",
          "Expected 'in' after the comprehension variable.",
          token.from,
          token.to,
        );
        throw new ParseAbort();
      }
      const inToken = this.consume();
      const iterable = this.parseExpression();
      const ifToken = this.word("if") ? this.consume() : null;
      const condition = ifToken ? this.parseExpression() : null;
      if (this.word("for") || this.word("if")) {
        const token = this.peek();
        this.pushDiagnostic(
          "calc.unsupported-comprehension",
          "A comprehension supports one 'for' clause and one optional 'if' filter.",
          token.from,
          token.to,
        );
        throw new ParseAbort();
      }
      const close = this.expect("]", "Expected ']' after list comprehension.");
      return {
        kind: "ListComprehension",
        element,
        binding: { name: binding.value, range: range(binding.from, binding.to) },
        iterable,
        condition,
        forRange: range(forToken.from, forToken.to),
        inRange: range(inToken.from, inToken.to),
        ifRange: ifToken ? range(ifToken.from, ifToken.to) : null,
        range: range(open.from, close.to),
      };
    }
    const elements = [element];
    while (this.match(",")) {
      if (this.peek().kind === "]") {
        this.pushDiagnostic(
          "calc.unexpected-token",
          "Trailing commas are not supported here.",
          this.peek().from,
          this.peek().to,
        );
        throw new ParseAbort();
      }
      elements.push(this.parseExpression());
    }
    const close = this.expect("]", "Expected ']' after list literal.");
    return { kind: "ListExpression", elements, range: range(open.from, close.to) };
  }

  private parseReferenceExpression(): CalcReferenceExpression {
    const first = this.peek();
    if (first.kind !== "identifier") {
      this.pushDiagnostic(
        "calc.invalid-pipe-target",
        "Expected a callable name for this stage.",
        first.from,
        first.to,
      );
      throw new ParseAbort();
    }

    this.consume();
    let reference: CalcReferenceExpression = {
      kind: "Identifier",
      name: first.value,
      range: range(first.from, first.to),
    };

    while (this.match(".")) {
      const property = this.expect("identifier", "Expected property name after '.'.");
      reference = {
        kind: "MemberExpression",
        object: reference,
        property: property.value,
        propertyRange: range(property.from, property.to),
        range: range(reference.range.from, property.to),
      };
    }

    return reference;
  }

  private parseArgumentList(closingKind: ")" | "]"): CalcExpression[] {
    const args: CalcExpression[] = [];
    if (this.peek().kind === closingKind) return args;

    while (true) {
      args.push(this.parseExpression());
      if (!this.match(",")) break;
      if (this.peek().kind === closingKind) {
        this.pushDiagnostic(
          "calc.unexpected-token",
          "Trailing commas are not supported here.",
          this.peek().from,
          this.peek().to,
        );
        throw new ParseAbort();
      }
    }

    return args;
  }

  private ensureReferenceExpression(
    expression: CalcExpression,
    token: CalcToken,
  ): CalcReferenceExpression {
    if (expression.kind === "Identifier" || expression.kind === "MemberExpression") {
      return expression;
    }

    this.pushDiagnostic(
      "calc.invalid-member-access",
      "Only identifier-like expressions can be used with '.'.",
      expression.range.from,
      token.to,
    );
    throw new ParseAbort();
  }

  private peek(offset = 0): CalcToken {
    return this.tokens[Math.min(this.index + offset, this.tokens.length - 1)]!;
  }

  private consume(): CalcToken {
    const token = this.peek();
    this.index = Math.min(this.index + 1, this.tokens.length - 1);
    return token;
  }

  private match(kind: CalcTokenKind): boolean {
    if (this.peek().kind !== kind) return false;
    this.consume();
    return true;
  }

  private expect(kind: CalcTokenKind, message: string): CalcToken {
    const token = this.peek();
    if (token.kind === kind) {
      return this.consume();
    }
    this.pushDiagnostic("calc.expected-token", message, token.from, token.to);
    throw new ParseAbort();
  }

  private pushExpectedExpression(token: CalcToken): void {
    this.pushDiagnostic(
      "calc.expected-expression",
      "Expected an expression.",
      token.from,
      token.to,
    );
  }

  private pushDiagnostic(code: string, message: string, from: number, to: number): void {
    this.diagnostics.push(diagnostic(code, message, from, to));
  }
}

function annotateDiagnosticLine(
  diag: CalcDiagnostic,
  line: number,
  lineStart: number,
): CalcDiagnostic {
  return {
    ...diag,
    line,
    column: Math.max(1, diag.from - lineStart + 1),
  };
}

function offsetRange(input: CalcRange, offset: number): CalcRange {
  return {
    from: input.from + offset,
    to: input.to + offset,
  };
}

export function offsetExpression(expression: CalcExpression, offset: number): CalcExpression {
  switch (expression.kind) {
    case "QuantityLiteral":
      return {
        ...expression,
        range: offsetRange(expression.range, offset),
        unitRange: offsetRange(expression.unitRange, offset),
      };
    case "ImaginaryLiteral":
      return { ...expression, range: offsetRange(expression.range, offset) };
    case "PresentationExpression":
      return {
        ...expression,
        input: offsetExpression(expression.input, offset),
        range: offsetRange(expression.range, offset),
        presenter: {
          ...expression.presenter,
          range: offsetRange(expression.presenter.range, offset),
          args: expression.presenter.args.map((arg) => offsetExpression(arg, offset)),
          target:
            expression.presenter.target.kind === "UnitPresenter"
              ? {
                  ...expression.presenter.target,
                  range: offsetRange(expression.presenter.target.range, offset),
                }
              : offsetReferenceExpression(expression.presenter.target, offset),
        },
      };

    case "NumberLiteral":
    case "BooleanLiteral":
    case "NullLiteral":
    case "StringLiteral":
    case "Identifier":
      return {
        ...expression,
        range: offsetRange(expression.range, offset),
      };

    case "MemberExpression":
      return {
        ...expression,
        object: offsetReferenceExpression(expression.object, offset),
        propertyRange: offsetRange(expression.propertyRange, offset),
        range: offsetRange(expression.range, offset),
      };

    case "CallExpression":
      return {
        ...expression,
        callee: offsetExpression(expression.callee, offset),
        args: expression.args.map((arg) => offsetExpression(arg, offset)),
        range: offsetRange(expression.range, offset),
      };

    case "UnaryExpression":
      return {
        ...expression,
        operand: offsetExpression(expression.operand, offset),
        range: offsetRange(expression.range, offset),
      };

    case "BinaryExpression":
      return {
        ...expression,
        left: offsetExpression(expression.left, offset),
        right: offsetExpression(expression.right, offset),
        range: offsetRange(expression.range, offset),
      };

    case "ListExpression":
      return {
        ...expression,
        elements: expression.elements.map((element) => offsetExpression(element, offset)),
        range: offsetRange(expression.range, offset),
      };

    case "ListComprehension":
      return {
        ...expression,
        element: offsetExpression(expression.element, offset),
        binding: { ...expression.binding, range: offsetRange(expression.binding.range, offset) },
        iterable: offsetExpression(expression.iterable, offset),
        condition: expression.condition ? offsetExpression(expression.condition, offset) : null,
        forRange: offsetRange(expression.forRange, offset),
        inRange: offsetRange(expression.inRange, offset),
        ifRange: expression.ifRange ? offsetRange(expression.ifRange, offset) : null,
        range: offsetRange(expression.range, offset),
      };

    case "PipeExpression":
      return {
        ...expression,
        input: offsetExpression(expression.input, offset),
        stage: {
          ...expression.stage,
          callee: offsetReferenceExpression(expression.stage.callee, offset),
          args: expression.stage.args.map((arg) => offsetExpression(arg, offset)),
          range: offsetRange(expression.stage.range, offset),
        },
        range: offsetRange(expression.range, offset),
      };
  }
}

function offsetReferenceExpression(
  expression: CalcReferenceExpression,
  offset: number,
): CalcReferenceExpression {
  if (expression.kind === "Identifier") {
    return {
      ...expression,
      range: offsetRange(expression.range, offset),
    };
  }

  return {
    ...expression,
    object: offsetReferenceExpression(expression.object, offset),
    propertyRange: offsetRange(expression.propertyRange, offset),
    range: offsetRange(expression.range, offset),
  };
}

export function offsetStatement(statement: CalcStatement, offset: number): CalcStatement {
  switch (statement.kind) {
    case "SymbolDeclaration":
      return {
        ...statement,
        symbols: statement.symbols.map((symbol) => ({
          ...symbol,
          range: offsetRange(symbol.range, offset),
        })),
        range: offsetRange(statement.range, offset),
      };

    case "ValueDefinition":
      return {
        ...statement,
        nameRange: offsetRange(statement.nameRange, offset),
        value: offsetExpression(statement.value, offset),
        range: offsetRange(statement.range, offset),
      };

    case "FunctionDefinition":
      return {
        ...statement,
        nameRange: offsetRange(statement.nameRange, offset),
        params: statement.params.map((param) => ({
          ...param,
          range: offsetRange(param.range, offset),
        })),
        body: offsetExpression(statement.body, offset),
        range: offsetRange(statement.range, offset),
      };

    case "ExpressionStatement":
      return {
        ...statement,
        expression: offsetExpression(statement.expression, offset),
        range: offsetRange(statement.range, offset),
      };
  }
}

export function parseCalcExpression(source: string): CalcExpressionParseResult {
  const lexed = tokenizeCalcSource(source);
  const parser = new CalcParser(source, lexed.tokens, lexed.diagnostics);
  return {
    source,
    expression: parser.parseExpressionRoot(),
    diagnostics: parser.diagnostics,
  };
}

export function parseCalcStatement(source: string): CalcStatementParseResult {
  const lexed = tokenizeCalcSource(source);
  const parser = new CalcParser(source, lexed.tokens, lexed.diagnostics);
  return {
    source,
    statement: parser.parseStatementRoot(),
    diagnostics: parser.diagnostics,
  };
}

function parseReactiveCalcBlockLine(source: string): {
  statement: CalcStatement | null;
  reactiveOutput: CalcReactiveSourceSplit;
  diagnostics: CalcDiagnostic[];
} {
  const reactiveOutput = splitReactiveCalcSource(source);
  if (!reactiveOutput) {
    throw new Error("Expected reactive calc source split.");
  }

  if (!reactiveOutput.expressionSource.trim()) {
    return {
      statement: null,
      reactiveOutput,
      diagnostics: [
        diagnostic(
          "calc.empty-reactive-expression",
          "Reactive calc line cannot have an empty expression.",
          0,
          reactiveOutput.separatorRange.to,
        ),
      ],
    };
  }

  const parsed = parseCalcStatement(reactiveOutput.expressionSource);
  if (
    parsed.statement?.kind === "FunctionDefinition" ||
    parsed.statement?.kind === "SymbolDeclaration"
  ) {
    return {
      statement: null,
      reactiveOutput,
      diagnostics: [
        diagnostic(
          "calc.invalid-reactive-statement",
          "Reactive calc lines support value definitions and expressions, not function definitions.",
          parsed.statement.range.from,
          parsed.statement.range.to,
        ),
      ],
    };
  }
  return {
    statement: parsed.statement,
    reactiveOutput,
    diagnostics: parsed.diagnostics,
  };
}

function stripCalcLineComment(source: string): string {
  let quote: "'" | '"' | null = null;
  let escaped = false;

  for (let index = 0; index < source.length; index += 1) {
    const char = source[index]!;
    if (quote) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === quote) quote = null;
      continue;
    }
    if (char === '"' || char === "'") quote = char;
    else if (char === "#" || char === ";") return source.slice(0, index);
  }

  return source;
}

export function parseCalcBlock(source: string): CalcBlockParseResult {
  const rawLines = source.split("\n");
  const lines: CalcBlockLine[] = [];
  const statements: CalcStatement[] = [];
  const diagnostics: CalcDiagnostic[] = [];
  let lineStart = 0;

  for (let index = 0; index < rawLines.length; index += 1) {
    const text = rawLines[index] ?? "";
    const lineNo = index + 1;
    const from = lineStart;
    const to = from + text.length;
    lineStart = to + 1;

    if (!text.trim()) {
      lines.push({
        kind: "blank",
        line: lineNo,
        from,
        to,
        text,
        statement: null,
        reactiveOutput: null,
        diagnostics: [],
      });
      continue;
    }

    const code = stripCalcLineComment(text);
    if (!code.trim()) {
      lines.push({
        kind: "comment",
        line: lineNo,
        from,
        to,
        text,
        statement: null,
        reactiveOutput: null,
        diagnostics: [],
      });
      continue;
    }

    const parsedReactiveOutput = splitReactiveCalcSource(code);
    const parsed = parsedReactiveOutput
      ? parseReactiveCalcBlockLine(code)
      : parseCalcStatement(code);
    const rebasedStatement = parsed.statement ? offsetStatement(parsed.statement, from) : null;
    const rebasedReactiveOutput = parsedReactiveOutput
      ? {
          ...parsedReactiveOutput,
          separatorRange: offsetRange(parsedReactiveOutput.separatorRange, from),
          outputRange: offsetRange(parsedReactiveOutput.outputRange, from),
        }
      : null;
    const rebasedDiagnostics = parsed.diagnostics.map((diag) =>
      annotateDiagnosticLine(
        {
          ...diag,
          from: diag.from + from,
          to: diag.to + from,
        },
        lineNo,
        from,
      ),
    );

    if (rebasedStatement) statements.push(rebasedStatement);
    diagnostics.push(...rebasedDiagnostics);
    lines.push({
      kind: "statement",
      line: lineNo,
      from,
      to,
      text,
      statement: rebasedStatement,
      reactiveOutput: rebasedReactiveOutput,
      diagnostics: rebasedDiagnostics,
    });
  }

  return {
    source,
    statements,
    lines,
    diagnostics,
  };
}
