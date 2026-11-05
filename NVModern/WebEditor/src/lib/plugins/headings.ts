import type { EditorState } from "@codemirror/state";
import { getNv3OrgParseResult } from "./orgIndex.ts";

type MarkdownHeadingLevel = 1 | 2 | 3 | 4 | 5 | 6;

export interface Nv3OutlineHeading {
  id: string;
  level: number;
  sourceLevel: number;
  text: string;
  from: number;
  to: number;
  line: number;
}

export interface Nv3TocHeading extends Nv3OutlineHeading {
  level: 1 | 2 | 3;
}

export interface Nv3MarkdownHeadingSection {
  text: string;
  level: MarkdownHeadingLevel;
  from: number;
  to: number;
  line: number;
  bodyFrom: number;
  bodyTo: number;
}

const MAX_LEVELS_TO_SHOW = 3;
const ATX_HEADING_PATTERN = /^\s{0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+[ \t]*)?$/;
const FENCE_PATTERN = /^\s{0,3}(`{3,}|~{3,})/;

function slugify(input: string): string {
  const slug = input
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .slice(0, 60);

  return slug || "heading";
}

function normalizeAtxHeadingText(raw: string): string {
  return raw.trim();
}

function lineMatchesFence(text: string): { marker: "`" | "~"; length: number } | null {
  const match = text.match(FENCE_PATTERN);
  if (!match) return null;

  const fence = match[1] ?? "";
  const marker = fence[0];
  if (marker !== "`" && marker !== "~") return null;

  return {
    marker,
    length: fence.length,
  };
}

function isClosingFence(
  text: string,
  openFence: { marker: "`" | "~"; length: number } | null,
): boolean {
  if (!openFence) return false;

  const pattern = new RegExp(`^\\s{0,3}\\${openFence.marker}{${openFence.length},}\\s*$`);
  return pattern.test(text);
}

function collectMarkdownHeadingCandidates(state: EditorState): Array<{
  text: string;
  from: number;
  to: number;
  line: number;
  sourceLevel: MarkdownHeadingLevel;
}> {
  const candidates: Array<{
    text: string;
    from: number;
    to: number;
    line: number;
    sourceLevel: MarkdownHeadingLevel;
  }> = [];

  let lineNumber = 1;
  let inFrontmatter = state.doc.lines > 0 && state.doc.line(1).text.trim() === "---";
  let openFence: { marker: "`" | "~"; length: number } | null = null;

  while (lineNumber <= state.doc.lines) {
    const line = state.doc.line(lineNumber);
    const text = line.text;
    const trimmed = text.trim();

    if (inFrontmatter) {
      if (lineNumber > 1 && trimmed === "---") {
        inFrontmatter = false;
      }
      lineNumber += 1;
      continue;
    }

    if (openFence) {
      if (isClosingFence(text, openFence)) {
        openFence = null;
      }
      lineNumber += 1;
      continue;
    }

    const fence = lineMatchesFence(text);
    if (fence) {
      openFence = fence;
      lineNumber += 1;
      continue;
    }

    const atxMatch = text.match(ATX_HEADING_PATTERN);
    if (atxMatch) {
      const hashes = atxMatch[1] ?? "";
      const rawText = atxMatch[2] ?? "";
      const headingText = normalizeAtxHeadingText(rawText);

      if (headingText) {
        candidates.push({
          text: headingText,
          from: line.from,
          to: line.to,
          line: line.number,
          sourceLevel: Math.min(hashes.length, 6) as MarkdownHeadingLevel,
        });
      }

      lineNumber += 1;
      continue;
    }

    lineNumber += 1;
  }

  return candidates;
}

export function collectMarkdownHeadingSections(state: EditorState): Nv3MarkdownHeadingSection[] {
  const candidates = collectMarkdownHeadingCandidates(state);
  if (!candidates.length) return [];

  return candidates.map((candidate, index) => {
    let bodyTo = state.doc.length;

    for (let lookahead = index + 1; lookahead < candidates.length; lookahead += 1) {
      const next = candidates[lookahead];
      if (!next) continue;
      if (next.sourceLevel <= candidate.sourceLevel) {
        // End at the last content line, not at the next heading's start. The
        // newline in between belongs to that heading's line: folding through it
        // collapses the separator too and pulls the next heading up onto the
        // folded line.
        bodyTo = Math.max(candidate.to, state.doc.lineAt(next.from).from - 1);
        break;
      }
    }

    return {
      text: candidate.text,
      level: candidate.sourceLevel,
      from: candidate.from,
      to: candidate.to,
      line: candidate.line,
      bodyFrom: candidate.to,
      bodyTo,
    } satisfies Nv3MarkdownHeadingSection;
  });
}

/** Complete source hierarchy for navigation; compact ToC limits are presentation only. */
export function collectMarkdownOutlineHeadings(state: EditorState): Nv3OutlineHeading[] {
  return outlineHeadings(collectMarkdownHeadingCandidates(state));
}

function outlineHeadings(candidates: readonly {
  text: string; from: number; to: number; line: number; sourceLevel: number;
}[]): Nv3OutlineHeading[] {
  return candidates.map((candidate) => ({
    ...candidate,
    id: `${slugify(candidate.text)}-${candidate.line}`,
    level: candidate.sourceLevel,
  }));
}

function compactTocHeadings(headings: readonly Nv3OutlineHeading[]): Nv3TocHeading[] {
  const levels = Array.from(new Set(headings.map((heading) => heading.sourceLevel)))
    .sort((left, right) => left - right).slice(0, MAX_LEVELS_TO_SHOW);
  return headings.filter((heading) => levels.includes(heading.sourceLevel)).map((heading) => ({
    ...heading,
    level: (levels.indexOf(heading.sourceLevel) + 1) as 1 | 2 | 3,
  }));
}

export function collectMarkdownTocHeadings(state: EditorState): Nv3TocHeading[] {
  return compactTocHeadings(collectMarkdownOutlineHeadings(state));
}

export function resolveActiveTocHeadingId(
  headings: readonly Nv3OutlineHeading[],
  viewportFrom: number,
  viewportTo: number,
): string | null {
  if (!headings.length) return null;

  const visible = headings.find((heading) => heading.from >= viewportFrom && heading.from <= viewportTo);
  if (visible) return visible.id;

  for (let index = headings.length - 1; index >= 0; index--) {
    const heading = headings[index];
    if (!heading) continue;
    if (heading.from <= viewportFrom) {
      return heading.id;
    }
  }

  return headings[0]?.id ?? null;
}

export function collectOrgOutlineHeadings(state: EditorState): Nv3OutlineHeading[] {
  const result = getNv3OrgParseResult(state);
  return outlineHeadings((result?.headings ?? []).map((heading) => ({
    text: heading.title,
    from: heading.from,
    to: heading.to,
    line: heading.line,
    sourceLevel: heading.level,
  })));
}

export function collectOrgTocHeadings(state: EditorState): Nv3TocHeading[] {
  return compactTocHeadings(collectOrgOutlineHeadings(state));
}
