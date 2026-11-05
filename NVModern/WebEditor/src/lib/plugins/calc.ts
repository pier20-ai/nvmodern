import type { HelpOpenRequest } from "../help/model.ts";
import {
  Annotation,
  EditorState,
  StateField,
  type ChangeSpec,
  type Extension,
  type Range,
  type Text,
  type Transaction,
  type TransactionSpec,
} from "@codemirror/state";
import {
  Decoration,
  EditorView,
  type DecorationSet,
  ViewPlugin,
  WidgetType,
  type ViewUpdate,
} from "@codemirror/view";
import {
  offsetExpression as offsetExpressionForDecoration,
  offsetStatement as offsetStatementForDecoration,
  parseCalcBlock,
  parseCalcExpression,
  splitReactiveCalcSource,
  type CalcBlockParseResult,
  type CalcDiagnostic,
  type CalcExpression,
  type CalcReferenceExpression,
  type CalcStatement,
} from "../calc/parser.ts";
import {
  createCalcRuntimeScope,
  evaluateCalcBlock,
  evaluateCalcExpression,
  formatCalcRuntimeValue,
  type CalcEvaluationResult,
  type CalcRuntimeScope,
  type CalcRuntimeValue,
} from "../calc/runtime.ts";
import { createMarkdownScannerContext, isMarkdownLineScannable } from "./scannerContext.ts";
import { detectFrontmatterBounds, isEscaped, rangeContainsIndex } from "./scanUtils.ts";
import { isCalcPlot, formatCalcPresentation, type CalcPlot } from "../calc/plot.ts";
import { CalcPlotWidget } from "./calcPlot.ts";
import { createCalcDiscoveryExtension } from "./calcDiscovery.ts";
import { selectionTouchesRange } from "./viewUtils.ts";

