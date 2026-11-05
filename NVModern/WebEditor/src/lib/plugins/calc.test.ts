import { describe, expect, it } from "bun:test";
import { EditorState } from "@codemirror/state";
import { readFileSync } from "node:fs";
import { EditorView } from "@codemirror/view";
import { CalcPlotWidget } from "./calcPlot.ts";
import {
  buildReactiveCalcSourceChanges,
  buildReactiveInlineCalcSourceChanges,
  createMarkdownCalcExtension,
  getMarkdownCalcEvaluation,
  scanMarkdownCalcDocument,
} from "./calc.ts";

function plotWidgets(state: EditorState): CalcPlotWidget[] {
  const widgets: CalcPlotWidget[] = [];
  for (const decorations of state.facet(EditorView.decorations)) {
    if (typeof decorations === "function") continue;
    decorations.between(0, state.doc.length, (_from, _to, decoration) => {
      if (decoration.spec.widget instanceof CalcPlotWidget) widgets.push(decoration.spec.widget);
    });
  }
  return widgets;
}

describe("calc plot editor integration", () => {
  it("keeps the documented comprehension examples runnable with current saved outputs", () => {
    for (const [path, heading] of [
      ["../calc/README.md", "### List comprehensions"],
      ["../../../test-files/calc-playground.md", "## List comprehensions"],
      ["../../../test-files/calc-plots.md", "## Plot data from comprehensions"],
    ] as const) {
      const source = readFileSync(new URL(path, import.meta.url), "utf8");
      const section = source.split(heading)[1]!.split(/\n#{2,3} /)[0]!;
      const state = EditorState.create({
        doc: section,
        extensions: [createMarkdownCalcExtension()],
      });
      const evaluation = getMarkdownCalcEvaluation(state);
      expect(evaluation.fenceOutputs.length).toBeGreaterThan(0);
      for (const entry of [...evaluation.fenceOutputs, ...evaluation.inlineEvaluations]) {
        if (!entry.result.ok) throw new Error(`${path}: ${entry.result.error.message}`);
        expect(entry.result.ok).toBe(true);
        if (entry.result.ok) expect(entry.result.presentationError).toBeUndefined();
      }
      expect(buildReactiveCalcSourceChanges(state)).toEqual([]);
    }
  });
  it("updates comprehensions in assignments, inline results, and plots without leaking the loop name", () => {
    const doc =
      "Before\n```calc\nscale = 2\nxs = [1, 2, 3]\nsquares = [x^2 * scale for x in xs if x > 1] -> old # keep\n[[x, x*scale] for x in xs] as plot\n```\n{{ [x*scale for x in xs] @sum -> old }}";
    let state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const at = doc.indexOf("scale = 2") + "scale = ".length;
    state = state.update({ changes: { from: at, to: at + 1, insert: "3" } }).state;
    expect(state.doc.toString()).toContain(
      "squares = [x^2 * scale for x in xs if x > 1] -> [12, 27] # keep",
    );
    expect(state.doc.toString()).toContain("{{ [x*scale for x in xs] @sum -> 18 }}");
    expect(plotWidgets(state)[0]!.plot.points).toEqual([
      { x: 1, y: 3 },
      { x: 2, y: 6 },
      { x: 3, y: 9 },
    ]);
    expect(buildReactiveCalcSourceChanges(state)).toEqual([]);
    const highlighted: string[] = [];
    for (const decorations of state.facet(EditorView.decorations)) {
      if (typeof decorations === "function") continue;
      decorations.between(0, state.doc.length, (from, to, decoration) => {
        if (decoration.spec.class === "nv3-calc-keyword")
          highlighted.push(state.doc.sliceString(from, to));
      });
    }
    expect(highlighted).toEqual(["for", "in", "if", "for", "in", "for", "in"]);
  });
  it("draws fenced and inline plots without an output arrow and updates their dependencies", () => {
    const doc =
      '```calc\nfactor = 2\nf(x) = factor * x\nf as plot(0, 1)\n```\n{{ [1, factor] as plot("bar") }}';
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    expect(plotWidgets(state).map((widget) => widget.plot.plotKind)).toEqual(["line", "bar"]);
    expect(plotWidgets(state)[0]!.plot.points.at(-1)!.y).toBe(2);
    const next = state.update({
      changes: { from: doc.indexOf("= 2") + 2, to: doc.indexOf("= 2") + 3, insert: "3" },
    }).state;
    expect(plotWidgets(next)[0]!.plot.points.at(-1)!.y).toBe(3);
    expect(plotWidgets(next)[1]!.plot.points.at(-1)!.y).toBe(3);
  });

  it("syncs stable plot summaries while preserving source comments and raw bindings", () => {
    const doc =
      '```calc\ndata = [2, 3] as plot -> old # keep\ndata @sum -> old\n```\n{{ data as plot("scatter") -> old }}';
    let state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    state = state.update({ changes: { from: 0, insert: "\n" } }).state;
    expect(state.doc.toString()).toContain(
      "data = [2, 3] as plot -> [plot: line, 2 points] # keep",
    );
    expect(state.doc.toString()).toContain("data @sum -> 5");
    expect(state.doc.toString()).toContain('as plot("scatter") -> [plot: scatter, 2 points]');
    expect(buildReactiveCalcSourceChanges(state)).toEqual([]);
    expect(plotWidgets(state)).toHaveLength(2);
  });

  it("isolates plot presentation errors and accepts custom plot presenters", () => {
    const doc =
      '```calc\nbars(data) = plot(data, "bar")\ndata = [1, 2] as bars\nbad = 4 as plot\nbad + 1\n```';
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    expect(plotWidgets(state)).toHaveLength(1);
    expect(plotWidgets(state)[0]!.plot.plotKind).toBe("bar");
    const outputs = getMarkdownCalcEvaluation(state).fenceOutputs;
    expect(outputs.at(-1)!.result).toMatchObject({ ok: true, value: 5 });
    expect(
      outputs.find((entry) => entry.result.ok && entry.result.presentationError)?.result,
    ).toMatchObject({ ok: true, value: 4 });
  });
});

describe("markdown calc scanning", () => {
  it("detects inline expressions while skipping inline code and regular fences", () => {
    const doc = [
      "Value: {{ amount |> math.round(2) }}",
      "Skip `{{ not_calc }}` here",
      "```js",
      "{{ also_not_calc }}",
      "```",
    ].join("\n");

    const result = scanMarkdownCalcDocument(EditorState.create({ doc }).doc);
    expect(result.inlineExpressions).toHaveLength(1);
    expect(result.inlineExpressions[0]?.expression?.kind).toBe("PipeExpression");
  });

  it("detects calc fences and rebases diagnostics to document lines", () => {
    const doc = ["Before", "```calc", "principal = 400000", "broken =", "```", "After"].join("\n");

    const result = scanMarkdownCalcDocument(EditorState.create({ doc }).doc);
    expect(result.fences).toHaveLength(1);
    expect(result.fences[0]?.result.statements).toHaveLength(1);
    expect(result.diagnostics.some((diag) => diag.line === 4)).toBe(true);
  });

  it("parses reactive inline expressions and keeps the output range separate", () => {
    const doc = ["Result: {{ amount * 2 -> old }}", "Again: {{ amount * 2 → stale }}"].join("\n");

    const result = scanMarkdownCalcDocument(EditorState.create({ doc }).doc);
    expect(result.inlineExpressions).toHaveLength(2);
    expect(result.inlineExpressions[0]).toMatchObject({
      expressionSource: " amount * 2 ",
      outputSource: "old",
      separator: "->",
    });
    expect(result.inlineExpressions[1]).toMatchObject({
      expressionSource: " amount * 2 ",
      outputSource: "stale",
      separator: "→",
    });
    expect(result.inlineExpressions[0]?.outputFrom).not.toBeNull();
    expect(result.inlineExpressions[0]?.outputTo).not.toBeNull();
  });

  it("parses reactive calc fence lines and keeps the output range separate", () => {
    const doc = [
      "```calc",
      "monthly |> math.round(2) -> stale",
      "rate |> math.round(3) → old",
      "```",
    ].join("\n");

    const result = scanMarkdownCalcDocument(EditorState.create({ doc }).doc);
    expect(result.fences).toHaveLength(1);
    const reactiveLines = result.fences[0]?.result.lines.filter((line) => line.reactiveOutput);
    expect(reactiveLines).toHaveLength(2);
    expect(reactiveLines?.[0]?.reactiveOutput).toMatchObject({
      expressionSource: "monthly |> math.round(2) ",
      outputSource: "stale",
      separator: "->",
    });
    expect(reactiveLines?.[1]?.reactiveOutput).toMatchObject({
      expressionSource: "rate |> math.round(3) ",
      outputSource: "old",
      separator: "→",
    });
    expect(reactiveLines?.[0]?.statement?.kind).toBe("ExpressionStatement");
  });

  it("reports unclosed calc fences", () => {
    const doc = ["```calc", "x = 1", "y = x + 1"].join("\n");

    const result = scanMarkdownCalcDocument(EditorState.create({ doc }).doc);
    expect(result.fences).toHaveLength(1);
    expect(result.fences[0]?.closed).toBe(false);
    expect(result.diagnostics.some((diag) => diag.code === "calc.unclosed-fence")).toBe(true);
  });

  it("evaluates inline expressions against the nearest preceding calc fence", () => {
    const doc = [
      "```calc",
      "x = 2",
      "double(n) = n * 2",
      "double(x)",
      "```",
      "Result: {{ double(x) |> math.round(0) }}",
    ].join("\n");

    const state = EditorState.create({
      doc,
      extensions: [createMarkdownCalcExtension()],
    });
    const evaluation = getMarkdownCalcEvaluation(state);

    expect(evaluation.fenceOutputs).toHaveLength(1);
    expect(evaluation.fenceOutputs[0]?.result.ok).toBe(true);
    expect(evaluation.inlineEvaluations).toHaveLength(1);
    expect(evaluation.inlineEvaluations[0]?.result.ok).toBe(true);
    expect(evaluation.inlineEvaluations[0]?.reactive).toBe(false);
    if (!evaluation.inlineEvaluations[0]?.result.ok) throw new Error("expected inline evaluation");
    expect(evaluation.inlineEvaluations[0].result.value).toBe(4);
  });

  it("builds source changes for stale reactive inline output", () => {
    const doc = ["```calc", "x = 2", "```", "Result: {{ x |> math.round(0) → 0 }}"].join("\n");

    const state = EditorState.create({ doc });
    const changes = buildReactiveInlineCalcSourceChanges(state);

    expect(changes).toHaveLength(1);
    expect(changes[0]).toMatchObject({ insert: "2" });
    if (
      !changes[0] ||
      typeof changes[0] !== "object" ||
      !("from" in changes[0]) ||
      !("to" in changes[0])
    ) {
      throw new Error("expected calc change");
    }
    expect(state.doc.sliceString(changes[0].from, changes[0].to)).toBe("0");
  });

  it("builds source changes for stale reactive fence output", () => {
    const doc = ["```calc", "x = 2", "x |> math.round(0) -> 0", "```"].join("\n");

    const state = EditorState.create({ doc });
    const changes = buildReactiveCalcSourceChanges(state);

    expect(changes).toHaveLength(1);
    expect(changes[0]).toMatchObject({ insert: "2" });
    if (
      !changes[0] ||
      typeof changes[0] !== "object" ||
      !("from" in changes[0]) ||
      !("to" in changes[0])
    ) {
      throw new Error("expected calc change");
    }
    expect(state.doc.sliceString(changes[0].from, changes[0].to)).toBe("0");
  });

  it("rewrites reactive inline output when calc inputs change", () => {
    const initialDoc = ["```calc", "x = 2", "```", "Result: {{ x -> 2 }}"].join("\n");

    const state = EditorState.create({
      doc: initialDoc,
      extensions: [createMarkdownCalcExtension()],
    });

    const from = state.doc.toString().indexOf("x = 2") + "x = ".length;
    const transaction = state.update({
      changes: { from, to: from + 1, insert: "7" },
    });

    expect(transaction.state.doc.toString()).toContain("{{ x -> 7 }}");
  });

  it("rewrites reactive fence output when calc inputs change", () => {
    const initialDoc = ["```calc", "x = 2", "x -> 2", "```"].join("\n");

    const state = EditorState.create({
      doc: initialDoc,
      extensions: [createMarkdownCalcExtension()],
    });

    const from = state.doc.toString().indexOf("x = 2") + "x = ".length;
    const transaction = state.update({
      changes: { from, to: from + 1, insert: "7" },
    });

    expect(transaction.state.doc.toString()).toContain("x -> 7");
  });

  it("fills empty assignment outputs while preserving comments and downstream bindings", () => {
    const doc = [
      "```calc",
      "# total = ??? -> leave this alone",
      "  ; price -> leave this alone too",
      "price = 3 -> ",
      "total = price * 2 → ",
      "total + 1 -> ",
      "```",
      "Total: {{ total -> }}",
    ].join("\n");
    const state = EditorState.create({ doc });
    const updated = state.update({ changes: buildReactiveCalcSourceChanges(state) }).state;

    expect(updated.doc.toString()).toBe(
      doc
        .replace("price = 3 -> ", "price = 3 -> 3")
        .replace("total = price * 2 → ", "total = price * 2 → 6")
        .replace("total + 1 -> ", "total + 1 -> 7")
        .replace("{{ total -> }}", "{{ total -> 6}}"),
    );
    expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
  });

  it("updates assignment results and their dependents while editing the expression", () => {
    const doc = [
      "```calc",
      "price = 3",
      "total = price * 2 -> 6",
      "total + 1 → 7",
      "```",
      "Total: {{ total -> 6 }}",
    ].join("\n");
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const from = doc.indexOf("* 2") + 2;
    const updated = state.update({ changes: { from, to: from + 1, insert: "4" } }).state;

    expect(updated.doc.toString()).toContain("total = price * 4 -> 12");
    expect(updated.doc.toString()).toContain("total + 1 → 13");
    expect(updated.doc.toString()).toContain("{{ total -> 12 }}");

    const priceFrom = updated.doc.toString().indexOf("price = 3") + "price = ".length;
    const repriced = updated.update({
      changes: { from: priceFrom, to: priceFrom + 1, insert: "5" },
    }).state;
    expect(repriced.doc.toString()).toContain("total = price * 4 -> 20");
    expect(repriced.doc.toString()).toContain("total + 1 → 21");
    expect(repriced.doc.toString()).toContain("{{ total -> 20 }}");
  });

  it("fills an assignment result when the arrow is first typed", () => {
    const doc = "```calc\ntotal = 2 * 3\n```";
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const updated = state.update({
      changes: { from: doc.indexOf("\n```", 4), insert: " -> " },
    }).state;

    expect(updated.doc.toString()).toBe("```calc\ntotal = 2 * 3 -> 6\n```");
  });

  it("shows circular definition errors for reactive assignments", () => {
    const doc = "```calc\ntotal = total + 1 -> stale\n```";
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const evaluation = getMarkdownCalcEvaluation(state);

    expect(evaluation.fenceOutputs[0]?.result).toMatchObject({
      ok: false,
      error: { code: "calc.circular-value" },
    });
    const updated = state.update({ changes: buildReactiveCalcSourceChanges(state) }).state;
    expect(updated.doc.toString()).toContain("⚠");
    expect(updated.doc.toString()).not.toContain("stale");
    expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
  });

  it("preserves trailing comments and their spacing as dependencies change", () => {
    const doc = [
      "Before",
      "```calc",
      "price = 25 # input -> keep this text",
      "total = price * 4 -> 100  # calculate total",
      "total → 100\t; show total",
      "```",
      "Total: {{ total -> 100 }}",
    ].join("\n");
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const from = doc.indexOf("25");
    const updated = state.update({ changes: { from, to: from + 2, insert: "30" } }).state;

    expect(updated.doc.toString()).toBe(
      doc
        .replace("price = 25", "price = 30")
        .replace("-> 100  #", "-> 120  #")
        .replace("→ 100\t;", "→ 120\t;")
        .replace("{{ total -> 100 }}", "{{ total -> 120 }}"),
    );
    expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
  });

  it("fills empty outputs before trailing comments and leaves them stable", () => {
    const doc = [
      "```calc",
      "total = 25 * 4 -> # calculate total",
      "total → ; show total",
      "total -># adjacent comment",
      "total → 0; adjacent stale output",
      "```",
    ].join("\n");
    const state = EditorState.create({ doc });
    const updated = state.update({ changes: buildReactiveCalcSourceChanges(state) }).state;

    expect(updated.doc.toString()).toBe(
      [
        "```calc",
        "total = 25 * 4 -> 100 # calculate total",
        "total → 100 ; show total",
        "total ->100 # adjacent comment",
        "total → 100 ; adjacent stale output",
        "```",
      ].join("\n"),
    );
    expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
  });

  it("quotes string results so comments survive repeated updates", () => {
    const values = ["#hash; semicolon", "don't", 'say "hello"', "back\\slash", "line\nbreak"];
    const doc = [
      "```calc",
      ...values.map(
        (value, index) => `s${index} = ${JSON.stringify(value)} -> stale # keep ${index}`,
      ),
      `items = ["#", ";", "don't"] → stale ; keep list`,
      "```",
    ].join("\n");
    const state = EditorState.create({ doc });
    const updated = state.update({ changes: buildReactiveCalcSourceChanges(state) }).state;

    for (const [index, value] of values.entries()) {
      expect(updated.doc.toString()).toContain(`-> ${JSON.stringify(value)} # keep ${index}`);
    }
    expect(updated.doc.toString()).toContain(`→ ["#", ";", "don't"] ; keep list`);
    expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
  });

  it("preserves trailing comments when a calculation fails and then recovers", () => {
    const doc = "```calc\nx = 0\ntotal = 10 / x -> stale # keep this\n```";
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const failed = state.update({ changes: buildReactiveCalcSourceChanges(state) }).state;
    expect(failed.doc.toString()).toContain("-> ⚠ Division by zero. # keep this");
    expect(buildReactiveCalcSourceChanges(failed)).toEqual([]);

    const from = failed.doc.toString().indexOf("x = 0") + "x = ".length;
    const recovered = failed.update({ changes: { from, to: from + 1, insert: "2" } }).state;
    expect(recovered.doc.toString()).toContain("total = 10 / x -> 5 # keep this");
  });

  it("presents typed assignments and inline results without changing dependent values", () => {
    const doc = [
      "```calc",
      "third = 1//3 as decimal(4) -> # exact fraction",
      "speed = 10m/s as km/h → ; velocity",
      "distance = speed * 20s -> stale",
      "3 + 4i @abs -> stale",
      "symbol x",
      "p = x^2 + 3*x",
      "p @diff(x) -> stale",
      "```",
      "Exact: {{ third * 3 -> stale }}",
      "Percent: {{ third as %(2) -> stale }}",
      "Distance: {{ distance as km(2) -> stale }}",
    ].join("\n");
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const updated = state.update({ changes: buildReactiveCalcSourceChanges(state) }).state;

    expect(updated.doc.toString()).toContain(
      "third = 1//3 as decimal(4) -> 0.3333 # exact fraction",
    );
    expect(updated.doc.toString()).toContain("speed = 10m/s as km/h → 36km/h ; velocity");
    expect(updated.doc.toString()).toContain("distance = speed * 20s -> 200m");
    expect(updated.doc.toString()).toContain("3 + 4i @abs -> 5");
    expect(updated.doc.toString()).toContain("p @diff(x) -> 2*x + 3");
    expect(updated.doc.toString()).toContain("{{ third * 3 -> 1 }}");
    expect(updated.doc.toString()).toContain("{{ third as %(2) -> 33.33% }}");
    expect(updated.doc.toString()).toContain("{{ distance as km(2) -> 0.20km }}");
    expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
  });

  it("updates outputs when a custom presenter or its arguments change", () => {
    const doc = [
      "```calc",
      "label(v, prefix) = prefix + decimal(v, places)",
      'prefix = "$"',
      "places = 2",
      "total = 25 as label(prefix) -> $25.00 # keep",
      "total * 4 -> 100",
      "```",
      "Again: {{ total as label(prefix) -> $25.00 }}",
    ].join("\n");
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const from = doc.indexOf("places = 2") + "places = ".length;
    const updated = state.update({ changes: { from, to: from + 1, insert: "3" } }).state;
    expect(updated.doc.toString()).toContain("total = 25 as label(prefix) -> $25.000 # keep");
    expect(updated.doc.toString()).toContain("{{ total as label(prefix) -> $25.000 }}");
    expect(updated.doc.toString()).toContain("total * 4 -> 100");
    expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
  });

  it("serializes arbitrary presenter text without consuming comments or inline delimiters", () => {
    const values = [
      "# total; note",
      "can't",
      'say "hello"',
      "back\\slash",
      "line\nbreak",
      "}}",
      " padded ",
      "",
    ];
    for (const value of values) {
      const doc = [
        "```calc",
        `label(v) = ${JSON.stringify(value)}`,
        "total = 3 as label -> stale # untouched",
        "total + 1 -> stale",
        "```",
        "Inline: {{ total as label -> stale }} after",
      ].join("\n");
      const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
      const updated = state.update({ changes: buildReactiveCalcSourceChanges(state) }).state;
      const scanned = scanMarkdownCalcDocument(updated.doc);
      expect(scanned.diagnostics).toEqual([]);
      expect(scanned.inlineExpressions).toHaveLength(1);
      expect(updated.doc.toString()).toContain("# untouched");
      expect(updated.doc.toString()).toContain("total + 1 -> 4");
      expect(updated.doc.toString()).toEndWith(" }} after");
      expect(getMarkdownCalcEvaluation(updated).inlineEvaluations[0]?.result).toMatchObject({
        ok: true,
        value: 3,
        presentation: value,
      });
      expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
    }
  });

  it("keeps numeric bindings usable after presenter failures", () => {
    const doc =
      "```calc\nbad(v) = v + 1\ntotal = 3 as bad -> stale # keep\ntotal * 4 -> stale\n```";
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const updated = state.update({ changes: buildReactiveCalcSourceChanges(state) }).state;
    expect(updated.doc.toString()).toContain(
      "total = 3 as bad -> ⚠ Presenter must return a string or plot. # keep",
    );
    expect(updated.doc.toString()).toContain("total * 4 -> 12");
    expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
  });

  it("escapes presentation errors that contain comment characters and closing delimiters", () => {
    const doc = [
      "```calc",
      `bad(v) = present.unit(v, "can't#;}}")`,
      "mass = 1kg as bad -> stale # keep this comment",
      "mass * 2 -> stale",
      "```",
      "Inline: {{ mass as bad -> stale }} after",
    ].join("\n");
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const updated = state.update({ changes: buildReactiveCalcSourceChanges(state) }).state;
    expect(updated.doc.toString()).toContain("# keep this comment");
    expect(updated.doc.toString()).toContain("mass * 2 -> 2kg");
    expect(updated.doc.toString()).toContain("⚠ Unknown unit");
    expect(scanMarkdownCalcDocument(updated.doc).diagnostics).toEqual([]);
    expect(scanMarkdownCalcDocument(updated.doc).inlineExpressions).toHaveLength(1);
    expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
  });

  it("keeps legacy string and list inline outputs valid with the quote-aware delimiter scanner", () => {
    const doc = [
      `String: {{ "can't }} stop" -> old }}`,
      `List: {{ ["can't", "}}", "#;"] -> old }}`,
      `Legacy: {{ "can't" -> can't }}`,
    ].join("\n");
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const updated = state.update({ changes: buildReactiveCalcSourceChanges(state) }).state;
    expect(scanMarkdownCalcDocument(updated.doc).diagnostics).toEqual([]);
    expect(scanMarkdownCalcDocument(updated.doc).inlineExpressions).toHaveLength(3);
    expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
  });

  it("rebases new syntax decorations and preserves inline scope across separate fences", () => {
    const doc = [
      "A long introduction to ensure that inline AST ranges need rebasing.",
      "```calc",
      "symbol x",
      "speed = 10m/s",
      "```",
      "{{ (x + 1)^2 @expand -> stale }}",
      "{{ speed as km/h -> stale }}",
      "```calc",
      "speed = 20m/s",
      "```",
      "{{ speed as km/h -> stale }}",
    ].join("\n");
    const state = EditorState.create({ doc, extensions: [createMarkdownCalcExtension()] });
    const updated = state.update({ changes: buildReactiveCalcSourceChanges(state) }).state;
    expect(updated.doc.toString()).toContain("{{ (x + 1)^2 @expand -> x^2 + 2*x + 1 }}");
    expect(updated.doc.toString()).toContain("{{ speed as km/h -> 36km/h }}");
    expect(updated.doc.toString()).toContain("{{ speed as km/h -> 72km/h }}");
    for (const inline of scanMarkdownCalcDocument(updated.doc).inlineExpressions) {
      expect(inline.expression!.range.from).toBeGreaterThanOrEqual(inline.expressionFrom);
      expect(inline.expression!.range.to).toBeLessThanOrEqual(inline.expressionTo);
    }
    expect(buildReactiveCalcSourceChanges(updated)).toEqual([]);
  });
});
