import { describe, expect, test } from "bun:test";
import {
  focusFromWikilinkTarget,
  focusLabel,
  normalizeStackPayload,
  reconcileOverrides,
  stackCardDisplay,
  stackLinkIntent,
  titleFromPath,
} from "./model.ts";

describe("normalizeStackPayload", () => {
  test("normalises cards and drops malformed or duplicate ones", () => {
    const state = normalizeStackPayload({
      cards: [
        { id: "a", path: "notes/Alpha.md", body: "one\r\ntwo", collapsed: true },
        { id: "a", path: "notes/Dup.md" },
        { path: "notes/Beta.org", title: "Beta", focus: { block: "^b1" }, showWholeNote: true },
        { id: "c" },
        "nonsense",
        { id: "d", path: "notes/Delta.txt", fileType: "md", focus: { heading: "  " } },
      ],
      revealId: "notes/Beta.org",
    });

    expect(state.cards.map((card) => card.id)).toEqual(["a", "notes/Beta.org", "d"]);
    expect(state.cards[0]).toMatchObject({
      title: "Alpha",
      body: "one\ntwo",
      fileType: "markdown",
      focus: null,
      collapsed: true,
      showWholeNote: undefined,
    });
    expect(state.cards[1]).toMatchObject({
      title: "Beta",
      fileType: "org",
      focus: { block: "b1" },
      collapsed: false,
      showWholeNote: true,
    });
    expect(state.cards[2]!.fileType).toBe("markdown");
    expect(state.cards[2]!.focus).toBeNull();
    expect(state.revealId).toBe("notes/Beta.org");
  });

  test("ignores a reveal id that is not in the stack and non-object payloads", () => {
    expect(normalizeStackPayload({ cards: [], revealId: "x" })).toEqual({ cards: [], revealId: null });
    expect(normalizeStackPayload(null)).toEqual({ cards: [], revealId: null });
  });
});

describe("helpers", () => {
  test("titleFromPath strips folders and the extension", () => {
    expect(titleFromPath("a/b/Some Note.md")).toBe("Some Note");
    expect(titleFromPath(".hidden")).toBe(".hidden");
  });

  test("focusFromWikilinkTarget reads heading and block references", () => {
    expect(focusFromWikilinkTarget("Note#Heading|Alias")).toEqual({ heading: "Heading" });
    expect(focusFromWikilinkTarget("Note#^abc")).toEqual({ block: "abc" });
    expect(focusFromWikilinkTarget("Note")).toBeNull();
    expect(focusLabel({ block: "abc" })).toBe("^abc");
    expect(focusLabel({ heading: "Plan" })).toBe("Plan");
  });

  test("Shift pushes; everything else opens in main", () => {
    expect(stackLinkIntent({ shiftKey: true })).toBe("push");
    expect(stackLinkIntent({ shiftKey: false })).toBe("openInMain");
  });
});

describe("stackCardDisplay", () => {
  const card = normalizeStackPayload({
    cards: [{ id: "n", path: "n.md", body: "# A\na body\n## B\nb body\n# C\nc body", focus: { heading: "B" } }],
  }).cards[0]!;

  test("shows only the focused section until the whole note is asked for", () => {
    expect(stackCardDisplay(card, false)).toMatchObject({
      doc: "## B\nb body",
      showingSection: true,
      sectionMissing: false,
    });
    expect(stackCardDisplay(card, true)).toMatchObject({
      doc: card.body,
      showingSection: false,
      section: { kind: "heading" },
    });
  });

  test("falls back to the whole note when the section is gone", () => {
    const missing = { ...card, focus: { heading: "Gone" } };
    expect(stackCardDisplay(missing, false)).toMatchObject({
      doc: card.body,
      showingSection: false,
      sectionMissing: true,
      section: null,
    });
  });
});

describe("reconcileOverrides", () => {
  const cards = normalizeStackPayload({
    cards: [
      { id: "a", path: "a.md", collapsed: true },
      { id: "b", path: "b.md", collapsed: false },
    ],
  }).cards;

  test("drops overrides the host has echoed or whose card left the stack", () => {
    const overrides = new Map([
      ["a", true],
      ["b", true],
      ["gone", false],
    ]);
    const next = reconcileOverrides(overrides, cards, (card) => card.collapsed);
    expect([...next.entries()]).toEqual([["b", true]]);
  });

  test("keeps overrides for flags the host does not track", () => {
    const next = reconcileOverrides(new Map([["a", true]]), cards, (card) => card.showWholeNote);
    expect(next.get("a")).toBe(true);
  });
});