const FENCE_PATTERN = /^\s*```(.*)$/;
const FENCE_INFO_PATTERN = /^\s*```+\s*([^\s`{(]+)/;

const markDecorationCache = new Map<string, Decoration>();

export interface Nv3MarkdownCalcInlineExpression {
  source: string;
  expressionSource: string;
  outputSource: string | null;
  separator: "->" | "→" | null;
  from: number;
  to: number;
  line: number;
  expressionFrom: number;
  expressionTo: number;
  separatorFrom: number | null;
  separatorTo: number | null;
  outputFrom: number | null;
  outputTo: number | null;
  expression: CalcExpression | null;
  diagnostics: CalcDiagnostic[];
}

export interface Nv3MarkdownCalcFence {
  source: string;
  fromLine: number;
  toLine: number;
  bodyFrom: number;
  bodyTo: number;
  closed: boolean;
  result: CalcBlockParseResult;
  diagnostics: CalcDiagnostic[];
}

export interface Nv3MarkdownCalcDocument {
  inlineExpressions: Nv3MarkdownCalcInlineExpression[];
  fences: Nv3MarkdownCalcFence[];
  diagnostics: CalcDiagnostic[];
}

export interface Nv3MarkdownCalcInlineEvaluation {
  from: number;
  to: number;
  reactive: boolean;
  outputFrom: number | null;
  outputTo: number | null;
  result: CalcEvaluationResult;
}

export interface Nv3MarkdownCalcFenceOutput {
  lineFrom: number;
  lineTo: number;
  statementFrom: number;
  statementTo: number;
  reactive: boolean;
  separatorFrom: number | null;
  separatorTo: number | null;
  outputFrom: number | null;
  outputTo: number | null;
  result: CalcEvaluationResult;
}

export interface Nv3MarkdownCalcEvaluation {
  inlineEvaluations: Nv3MarkdownCalcInlineEvaluation[];
  fenceOutputs: Nv3MarkdownCalcFenceOutput[];
}

interface Nv3MarkdownCalcState {
  document: Nv3MarkdownCalcDocument;
  evaluation: Nv3MarkdownCalcEvaluation;
  decorations: DecorationSet;
}

export interface MarkdownCalcExtensionOptions {
  onHelpOpen?: (request: HelpOpenRequest) => void;
  onChange?: (document: Nv3MarkdownCalcDocument) => void;
}

const reactiveCalcAnnotation = Annotation.define<boolean>();

interface ReactiveCalcSourceChange {
  from: number;
  to: number;
  insert: string;
}

function markDecoration(className: string): Decoration {
  const cached = markDecorationCache.get(className);
  if (cached) return cached;
  const decoration = Decoration.mark({ class: className });
  markDecorationCache.set(className, decoration);
  return decoration;
}

function normalizeFenceInfo(info: string): string {
  const trimmed = info.trim().toLowerCase();
  if (!trimmed) return "";
  const separator = trimmed.search(/[\s,{(]/);
  const head = separator < 0 ? trimmed : trimmed.slice(0, separator);
  return head.replace(/^language-/, "");
}

function offsetDiagnostic(diag: CalcDiagnostic, offset: number, lineOffset = 0): CalcDiagnostic {
  return {
    ...diag,
    from: diag.from + offset,
    to: diag.to + offset,
    line: typeof diag.line === "number" ? diag.line + lineOffset : diag.line,
  };
}

function formatReactiveFenceValue(value: CalcRuntimeValue): string {
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(formatReactiveFenceValue).join(", ")}]`;
  return formatCalcRuntimeValue(value);
}

function serializePresenterText(text: string, inline: boolean): string {
  return !text ||
    /[#;'"\\\r\n]/.test(text) ||
    /^\s|\s$/.test(text) ||
    (inline && text.includes("}}"))
    ? JSON.stringify(text)
    : text;
}

function formatReactiveCalcResult(result: CalcEvaluationResult, fence = false): string {
  const error = result.ok ? result.presentationError : result.error;
  if (error) return serializePresenterText(`⚠ ${error.message}`, !fence);
  if (result.ok && result.presentation !== undefined)
    return serializePresenterText(formatCalcPresentation(result.presentation), !fence);
  return (
    result.ok
      ? fence
        ? formatReactiveFenceValue(result.value)
        : typeof result.value === "string"
          ? serializePresenterText(result.value, true)
          : Array.isArray(result.value)
            ? formatReactiveFenceValue(result.value)
            : formatCalcRuntimeValue(result.value)
      : `⚠ ${result.error.message}`
  )
    .replace(/\s*\n\s*/g, " ")
    .trim();
}

function transactionAsSpec(transaction: Transaction): TransactionSpec {
  return transaction as unknown as TransactionSpec;
}

function scanInlineExpressions(doc: Text): {
  expressions: Nv3MarkdownCalcInlineExpression[];
  diagnostics: CalcDiagnostic[];
} {
  const context = createMarkdownScannerContext(doc);
  const expressions: Nv3MarkdownCalcInlineExpression[] = [];
  const diagnostics: CalcDiagnostic[] = [];

  for (const line of context.lines) {
    if (!isMarkdownLineScannable(line)) continue;

    const text = line.text;
    for (let index = 0; index < text.length - 1; index += 1) {
      if (text[index] !== "{" || text[index + 1] !== "{") continue;
      if (isEscaped(text, index)) continue;
      if (
        rangeContainsIndex(line.inlineCodeRanges, index) ||
        rangeContainsIndex(line.inlineCodeRanges, index + 1)
      ) {
        continue;
      }

      let closeIndex = -1;
      let quote: string | null = null,
        escaped = false;
      for (let cursor = index + 2; cursor < text.length - 1; cursor += 1) {
        const char = text[cursor];
        if (quote) {
          if (escaped) escaped = false;
          else if (char === "\\") escaped = true;
          else if (char === quote) quote = null;
          continue;
        }
        if (char === '"' || char === "'") {
          quote = char;
          continue;
        }
        if (char === "}" && text[cursor + 1] === "}" && !isEscaped(text, cursor)) {
          closeIndex = cursor;
          break;
        }
      }

      if (closeIndex < 0) {
        for (let cursor = index + 2; cursor < text.length - 1; cursor++) {
          if (text[cursor] !== "}" || text[cursor + 1] !== "}" || isEscaped(text, cursor)) continue;
          if (splitReactiveCalcSource(text.slice(index + 2, cursor))) {
            closeIndex = cursor;
            break;
          }
        }
      }

      if (closeIndex < 0) {
        diagnostics.push({
          code: "calc.unclosed-inline-expression",
          message: "Unclosed inline calc expression.",
          severity: "error",
          from: line.from + index,
          to: line.to,
          line: line.lineNo,
          column: index + 1,
        });
        break;
      }

      const source = text.slice(index + 2, closeIndex);
      const reactiveSplit = splitReactiveCalcSource(source);
      const expressionSource = reactiveSplit?.expressionSource ?? source;
      const expressionBaseFrom = line.from + index + 2;
      const parsed = parseCalcExpression(expressionSource);
      const rebasedDiagnostics = parsed.diagnostics.map((diag) => ({
        ...diag,
        from: diag.from + expressionBaseFrom,
        to: diag.to + expressionBaseFrom,
        line: line.lineNo,
        column: diag.from + index + 3,
      }));

      if (!expressionSource.trim()) {
        rebasedDiagnostics.push({
          code: "calc.empty-inline-expression",
          message: "Inline calc expression cannot be empty.",
          severity: "error",
          from: line.from + index,
          to: line.from + closeIndex + 2,
          line: line.lineNo,
          column: index + 1,
        });
      }

      const occurrence: Nv3MarkdownCalcInlineExpression = {
        source,
        expressionSource,
        outputSource: reactiveSplit?.outputSource ?? null,
        separator: reactiveSplit?.separator ?? null,
        from: line.from + index,
        to: line.from + closeIndex + 2,
        line: line.lineNo,
        expressionFrom: expressionBaseFrom,
        expressionTo: expressionBaseFrom + expressionSource.length,
        separatorFrom: reactiveSplit
          ? expressionBaseFrom + reactiveSplit.separatorRange.from
          : null,
        separatorTo: reactiveSplit ? expressionBaseFrom + reactiveSplit.separatorRange.to : null,
        outputFrom: reactiveSplit ? expressionBaseFrom + reactiveSplit.outputRange.from : null,
        outputTo: reactiveSplit ? expressionBaseFrom + reactiveSplit.outputRange.to : null,
        expression: parsed.expression
          ? offsetExpressionForDecoration(parsed.expression, expressionBaseFrom)
          : null,
        diagnostics: rebasedDiagnostics,
      };

      expressions.push(occurrence);
      diagnostics.push(...rebasedDiagnostics);
      index = closeIndex + 1;
    }
  }

  return { expressions, diagnostics };
}

export function scanMarkdownCalcDocument(doc: Text | string): Nv3MarkdownCalcDocument {
  const textDoc = typeof doc === "string" ? EditorState.create({ doc }).doc : doc;
  const { expressions: inlineExpressions, diagnostics: inlineDiagnostics } =
    scanInlineExpressions(textDoc);
  const frontmatter = detectFrontmatterBounds(textDoc);
  const fences: Nv3MarkdownCalcFence[] = [];
  const diagnostics: CalcDiagnostic[] = [...inlineDiagnostics];

  const isFrontmatterLine = (lineNo: number): boolean => {
    return Boolean(frontmatter && lineNo >= frontmatter.fromLine && lineNo <= frontmatter.toLine);
  };

  let activeFence: { fromLine: number; info: string } | null = null;

  for (let lineNo = 1; lineNo <= textDoc.lines; lineNo += 1) {
    const line = textDoc.line(lineNo);
    if (isFrontmatterLine(lineNo)) continue;

    const fenceMatch = line.text.match(FENCE_PATTERN);
    if (!fenceMatch) continue;

    if (!activeFence) {
      activeFence = {
        fromLine: lineNo,
        info: normalizeFenceInfo(fenceMatch[1] ?? ""),
      };
      continue;
    }

    const opening = activeFence;
    activeFence = null;
    if (opening.info !== "calc") continue;

    const bodyLines: string[] = [];
    for (let bodyLineNo = opening.fromLine + 1; bodyLineNo < lineNo; bodyLineNo += 1) {
      bodyLines.push(textDoc.line(bodyLineNo).text);
    }
    const source = bodyLines.join("\n");
    const result = parseCalcBlock(source);
    const bodyFrom = opening.fromLine < lineNo ? textDoc.line(opening.fromLine).to + 1 : line.from;
    const bodyTo = line.from;
    const rebasedDiagnostics = result.diagnostics.map((diag) =>
      offsetDiagnostic(diag, bodyFrom, opening.fromLine),
    );

    diagnostics.push(...rebasedDiagnostics);
    fences.push({
      source,
      fromLine: opening.fromLine,
      toLine: lineNo,
      bodyFrom,
      bodyTo,
      closed: true,
      result,
      diagnostics: rebasedDiagnostics,
    });
  }

  if (activeFence?.info === "calc") {
    const bodyLines: string[] = [];
    for (let bodyLineNo = activeFence.fromLine + 1; bodyLineNo <= textDoc.lines; bodyLineNo += 1) {
      bodyLines.push(textDoc.line(bodyLineNo).text);
    }
    const source = bodyLines.join("\n");
    const result = parseCalcBlock(source);
    const bodyFrom =
      activeFence.fromLine < textDoc.lines
        ? textDoc.line(activeFence.fromLine).to + 1
        : textDoc.line(activeFence.fromLine).to;
    const bodyTo = textDoc.length;
    const rebasedDiagnostics = result.diagnostics.map((diag) =>
      offsetDiagnostic(diag, bodyFrom, activeFence.fromLine),
    );

    diagnostics.push(
      {
        code: "calc.unclosed-fence",
        message: "Unclosed calc code fence.",
        severity: "error",
        from: textDoc.line(activeFence.fromLine).from,
        to: textDoc.line(activeFence.fromLine).to,
        line: activeFence.fromLine,
        column: 1,
      },
      ...rebasedDiagnostics,
    );

    fences.push({
      source,
      fromLine: activeFence.fromLine,
      toLine: textDoc.lines,
      bodyFrom,
      bodyTo,
      closed: false,
      result,
      diagnostics: rebasedDiagnostics,
    });
  }

  return {
    inlineExpressions,
    fences,
    diagnostics,
  };
}

function addReferenceDecorations(
  ranges: Range<Decoration>[],
  reference: CalcReferenceExpression,
  leafClass = "nv3-calc-name",
): void {
  if (reference.kind === "Identifier") {
    ranges.push(markDecoration(leafClass).range(reference.range.from, reference.range.to));
    return;
  }

  addReferenceDecorations(ranges, reference.object, "nv3-calc-namespace");
  ranges.push(
    markDecoration(leafClass).range(reference.propertyRange.from, reference.propertyRange.to),
  );
}

function addExpressionDecorations(ranges: Range<Decoration>[], expression: CalcExpression): void {
  switch (expression.kind) {
    case "QuantityLiteral":
    case "ImaginaryLiteral":
      ranges.push(
        markDecoration("nv3-calc-number").range(expression.range.from, expression.range.to),
      );
      return;
    case "PresentationExpression":
      addExpressionDecorations(ranges, expression.input);
      if (expression.presenter.target.kind === "UnitPresenter") {
        ranges.push(
          markDecoration("nv3-calc-callable").range(
            expression.presenter.target.range.from,
            expression.presenter.target.range.to,
          ),
        );
      } else addReferenceDecorations(ranges, expression.presenter.target, "nv3-calc-callable");
      for (const arg of expression.presenter.args) addExpressionDecorations(ranges, arg);
      return;

    case "NumberLiteral":
      ranges.push(
        markDecoration("nv3-calc-number").range(expression.range.from, expression.range.to),
      );
      return;

    case "BooleanLiteral":
    case "NullLiteral":
      ranges.push(
        markDecoration("nv3-calc-atom").range(expression.range.from, expression.range.to),
      );
      return;

    case "StringLiteral":
      ranges.push(
        markDecoration("nv3-calc-string").range(expression.range.from, expression.range.to),
      );
      return;

    case "Identifier":
      ranges.push(
        markDecoration("nv3-calc-name").range(expression.range.from, expression.range.to),
      );
      return;

    case "MemberExpression":
      addReferenceDecorations(ranges, expression, "nv3-calc-property");
      return;

    case "CallExpression":
      if (
        expression.callee.kind === "Identifier" ||
        expression.callee.kind === "MemberExpression"
      ) {
        addReferenceDecorations(ranges, expression.callee, "nv3-calc-callable");
      } else {
        addExpressionDecorations(ranges, expression.callee);
      }
      for (const arg of expression.args) addExpressionDecorations(ranges, arg);
      return;

    case "UnaryExpression":
      addExpressionDecorations(ranges, expression.operand);
      return;

    case "BinaryExpression":
      addExpressionDecorations(ranges, expression.left);
      addExpressionDecorations(ranges, expression.right);
      return;

    case "ListExpression":
      for (const element of expression.elements) addExpressionDecorations(ranges, element);
      return;

    case "ListComprehension":
      addExpressionDecorations(ranges, expression.element);
      addExpressionDecorations(ranges, expression.iterable);
      if (expression.condition) addExpressionDecorations(ranges, expression.condition);
      ranges.push(
        markDecoration("nv3-calc-definition").range(
          expression.binding.range.from,
          expression.binding.range.to,
        ),
      );
      for (const keyword of [expression.forRange, expression.inRange, expression.ifRange]) {
        if (keyword)
          ranges.push(markDecoration("nv3-calc-keyword").range(keyword.from, keyword.to));
      }
      return;

    case "PipeExpression":
      addExpressionDecorations(ranges, expression.input);
      addReferenceDecorations(ranges, expression.stage.callee, "nv3-calc-callable");
      for (const arg of expression.stage.args) addExpressionDecorations(ranges, arg);
      return;
  }
}

function addStatementDecorations(ranges: Range<Decoration>[], statement: CalcStatement): void {
  ranges.push(markDecoration("nv3-calc-statement").range(statement.range.from, statement.range.to));

  switch (statement.kind) {
    case "SymbolDeclaration":
      for (const item of statement.symbols)
        ranges.push(markDecoration("nv3-calc-definition").range(item.range.from, item.range.to));
      return;

    case "ValueDefinition":
      ranges.push(
        markDecoration("nv3-calc-definition").range(
          statement.nameRange.from,
          statement.nameRange.to,
        ),
      );
      addExpressionDecorations(ranges, statement.value);
      return;

    case "FunctionDefinition":
      ranges.push(
        markDecoration("nv3-calc-definition nv3-calc-definition-function").range(
          statement.nameRange.from,
          statement.nameRange.to,
        ),
      );
      for (const param of statement.params) {
        ranges.push(markDecoration("nv3-calc-parameter").range(param.range.from, param.range.to));
      }
      addExpressionDecorations(ranges, statement.body);
      return;

    case "ExpressionStatement":
      addExpressionDecorations(ranges, statement.expression);
      return;
  }
}

function addDiagnosticDecorations(
  ranges: Range<Decoration>[],
  diagnostics: readonly CalcDiagnostic[],
): void {
  for (const diag of diagnostics) {
    const from = diag.from;
    const to = Math.max(diag.to, from + 1);
    ranges.push(markDecoration("nv3-calc-error").range(from, to));
  }
}

function addFenceLanguageDecoration(
  ranges: Range<Decoration>[],
  line: import("@codemirror/state").Line,
): void {
  const match = line.text.match(FENCE_INFO_PATTERN);
  const rawInfo = match?.[1] ?? "";
  if (normalizeFenceInfo(rawInfo) !== "calc") return;
  const infoIndex = line.text.indexOf(rawInfo);
  if (infoIndex < 0) return;
  const from = line.from + infoIndex;
  ranges.push(markDecoration("nv3-calc-fence-language").range(from, from + rawInfo.length));
}

function evaluateMarkdownCalcDocument(
  state: EditorState,
  document: Nv3MarkdownCalcDocument,
): Nv3MarkdownCalcEvaluation {
  const inlineEvaluations: Nv3MarkdownCalcInlineEvaluation[] = [];
  const fenceOutputs: Nv3MarkdownCalcFenceOutput[] = [];
  const fenceScopes: Array<{ from: number; scope: CalcRuntimeScope }> = [];

  for (const fence of document.fences) {
    const block = evaluateCalcBlock(fence.result);
    fenceScopes.push({
      from: state.doc.line(fence.fromLine).from,
      scope: block.scope,
    });

    const results = new Map(
      block.statementResults.map((entry) => [entry.statement.range.from, entry.result]),
    );
    for (const line of fence.result.lines) {
      const statement = line.statement;
      if (!statement) continue;
      const result = results.get(statement.range.from);
      if (!result) continue;
      const docLine = state.doc.line(fence.fromLine + line.line);
      fenceOutputs.push({
        lineFrom: docLine.from,
        lineTo: docLine.to,
        statementFrom: fence.bodyFrom + statement.range.from,
        statementTo: fence.bodyFrom + statement.range.to,
        reactive: line.reactiveOutput !== null,
        separatorFrom: line.reactiveOutput
          ? fence.bodyFrom + line.reactiveOutput.separatorRange.from
          : null,
        separatorTo: line.reactiveOutput
          ? fence.bodyFrom + line.reactiveOutput.separatorRange.to
          : null,
        outputFrom: line.reactiveOutput
          ? fence.bodyFrom + line.reactiveOutput.outputRange.from
          : null,
        outputTo: line.reactiveOutput ? fence.bodyFrom + line.reactiveOutput.outputRange.to : null,
        result,
      });
    }
  }

  for (const inlineExpression of document.inlineExpressions) {
    if (!inlineExpression.expression || inlineExpression.diagnostics.length > 0) continue;

    let scope: CalcRuntimeScope | undefined;
    for (const fenceScope of fenceScopes) {
      if (fenceScope.from < inlineExpression.from) {
        scope = fenceScope.scope;
        continue;
      }
      break;
    }

    inlineEvaluations.push({
      from: inlineExpression.from,
      to: inlineExpression.to,
      reactive: inlineExpression.separator !== null,
      outputFrom: inlineExpression.outputFrom,
      outputTo: inlineExpression.outputTo,
      result: evaluateCalcExpression(
        inlineExpression.expression,
        scope ?? createCalcRuntimeScope(),
      ),
    });
  }

  return {
    inlineEvaluations,
    fenceOutputs,
  };
}

function formatInlineResult(result: CalcEvaluationResult): string | null {
  const text = result.ok
    ? result.presentationError
      ? `⚠ ${result.presentationError.message}`
      : result.presentation !== undefined
        ? formatCalcPresentation(result.presentation)
        : formatCalcRuntimeValue(result.value)
    : `⚠ ${result.error.message}`;
  const normalized = text.replace(/\s*\n\s*/g, " ");
  const singleLine =
    result.ok && result.presentation !== undefined ? normalized : normalized.trim();
  if (!singleLine) return result.ok && result.presentation !== undefined ? "" : null;
  if (singleLine.length > 80) return `${singleLine.slice(0, 77)}…`;
  return singleLine;
}

export function buildReactiveCalcSourceChanges(state: EditorState): ChangeSpec[] {
  const document = scanMarkdownCalcDocument(state.doc);
  const evaluation = evaluateMarkdownCalcDocument(state, document);
  const changes: ReactiveCalcSourceChange[] = [];

  for (const inlineEvaluation of evaluation.inlineEvaluations) {
    if (!inlineEvaluation.reactive) continue;
    if (inlineEvaluation.outputFrom == null || inlineEvaluation.outputTo == null) continue;

    const nextOutput = formatReactiveCalcResult(inlineEvaluation.result);
    const currentOutput = state.doc.sliceString(
      inlineEvaluation.outputFrom,
      inlineEvaluation.outputTo,
    );
    if (currentOutput === nextOutput) continue;

    changes.push({
      from: inlineEvaluation.outputFrom,
      to: inlineEvaluation.outputTo,
      insert: nextOutput,
    });
  }

  for (const fenceOutput of evaluation.fenceOutputs) {
    if (!fenceOutput.reactive) continue;
    if (fenceOutput.outputFrom == null || fenceOutput.outputTo == null) continue;

    const nextOutput = formatReactiveCalcResult(fenceOutput.result, true);
    const currentOutput = state.doc.sliceString(fenceOutput.outputFrom, fenceOutput.outputTo);
    if (currentOutput === nextOutput) continue;

    changes.push({
      from: fenceOutput.outputFrom,
      to: fenceOutput.outputTo,
      insert:
        nextOutput +
        (/^[#;]/.test(state.doc.sliceString(fenceOutput.outputTo, fenceOutput.outputTo + 1))
          ? " "
          : ""),
    });
  }

  changes.sort((left, right) => {
    if (left.from !== right.from) return left.from - right.from;
    return (left.to ?? left.from) - (right.to ?? right.from);
  });
  return changes;
}

export function buildReactiveInlineCalcSourceChanges(state: EditorState): ChangeSpec[] {
  return buildReactiveCalcSourceChanges(state);
}

function normalizeReactiveCalcOutputs(
  transaction: Transaction,
): TransactionSpec | readonly TransactionSpec[] {
  if (transaction.annotation(reactiveCalcAnnotation)) {
    return transactionAsSpec(transaction);
  }
  if (!transaction.docChanged) return transactionAsSpec(transaction);

  const changes = buildReactiveCalcSourceChanges(transaction.state);
  if (changes.length === 0) return transactionAsSpec(transaction);

  return [
    transactionAsSpec(transaction),
    {
      changes,
      sequential: true,
      annotations: reactiveCalcAnnotation.of(true),
    },
  ];
}

function queueReactiveCalcSync(view: EditorView): void {
  const state = view.state;
  const changes = buildReactiveCalcSourceChanges(state);
  if (changes.length === 0) return;

  queueMicrotask(() => {
    if (!view.dom.isConnected || view.state !== state) return;
    view.dispatch({
      changes,
      annotations: reactiveCalcAnnotation.of(true),
    });
  });
}

class InlineCalcResultWidget extends WidgetType {
  constructor(
    readonly text: string,
    readonly error: boolean,
  ) {
    super();
  }

  override eq(other: InlineCalcResultWidget): boolean {
    return other.text === this.text && other.error === this.error;
  }

  override toDOM(): HTMLElement {
    const node = document.createElement("span");
    node.className = this.error
      ? "nv3-calc-inline-result nv3-calc-inline-result-error"
      : "nv3-calc-inline-result";
    node.setAttribute("contenteditable", "false");
    node.textContent = this.text;
    return node;
  }

  override ignoreEvent(): boolean {
    return false;
  }
}

function buildInlineCalcResultDecorations(state: EditorState): DecorationSet {
  const calcState = state.field(markdownCalcStateField);
  const ranges: Range<Decoration>[] = [];
  const selections = state.selection.ranges;

  for (const inlineEvaluation of calcState.evaluation.inlineEvaluations) {
    if (inlineEvaluation.reactive) continue;
    if (selectionTouchesRange(selections, inlineEvaluation.from, inlineEvaluation.to)) continue;
    const text = formatInlineResult(inlineEvaluation.result);
    if (text === null) continue;
    ranges.push(
      Decoration.replace({
        widget: new InlineCalcResultWidget(
          text,
          !inlineEvaluation.result.ok || !!inlineEvaluation.result.presentationError,
        ),
      }).range(inlineEvaluation.from, inlineEvaluation.to),
    );
  }

  const presentedOutputs = [
    ...calcState.evaluation.inlineEvaluations.filter((entry) => entry.reactive),
    ...calcState.evaluation.fenceOutputs,
  ];
  for (const output of presentedOutputs) {
    const error = output.result.ok ? output.result.presentationError : output.result.error;
    const presentation = error
      ? `⚠ ${error.message}`
      : output.result.ok
        ? output.result.presentation
        : undefined;
    if (presentation === undefined || isCalcPlot(presentation)) continue;
    if (
      output.outputFrom === null ||
      output.outputTo === null ||
      output.outputFrom >= output.outputTo
    )
      continue;
    if (selectionTouchesRange(selections, output.outputFrom, output.outputTo)) continue;
    const source = state.doc.sliceString(output.outputFrom, output.outputTo);
    if (source !== JSON.stringify(presentation)) continue;
    ranges.push(
      Decoration.replace({
        widget: new InlineCalcResultWidget(presentation.replace(/\r?\n/g, " "), !!error),
      }).range(output.outputFrom, output.outputTo),
    );
  }

  return Decoration.set(ranges, true);
}

const calcInlineResultViewPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: import("@codemirror/view").EditorView) {
      this.decorations = buildInlineCalcResultDecorations(view.state);
    }

    update(update: ViewUpdate) {
      if (!update.docChanged && !update.selectionSet) return;
      this.decorations = buildInlineCalcResultDecorations(update.state);
    }
  },
  {
    decorations: (value) => value.decorations,
  },
);

