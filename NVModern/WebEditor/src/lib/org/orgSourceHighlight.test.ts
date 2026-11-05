import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { EditorState } from "@codemirror/state";
import { tags } from "@lezer/highlight";
import { describe, expect, it } from "bun:test";
import { nv3OrgParseStateField } from "../plugins/orgIndex.ts";
import { orgSourceHighlightField } from "./orgSourceHighlight.ts";

const testHighlightStyle = HighlightStyle.define([
  { tag: tags.keyword, color: "#f00" },
  { tag: tags.string, color: "#0a0" },
  { tag: tags.variableName, color: "#00f" },
]);

describe("org source highlighting", () => {
  it("applies embedded-language token classes only inside BEGIN_SRC bodies", () => {
    const source = [
      "#+BEGIN_SRC python",
      "def greet(name):",
      "    return f\"Hello {name}\"",
      "#+END_SRC",
    ].join("\n");
    const state = EditorState.create({
      doc: source,
      extensions: [
        syntaxHighlighting(testHighlightStyle),
        nv3OrgParseStateField,
        orgSourceHighlightField,
      ],
    });
    const bodyFrom = state.doc.line(2).from;
    const bodyTo = state.doc.line(3).to;
    const highlighted: Array<{ from: number; to: number; className: string }> = [];

    state.field(orgSourceHighlightField).between(0, state.doc.length, (from, to, decoration) => {
      if (typeof decoration.spec.class !== "string") return;
      highlighted.push({ from, to, className: decoration.spec.class });
    });

    expect(highlighted.length).toBeGreaterThan(0);
    expect(highlighted.every((range) => range.from >= bodyFrom && range.to <= bodyTo)).toBe(true);
    expect(highlighted.some((range) => source.slice(range.from, range.to) === "def")).toBe(true);
    expect(highlighted.some((range) => source.slice(range.from, range.to) === "return")).toBe(true);
  });
});
