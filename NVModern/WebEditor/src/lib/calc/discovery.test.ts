import { describe, expect, it } from "bun:test";
import { EditorState, type Transaction } from "@codemirror/state";
import { CompletionContext, type Completion } from "@codemirror/autocomplete";
import { createMarkdownCalcExtension } from "../plugins/calc.ts";
import {
  calcCallHelp,
  calcCompletionSource,
  getCalcEditingContext,
} from "../plugins/calcDiscovery.ts";
import {
  createNv3AutocompleteExtension,
  nv3AdditionalCompletionSources,
} from "../plugins/autocomplete.ts";
import { calcEntry, renderCalcCatalogReference } from "./catalog.ts";
import { readFileSync } from "node:fs";

function setup(source: string, explicit = true, readonly = false) {
  const pos = source.indexOf("¦");
  expect(pos).toBeGreaterThanOrEqual(0);
  const state = EditorState.create({
    doc: source.replace("¦", ""),
    selection: { anchor: pos },
    extensions: [createMarkdownCalcExtension(), EditorState.readOnly.of(readonly)],
  });
  const result = calcCompletionSource(new CompletionContext(state, pos, explicit));
  return {
    state,
    pos,
    result,
    labels: result?.options.map((o) => o.displayLabel ?? o.label) ?? [],
  };
}
const fence = (source: string) => "```calc\n" + source + "\n```";
function applyCompletion(source: string, name: string) {
  let { state, result } = setup(source);
  const completion = result!.options.find((o) => (o.displayLabel ?? o.label) === name)!;
  expect(completion).toBeDefined();
  if (typeof completion.apply !== "function") throw new Error("Expected snippet");
  const editor = {
    get state() {
      return state;
    },
    dispatch(transaction: Transaction) {
      state = transaction.state;
    },
  };
  completion.apply(
    editor as never,
    completion,
    result!.from,
    result!.to ?? state.selection.main.head,
  );
  return state;
}
describe("calc editor discovery", () => {
  it("works in incomplete calc fences and closed or unfinished inline expressions", () => {
    expect(setup(fence("sqr¦")).labels).toContain("sqrt");
    expect(setup("Before {{ sqr¦ }} after").labels).toContain("sqrt");
    expect(setup("Before {{ sqr¦").labels).toContain("sqrt");
    expect(setup("```calc\nsqr¦").labels).toContain("sqrt");
  });
  it("stays out of prose, other code, comments, strings, output text, and read-only notes", () => {
    for (const source of [
      "sqr¦",
      "`{{ sqr¦ }}`",
      "```js\nsqr¦\n```",
      fence("# sqr¦"),
      fence('"sqr¦"'),
      fence("1 -> sqr¦"),
      fence("1 # sqr¦"),
      "{{ 1 -> sqr¦ }}",
    ])
      expect(setup(source).result).toBeNull();
    expect(setup(fence("sqr¦"), true, true).result).toBeNull();
    expect(setup(fence("fn(sqr¦) = 1")).result).toBeNull();
  });
  it("lists namespace members, including qualified aliases, without duplicates", () => {
    const result = setup(fence("math.¦"));
    expect(result.labels).toContain("sqrt");
    expect(result.labels).toContain("pi");
    expect(result.labels).not.toContain("mean");
    expect(new Set(setup(fence("core.¦")).labels).size).toBe(setup(fence("core.¦")).labels.length);
    expect(setup(fence("stats.¦")).labels).toContain("stddev");
    expect(setup(fence("math = 3\nmath.¦")).result).toBeNull();
  });
  it("ranks known receiver types but keeps other functions discoverable", () => {
    const { result, labels } = setup(fence("values = [1,2]\nvalues @¦"), false);
    expect(labels).toContain("list.len");
    expect(labels).toContain("str.len");
    expect(labels).toContain("mean");
    const option = (name: string) =>
      result!.options.find((o) => (o.displayLabel ?? o.label) === name)!;
    expect(option("list.len").boost).toBeGreaterThan(option("str.len").boost ?? 0);
    expect(setup(fence("unknown @¦"), false).labels).toContain("sqrt");
  });
  it("offers presenters, units, multipliers, and custom functions after as", () => {
    const { labels } = setup(fence("money(value) = decimal(value,2)\n1 as ¦"), false);
    for (const name of ["%", "decimal", "plot", "kg", "Cr", "km", "money"])
      expect(labels).toContain(name);
    expect(labels).not.toContain("sqrt");
    expect(setup(fence("1¦")).result).toBeNull();
  });
  it("uses the current block, preceding inline scope, parameters, and comprehension scope", () => {
    expect(setup(fence("a = 3\ndouble(x) = x*2\na¦")).labels).toContain("a");
    expect(setup(fence("double(x) = x*2\ndouble¦")).labels).toContain("double");
    expect(setup("```calc\nlocal = 2\n```\n{{ lo¦ }}").labels).toContain("local");
    expect(setup("```calc\nold = 2\n```\n```calc\nnew = 3\nlo¦\n```").labels).not.toContain("old");
    expect(setup(fence("fn(parameter) = par¦")).labels).toContain("parameter");
    expect(setup(fence("[va¦ for variable in [1,2]]")).labels).toContain("variable");
    expect(setup(fence("[x for x in x¦]")).labels).not.toContain("x");
    expect(setup(fence("mean = 3\nme¦")).labels).toContain("stats.mean");
  });
  it("uses CodeMirror snippets for function calls and constructions", () => {
    expect(applyCompletion(fence("sq¦"), "sqrt").doc.toString()).toContain("sqrt(value)");
    expect(applyCompletion(fence("math.sq¦"), "sqrt").doc.toString()).toContain("math.sqrt(value)");
    expect(applyCompletion(fence("[1,2] @me¦"), "mean").doc.toString()).toContain("[1,2] @mean");
    expect(applyCompletion(fence("¦"), "List comprehension").doc.toString()).toContain(
      "[n^2 for n in range(5) if n > 0]",
    );
    expect(applyCompletion(fence("f(x) = x^2\nf as pl¦"), "plot").doc.toString()).toContain(
      "f as plot(from, to)",
    );
  });
  it("hides multi-line templates from inline completion", () => {
    expect(setup("{{ ¦ }}").labels).not.toContain("Function plot");
    expect(setup("{{ ¦ }}").labels).toContain("List comprehension");
  });
  it("does not activate on an empty line until explicitly invoked", () => {
    expect(setup(fence("¦"), false).result).toBeNull();
    expect(setup(fence("¦")).labels).toContain("Explore calc");
  });
  it("shows argument help, accounting for implicit inputs, overloads, and nested lists", () => {
    const help = (source: string) => {
      const { state, pos } = setup(fence(source));
      return calcCallHelp(state, pos);
    };
    expect(help("range(0, ¦")).toMatchObject({
      name: "range",
      argument: 1,
      variant: 1,
      implicit: false,
    });
    expect(help("[1,2] @slice(1, ¦")).toMatchObject({ name: "slice", argument: 1, implicit: true });
    expect(help("0.375 as %(¦")).toMatchObject({ name: "%", argument: 0, implicit: true });
    expect(help("mean([1,2,3], ¦")).toMatchObject({ name: "mean", argument: 1 });
    expect(help("fn(a,b) = a+b\nfn(1, ¦")).toMatchObject({ name: "fn", argument: 1 });
    expect(help("range(0, 5)¦")).toBeNull();
    expect(help('mean("x, ¦')).toBeNull();
    expect(help("10m/s as km/h(¦")).toMatchObject({ name: "km/h", implicit: true, argument: 0 });
    expect(help("Cr = 1\n100 as Cr(¦")).toMatchObject({ name: "Cr", implicit: true, argument: 0 });
    expect(help("f(x) = x^2\nf as plot(-5, ¦")).toMatchObject({ variant: 1, implicit: true });
    expect(help("f(x) = x^2\nplot(f, -5, ¦")).toMatchObject({ variant: 1, implicit: false });
    expect(help("symbol x\nplot(x^2, x, -5, ¦")).toMatchObject({ variant: 2 });
    expect(help("10m as m^5000(¦")).toBeNull();
  });
  it("composes with the existing prose autocomplete configuration", () => {
    const state = EditorState.create({
      doc: fence("math."),
      extensions: [
        createMarkdownCalcExtension(),
        createNv3AutocompleteExtension({
          providers: [{ source: "test", trigger: "[[", query: () => [] }],
          activateOnTypingDelay: 120,
        }),
      ],
    });
    expect(
      state.languageDataAt("autocomplete", state.doc.toString().indexOf("math.") + 5).length,
    ).toBeGreaterThan(0);
  });
  it("keeps inline calc coordinate brackets and quoted text out of prose completion", async () => {
    for (const source of ["{{ [[¦ }}", '{{ "[[¦" }}', "{{ 1 -> [[¦ }}"]) {
      const { state, pos } = setup(source);
      const contribution = state.facet(nv3AdditionalCompletionSources)[0]!;
      expect(await contribution(new CompletionContext(state, pos, false))).toMatchObject({
        options: [],
      });
    }
    const { state, pos } = setup("A prose [[¦");
    expect(
      await state.facet(nv3AdditionalCompletionSources)[0]!(
        new CompletionContext(state, pos, true),
      ),
    ).toBeNull();
  });
  it("keeps the generated reference synchronized with the catalog", () => {
    expect(readFileSync(new URL("./REFERENCE.md", import.meta.url), "utf8")).toBe(
      renderCalcCatalogReference(),
    );
    expect(calcEntry("list.join")!.signatures[0]).toEqual(["values", 'separator = ", "']);
  });
});
