import { describe, expect, it } from "bun:test";
import { placeNv3MarginNotes, renderNv3AnnotationNoteHTML } from "./annotationMarginNotes.ts";

describe("renderNv3AnnotationNoteHTML", () => {
  it("renders paragraphs, line breaks, and inline marks", () => {
    expect(renderNv3AnnotationNoteHTML("A **bold** and *soft* `x*2*y`\nnext\n\nSecond")).toBe(
      "<p>A <strong>bold</strong> and <em>soft</em> <code>x*2*y</code><br>next</p><p>Second</p>",
    );
  });

  it("renders dash lists", () => {
    expect(renderNv3AnnotationNoteHTML("- one\n- **two**")).toBe("<ul><li>one</li><li><strong>two</strong></li></ul>");
  });

  it("escapes markup and leaves arithmetic alone", () => {
    expect(renderNv3AnnotationNoteHTML('<img src=x onerror="a()"> 2 * 3 * 4')).toBe(
      "<p>&lt;img src=x onerror=&quot;a()&quot;&gt; 2 * 3 * 4</p>",
    );
    expect(renderNv3AnnotationNoteHTML("snake_case_name")).toBe("<p>snake_case_name</p>");
  });
});

describe("placeNv3MarginNotes", () => {
  it("keeps notes on the right at their anchors when they fit", () => {
    expect(placeNv3MarginNotes([{ top: 0, height: 20 }, { top: 100, height: 20 }], { twoSided: true })).toEqual([
      { top: 0, side: "right" },
      { top: 100, side: "right" },
    ]);
  });

  it("stacks overlapping notes on one side", () => {
    expect(
      placeNv3MarginNotes([{ top: 0, height: 50 }, { top: 10, height: 20 }, { top: 30, height: 5 }], {
        twoSided: false,
        gap: 8,
      }).map((placement) => placement.top),
    ).toEqual([0, 58, 86]);
  });

  it("moves a displaced note to the left when that keeps it closer", () => {
    expect(
      placeNv3MarginNotes([{ top: 0, height: 50 }, { top: 10, height: 20 }, { top: 20, height: 20 }], {
        twoSided: true,
        gap: 8,
      }),
    ).toEqual([
      { top: 0, side: "right" },
      { top: 10, side: "left" },
      { top: 38, side: "left" },
    ]);
  });
});
