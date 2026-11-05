/**
 * Section ranges for heading and block references (`[[note#Heading]]`,
 * `[[note#^block-id]]`): the part of a note a reference points at.
 *
 * - A heading section is the heading line and its subtree: everything up to
 *   the next heading of the same or a higher level (Markdown `#`, Org `*`).
 *   This matches the Swift transclusion resolver in `NotesWorkspaceModel`.
 * - A block section is the block that carries the `^id` marker: the heading
 *   line, the list item (with its nested children) or the paragraph it ends.
 *   A marker on a line of its own refers to the block just above it (tables,
 *   quotes, lists, code), Obsidian-style.
 *
 * Pure text functions: no editor state, no DOM. Offsets index into the
 * `text` as given (callers should normalise CRLF line endings first).
 */
import { type Nv3FileType } from "./filetype.ts";
import { parseOrgDocument } from "./org/parser.ts";
import { scanMarkdownText } from "./plugins/markdownScanner.ts";
import { nv3BlockReferenceMatches, nv3HeadingReferenceMatches } from "./plugins/wikilinks.ts";

export interface Nv3SectionFocus {
  heading?: string | null;
  block?: string | null;
}

export interface Nv3SectionRange {
  kind: "heading" | "block";
  from: number;
  to: number;
}

interface TextLine {
  text: string;
  from: number;
  to: number;
}

