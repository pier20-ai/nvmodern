import { describe, expect, it } from "bun:test";
import { renderMarkdownInlineLatex, scanMarkdownLatex } from "./latex.ts";

const skuChurnParagraph = `**Multi-Brand SKU Churn Breaks Traditional Automation:**
   A 3PL like Highline Commerce fulfills orders for 200+ different brands—handling cosmetics in the morning, polybagged apparel in the afternoon, and boxed electronics at night. Traditional fixed automation (conveyor sortation, rigid pick-and-place cells, or custom box erectors) costs **$500k–$5M+**, takes **6–18 months** to integrate, and fails when packaging switches from rigid boxes to deformable polybags and padded mailers. Because OP1 uses a VLA policy ($\\pi_{0.6}\\text{ +UPT}$), it generalizes across deformable bags, variable items, and mixed mailers without re-engineering.`;

describe("renderMarkdownInlineLatex", () => {
  it("renders only the formula in prose containing a bold currency range", () => {
    const segments = renderMarkdownInlineLatex(skuChurnParagraph);
    const math = segments.filter((segment) => segment.kind === "latex");
    expect(math.map((segment) => segment.source)).toEqual([String.raw`$\pi_{0.6}\text{ +UPT}$`]);
    expect(math.every((segment) => !segment.html.includes("katex-error"))).toBe(true);
    expect(segments.map((segment) => segment.kind === "text" ? segment.text : segment.source).join(""))
      .toBe(skuChurnParagraph);
  });

  it("renders mixed table-cell prose and inline math without changing the source text", () => {
    const input = "route $e \\to v$ through \\(\\rho\\)";
    const segments = renderMarkdownInlineLatex(input);

    expect(segments.map((segment) => segment.kind)).toEqual([
      "text",
      "latex",
      "text",
      "latex",
    ]);
    expect(
      segments.map((segment) => segment.kind === "text" ? segment.text : segment.source).join(""),
    ).toBe(input);
    expect(segments.filter((segment) => segment.kind === "latex").every(
      (segment) => segment.kind === "latex" && segment.html.includes("class=\"katex\""),
    )).toBe(true);
  });

  it("leaves inline code, currency prose, and block math as source text", () => {
    for (const input of ["`$x$`", "Costs are $5 today", "$$x^2$$"]) {
      expect(renderMarkdownInlineLatex(input)).toEqual([{ kind: "text", text: input }]);
    }
  });
});

describe("scanMarkdownLatex", () => {
  it("does not consume Markdown formatting or prose after a currency range", () => {
    expect(scanMarkdownLatex(skuChurnParagraph).fragments.map((fragment) => fragment.source))
      .toEqual([String.raw`$\pi_{0.6}\text{ +UPT}$`]);
  });

  it("recognizes currency ranges and amounts followed by Markdown delimiters", () => {
    for (const currency of [
      "**$500k–$5M+**", "**$500k-$5M+**", "**$500k—$5M+**",
      "**$500k–5M+**", "**$500–600**", "**$500 - $600**",
      "**$5M+**", "*$5*", "__$1,000.50__", "~~$50~~",
    ]) {
      expect(scanMarkdownLatex(`Costs ${currency}, then math $x+1$.`).fragments.map((fragment) => fragment.source))
        .toEqual(["$x+1$"]);
    }
  });

  it("detects inline dollar math", () => {
    const index = scanMarkdownLatex("Euler: $e^{i\\pi}+1=0$.");

    expect(index.inlineCount).toBe(1);
    expect(index.blockCount).toBe(0);
    expect(index.fragments[0]?.kind).toBe("inline-dollar");
  });

  it("ignores common currency usage", () => {
    const index = scanMarkdownLatex("Costs are $5 and $10 today.");

    expect(index.inlineCount).toBe(0);
    expect(index.blockCount).toBe(0);
  });

  it("ignores currency amounts with magnitude suffixes in prose", () => {
    const index = scanMarkdownLatex(
      [
        "The typed-financial-DSL tradition is 25 years deep with $6T+ in production deployment today.",
        "**Goldman Sachs and the Versana consortium ($8T loan market) are running real money.**",
      ].join(" "),
    );

    expect(index.inlineCount).toBe(0);
    expect(index.blockCount).toBe(0);
  });

  it("ignores currency prose while preserving later inline math", () => {
    const index = scanMarkdownLatex(
      "Revenue is $6T and costs are $5 while math $x+1$ still works.",
    );

    expect(index.inlineCount).toBe(1);
    expect(index.fragments[0]?.source).toBe("$x+1$");
  });

  it("keeps numeric inline math", () => {
    const index = scanMarkdownLatex("Math still works: $2$, $2x$, $1 + 1$, $x^2$, $1-2$, $2_m$, $2 * 3$, $2* x$, and $2_ x$.");

    expect(index.fragments.map((fragment) => fragment.source)).toEqual([
      "$2$",
      "$2x$",
      "$1 + 1$",
      "$x^2$",
      "$1-2$",
      "$2_m$",
      "$2 * 3$",
      "$2* x$",
      "$2_ x$",
    ]);
  });

  it("ignores escaped dollars and parses valid math later", () => {
    const index = scanMarkdownLatex("Literal \\$x and math $y+1$.");

    expect(index.inlineCount).toBe(1);
    expect(index.fragments[0]?.source).toBe("$y+1$");
  });

  it("ignores dollar pairs embedded in words", () => {
    const index = scanMarkdownLatex("foo$bar$baz");

    expect(index.inlineCount).toBe(0);
  });

  it("ignores code fence and inline code, but keeps real block math", () => {
    const input = [
      "```md",
      "$x$",
      "```",
      "`$a$`",
      "$$",
      "x^2",
      "$$",
    ].join("\n");

    const index = scanMarkdownLatex(input);

    expect(index.inlineCount).toBe(0);
    expect(index.blockCount).toBe(1);
    expect(index.fragments[0]?.kind).toBe("block-dollar");
  });

  const optionalNewlineCases = [
    {
      name: "dollar delimiters and body on one line",
      input: "$$x^2$$",
      kind: "block-dollar",
    },
    {
      name: "dollar opener attached to the body",
      input: "$$x^2\n$$",
      kind: "block-dollar",
    },
    {
      name: "dollar closer attached to the body",
      input: "$$\nx^2$$",
      kind: "block-dollar",
    },
    {
      name: "dollar delimiters on separate lines",
      input: "$$\nx^2\n$$",
      kind: "block-dollar",
    },
    {
      name: "bracket delimiters and body on one line",
      input: "\\[x^2\\]",
      kind: "block-bracket",
    },
    {
      name: "bracket opener attached to the body",
      input: "\\[x^2\n\\]",
      kind: "block-bracket",
    },
    {
      name: "bracket closer attached to the body",
      input: "\\[\nx^2\\]",
      kind: "block-bracket",
    },
    {
      name: "bracket delimiters on separate lines",
      input: "\\[\nx^2\n\\]",
      kind: "block-bracket",
    },
  ] as const;

  for (const sample of optionalNewlineCases) {
    it(`detects ${sample.name}`, () => {
      const index = scanMarkdownLatex(sample.input);

      expect(index.inlineCount).toBe(0);
      expect(index.blockCount).toBe(1);
      expect(index.fragments).toHaveLength(1);
      expect(index.fragments[0]?.kind).toBe(sample.kind);
      expect(index.fragments[0]?.source).toBe(sample.input);
    });
  }
});
