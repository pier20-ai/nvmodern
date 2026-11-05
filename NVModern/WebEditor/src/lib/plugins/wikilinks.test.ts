import { describe, expect, it } from "bun:test";
import { parseNv3WikilinkTarget, wikilinkDisplaySegments } from "./wikilinks.ts";

describe("parseNv3WikilinkTarget", () => {
  it("parses heading references", () => {
    expect(parseNv3WikilinkTarget("note/path#Heading")).toEqual({
      raw: "note/path#Heading",
      core: "note/path#Heading",
      note: "note/path",
      alias: "",
      referenceKind: "heading",
      referenceQuery: "Heading",
    });
  });

  it("accepts pasted markdown heading markers in heading references", () => {
    expect(parseNv3WikilinkTarget("note/path### Heading")).toEqual({
      raw: "note/path### Heading",
      core: "note/path### Heading",
      note: "note/path",
      alias: "",
      referenceKind: "heading",
      referenceQuery: "Heading",
    });
  });

  it("parses strict obsidian block references", () => {
    expect(parseNv3WikilinkTarget("note/path#^block-id|Alias")).toEqual({
      raw: "note/path#^block-id|Alias",
      core: "note/path#^block-id",
      note: "note/path",
      alias: "Alias",
      referenceKind: "block",
      referenceQuery: "block-id",
    });
  });

  it("parses current-note heading references", () => {
    expect(parseNv3WikilinkTarget("#Heading")).toEqual({
      raw: "#Heading",
      core: "#Heading",
      note: "",
      alias: "",
      referenceKind: "heading",
      referenceQuery: "Heading",
    });
  });
});

describe("wikilinkDisplaySegments", () => {
  it("isolates note and subpath ranges", () => {
    expect(wikilinkDisplaySegments("note#^block")).toEqual({
      noteFrom: 0,
      noteTo: 4,
      referenceMarkerFrom: 4,
      referenceMarkerTo: 6,
      referenceTextFrom: 6,
      referenceTextTo: 11,
      aliasFrom: null,
      aliasTo: null,
    });
  });

  it("isolates titles from paths and references using source offsets", () => {
    for (const target of ["note/path|Title", "note#Heading|Title", "note#^block|Title", "  note  |  Title  "]) {
      const { aliasFrom, aliasTo } = wikilinkDisplaySegments(target);
      expect(aliasFrom).not.toBeNull();
      expect(aliasTo).not.toBeNull();
      expect(target.slice(aliasFrom!, aliasTo!)).toBe("Title");
    }
  });

  it("keeps the path visible when the title is missing or empty", () => {
    for (const target of ["note/path", "note/path|", "note/path|  "]) {
      expect(wikilinkDisplaySegments(target)).toMatchObject({ aliasFrom: null, aliasTo: null });
    }
  });
});