const BLOCK_ID_PATTERN = /(?:^|[\t ]+)\^([A-Za-z0-9_-]+)[\t ]*$/;
const STANDALONE_BLOCK_ID_PATTERN = /^\s*\^[A-Za-z0-9_-]+\s*$/;
const MARKDOWN_HEADING_PATTERN = /^\s{0,3}#{1,6}[ \t]/;
const ORG_HEADING_PATTERN = /^\*+[ \t]/;
const LIST_ITEM_PATTERN = /^\s*(?:[-+*]|\d+[.)])[ \t]/;
/** Fence lines and Org `#+` lines delimit blocks; a paragraph never spans them. */
const BLOCK_BOUNDARY_PATTERN = /^\s*(?:```|~~~|#\+)/;
const ORG_BLOCK_BEGIN_PATTERN = /^\s*#\+begin_/i;
const ORG_BLOCK_END_PATTERN = /^\s*#\+end_/i;

/**
 * Resolves the range a focus refers to. A heading focus wins over a block
 * focus when both are given. Returns null for plain text, for an empty focus,
 * or when the heading/block does not exist.
 */
export function resolveNv3SectionRange(
  text: string,
  fileType: Nv3FileType,
  focus: Nv3SectionFocus | null | undefined,
): Nv3SectionRange | null {
  if (!focus || fileType === "plain") return null;

  const heading = focus.heading?.trim();
  if (heading) {
    return fileType === "org"
      ? resolveNv3OrgHeadingSection(text, heading)
      : resolveNv3MarkdownHeadingSection(text, heading);
  }

  const block = focus.block?.trim().replace(/^\^/, "");
  if (block) return resolveNv3BlockSection(text, fileType, block);

  return null;
}

export function resolveNv3MarkdownHeadingSection(text: string, query: string): Nv3SectionRange | null {
  const headings = scanMarkdownText(text).headingOccurrences;
  const startIndex = headings.findIndex((heading) => nv3HeadingReferenceMatches(query, heading.text));
  if (startIndex < 0) return null;

  const start = headings[startIndex]!;
  const next = headings.slice(startIndex + 1).find((heading) => heading.level <= start.level);
  return {
    kind: "heading",
    from: start.from,
    to: trimTrailingBlankLines(text, start.from, next ? next.from : text.length),
  };
}

export function resolveNv3OrgHeadingSection(text: string, query: string): Nv3SectionRange | null {
  const heading = parseOrgDocument(text).headings.find((candidate) => {
    return nv3HeadingReferenceMatches(query, candidate.title);
  });
  if (!heading) return null;

  return {
    kind: "heading",
    from: heading.sectionFrom,
    to: trimTrailingBlankLines(text, heading.sectionFrom, heading.sectionTo),
  };
}

export function resolveNv3BlockSection(
  text: string,
  fileType: Nv3FileType,
  blockID: string,
): Nv3SectionRange | null {
  if (fileType === "plain") return null;

  const lines = splitLines(text);
  const markerLine = findBlockMarkerLine(text, lines, fileType, blockID);
  if (markerLine < 0) return null;

  const isHeading = fileType === "org" ? ORG_HEADING_PATTERN : MARKDOWN_HEADING_PATTERN;
  const line = lines[markerLine]!;

  if (STANDALONE_BLOCK_ID_PATTERN.test(line.text)) {
    let end = markerLine - 1;
    while (end >= 0 && isBlank(lines[end]!.text)) end -= 1;
    if (end < 0) return { kind: "block", from: line.from, to: line.to };

    // The whole block above: contiguous non-blank lines, so a list or table
    // is taken entire. A heading line is a block of its own.
    let start = end;
    while (start > 0 && !isHeading.test(lines[start]!.text)) {
      const previous = lines[start - 1]!.text;
      if (isBlank(previous) || isHeading.test(previous)) break;
      start -= 1;
    }
    return { kind: "block", from: lines[start]!.from, to: lines[end]!.to };
  }

  if (isHeading.test(line.text)) {
    return { kind: "block", from: line.from, to: line.to };
  }

  if (LIST_ITEM_PATTERN.test(line.text)) {
    const indent = indentWidth(line.text);
    let end = markerLine;
    while (end + 1 < lines.length) {
      const next = lines[end + 1]!.text;
      if (isBlank(next) || indentWidth(next) <= indent) break;
      end += 1;
    }
    return { kind: "block", from: line.from, to: lines[end]!.to };
  }

  // A paragraph (or list-item continuation): walk up to the blank line,
  // heading or list item that starts it.
  let start = markerLine;
  while (start > 0) {
    if (LIST_ITEM_PATTERN.test(lines[start]!.text)) break;
    const previous = lines[start - 1]!.text;
    if (isBlank(previous) || isHeading.test(previous) || BLOCK_BOUNDARY_PATTERN.test(previous)) break;
    start -= 1;
  }
  return { kind: "block", from: lines[start]!.from, to: line.to };
}

function findBlockMarkerLine(
  text: string,
  lines: readonly TextLine[],
  fileType: Nv3FileType,
  blockID: string,
): number {
  if (fileType === "markdown") {
    // The Markdown scanner already skips frontmatter, fences and inline code.
    const occurrence = scanMarkdownText(text).blockIDOcurrences.find((candidate) => {
      return nv3BlockReferenceMatches(blockID, candidate.id);
    });
    return occurrence ? occurrence.line - 1 : -1;
  }

  let inBlock = false;
  for (let index = 0; index < lines.length; index += 1) {
    const lineText = lines[index]!.text;
    if (inBlock) {
      if (ORG_BLOCK_END_PATTERN.test(lineText)) inBlock = false;
      continue;
    }
    if (ORG_BLOCK_BEGIN_PATTERN.test(lineText)) {
      inBlock = true;
      continue;
    }
    const match = lineText.match(BLOCK_ID_PATTERN);
    if (match && nv3BlockReferenceMatches(blockID, match[1] ?? "")) return index;
  }
  return -1;
}

function splitLines(text: string): TextLine[] {
  const lines: TextLine[] = [];
  let from = 0;
  for (const lineText of text.split("\n")) {
    lines.push({ text: lineText, from, to: from + lineText.length });
    from += lineText.length + 1;
  }
  return lines;
}

function trimTrailingBlankLines(text: string, from: number, to: number): number {
  let end = Math.min(to, text.length);
  while (end > from && /\s/.test(text[end - 1] ?? "")) end -= 1;
  return end;
}

function isBlank(lineText: string): boolean {
  return lineText.trim().length === 0;
}

function indentWidth(lineText: string): number {
  let width = 0;
  for (const character of lineText) {
    if (character === " ") width += 1;
    else if (character === "\t") width += 4;
    else break;
  }
  return width;
}