const reactiveCalcSyncViewPlugin = ViewPlugin.fromClass(
  class {
    constructor(view: import("@codemirror/view").EditorView) {
      queueReactiveCalcSync(view);
    }

    update(update: ViewUpdate) {
      if (!update.docChanged) return;
      if (
        update.transactions.some((transaction) => transaction.annotation(reactiveCalcAnnotation))
      ) {
        return;
      }
      queueReactiveCalcSync(update.view);
    }
  },
);

function resultPlot(result: CalcEvaluationResult): CalcPlot | null {
  if (!result.ok || result.presentationError) return null;
  if (result.presentation !== undefined)
    return isCalcPlot(result.presentation) ? result.presentation : null;
  return isCalcPlot(result.value) ? result.value : null;
}

function buildMarkdownCalcState(state: EditorState): Nv3MarkdownCalcState {
  const document = scanMarkdownCalcDocument(state.doc);
  const evaluation = evaluateMarkdownCalcDocument(state, document);
  const ranges: Range<Decoration>[] = [];

  for (const inlineExpression of document.inlineExpressions) {
    const closingDelimiterFrom = Math.max(inlineExpression.from, inlineExpression.to - 2);

    ranges.push(
      markDecoration("nv3-calc-inline").range(inlineExpression.from, inlineExpression.to),
    );
    ranges.push(
      markDecoration("nv3-calc-inline-delimiter").range(
        inlineExpression.from,
        inlineExpression.expressionFrom,
      ),
    );
    ranges.push(
      markDecoration("nv3-calc-inline-delimiter").range(closingDelimiterFrom, inlineExpression.to),
    );
    if (inlineExpression.expressionFrom < inlineExpression.expressionTo) {
      ranges.push(
        markDecoration("nv3-calc-inline-body").range(
          inlineExpression.expressionFrom,
          inlineExpression.expressionTo,
        ),
      );
    }
    if (
      inlineExpression.separatorFrom !== null &&
      inlineExpression.separatorTo !== null &&
      inlineExpression.separatorFrom < inlineExpression.separatorTo
    ) {
      ranges.push(
        markDecoration("nv3-calc-inline-separator").range(
          inlineExpression.separatorFrom,
          inlineExpression.separatorTo,
        ),
      );
    }
    if (
      inlineExpression.outputFrom !== null &&
      inlineExpression.outputTo !== null &&
      inlineExpression.outputFrom < inlineExpression.outputTo
    ) {
      ranges.push(
        markDecoration("nv3-calc-inline-output").range(
          inlineExpression.outputFrom,
          inlineExpression.outputTo,
        ),
      );
    }
    if (inlineExpression.expression) {
      addExpressionDecorations(ranges, inlineExpression.expression);
    }
    addDiagnosticDecorations(ranges, inlineExpression.diagnostics);
  }

  for (const fence of document.fences) {
    const errorLines = new Set<number>();

    for (const line of fence.result.lines) {
      if (line.diagnostics.length > 0) {
        errorLines.add(fence.fromLine + line.line);
      }
    }

    for (let lineNo = fence.fromLine; lineNo <= fence.toLine; lineNo += 1) {
      const line = state.doc.line(lineNo);
      const className = [
        "nv3-calc-fence-line",
        lineNo === fence.fromLine ? "nv3-calc-fence-start" : "nv3-calc-fence-body",
        lineNo === fence.toLine && fence.closed ? "nv3-calc-fence-end" : "",
        errorLines.has(lineNo) ? "nv3-calc-line-error" : "",
      ]
        .filter(Boolean)
        .join(" ");
      ranges.push(
        Decoration.line({
          class: className,
        }).range(line.from),
      );
      if (lineNo === fence.fromLine) addFenceLanguageDecoration(ranges, line);
    }

    for (const line of fence.result.lines) {
      const docOffset = fence.bodyFrom;
      if (line.statement) {
        addStatementDecorations(ranges, offsetStatementForDecoration(line.statement, docOffset));
      }
      if (line.reactiveOutput) {
        ranges.push(
          markDecoration("nv3-calc-inline-separator").range(
            docOffset + line.reactiveOutput.separatorRange.from,
            docOffset + line.reactiveOutput.separatorRange.to,
          ),
        );
        if (line.reactiveOutput.outputRange.from < line.reactiveOutput.outputRange.to) {
          ranges.push(
            markDecoration("nv3-calc-inline-output").range(
              docOffset + line.reactiveOutput.outputRange.from,
              docOffset + line.reactiveOutput.outputRange.to,
            ),
          );
        }
      }
      addDiagnosticDecorations(
        ranges,
        line.diagnostics.map((diag) => offsetDiagnostic(diag, docOffset, fence.fromLine)),
      );
    }
  }

  addDiagnosticDecorations(
    ranges,
    document.diagnostics.filter(
      (diag) =>
        diag.code === "calc.unclosed-fence" || diag.code === "calc.unclosed-inline-expression",
    ),
  );

  for (const output of evaluation.fenceOutputs) {
    const plot = resultPlot(output.result);
    if (plot)
      ranges.push(
        Decoration.widget({ widget: new CalcPlotWidget(plot), block: true, side: 1 }).range(
          output.lineTo,
        ),
      );
  }
  for (const output of evaluation.inlineEvaluations) {
    const plot = resultPlot(output.result);
    if (plot)
      ranges.push(
        Decoration.widget({ widget: new CalcPlotWidget(plot), block: true, side: 1 }).range(
          state.doc.lineAt(output.from).to,
        ),
      );
  }

  return {
    document,
    evaluation,
    decorations: Decoration.set(ranges, true),
  };
}

