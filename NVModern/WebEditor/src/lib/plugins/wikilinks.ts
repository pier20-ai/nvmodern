/**
 * Obsidian-style wikilink subpath support.
 *
 * This file is intentionally the small, shared source of truth for wikilink target parsing.
 * Both the app adapter (`App.tsx`) and CM plugins use it, and the Swift side mirrors the same
 * grammar in `NotesWorkspaceModel.swift`.
 *
 * Supported forms:
 * - `[[note]]`
 * - `[[note#Heading]]`
 * - `[[#Heading]]`
 * - `[[note#^block-id]]`
 * - `[[#^block-id]]`
 * - alias forms like `[[note#Heading|Alias]]`
 *
 * Why this is split out:
 * - click/open behavior needs to know whether the target is a plain note, heading ref, or block ref
 * - link styling wants to dim the subpath (`#...` / `#^...`) independently from the note part
 * - autocomplete needs to understand the same structure so it can switch between file, heading,
 *   and block-id suggestion modes without guessing from raw string slices in multiple places
 *
 * Important CM6 autocomplete gotcha:
 * - For deep wikilinks, the typed query is usually the *full insert text* (for example
 *   `path/to/note.md#hea`) while the visible completion label is often only the trailing part
 *   (`Heading Title` or `^block-id`).
 * - If CodeMirror performs its default label-based filtering, it hides valid results because the
 *   label does not fuzzy-match the entire typed query prefix.
 * - The autocomplete extension therefore treats wikilink completion as provider-authoritative:
 *   the provider reruns as the query changes and returns the already-filtered result set.
 *
 * Performance rules for this feature:
 * - parsing here must stay O(length of target string)
 * - no DOM work
 * - no viewport work
 * - no per-scroll recomputation
 * - all heavy document indexing lives elsewhere and only updates on `docChanged`
 */
export type Nv3WikilinkReferenceKind = "none" | "heading" | "block";

export interface Nv3ParsedWikilinkTarget {
  raw: string;
  core: string;
  note: string;
  alias: string;
  referenceKind: Nv3WikilinkReferenceKind;
  referenceQuery: string;
}

export interface Nv3WikilinkDisplaySegments {
  noteFrom: number;
  noteTo: number;
  referenceMarkerFrom: number | null;
  referenceMarkerTo: number | null;
  referenceTextFrom: number | null;
  referenceTextTo: number | null;
  aliasFrom: number | null;
  aliasTo: number | null;
}

export function parseNv3WikilinkTarget(rawTarget: string): Nv3ParsedWikilinkTarget {
  const raw = typeof rawTarget === "string" ? rawTarget : "";
  const aliasSeparator = raw.indexOf("|");
  const core = (aliasSeparator >= 0 ? raw.slice(0, aliasSeparator) : raw).trim();
  const alias = aliasSeparator >= 0 ? raw.slice(aliasSeparator + 1).trim() : "";

  const blockSeparator = core.indexOf("#^");
  if (blockSeparator >= 0) {
    return {
      raw,
      core,
      note: core.slice(0, blockSeparator).trim(),
      alias,
      referenceKind: "block",
      referenceQuery: core.slice(blockSeparator + 2).trim(),
    };
  }

  const headingSeparator = core.indexOf("#");
  if (headingSeparator >= 0) {
    return {
      raw,
      core,
      note: core.slice(0, headingSeparator).trim(),
      alias,
      referenceKind: "heading",
      referenceQuery: cleanMarkdownHeadingReferenceQuery(core.slice(headingSeparator + 1)),
    };
  }

  return {
    raw,
    core,
    note: core,
    alias,
    referenceKind: "none",
    referenceQuery: "",
  };
}

function cleanMarkdownHeadingReferenceQuery(rawQuery: string): string {
  return rawQuery.trim().replace(/^#+\s*/, "").trim();
}

export function wikilinkDisplaySegments(rawTarget: string): Nv3WikilinkDisplaySegments {
  const parsed = parseNv3WikilinkTarget(rawTarget);
  const noteLength = parsed.note.length;
  const aliasSeparator = rawTarget.indexOf("|");
  const aliasSource = rawTarget.slice(aliasSeparator + 1);
  const aliasFrom = parsed.alias
    ? aliasSeparator + 1 + aliasSource.length - aliasSource.trimStart().length
    : null;
  const aliasTo = aliasFrom === null ? null : aliasFrom + parsed.alias.length;

  if (parsed.referenceKind === "none") {
    return {
      noteFrom: 0,
      noteTo: parsed.core.length,
      referenceMarkerFrom: null,
      referenceMarkerTo: null,
      referenceTextFrom: null,
      referenceTextTo: null,
      aliasFrom,
      aliasTo,
    };
  }

  const markerLength = parsed.referenceKind === "block" ? 2 : 1;
  const markerFrom = noteLength;
  const markerTo = markerFrom + markerLength;
  const referenceTextFrom = markerTo;
  const referenceTextTo = referenceTextFrom + parsed.referenceQuery.length;

  return {
    noteFrom: 0,
    noteTo: noteLength,
    referenceMarkerFrom: markerFrom,
    referenceMarkerTo: markerTo,
    referenceTextFrom,
    referenceTextTo,
    aliasFrom,
    aliasTo,
  };
}

function normalizeHeadingReference(value: string): string {
  return value.trim().replace(/\s+/g, " ").toLocaleLowerCase();
}

export function nv3HeadingReferenceMatches(target: string, candidate: string): boolean {
  const normalizedTarget = normalizeHeadingReference(target);
  const normalizedCandidate = normalizeHeadingReference(candidate);
  if (!normalizedTarget || !normalizedCandidate) return false;
  return normalizedTarget === normalizedCandidate;
}

export function nv3BlockReferenceMatches(target: string, candidate: string): boolean {
  const normalizedTarget = target.trim().toLocaleLowerCase();
  const normalizedCandidate = candidate.trim().toLocaleLowerCase();
  if (!normalizedTarget || !normalizedCandidate) return false;
  return normalizedTarget === normalizedCandidate;
}
