import {
  EditorState,
  Facet,
  Prec,
  StateEffect,
  StateField,
  type Extension,
} from "@codemirror/state";
import {
  autocompletion,
  completionStatus,
  snippet,
  snippetCompletion,
  startCompletion,
  type Completion,
  type CompletionContext,
  type CompletionResult,
} from "@codemirror/autocomplete";
import {
  Decoration,
  EditorView,
  ViewPlugin,
  WidgetType,
  getPanel,
  hoverTooltip,
  keymap,
  showPanel,
  showTooltip,
  type Panel,
  type Tooltip,
  type ViewUpdate,
} from "@codemirror/view";
import {
  calcCatalog,
  calcEntriesNamed,
  calcEntry,
  calcPresenterAliases,
  calcSignature,
  searchCalcCatalog,
  type CalcCatalogEntry,
  type CalcDiscoveryType,
} from "../calc/catalog.ts";
import {
  parseCalcExpression,
  parseCalcStatement,
  splitReactiveCalcSource,
  type CalcExpression,
  type CalcStatement,
} from "../calc/parser.ts";
import type { Nv3MarkdownCalcDocument, Nv3MarkdownCalcFence } from "./calc.ts";
import { nv3AdditionalCompletionSources } from "./autocomplete.ts";
import { scanCalcUnit } from "../calc/units.ts";

import type { HelpOpenRequest } from "../help/model.ts";

