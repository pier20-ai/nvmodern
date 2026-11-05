import { describe, expect, it } from "bun:test";
import {
  activeEpubOutlineID,
  createEpubThemeOverrideCSS,
  flattenEpubToc,
  isBlockedEpubAttribute,
  isBlockedEpubElementName,
  isExternalEpubHref,
  MAX_EPUB_ARCHIVE_BYTES,
  validateEpubArchiveSize,
} from "./epubHelpers.ts";

describe("EPUB table of contents", () => {
  it("flattens nested navigation while preserving depth and stable IDs", () => {
    expect(flattenEpubToc([
      {
        id: "part",
        label: "Part One",
        href: "part.xhtml",
        subitems: [
          { id: "chapter", label: "Chapter 1", href: "chapter.xhtml#start" },
          { id: "chapter", label: "Chapter 2", href: "chapter-2.xhtml" },
        ],
      },
    ])).toEqual([
      { id: "part", title: "Part One", level: 1, href: "part.xhtml" },
      { id: "chapter", title: "Chapter 1", level: 2, href: "chapter.xhtml#start" },
      { id: "chapter-2", title: "Chapter 2", level: 2, href: "chapter-2.xhtml" },
    ]);
  });

  it("matches the active entry even when the location omits its fragment", () => {
    const outline = flattenEpubToc([
      { id: "one", label: "One", href: "one.xhtml#title" },
      { id: "two", label: "Two", href: "two.xhtml" },
    ]);
    expect(activeEpubOutlineID(outline, "one.xhtml")).toBe("one");
  });
});

describe("EPUB theme override rules", () => {
  it("does not inject inspector CSS for the publisher default theme", () => {
    expect(createEpubThemeOverrideCSS("system", ":root { color: red; }")).toBeNull();
    expect(createEpubThemeOverrideCSS("publisher", ":root { color: red; }")).toBeNull();
  });

  it("maps nvModern tokens only for a named theme", () => {
    const css = createEpubThemeOverrideCSS("paper", ":root { --nv3-color-text: #123; }");
    expect(css).toContain("--nv3-color-text: #123");
    expect(css).toContain("color: var(--nv3-color-text");
    expect(css).toContain("font-size: var(--nv3-document-scale, 100%)");
    expect(css).toContain("!important");
  });
});

describe("EPUB security policy", () => {
  it("rejects oversized archives before parsing", () => {
    expect(() => validateEpubArchiveSize(MAX_EPUB_ARCHIVE_BYTES)).not.toThrow();
    expect(() => validateEpubArchiveSize(MAX_EPUB_ARCHIVE_BYTES + 1)).toThrow("256 MB");
  });

  it("blocks executable and nested browsing elements", () => {
    expect(isBlockedEpubElementName("SCRIPT")).toBe(true);
    expect(isBlockedEpubElementName("iframe")).toBe(true);
    expect(isBlockedEpubElementName("p")).toBe(false);
  });

  it("blocks event handlers and obfuscated executable URLs", () => {
    expect(isBlockedEpubAttribute("onclick", "alert(1)")).toBe(true);
    expect(isBlockedEpubAttribute("href", " java\nscript:alert(1)")).toBe(true);
    expect(isBlockedEpubAttribute("href", "chapter.xhtml#two")).toBe(false);
  });

  it("routes only ordinary external links to the host", () => {
    expect(isExternalEpubHref("https://example.com/help")).toBe(true);
    expect(isExternalEpubHref("mailto:reader@example.com")).toBe(true);
    expect(isExternalEpubHref("chapter.xhtml#two")).toBe(false);
    expect(isExternalEpubHref("javascript:alert(1)")).toBe(false);
  });
});
