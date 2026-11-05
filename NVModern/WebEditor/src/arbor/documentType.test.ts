import { describe, expect, test } from "bun:test";

import { isArborDocumentPath, prepareArborSource } from "./documentType";

describe("Arbor document type", () => {
  test("activates only for the .outline extension", () => {
    expect(isArborDocumentPath("Projects.outline")).toBe(true);
    expect(isArborDocumentPath("Projects.OUTLINE")).toBe(true);
    expect(isArborDocumentPath("folder/Projects.outline?preview=1")).toBe(true);
    expect(isArborDocumentPath("Projects.md")).toBe(false);
    expect(isArborDocumentPath("Projects.md#lang-arbor/0")).toBe(false);
    expect(isArborDocumentPath(undefined)).toBe(false);
  });

  test("adds the pinned language directive only when absent", () => {
    expect(prepareArborSource("")).toEqual({
      source: "#lang arbor/0\n",
      insertedLanguageDirective: true,
    });
    expect(prepareArborSource("- Existing ^block\n")).toEqual({
      source: "#lang arbor/0\n- Existing ^block\n",
      insertedLanguageDirective: true,
    });
    expect(prepareArborSource("#lang arbor/0\n- Existing ^block\n")).toEqual({
      source: "#lang arbor/0\n- Existing ^block\n",
      insertedLanguageDirective: false,
    });
  });
});