const helpHost = Facet.define<(request: HelpOpenRequest) => void>();
let nextHelpToken = 0;
const documentSource = Facet.define<(state: EditorState) => Nv3MarkdownCalcDocument>();
export interface CalcEditingContext {
  from: number;
  to: number;
  source: string;
  inline: boolean;
  statements: readonly CalcStatement[];
  fence?: Nv3MarkdownCalcFence;
}
interface Token {
  text: string;
  from: number;
  to: number;
}
function lexical(source: string): { tokens: Token[]; quoted: boolean; comment: number | null } {
  const tokens: Token[] = [];
  for (let i = 0; i < source.length; ) {
    const char = source[i]!;
    if (/\s/.test(char)) {
      i++;
      continue;
    }
    if (char === "#" || char === ";") return { tokens, quoted: false, comment: i };
    if (char === '"' || char === "'") {
      const start = i++,
        quote = char;
      let closed = false;
      while (i < source.length) {
        const c = source[i++];
        if (c === "\\") i++;
        else if (c === quote) {
          closed = true;
          break;
        }
      }
      if (!closed) return { tokens, quoted: true, comment: null };
      tokens.push({ text: "<string>", from: start, to: i });
      continue;
    }
    const match = source
      .slice(i)
      .match(
        /^[A-Za-z_][A-Za-z0-9_]*(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*|^(?:\d[\d_]*(?:\.[\d_]+)?(?:e[+-]?\d+)?)/i,
      );
    if (match) {
      tokens.push({ text: match[0].replace(/\s/g, ""), from: i, to: i + match[0].length });
      i += match[0].length;
      continue;
    }
    const text = source.startsWith("|>", i) ? "|>" : char;
    tokens.push({ text, from: i, to: i + text.length });
    i += text.length;
  }
  return { tokens, quoted: false, comment: null };
}
export function getCalcEditingContext(state: EditorState, pos: number): CalcEditingContext | null {
  const read = state.facet(documentSource)[0];
  if (!read) return null;
  const document = read(state),
    line = state.doc.lineAt(pos);
  const fence = document.fences.find((f) => pos >= f.bodyFrom && pos <= f.bodyTo);
  let from: number,
    to: number,
    inline = false;
  if (fence) {
    from = Math.max(fence.bodyFrom, line.from);
    to = Math.min(fence.bodyTo, line.to);
  } else {
    const entry = document.inlineExpressions.find(
      (e) => pos >= e.expressionFrom && pos <= e.expressionTo,
    );
    const incomplete = document.diagnostics.find(
      (e) => e.code === "calc.unclosed-inline-expression" && pos >= e.from + 2 && pos <= e.to,
    );
    if (!entry && !incomplete) return null;
    from = entry?.expressionFrom ?? incomplete!.from + 2;
    to = entry?.expressionTo ?? incomplete!.to;
    inline = true;
  }
  const source = state.doc.sliceString(from, to),
    split = splitReactiveCalcSource(source);
  if (split) to = Math.min(to, from + split.separatorRange.from);
  if (pos > to) return null;
  const before = lexical(state.doc.sliceString(from, pos));
  if (before.quoted || before.comment !== null) return null;
  const scopeFence = fence ?? document.fences.filter((f) => f.bodyFrom < from).at(-1);
  return {
    from,
    to,
    source: state.doc.sliceString(from, to),
    inline,
    statements: scopeFence?.result.statements ?? [],
    fence,
  };
}
function localEntries(context: CalcEditingContext, pos: number): CalcCatalogEntry[] {
  const entries: CalcCatalogEntry[] = [];
  for (const statement of context.statements) {
    if (statement.kind === "ValueDefinition" || statement.kind === "FunctionDefinition") {
      entries.push({
        name: statement.name,
        kind: statement.kind === "FunctionDefinition" ? "function" : "constant",
        category: "This block",
        summary:
          statement.kind === "FunctionDefinition"
            ? "Function defined in this calc block."
            : "Value defined in this calc block.",
        signatures:
          statement.kind === "FunctionDefinition" ? [statement.params.map((p) => p.name)] : [],
        keywords: [],
        accepts: [],
        examples: [],
      });
    } else if (statement.kind === "SymbolDeclaration")
      for (const symbol of statement.symbols)
        entries.push({
          name: symbol.name,
          kind: "constant",
          category: "This block",
          summary: "Declared symbolic value.",
          signatures: [],
          keywords: [],
          accepts: [],
          examples: [],
        });
  }
  const parameter = (name: string) => {
    entries.unshift({
      name,
      kind: "constant",
      category: "Local",
      summary: "Local parameter or comprehension variable.",
      signatures: [],
      keywords: [],
      accepts: [],
      examples: [],
    });
  };
  const parsed = parseCalcStatement(context.source).statement;
  const relative = pos - context.from;
  const walk = (node: unknown) => {
    if (!node || typeof node !== "object" || !("kind" in node) || !("range" in node)) return;
    const expression = node as CalcExpression;
    if (relative < expression.range.from || relative > expression.range.to) return;
    if (
      expression.kind === "ListComprehension" &&
      ((relative >= expression.element.range.from && relative <= expression.element.range.to) ||
        (expression.condition &&
          relative >= expression.condition.range.from &&
          relative <= expression.condition.range.to))
    )
      parameter(expression.binding.name);
    for (const child of Object.values(node)) {
      if (Array.isArray(child)) child.forEach(walk);
      else walk(child);
    }
  };
  if (parsed?.kind === "FunctionDefinition") {
    parsed.params.forEach((p) => parameter(p.name));
    walk(parsed.body);
  } else if (parsed?.kind === "ValueDefinition") walk(parsed.value);
  else if (parsed?.kind === "ExpressionStatement") walk(parsed.expression);
  else {
    const signature = context.source.match(/^\s*[A-Za-z_]\w*\s*\(([^()]*)\)\s*=/);
    signature?.[1]
      ?.split(",")
      .map((s) => s.trim())
      .filter((s) => /^[A-Za-z_]\w*$/.test(s))
      .forEach(parameter);
    // During incomplete input, only collect loop names from brackets that still enclose the cursor.
    const tokens = lexical(context.source).tokens,
      stack: number[] = [];
    for (const token of tokens) {
      if (token.text === "[") stack.push(token.from);
      else if (token.text === "]") {
        const start = stack.pop();
        if (start !== undefined && relative >= start && relative <= token.to) {
          const clause = context.source
            .slice(start, token.to)
            .match(/\bfor\s+([A-Za-z_]\w*)\s+in\b/);
          if (clause?.[1]) parameter(clause[1]);
        }
      }
    }
    for (const start of stack)
      if (relative >= start) {
        const clause = context.source.slice(start).match(/\bfor\s+([A-Za-z_]\w*)\s+in\b/);
        if (clause?.[1]) parameter(clause[1]);
      }
  }
  return entries.filter(
    (entry, index) => entries.findIndex((e) => e.name === entry.name) === index,
  );
}
function inferredType(
  expression: CalcExpression | null,
  context: CalcEditingContext,
  seen = new Set<string>(),
): CalcDiscoveryType | null {
  if (!expression) return null;
  switch (expression.kind) {
    case "NumberLiteral":
      return "number";
    case "QuantityLiteral":
      return "quantity";
    case "ImaginaryLiteral":
      return "complex";
    case "StringLiteral":
      return "string";
    case "BooleanLiteral":
      return "boolean";
    case "NullLiteral":
      return "null";
    case "ListExpression":
    case "ListComprehension":
      return "list";
    case "PresentationExpression":
      return inferredType(expression.input, context, seen);
    case "Identifier": {
      if (seen.has(expression.name)) return null;
      seen.add(expression.name);
      const definition = context.statements.find((s) => "name" in s && s.name === expression.name);
      if (definition?.kind === "ValueDefinition")
        return inferredType(definition.value, context, seen);
      if (definition?.kind === "FunctionDefinition") return "function";
      if (
        context.statements.some(
          (s) =>
            s.kind === "SymbolDeclaration" && s.symbols.some((v) => v.name === expression.name),
        )
      )
        return "expression";
      if (expression.name === "i") return "complex";
      return null;
    }
    case "UnaryExpression":
      return inferredType(expression.operand, context, seen);
    case "BinaryExpression": {
      const left = inferredType(expression.left, context, new Set(seen));
      const right = inferredType(expression.right, context, new Set(seen));
      if (left === "expression" || right === "expression") return "expression";
      if (["==", "!=", "<", ">", "<=", ">="].includes(expression.operator)) return "boolean";
      if (left === "number" && right === "number") return "number";
      return null;
    }
    default:
      return null;
  }
}
function lookup(
  name: string,
  context: CalcEditingContext,
  pos: number,
  presenter = false,
): readonly CalcCatalogEntry[] {
  if (presenter) {
    const alias = calcPresenterAliases().find((entry) => entry.name === name);
    if (alias) return [alias];
  }
  if (!name.includes(".")) {
    const local = localEntries(context, pos).find((e) => e.name === name);
    if (local) return [local];
  }
  if (name === "%") return [calcEntry("%")!];
  const entries = calcEntriesNamed(name);
  if (entries.length) return entries;
  const alias = calcPresenterAliases().find((entry) => entry.name === name);
  if (alias) return [alias];
  try {
    const unit = scanCalcUnit(name);
    return unit?.to === name.length
      ? [{ ...calcEntry("present.unit")!, name, signatures: [["value", "digits?"]] }]
      : [];
  } catch {
    return [];
  }
}
interface CompletionSite {
  mode: "value" | "operation" | "presenter" | "namespace";
  from: number;
  text: string;
  namespace?: string;
  receiver: CalcDiscoveryType | null;
}
function completionSite(context: CalcEditingContext, pos: number): CompletionSite {
  const before = context.source.slice(0, pos - context.from),
    token = before.match(/[A-Za-z_][\w.]*$|%$/)?.[0] ?? "";
  const from = pos - token.length,
    preceding = before.slice(0, before.length - token.length);
  const namespace = token.includes(".") ? token.slice(0, token.lastIndexOf(".")) : null;
  if (namespace)
    return {
      mode: "namespace",
      from: from + namespace.length + 1,
      text: token.slice(namespace.length + 1),
      namespace,
      receiver: null,
    };
  const match = preceding.match(/(\bas\s+|@\s*|\|>\s*)$/);
  const mode = match?.[1]?.trim() === "as" ? "presenter" : match ? "operation" : "value";
  let receiver: CalcDiscoveryType | null = null;
  if (match) {
    let input = preceding.slice(0, match.index).trim();
    input = input.replace(/^\s*[A-Za-z_]\w*\s*=\s*/, "");
    receiver = inferredType(parseCalcExpression(input).expression, context);
  }
  return { mode, from, text: token, receiver };
}
function operationName(entry: CalcCatalogEntry): string {
  if (!entry.name.includes(".")) return entry.name;
  const short = entry.name.split(".").at(-1)!;
  return calcEntry(short) === entry ? short : entry.name;
}
function selectedVariant(entry: CalcCatalogEntry, receiver: CalcDiscoveryType | null): number {
  return entry.name === "present.plot"
    ? receiver === "function"
      ? 1
      : receiver === "expression"
        ? 2
        : 0
    : 0;
}
function paramsFor(entry: CalcCatalogEntry, implicit: boolean, variant = 0): readonly string[] {
  return (entry.signatures[variant] ?? []).slice(implicit ? 1 : 0);
}
function completionInfo(
  entry: CalcCatalogEntry,
  name: string,
  implicit: boolean,
  variant = 0,
): HTMLElement {
  return helpDOM(entry, name, implicit, variant);
}
function callableCompletion(
  entry: CalcCatalogEntry,
  name: string,
  implicit: boolean,
  receiver: CalcDiscoveryType | null,
): Completion {
  const variant = selectedVariant(entry, receiver),
    params = paramsFor(entry, implicit, variant);
  const required = params.filter(
    (p) => !p.includes("=") && !p.endsWith("?") && !p.startsWith("..."),
  );
  const template =
    name +
    (required.length
      ? "(" + required.map((p, index) => "${" + (index + 1) + ":" + p + "}").join(", ") + ")"
      : implicit
        ? ""
        : entry.kind === "constant"
          ? ""
          : "()");
  return snippetCompletion(template, {
    label: `${name} ${entry.keywords.join(" ")}`,
    displayLabel: name,
    type: entry.kind === "constant" ? "constant" : "function",
    detail: entry.signatures.length
      ? calcSignature(entry, name, implicit, variant).slice(name.length)
      : entry.category,
    info: () => completionInfo(entry, name, implicit, variant),
    section:
      entry.category === "This block" || entry.category === "Local"
        ? "This block"
        : implicit
          ? "Operations"
          : "Standard library",
    boost: receiver && entry.accepts.includes(receiver) ? 15 : entry.accepts.length === 0 ? 3 : 0,
  });
}
export function calcCompletionSource(completion: CompletionContext): CompletionResult | null {
  if (completion.state.readOnly) return null;
  const context = getCalcEditingContext(completion.state, completion.pos);
  if (!context) return null;
  const definition = context.source.match(/^\s*[A-Za-z_]\w*(?:\([^)]*\))?\s*=(?!=)/);
  if (definition && completion.pos < context.from + definition[0].length) return null;
  const site = completionSite(context, completion.pos);
  if (!completion.explicit && !site.text && site.mode === "value") return null;
  // Do not turn a number suffix, parameter declaration, or output segment into a name completion.
  if (
    site.mode === "value" &&
    /[\d.]$/.test(
      completion.state.doc.sliceString(Math.max(context.from, site.from - 1), site.from),
    )
  )
    return null;
  let entries: CalcCatalogEntry[] = [],
    names = new Map<CalcCatalogEntry, string>();
  const locals = localEntries(context, completion.pos);
  if (site.mode === "namespace") {
    if (locals.some((e) => e.name === site.namespace)) return null;
    for (const entry of calcCatalog)
      for (const alias of [entry.name, ...(entry.aliases ?? [])])
        if (
          alias.startsWith(site.namespace + ".") &&
          !alias.slice(site.namespace!.length + 1).includes(".")
        ) {
          const named = { ...entry };
          entries.push(named);
          names.set(named, alias.slice(site.namespace!.length + 1));
        }
  } else if (site.mode === "presenter")
    entries = [
      ...calcCatalog.filter((e) => e.kind === "presenter"),
      ...calcPresenterAliases(),
      ...locals.filter((e) => e.kind === "function"),
    ];
  else
    entries = [
      ...locals,
      ...calcCatalog.filter(
        (e) => e.kind === "function" || e.kind === "presenter" || e.kind === "constant",
      ),
    ];
  if (site.mode === "operation")
    entries = entries.filter((e) => e.kind === "function" || e.kind === "presenter");
  const options: Completion[] = entries.map((entry) => {
    let name = names.get(entry) ?? operationName(entry);
    if (
      entry.name.includes(".") &&
      site.mode !== "namespace" &&
      locals.some((local) => local.name === name)
    )
      name = entry.name;
    return callableCompletion(
      entry,
      name,
      site.mode === "operation" || site.mode === "presenter",
      site.receiver,
    );
  });
  if (site.mode === "value") {
    for (const namespace of ["math", "stats", "list", "str", "core", "algebra", "present"])
      if (!locals.some((e) => e.name === namespace))
        options.push({
          label: namespace,
          apply: namespace + ".",
          type: "namespace",
          detail: "Browse namespace",
          section: "Namespaces",
        });
    for (const entry of calcCatalog.filter((e) => e.kind === "syntax" && e.snippet)) {
      if (context.inline && entry.snippet!.includes("\n")) continue;
      options.push(
        snippetCompletion(entry.snippet!, {
          label: `${entry.name} ${entry.keywords.join(" ")}`,
          displayLabel: entry.name,
          type: "keyword",
          detail: entry.summary,
          info: () => helpDOM(entry, entry.name, false),
          section: "Constructions",
        }),
      );
    }
    options.push({
      label: "Explore calc",
      detail: "Search functions, constructions, and examples",
      type: "text",
      section: "Help",
      apply: (view, _completion, from, to) => {
        openCalcExplorer(view, { from, to });
      },
    });
  }
  return { from: site.from, options, validFor: /^[\w%µ]*$/ };
}
function helpDOM(
  entry: CalcCatalogEntry,
  name: string,
  implicit: boolean,
  variant = 0,
  argument?: number,
): HTMLElement {
  const root = document.createElement("div");
  root.className = "nv3-calc-help";
  const signature = document.createElement("div");
  signature.className = "nv3-calc-signature";
  if (entry.signatures.length) {
    signature.append(document.createTextNode(name + "("));
    paramsFor(entry, implicit, variant).forEach((param, index) => {
      if (index) signature.append(document.createTextNode(", "));
      const node = document.createElement(index === argument ? "strong" : "span");
      node.textContent = param;
      signature.append(node);
    });
    signature.append(document.createTextNode(")"));
  } else signature.textContent = name;
  const description = document.createElement("p");
  description.textContent = entry.summary;
  root.append(signature, description);
  const example = entry.examples[0];
  if (example) {
    const code = document.createElement("pre");
    code.textContent =
      example.source + (example.expected !== undefined ? " → " + example.expected : "");
    root.append(code);
  }
  return root;
}
interface CallHelp {
  entry: CalcCatalogEntry;
  name: string;
  open: number;
  implicit: boolean;
  argument: number;
  variant: number;
}
export function calcCallHelp(state: EditorState, pos: number): CallHelp | null {
  const context = getCalcEditingContext(state, pos);
  if (!context) return null;
  const tokens = lexical(context.source.slice(0, pos - context.from)).tokens;
  const stack: { token: Token; name?: string; implicit: boolean; argument: number }[] = [];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i]!;
    if (token.text === "(" || token.text === "[") {
      const previous = tokens[i - 1],
        prior = tokens[i - 2];
      stack.push({
        token,
        name:
          token.text === "(" && previous && /^[A-Za-z_%][\w.]*$/.test(previous.text)
            ? previous.text
            : undefined,
        implicit: !!prior && ["@", "|>", "as"].includes(prior.text),
        argument: 0,
      });
    } else if (token.text === ")" || token.text === "]") stack.pop();
    else if (token.text === "," && stack.length) stack.at(-1)!.argument++;
  }
  const frame = [...stack].reverse().find((f) => f.name);
  if (!frame?.name) return null;
  const presenter = context.source
    .slice(0, frame.token.from)
    .match(/\bas\s+([A-Za-z%][A-Za-z0-9*/^\s-]*)$/)?.[1]
    ?.trim();
  if (presenter) {
    frame.name = presenter;
    frame.implicit = true;
  }
  const entry = lookup(frame.name, context, pos, !!presenter).find((e) => e.signatures.length);
  if (!entry) return null;
  let variant = entry.signatures.findIndex(
    (s) => s.length - (frame.implicit ? 1 : 0) > frame.argument,
  );
  if (entry.name === "present.plot" && frame.implicit)
    variant = selectedVariant(
      entry,
      completionSite(
        { ...context, source: context.source.slice(0, frame.token.from) },
        context.from + frame.token.from,
      ).receiver,
    );
  else if (entry.name === "present.plot") {
    let depth = 0,
      end = pos - context.from;
    for (const token of tokens.filter((token) => token.from >= frame.token.to)) {
      if (["(", "["].includes(token.text)) depth++;
      else if ([")", "]"].includes(token.text)) depth--;
      else if (token.text === "," && depth === 0) {
        end = token.from;
        break;
      }
    }
    const receiver = inferredType(
      parseCalcExpression(context.source.slice(frame.token.to, end)).expression,
      context,
    );
    if (receiver) variant = selectedVariant(entry, receiver);
  }
  if (variant < 0) variant = entry.signatures.length - 1;
  return {
    entry,
    name: frame.name,
    open: context.from + frame.token.from,
    implicit: frame.implicit,
    argument: frame.argument,
    variant,
  };
}
function signatureTooltip(state: EditorState): Tooltip | null {
  if (!state.selection.main.empty || state.field(explorerField, false)) return null;
  const help = calcCallHelp(state, state.selection.main.head);
  if (!help) return null;
  return {
    pos: help.open,
    above: true,
    create: (view) => {
      const dom = helpDOM(help.entry, help.name, help.implicit, help.variant, help.argument);
      dom.hidden = !view.hasFocus;
      return {
        dom,
        update: (update) => {
          dom.hidden = !update.view.hasFocus;
        },
      };
    },
  };
}
const dismissSignature = StateEffect.define<null>();
const signatureField = StateField.define<Tooltip | null>({
  create: signatureTooltip,
  update: (old, tr) =>
    tr.effects.some((effect) => effect.is(dismissSignature))
      ? null
      : tr.docChanged || tr.selection || tr.effects.some((effect) => effect.is(explorerEffect))
        ? signatureTooltip(tr.state)
        : old,
  provide: (field) => showTooltip.from(field),
});
interface ExplorerTarget {
  token?: string;
  from: number;
  to: number;
  inline: boolean;
  prefix: string;
}
const explorerEffect = StateEffect.define<ExplorerTarget | null>();
const explorerField = StateField.define<ExplorerTarget | null>({
  create: () => null,
  update(value, tr) {
    if (value && tr.docChanged)
      value = {
        ...value,
        from: tr.changes.mapPos(value.from, -1),
        to: tr.changes.mapPos(value.to, 1),
      };
    for (const effect of tr.effects) if (effect.is(explorerEffect)) value = effect.value;
    return value;
  },
  provide: (field) => showPanel.from(field, (target) => (target && !target.token ? calcExplorerPanel : null)),
});
export function openCalcExplorer(
  view: EditorView,
  replace?: { from: number; to: number },
): boolean {
  let selection = view.state.selection.main,
    pos = selection.head;
  let context = getCalcEditingContext(view.state, pos);
  if (!context) {
    const read = view.state.facet(documentSource)[0],
      document = read?.(view.state);
    const fence = document?.fences.find((f) => view.state.doc.lineAt(pos).number === f.fromLine);
    if (!fence) return false;
    pos = fence.bodyFrom;
    context = getCalcEditingContext(view.state, pos);
  }
  if (!context) return false;
  const line = view.state.doc.lineAt(pos);
  const target: ExplorerTarget = replace
    ? { ...replace, inline: context.inline, prefix: "" }
    : !context.inline && selection.empty && context.source.trim()
      ? { from: line.to, to: line.to, inline: false, prefix: "\n" }
      : {
          from: Math.max(context.from, selection.from),
          to: Math.min(context.to, selection.to),
          inline: context.inline,
          prefix: "",
        };
  const host = view.state.facet(helpHost)[0];
  if (host) target.token = `calc-help-${Date.now()}-${++nextHelpToken}`;
  view.dispatch({ effects: explorerEffect.of(target) });
  if (host) {
    const rect = view.coordsAtPos(pos) ?? view.dom.getBoundingClientRect();
    host({
      providerID: "calc", token: target.token!, canInsert: !view.state.readOnly,
      allowsMultiline: !target.inline,
      anchor: { x: rect.left, y: rect.top, width: 1, height: Math.max(1, rect.bottom - rect.top) },
    });
    return true;
  }
  getPanel(view, calcExplorerPanel)?.dom.querySelector<HTMLInputElement>("input")?.focus();
  return true;
}
export function closeCalcExplorer(view: EditorView): boolean {
  if (!view.state.field(explorerField, false)) return false;
  view.dispatch({ effects: explorerEffect.of(null) });
  view.focus();
  return true;
}
/** Apply only to the originating, still-valid help session. Positions map through edits. */
export function applyCalcHelpInsertion(view: EditorView, token: string, template: string): boolean {
  const target = view.state.field(explorerField, false);
  if (!target || target.token !== token || view.state.readOnly ||
      (target.inline && template.includes("\n")) ||
      !getCalcEditingContext(view.state, target.from)) return false;
  snippet(target.prefix + template)(view, null, target.from, target.to);
  closeCalcExplorer(view);
  return true;
}
export function dismissCalcHelp(view: EditorView, token: string): boolean {
  if (view.state.field(explorerField, false)?.token !== token) return false;
  return closeCalcExplorer(view);
}
function calcExplorerPanel(view: EditorView): Panel {
  const dom = document.createElement("section");
  dom.className = "nv3-calc-explorer";
  dom.setAttribute("aria-label", "Explore calc");
  const header = document.createElement("div");
  header.className = "nv3-calc-explorer-header";
  const title = document.createElement("strong");
  title.textContent = "Explore calc";
  const search = document.createElement("input");
  search.type = "search";
  search.placeholder = "Search calc: percentage, graph, filter…";
  search.setAttribute("aria-label", "Search calc");
  const category = document.createElement("select");
  category.setAttribute("aria-label", "Calc category");
  for (const name of [
    "All",
    "Constructions",
    ...new Set(
      calcCatalog
        .map((e) => e.category)
        .concat(["Units", "Multipliers"])
        .filter((c) => c !== "Constructions"),
    ),
  ]) {
    const option = document.createElement("option");
    option.textContent = name;
    option.value = name;
    category.append(option);
  }
  const close = document.createElement("button");
  close.type = "button";
  close.textContent = "×";
  close.setAttribute("aria-label", "Close calc reference");
  close.onclick = () => closeCalcExplorer(view);
  header.append(title, search, category, close);
  const body = document.createElement("div");
  body.className = "nv3-calc-explorer-body";
  const list = document.createElement("div");
  list.className = "nv3-calc-explorer-list";
  list.setAttribute("role", "listbox");
  list.setAttribute("aria-label", "Calc reference results");
  const details = document.createElement("div");
  details.className = "nv3-calc-explorer-details";
  const footer = document.createElement("div");
  footer.className = "nv3-calc-explorer-footer";
  footer.setAttribute("aria-live", "polite");
  body.append(list, details);
  dom.append(header, body, footer);
  let matches: CalcCatalogEntry[] = [],
    selected = 0;
  const insert = (template: string) => {
    const target = view.state.field(explorerField);
    if (!target || view.state.readOnly) return;
    if (!getCalcEditingContext(view.state, target.from)) {
      footer.textContent =
        "The saved cursor is no longer in calc. Close this panel and place the cursor in a calc expression.";
      return;
    }
    if (target.inline && template.includes("\n")) return;
    snippet(target.prefix + template)(view, null, target.from, target.to);
    closeCalcExplorer(view);
  };
  const insertButton = (label: string, template: string) => {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = label;
    button.disabled =
      view.state.readOnly || (!!view.state.field(explorerField)?.inline && template.includes("\n"));
    if (button.disabled)
      button.title = view.state.readOnly
        ? "This document is read-only."
        : "Multi-line examples need a calc block.";
    button.onclick = () => insert(template);
    return button;
  };
  const showDetails = () => {
    details.replaceChildren();
    const entry = matches[selected];
    if (!entry) {
      const p = document.createElement("p");
      p.textContent = "No matches. Try “percentage”, “convert”, “graph”, or “comprehension”.";
      details.append(p);
      return;
    }
    const heading = document.createElement("h3");
    heading.textContent = entry.name;
    details.append(heading);
    const summary = document.createElement("p");
    summary.textContent = entry.summary;
    details.append(summary);
    for (let index = 0; index < entry.signatures.length; index++) {
      const signature = document.createElement("code");
      signature.className = "nv3-calc-reference-signature";
      const alias = entry.kind === "presenter" && !entry.name.includes(".");
      signature.textContent = calcSignature(
        entry,
        alias ? "as " + entry.name : entry.name,
        alias,
        index,
      );
      details.append(signature);
    }
    if (entry.aliases?.length) {
      const aliases = document.createElement("p");
      aliases.className = "nv3-calc-reference-aliases";
      aliases.textContent = "Also available as " + entry.aliases.join(", ");
      details.append(aliases);
    }
    if (entry.snippet) details.append(insertButton("Insert template", entry.snippet));
    for (const example of entry.examples) {
      const code = document.createElement("pre");
      code.textContent = example.source;
      details.append(code);
      if (example.expected !== undefined) {
        const result = document.createElement("div");
        result.className = "nv3-calc-reference-result";
        result.textContent = "→ " + example.expected;
        details.append(result);
      }
      // Examples are literal code; escape snippet metacharacters before inserting them.
      const source = example.source + (example.expected !== undefined ? " -> " : "");
      details.append(insertButton("Insert example", source.replace(/[{}]/g, "\\$&")));
    }
    for (const [index, child] of [...list.children].entries())
      child.setAttribute("aria-selected", String(index === selected));
  };
  const refresh = () => {
    const query = search.value;
    const aliases = calcPresenterAliases().filter((e) => {
      const words = query.toLowerCase().trim().split(/\s+/);
      const text = `${e.name} ${e.summary} ${e.keywords.join(" ")}`.toLowerCase();
      return words.every((w) => text.includes(w));
    });
    const base = searchCalcCatalog(query);
    matches = [
      ...base.filter((e) => e.kind === "syntax"),
      ...base.filter((e) => e.kind !== "syntax"),
      ...aliases,
    ].filter((e) => category.value === "All" || e.category === category.value);
    selected = 0;
    list.replaceChildren();
    for (const [index, entry] of matches.entries()) {
      const row = document.createElement("button");
      row.type = "button";
      row.tabIndex = -1;
      row.setAttribute("role", "option");
      row.setAttribute("aria-selected", String(index === selected));
      const label = document.createElement("span");
      label.textContent = entry.name;
      const kind = document.createElement("small");
      kind.textContent = entry.category;
      row.append(label, kind);
      row.onclick = () => {
        selected = index;
        showDetails();
      };
      list.append(row);
    }
    footer.textContent = `${matches.length} results · ↑↓ browse · Enter inserts · Esc closes${view.state.field(explorerField)?.inline ? " · Multi-line examples need a calc block." : " · Examples insert on a new line, or replace selected text."}`;
    showDetails();
  };
  search.addEventListener("input", refresh);
  category.addEventListener("change", refresh);
  dom.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      closeCalcExplorer(view);
    }
    if (
      (event.target === search || event.target === list || list.contains(event.target as Node)) &&
      ["ArrowDown", "ArrowUp"].includes(event.key)
    ) {
      event.preventDefault();
      selected = Math.max(
        0,
        Math.min(matches.length - 1, selected + (event.key === "ArrowDown" ? 1 : -1)),
      );
      showDetails();
      list.children[selected]?.scrollIntoView({ block: "nearest" });
    }
    if (event.target === search && event.key === "Enter") {
      event.preventDefault();
      const entry = matches[selected];
      if (entry) insert(entry.snippet ?? entry.examples[0]?.source.replace(/[{}]/g, "\\$&") ?? "");
    }
  });
  refresh();
  return {
    dom,
    top: false,
    mount: () => search.focus(),
    update: (update) => {
      if (update.startState.readOnly !== update.state.readOnly) showDetails();
    },
  };
}
class ExploreCalcWidget extends WidgetType {
  override eq(): boolean {
    return true;
  }
  override toDOM(view: EditorView): HTMLElement {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "nv3-calc-explore-button";
    button.textContent = "Explore calc";
    button.title = "Search functions and constructions (F1)";
    button.setAttribute("aria-label", "Explore calc");
    button.onmousedown = (event) => event.preventDefault();
    button.onclick = () => openCalcExplorer(view);
    return button;
  }
  override ignoreEvent(): boolean {
    return true;
  }
}
function affordance(state: EditorState) {
  const read = state.facet(documentSource)[0];
  if (!read) return Decoration.none;
  const head = state.selection.main.head;
  const fence = read(state).fences.find(
    (f) => head >= state.doc.line(f.fromLine).from && head <= f.bodyTo,
  );
  if (!fence) return Decoration.none;
  return Decoration.set([
    Decoration.widget({ widget: new ExploreCalcWidget(), side: 1 }).range(
      state.doc.line(fence.fromLine).to,
    ),
  ]);
}
export function createCalcDiscoveryExtension(
  readDocument: (state: EditorState) => Nv3MarkdownCalcDocument,
  onHelpOpen?: (request: HelpOpenRequest) => void,
): Extension {
  return [
    documentSource.of(readDocument),
    ...(onHelpOpen ? [helpHost.of(onHelpOpen)] : []),
    explorerField,
    signatureField,
    autocompletion({ activateOnCompletion: (completion) => completion.type === "namespace" }),
    EditorState.languageData.of(() => [{ autocomplete: calcCompletionSource }]),
    nv3AdditionalCompletionSources.of((context) => {
      const result = calcCompletionSource(context);
      if (result) return result;
      const document = readDocument(context.state);
      const ownsInline =
        document.inlineExpressions.some(
          (entry) => context.pos >= entry.from && context.pos <= entry.to,
        ) ||
        document.diagnostics.some(
          (entry) =>
            entry.code === "calc.unclosed-inline-expression" &&
            context.pos >= entry.from &&
            context.pos <= entry.to,
        );
      // Inline calc owns its brackets even when no calc completion is appropriate.
      // In particular, coordinate lists must not activate the prose wikilink provider.
      return ownsInline ? { from: context.pos, options: [] } : null;
    }),
    Prec.high(
      keymap.of([
        {
          key: "Escape",
          run: (view) => {
            if (completionStatus(view.state)) return false;
            if (!view.state.field(signatureField)) return false;
            view.dispatch({ effects: dismissSignature.of(null) });
            return true;
          },
        },
        { key: "F1", run: openCalcExplorer },
        {
          key: "Mod-Shift-Space",
          run: (view) =>
            getCalcEditingContext(view.state, view.state.selection.main.head)
              ? startCompletion(view)
              : false,
        },
      ]),
    ),
    ViewPlugin.fromClass(
      class {
        decorations;
        constructor(view: EditorView) {
          this.decorations = affordance(view.state);
        }
        update(update: ViewUpdate) {
          if (update.docChanged || update.selectionSet) this.decorations = affordance(update.state);
        }
      },
      { decorations: (plugin) => plugin.decorations },
    ),
    EditorView.updateListener.of((update) => {
      if (
        !update.docChanged ||
        !update.transactions.some((t) => t.isUserEvent("input.type")) ||
        update.state.readOnly
      )
        return;
      const head = update.state.selection.main.head,
        context = getCalcEditingContext(update.state, head);
      if (
        context &&
        /(?:@|\|>|\bas\s+|\b[A-Za-z_]\w*\.)\s*$/.test(context.source.slice(0, head - context.from))
      )
        queueMicrotask(() => {
          if (update.view.state === update.state) startCompletion(update.view);
        });
    }),
    hoverTooltip(
      (view, pos) => {
        const context = getCalcEditingContext(view.state, pos);
        if (!context) return null;
        const token = lexical(context.source).tokens.find(
          (t) => pos >= context.from + t.from && pos <= context.from + t.to,
        );
        if (!token) return null;
        let entries = lookup(token.text, context, pos);
        if (!entries.length) {
          const syntaxName = (
            {
              for: "List comprehension",
              in: "List comprehension",
              as: "Presenter",
              symbol: "Symbol declaration",
            } as Record<string, string>
          )[token.text];
          if (syntaxName) entries = [calcCatalog.find((e) => e.name === syntaxName)!];
        }
        const entry = entries[0];
        if (!entry) return null;
        const before = context.source.slice(0, token.from),
          implicit = /(?:@|\|>|\bas)\s*$/.test(before);
        return {
          pos: context.from + token.from,
          end: context.from + token.to,
          above: true,
          create: () => ({ dom: helpDOM(entry, token.text, implicit) }),
        };
      },
      { hoverTime: 400 },
    ),
  ];
}