const markdownCalcStateField = StateField.define<Nv3MarkdownCalcState>({
  create(state) {
    return buildMarkdownCalcState(state);
  },

  update(value, transaction) {
    if (!transaction.docChanged) return value;
    return buildMarkdownCalcState(transaction.state);
  },

  provide(field) {
    return EditorView.decorations.from(field, (value) => value.decorations);
  },
});

export function getMarkdownCalcDocument(state: EditorState): Nv3MarkdownCalcDocument {
  return state.field(markdownCalcStateField).document;
}

export function getMarkdownCalcEvaluation(state: EditorState): Nv3MarkdownCalcEvaluation {
  return state.field(markdownCalcStateField).evaluation;
}

export function createMarkdownCalcExtension(options: MarkdownCalcExtensionOptions = {}): Extension {
  const extensions: Extension[] = [
    EditorState.transactionFilter.of((transaction) => normalizeReactiveCalcOutputs(transaction)),
    markdownCalcStateField,
    createCalcDiscoveryExtension(getMarkdownCalcDocument, options.onHelpOpen),
    calcInlineResultViewPlugin,
    reactiveCalcSyncViewPlugin,
  ];

  if (options.onChange) {
    const { onChange } = options;
    extensions.push(
      ViewPlugin.fromClass(
        class {
          constructor(view: import("@codemirror/view").EditorView) {
            onChange(view.state.field(markdownCalcStateField).document);
          }

          update(update: ViewUpdate) {
            if (!update.docChanged) return;
            onChange(update.state.field(markdownCalcStateField).document);
          }
        },
      ),
    );
  }

  return extensions;
}
