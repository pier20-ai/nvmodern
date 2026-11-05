import { describe, expect, it } from "bun:test";
import { OrgRegexUtils, restrictionFor } from "uniorg-parse/lib/utils.js";
import { defaultOptions } from "uniorg-parse/lib/parse-options.js";
import { getOrgSyntax } from "./orgSyntax.ts";
import { Text } from "@codemirror/state";

describe("Uniorg fork", () => {
  it("reuses the object regexp within one parser and isolates configured link types", () => {
    const first = new OrgRegexUtils({ ...defaultOptions, linkTypes: ["custom.scheme"] });
    const second = new OrgRegexUtils({ ...defaultOptions, linkTypes: ["different"] });
    expect(first.objectRe()).toBe(first.objectRe());
    expect(first.objectRe().test("custom.scheme:value")).toBe(true);
    expect(second.objectRe().test("custom.scheme:value")).toBe(false);
    expect(first.objectRe().test("different:value")).toBe(false);
    expect(second.objectRe().test("different:value")).toBe(true);
  });

  it("returns independent mutable restrictions for successive and nested parses", () => {
    const first = restrictionFor("citation");
    const second = restrictionFor("citation");
    first.delete("citation-reference");
    expect(second.has("citation-reference")).toBe(true);
    expect(restrictionFor("citation").has("citation-reference")).toBe(true);
    const paragraph = restrictionFor("paragraph");
    paragraph.clear();
    expect(restrictionFor("paragraph").has("link")).toBe(true);
    expect(restrictionFor("table-row")).toEqual(new Set(["table-cell"]));
  });

  it("preserves nested emphasis, citations, and links across document versions", () => {
    const source = "* TODO Heading\nA *bold /italic/* passage [cite:@one; @two] and [[https://example.com][Site]].";
    const first = getOrgSyntax(Text.of(source.split("\n"))).tree;
    const second = getOrgSyntax(Text.of(source.split("\n"))).tree;
    expect(first).toEqual(second);
    const types: string[] = [];
    function walk(node: any) {
      types.push(node.type);
      for (const child of node.children ?? []) walk(child);
    }
    walk(first);
    for (const type of ["bold", "italic", "citation", "citation-reference", "link"]) expect(types).toContain(type);
  });
});
