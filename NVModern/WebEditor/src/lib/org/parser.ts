import { Text } from "@codemirror/state";
import {
  hasRangeOverlap,
  isEscaped,
  isWhitespace,
  isWordLike,
  type TextRange,
} from "../plugins/scanUtils.ts";

export type Nv3OrgLinkType = "file" | "http" | "https" | "id" | "shell" | "unknown";
export type Nv3OrgChecklistState = "unchecked" | "checked" | "partial";
export type Nv3OrgListKind = "bullet" | "ordered" | "description";
export type Nv3OrgMarkupKind =
  | "bold"
  | "italic"
  | "code"
  | "verbatim"
  | "strike"
  | "latex-dollar"
  | "latex-paren";

export interface Nv3OrgHeadingTag {
  tag: string;
  from: number;
  to: number;
  tokenFrom: number;
  tokenTo: number;
}

export interface Nv3OrgHeading {
  index: number;
  line: number;
  from: number;
  to: number;
  level: number;
  todoKeyword: string | null;
  todoFrom: number | null;
  todoTo: number | null;
  title: string;
  titleFrom: number;
  titleTo: number;
  tags: string[];
  tagRanges: Nv3OrgHeadingTag[];
  parentIndex: number | null;
  sectionFrom: number;
  sectionTo: number;
  sectionToLine: number;
  scheduledTimestampIndex: number | null;
  deadlineTimestampIndex: number | null;
}

export interface Nv3OrgTimestamp {
  line: number;
  from: number;
  to: number;
  raw: string;
  kind: "active" | "inactive";
  date: string;
  day: string;
  time: string | null;
  endTime: string | null;
  context: "inline" | "scheduled" | "deadline";
  headingIndex: number | null;
}

export interface Nv3OrgListItem {
  index: number;
  line: number;
  from: number;
  to: number;
  toLine: number;
  bodyTo: number;
  indent: number;
  depth: number;
  marker: string;
  markerFrom: number;
  markerTo: number;
  kind: Nv3OrgListKind;
  order: string | null;
  checklist: Nv3OrgChecklistState | null;
  checklistFrom: number | null;
  checklistTo: number | null;
  descriptionTerm: string | null;
  descriptionTermFrom: number | null;
  descriptionTermTo: number | null;
  contentFrom: number;
  contentTo: number;
  content: string;
  parentIndex: number | null;
  /** Indent column where content text starts (marker + spacing width). */
  contentIndent: number;
}

export interface Nv3OrgMarkup {
  kind: Nv3OrgMarkupKind;
  line: number;
  from: number;
  to: number;
  contentFrom: number;
  contentTo: number;
  raw: string;
}

export interface Nv3OrgFootnoteDefinition {
  name: string;
  line: number;
  from: number;
  to: number;
  body: string;
  bodyFrom: number;
  bodyTo: number;
}

export interface Nv3OrgFootnoteReference {
  name: string;
  line: number;
  from: number;
  to: number;
  inlineDefinition: string | null;
}

export interface Nv3OrgPropertyEntry {
  key: string;
  value: string;
  line: number;
  from: number;
  to: number;
  valueFrom: number;
  valueTo: number;
}

export interface Nv3OrgPropertiesDrawer {
  from: number;
  to: number;
  fromLine: number;
  toLine: number;
  closed: boolean;
  entries: Nv3OrgPropertyEntry[];
  headingIndex: number | null;
}

export interface Nv3OrgSourceBlock {
  from: number;
  to: number;
  fromLine: number;
  toLine: number;
  closed: boolean;
  language: string | null;
}

export type Nv3OrgSpecialBlockKind = "quote" | "example" | "verse" | "center" | "comment" | string;

export interface Nv3OrgSpecialBlock {
  kind: Nv3OrgSpecialBlockKind;
  from: number;
  to: number;
  fromLine: number;
  toLine: number;
  closed: boolean;
}

export interface Nv3OrgTableCell {
  column: number;
  from: number;
  to: number;
  text: string;
}

export interface Nv3OrgTableRow {
  line: number;
  from: number;
  to: number;
  isRule: boolean;
  cells: Nv3OrgTableCell[];
}

export interface Nv3OrgTable {
  from: number;
  to: number;
  fromLine: number;
  toLine: number;
  rows: Nv3OrgTableRow[];
}

export interface Nv3OrgLink {
  line: number;
  from: number;
  to: number;
  target: string;
  label: string | null;
  type: Nv3OrgLinkType;
  supported: boolean;
}

export interface Nv3OrgDirective {
  line: number;
  from: number;
  to: number;
}

export interface Nv3OrgExcludedRange {
  from: number;
  to: number;
  reason: "source-block" | "top-properties-drawer";
}

export interface Nv3OrgDiagnostic {
  severity: "warning";
  code:
    | "org.unsupported-link-type"
    | "org.unclosed-source-block"
    | "org.unclosed-top-properties";
  message: string;
  line: number;
  from?: number;
  to?: number;
}

export interface Nv3OrgParseCounts {
  headingCount: number;
  listItemCount: number;
  markupCount: number;
  footnoteDefinitionCount: number;
  footnoteReferenceCount: number;
  propertiesDrawerCount: number;
  sourceBlockCount: number;
  specialBlockCount: number;
  tableCount: number;
  tableRowCount: number;
  linkCount: number;
  supportedLinkCount: number;
  timestampCount: number;
}

export interface Nv3OrgParseResult {
  todoKeywords: string[];
  headings: Nv3OrgHeading[];
  timestamps: Nv3OrgTimestamp[];
  listItems: Nv3OrgListItem[];
  markups: Nv3OrgMarkup[];
  footnoteDefinitions: Nv3OrgFootnoteDefinition[];
  footnoteReferences: Nv3OrgFootnoteReference[];
  unresolvedFootnotes: string[];
  topLevelProperties: Nv3OrgPropertiesDrawer[];
  propertiesDrawers: Nv3OrgPropertiesDrawer[];
  directives: Nv3OrgDirective[];
  sourceBlocks: Nv3OrgSourceBlock[];
  specialBlocks: Nv3OrgSpecialBlock[];
  tables: Nv3OrgTable[];
  links: Nv3OrgLink[];
  excludedRanges: Nv3OrgExcludedRange[];
  diagnostics: Nv3OrgDiagnostic[];
  counts: Nv3OrgParseCounts;
}

interface OpenTopLevelProperties {
  fromLine: number;
  from: number;
  entries: Nv3OrgPropertyEntry[];
}

interface OpenSourceBlock {
  fromLine: number;
  from: number;
  language: string | null;
}

interface OpenTable {
  fromLine: number;
  from: number;
  toLine: number;
  to: number;
  rows: Nv3OrgTableRow[];
}

const HEADING_PATTERN = /^(\*+)(\s+)(.*)$/;
const HEADING_TAG_BLOCK_PATTERN = /\s+(:[A-Za-z][A-Za-z0-9_@#%+-]*(?::[A-Za-z][A-Za-z0-9_@#%+-]*)*:)\s*$/;
const HEADING_TAG_TOKEN_PATTERN = /:([A-Za-z][A-Za-z0-9_@#%+-]*)/g;
const TODO_KEYWORD_DECLARATION_PATTERN = /^\s*#\+(?:TODO|SEQ_TODO|TYP_TODO):\s*(.+)$/i;
const ORG_LINK_OPEN = "[[";
const ORG_LINK_CLOSE = "]]";
const ORG_TIMESTAMP_PATTERN = /([<[])(\d{4}-\d{2}-\d{2})\s+([A-Za-z]{3})(?:\s+(\d{2}:\d{2})(?:-(\d{2}:\d{2}))?)?([>\]])/g;
const PLANNING_PATTERN = /(SCHEDULED|DEADLINE):\s*([<[]\d{4}-\d{2}-\d{2}\s+[A-Za-z]{3}(?:\s+\d{2}:\d{2}(?:-\d{2}:\d{2})?)?[>\]])/g;
const FOOTNOTE_DEFINITION_PATTERN = /^(\s*)\[fn:([^\]\s:]+)\](?:\s+(.*))?$/i;
const FOOTNOTE_REFERENCE_PATTERN = /\[fn:([^\]\s:]+)(?::([^\]]+))?\]/gi;
const LIST_ITEM_PATTERN = /^([ \t]*)([-+*]|\d+[.)]|[A-Za-z][.)])([ \t]+)(.*)$/;
const CHECKLIST_PATTERN = /^\[([ xX-])\](?:[ \t]+|$)/;
const DESCRIPTION_LIST_PATTERN = /^(.*?)\s+::(?:\s+(.*))?$/;
const TOP_LEVEL_PROPERTIES_START_PATTERN = /^\s*:PROPERTIES:\s*$/i;
const PROPERTIES_END_PATTERN = /^\s*:END:\s*$/i;
const PROPERTY_ENTRY_PATTERN = /^\s*:([A-Za-z][A-Za-z0-9_@#%:+.-]*):\s*(.*?)\s*$/;
const SOURCE_BLOCK_START_PATTERN = /^\s*#\+BEGIN_SRC(?:\s+([^\s]+))?/i;
const SOURCE_BLOCK_END_PATTERN = /^\s*#\+END_SRC\s*$/i;
const SPECIAL_BLOCK_START_PATTERN = /^\s*#\+BEGIN_([A-Za-z]+)\s*$/i;
const SPECIAL_BLOCK_END_PATTERN = /^\s*#\+END_([A-Za-z]+)\s*$/i;
const TABLE_ROW_PATTERN = /^\s*\|.*\|\s*$/;

const DEFAULT_TODO_KEYWORDS = ["TODO", "DONE"] as const;

function clampRange(from: number, to: number): TextRange | null {
  if (!Number.isFinite(from) || !Number.isFinite(to)) return null;
  if (to <= from) return null;
  return { from, to };
}

function expandIndent(raw: string): number {
  let width = 0;
  for (const char of raw) {
    if (char === "\t") {
      width += 4;
    } else {
      width += 1;
    }
  }
  return width;
}

function parseTodoKeywordDeclarations(expression: string): string[] {
  const tokens = expression.split(/\s+/).filter(Boolean);
  const keywords: string[] = [];

  for (const token of tokens) {
    if (token === "|") continue;

    const keywordMatch = token.match(/^([A-Za-z][A-Za-z0-9_-]*)/);
    if (!keywordMatch) continue;

    const keyword = (keywordMatch[1] ?? "").toUpperCase();
    if (!keyword) continue;

    keywords.push(keyword);
  }

  return keywords;
}

function classifyOrgLinkType(target: string): { type: Nv3OrgLinkType; supported: boolean } {
  const trimmed = target.trim();
  const schemeMatch = trimmed.match(/^([A-Za-z][A-Za-z0-9+.-]*):/);

  if (!schemeMatch) {
    return {
      type: "file",
      supported: true,
    };
  }

  const scheme = (schemeMatch[1] ?? "").toLowerCase();
  switch (scheme) {
    case "file":
      return { type: "file", supported: true };
    case "http":
      return { type: "http", supported: true };
    case "https":
      return { type: "https", supported: true };
    case "id":
      return { type: "id", supported: true };
    case "shell":
      return { type: "shell", supported: true };
    default:
      return { type: "unknown", supported: false };
  }
}

interface ParsedHeading {
  level: number;
  todoKeyword: string | null;
  todoFrom: number | null;
  todoTo: number | null;
  title: string;
  titleFrom: number;
  titleTo: number;
  tags: string[];
  tagRanges: Nv3OrgHeadingTag[];
}

function parseHeadingLine(
  lineText: string,
  lineFrom: number,
  todoKeywords: ReadonlySet<string>,
): ParsedHeading | null {
  const match = lineText.match(HEADING_PATTERN);
  if (!match) return null;

  const stars = match[1] ?? "";
  if (!stars) return null;

  const spaces = match[2] ?? "";
  const body = match[3] ?? "";

  let content = body;
  let contentLength = body.length;
  let tags: string[] = [];
  const tagRanges: Nv3OrgHeadingTag[] = [];

  const tagsMatch = body.match(HEADING_TAG_BLOCK_PATTERN);
  if (tagsMatch) {
    const block = tagsMatch[1] ?? "";
    const blockStart = body.lastIndexOf(block);

    if (block && blockStart >= 0) {
      tags = [];

      HEADING_TAG_TOKEN_PATTERN.lastIndex = 0;
      let tokenMatch: RegExpExecArray | null;
      while ((tokenMatch = HEADING_TAG_TOKEN_PATTERN.exec(block)) !== null) {
        const tag = tokenMatch[1] ?? "";
        if (!tag) continue;

        const tokenFrom = lineFrom + stars.length + spaces.length + blockStart + tokenMatch.index;
        const tokenTo = tokenFrom + 1 + tag.length;

        tags.push(tag);
        tagRanges.push({
          tag,
          tokenFrom,
          tokenTo,
          from: tokenFrom + 1,
          to: tokenTo,
        });

        if (HEADING_TAG_TOKEN_PATTERN.lastIndex === tokenMatch.index) {
          HEADING_TAG_TOKEN_PATTERN.lastIndex += 1;
        }
      }

      const withoutTags = body.slice(0, blockStart);
      content = withoutTags.replace(/\s+$/, "");
      contentLength = content.length;
    }
  }

  const contentBaseOffset = stars.length + spaces.length;

  let todoKeyword: string | null = null;
  let todoFrom: number | null = null;
  let todoTo: number | null = null;
  let title = content.trim();
  let titleFrom = lineFrom + contentBaseOffset + (content.length - content.trimStart().length);
  let titleTo = titleFrom + title.length;

  const todoMatch = content.match(/^([A-Z][A-Z0-9_-]*)(\s+)(.*)$/);
  if (todoMatch) {
    const keyword = todoMatch[1] ?? "";
    if (keyword && todoKeywords.has(keyword)) {
      const spacer = todoMatch[2] ?? "";
      const rest = todoMatch[3] ?? "";
      const restTrimmed = rest.trim();
      const restLeading = rest.length - rest.trimStart().length;

      todoKeyword = keyword;
      todoFrom = lineFrom + contentBaseOffset;
      todoTo = todoFrom + keyword.length;

      title = restTrimmed;
      titleFrom = lineFrom + contentBaseOffset + keyword.length + spacer.length + restLeading;
      titleTo = titleFrom + restTrimmed.length;
    }
  }

  if (!title) {
    titleFrom = lineFrom + contentBaseOffset + contentLength;
    titleTo = titleFrom;
  }

  return {
    level: stars.length,
    todoKeyword,
    todoFrom,
    todoTo,
    title,
    titleFrom,
    titleTo,
    tags,
    tagRanges,
  };
}

function scanOrgLinksInLine(
  lineText: string,
  lineFrom: number,
  lineNo: number,
): { links: Nv3OrgLink[]; ranges: TextRange[] } {
  const links: Nv3OrgLink[] = [];
  const ranges: TextRange[] = [];

  for (let cursor = 0; cursor < lineText.length; cursor++) {
    const open = lineText.indexOf(ORG_LINK_OPEN, cursor);
    if (open < 0) break;

    const close = lineText.indexOf(ORG_LINK_CLOSE, open + ORG_LINK_OPEN.length);
    if (close < 0) break;

    const fromOffset = open;
    const toOffset = close + ORG_LINK_CLOSE.length;
    const inner = lineText.slice(open + 2, close);

    const delimiter = inner.indexOf("][");
    const targetRaw = delimiter >= 0 ? inner.slice(0, delimiter) : inner;
    const labelRaw = delimiter >= 0 ? inner.slice(delimiter + 2) : null;

    const target = targetRaw.trim();
    if (!target) {
      cursor = toOffset - 1;
      continue;
    }

    const label = labelRaw === null ? null : labelRaw.trim();
    const kind = classifyOrgLinkType(target);

    links.push({
      line: lineNo,
      from: lineFrom + fromOffset,
      to: lineFrom + toOffset,
      target,
      label: label && label.length ? label : null,
      type: kind.type,
      supported: kind.supported,
    });

    const range = clampRange(fromOffset, toOffset);
    if (range) {
      ranges.push(range);
    }

    cursor = toOffset - 1;
  }

  return {
    links,
    ranges,
  };
}

function parseTimestampLiteral(
  raw: string,
  from: number,
  lineNo: number,
  context: Nv3OrgTimestamp["context"],
  headingIndex: number | null,
): Nv3OrgTimestamp | null {
  const match = raw.match(/^([<[])(\d{4}-\d{2}-\d{2})\s+([A-Za-z]{3})(?:\s+(\d{2}:\d{2})(?:-(\d{2}:\d{2}))?)?([>\]])$/);
  if (!match) return null;

  const open = match[1] ?? "";
  const date = match[2] ?? "";
  const day = match[3] ?? "";
  const time = match[4] ?? null;
  const endTime = match[5] ?? null;
  const close = match[6] ?? "";

  const validPair = (open === "<" && close === ">") || (open === "[" && close === "]");
  if (!validPair) return null;

  return {
    line: lineNo,
    from,
    to: from + raw.length,
    raw,
    kind: open === "<" ? "active" : "inactive",
    date,
    day,
    time,
    endTime,
    context,
    headingIndex,
  };
}

function scanInlineTimestampsInLine(
  lineText: string,
  lineFrom: number,
  lineNo: number,
  headingIndex: number | null,
  blockedRanges: readonly TextRange[],
): { timestamps: Nv3OrgTimestamp[]; ranges: TextRange[] } {
  const timestamps: Nv3OrgTimestamp[] = [];
  const ranges: TextRange[] = [];

  ORG_TIMESTAMP_PATTERN.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = ORG_TIMESTAMP_PATTERN.exec(lineText)) !== null) {
    const raw = match[0] ?? "";
    if (!raw) continue;

    const fromOffset = match.index;
    const toOffset = fromOffset + raw.length;

    if (hasRangeOverlap(blockedRanges, fromOffset, toOffset)) {
      if (ORG_TIMESTAMP_PATTERN.lastIndex === match.index) {
        ORG_TIMESTAMP_PATTERN.lastIndex += 1;
      }
      continue;
    }

    const timestamp = parseTimestampLiteral(raw, lineFrom + fromOffset, lineNo, "inline", headingIndex);
    if (!timestamp) {
      if (ORG_TIMESTAMP_PATTERN.lastIndex === match.index) {
        ORG_TIMESTAMP_PATTERN.lastIndex += 1;
      }
      continue;
    }

    timestamps.push(timestamp);

    const range = clampRange(fromOffset, toOffset);
    if (range) {
      ranges.push(range);
    }

    if (ORG_TIMESTAMP_PATTERN.lastIndex === match.index) {
      ORG_TIMESTAMP_PATTERN.lastIndex += 1;
    }
  }

  return {
    timestamps,
    ranges,
  };
}

function scanPlanningTimestampsInLine(
  lineText: string,
  lineFrom: number,
  lineNo: number,
  headingIndex: number | null,
): Array<{
  keyword: "SCHEDULED" | "DEADLINE";
  timestamp: Nv3OrgTimestamp;
  localRange: TextRange;
}> {
  const result: Array<{
    keyword: "SCHEDULED" | "DEADLINE";
    timestamp: Nv3OrgTimestamp;
    localRange: TextRange;
  }> = [];

  PLANNING_PATTERN.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = PLANNING_PATTERN.exec(lineText)) !== null) {
    const keyword = (match[1] ?? "").toUpperCase();
    const raw = match[2] ?? "";
    if (!raw) continue;

    if (keyword !== "SCHEDULED" && keyword !== "DEADLINE") {
      if (PLANNING_PATTERN.lastIndex === match.index) {
        PLANNING_PATTERN.lastIndex += 1;
      }
      continue;
    }

    const rawOffset = match.index + (match[0] ?? "").lastIndexOf(raw);
    const timestamp = parseTimestampLiteral(
      raw,
      lineFrom + rawOffset,
      lineNo,
      keyword === "SCHEDULED" ? "scheduled" : "deadline",
      headingIndex,
    );

    if (!timestamp) {
      if (PLANNING_PATTERN.lastIndex === match.index) {
        PLANNING_PATTERN.lastIndex += 1;
      }
      continue;
    }

    const localRange = clampRange(rawOffset, rawOffset + raw.length);
    if (!localRange) {
      if (PLANNING_PATTERN.lastIndex === match.index) {
        PLANNING_PATTERN.lastIndex += 1;
      }
      continue;
    }

    result.push({
      keyword,
      timestamp,
      localRange,
    });

    if (PLANNING_PATTERN.lastIndex === match.index) {
      PLANNING_PATTERN.lastIndex += 1;
    }
  }

  return result;
}

function scanFootnoteReferencesInLine(
  lineText: string,
  lineFrom: number,
  lineNo: number,
  blockedRanges: readonly TextRange[],
): Nv3OrgFootnoteReference[] {
  const references: Nv3OrgFootnoteReference[] = [];

  FOOTNOTE_REFERENCE_PATTERN.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = FOOTNOTE_REFERENCE_PATTERN.exec(lineText)) !== null) {
    const raw = match[0] ?? "";
    const name = match[1] ?? "";
    const inlineDefinition = match[2] ?? null;
    if (!raw || !name) continue;

    const fromOffset = match.index;
    const toOffset = fromOffset + raw.length;
    if (hasRangeOverlap(blockedRanges, fromOffset, toOffset)) {
      if (FOOTNOTE_REFERENCE_PATTERN.lastIndex === match.index) {
        FOOTNOTE_REFERENCE_PATTERN.lastIndex += 1;
      }
      continue;
    }

    references.push({
      name,
      line: lineNo,
      from: lineFrom + fromOffset,
      to: lineFrom + toOffset,
      inlineDefinition: inlineDefinition ? inlineDefinition.trim() : null,
    });

    if (FOOTNOTE_REFERENCE_PATTERN.lastIndex === match.index) {
      FOOTNOTE_REFERENCE_PATTERN.lastIndex += 1;
    }
  }

  return references;
}

function scanDelimitedMarkupInLine(
  lineText: string,
  lineFrom: number,
  lineNo: number,
  delimiter: string,
  kind: Extract<Nv3OrgMarkupKind, "bold" | "italic" | "code" | "verbatim" | "strike">,
  blockedRanges: readonly TextRange[],
): Nv3OrgMarkup[] {
  const markups: Nv3OrgMarkup[] = [];

  for (let index = 0; index < lineText.length; index++) {
    if (lineText[index] !== delimiter) continue;
    if (isEscaped(lineText, index)) continue;
    if (hasRangeOverlap(blockedRanges, index, index + 1)) continue;

    const prev = lineText[index - 1];
    const next = lineText[index + 1];

    if (!next || isWhitespace(next)) continue;
    if (isWordLike(prev) && delimiter !== "*") continue;
    if (delimiter === "/" && prev === ":") continue;

    let close = -1;
    for (let cursor = index + 1; cursor < lineText.length; cursor++) {
      if (lineText[cursor] !== delimiter) continue;
      if (isEscaped(lineText, cursor)) continue;
      if (hasRangeOverlap(blockedRanges, cursor, cursor + 1)) continue;

      const innerEnd = lineText[cursor - 1];
      const after = lineText[cursor + 1];

      if (!innerEnd || isWhitespace(innerEnd)) continue;
      if (isWordLike(after) && delimiter !== "*") continue;

      close = cursor;
      break;
    }

    if (close < 0) continue;

    const fromOffset = index;
    const toOffset = close + 1;

    if (hasRangeOverlap(blockedRanges, fromOffset, toOffset)) {
      index = close;
      continue;
    }

    const raw = lineText.slice(fromOffset, toOffset);
    markups.push({
      kind,
      line: lineNo,
      from: lineFrom + fromOffset,
      to: lineFrom + toOffset,
      contentFrom: lineFrom + fromOffset + 1,
      contentTo: lineFrom + close,
      raw,
    });

    index = close;
  }

  return markups;
}

function scanInlineParenLatex(
  lineText: string,
  lineFrom: number,
  lineNo: number,
  blockedRanges: readonly TextRange[],
): Nv3OrgMarkup[] {
  const markups: Nv3OrgMarkup[] = [];

  for (let index = 0; index < lineText.length - 1; index++) {
    if (lineText[index] !== "\\" || lineText[index + 1] !== "(") continue;
    if (hasRangeOverlap(blockedRanges, index, index + 2)) continue;

    let closeStart = -1;
    for (let cursor = index + 2; cursor < lineText.length - 1; cursor++) {
      if (lineText[cursor] !== "\\" || lineText[cursor + 1] !== ")") continue;
      if (isEscaped(lineText, cursor)) continue;
      if (hasRangeOverlap(blockedRanges, cursor, cursor + 2)) continue;

      closeStart = cursor;
      break;
    }

    if (closeStart < 0) continue;

    const fromOffset = index;
    const toOffset = closeStart + 2;
    const raw = lineText.slice(fromOffset, toOffset);
    const content = lineText.slice(index + 2, closeStart);

    if (!content.trim()) {
      index = toOffset - 1;
      continue;
    }

    markups.push({
      kind: "latex-paren",
      line: lineNo,
      from: lineFrom + fromOffset,
      to: lineFrom + toOffset,
      contentFrom: lineFrom + index + 2,
      contentTo: lineFrom + closeStart,
      raw,
    });

    index = toOffset - 1;
  }

  return markups;
}

function scanInlineDollarLatex(
  lineText: string,
  lineFrom: number,
  lineNo: number,
  blockedRanges: readonly TextRange[],
): Nv3OrgMarkup[] {
  const markups: Nv3OrgMarkup[] = [];

  for (let index = 0; index < lineText.length; index++) {
    if (lineText[index] !== "$") continue;
    if (isEscaped(lineText, index)) continue;
    if (hasRangeOverlap(blockedRanges, index, index + 1)) continue;

    const openPrev = lineText[index - 1];
    const openNext = lineText[index + 1];

    if (!openNext || openNext === "$") continue;
    if (isWhitespace(openNext)) continue;
    if (isWordLike(openPrev) && isWordLike(openNext)) continue;

    let closeIndex = -1;
    for (let cursor = index + 1; cursor < lineText.length; cursor++) {
      if (lineText[cursor] !== "$") continue;
      if (isEscaped(lineText, cursor)) continue;
      if (hasRangeOverlap(blockedRanges, cursor, cursor + 1)) continue;
      if (lineText[cursor - 1] === "$" || lineText[cursor + 1] === "$") continue;

      const closePrev = lineText[cursor - 1];
      const closeNext = lineText[cursor + 1];
      if (isWhitespace(closePrev)) continue;
      if (isWordLike(closePrev) && isWordLike(closeNext)) continue;

      closeIndex = cursor;
      break;
    }

    if (closeIndex < 0) continue;

    const body = lineText.slice(index + 1, closeIndex);
    if (!body.trim()) {
      index = closeIndex;
      continue;
    }

    const fromOffset = index;
    const toOffset = closeIndex + 1;

    markups.push({
      kind: "latex-dollar",
      line: lineNo,
      from: lineFrom + fromOffset,
      to: lineFrom + toOffset,
      contentFrom: lineFrom + fromOffset + 1,
      contentTo: lineFrom + closeIndex,
      raw: lineText.slice(fromOffset, toOffset),
    });

    index = closeIndex;
  }

  return markups;
}

function parseListItemLine(
  lineText: string,
  lineFrom: number,
  lineNo: number,
): Nv3OrgListItem | null {
  const match = lineText.match(LIST_ITEM_PATTERN);
  if (!match) return null;

  const leading = match[1] ?? "";
  const marker = match[2] ?? "";
  const spacing = match[3] ?? "";
  const rest = match[4] ?? "";

  if (!marker || !spacing) return null;

  const markerFromOffset = leading.length;
  const markerToOffset = markerFromOffset + marker.length;
  const contentFromOffset = markerToOffset + spacing.length;

  let kind: Nv3OrgListKind = /^[+*-]$/.test(marker) ? "bullet" : "ordered";
  let order: string | null = null;
  if (kind === "ordered") {
    order = marker.slice(0, -1) || null;
  }

  let checklist: Nv3OrgChecklistState | null = null;
  let checklistFrom: number | null = null;
  let checklistTo: number | null = null;
  let content = rest;
  let contentOffset = contentFromOffset;

  const checklistMatch = rest.match(CHECKLIST_PATTERN);
  if (checklistMatch) {
    const stateChar = checklistMatch[1] ?? " ";
    checklist = stateChar === " " ? "unchecked" : stateChar === "-" ? "partial" : "checked";

    checklistFrom = lineFrom + contentFromOffset;
    checklistTo = checklistFrom + 3;

    content = rest.slice((checklistMatch[0] ?? "").length);
    contentOffset = contentFromOffset + (checklistMatch[0] ?? "").length;
  }

  let descriptionTerm: string | null = null;
  let descriptionTermFrom: number | null = null;
  let descriptionTermTo: number | null = null;

  const descriptionMatch = content.match(DESCRIPTION_LIST_PATTERN);
  if (descriptionMatch) {
    const rawTerm = descriptionMatch[1] ?? "";
    const term = rawTerm.trim();

    if (term) {
      kind = "description";
      descriptionTerm = term;

      const leadingWhitespace = rawTerm.length - rawTerm.trimStart().length;
      const termFromOffset = contentOffset + leadingWhitespace;
      descriptionTermFrom = lineFrom + termFromOffset;
      descriptionTermTo = descriptionTermFrom + term.length;
    }
  }

  const contentIndent = expandIndent(leading) + marker.length + spacing.length;

  return {
    index: 0,     // filled in by caller
    line: lineNo,
    from: lineFrom,
    to: lineFrom + lineText.length,
    toLine: lineNo,  // extended by multi-line scan
    bodyTo: lineFrom + lineText.length,
    indent: expandIndent(leading),
    depth: 0,        // filled in by caller
    marker,
    markerFrom: lineFrom + markerFromOffset,
    markerTo: lineFrom + markerToOffset,
    kind,
    order,
    checklist,
    checklistFrom,
    checklistTo,
    descriptionTerm,
    descriptionTermFrom,
    descriptionTermTo,
    contentFrom: lineFrom + contentOffset,
    contentTo: lineFrom + contentOffset + content.length,
    content,
    parentIndex: null, // filled in by caller
    contentIndent,
  };
}

function parseTableRow(
  lineText: string,
  lineFrom: number,
  lineNo: number,
): Nv3OrgTableRow | null {
  const firstPipe = lineText.indexOf("|");
  const lastPipe = lineText.lastIndexOf("|");
  if (firstPipe < 0 || lastPipe <= firstPipe) return null;

  const segment = lineText.slice(firstPipe + 1, lastPipe);
  const parts = segment.split("|");
  const cells: Nv3OrgTableCell[] = [];

  let cursor = firstPipe + 1;
  for (let index = 0; index < parts.length; index++) {
    const part = parts[index] ?? "";
    const rawFrom = cursor;
    const rawTo = rawFrom + part.length;

    const leading = part.length - part.trimStart().length;
    const trimmed = part.trim();

    const textFrom = rawFrom + leading;
    const textTo = textFrom + trimmed.length;

    cells.push({
      column: index + 1,
      from: lineFrom + textFrom,
      to: lineFrom + textTo,
      text: trimmed,
    });

    cursor = rawTo + 1;
  }

  const compact = segment.replace(/\s/g, "");
  const isRule = compact.length > 0 && /^[-+:]+(?:\+[-+:]+)*$/.test(compact);

  return {
    line: lineNo,
    from: lineFrom + firstPipe,
    to: lineFrom + lastPipe + 1,
    isRule,
    cells,
  };
}

function pushExcludedRange(
  ranges: Nv3OrgExcludedRange[],
  range: Nv3OrgExcludedRange,
): void {
  if (range.to <= range.from) return;
  ranges.push(range);
}

function finalizeOpenTable(tables: Nv3OrgTable[], openTable: OpenTable | null): OpenTable | null {
  if (!openTable) return null;

  tables.push({
    from: openTable.from,
    to: openTable.to,
    fromLine: openTable.fromLine,
    toLine: openTable.toLine,
    rows: openTable.rows,
  });

  return null;
}

function mergeExcludedRanges(ranges: readonly Nv3OrgExcludedRange[]): Nv3OrgExcludedRange[] {
  if (!ranges.length) return [];

  const sorted = [...ranges].sort((left, right) => {
    if (left.from !== right.from) return left.from - right.from;
    return left.to - right.to;
  });

  const merged: Nv3OrgExcludedRange[] = [];

  for (const range of sorted) {
    const previous = merged[merged.length - 1];
    if (!previous) {
      merged.push({ ...range });
      continue;
    }

    if (range.from <= previous.to && range.reason === previous.reason) {
      previous.to = Math.max(previous.to, range.to);
      continue;
    }

    merged.push({ ...range });
  }

  return merged;
}

function closeHeadingsToLine(
  headings: Nv3OrgHeading[],
  headingStack: number[],
  nextHeadingLevel: number,
  doc: Text,
  lineNo: number,
): void {
  const previousLineNo = Math.max(1, lineNo - 1);
  const previousLineTo = lineNo > 1 ? doc.line(previousLineNo).to : 0;

  while (headingStack.length) {
    const lastIndex = headingStack[headingStack.length - 1];
    if (lastIndex === undefined) break;

    const heading = headings[lastIndex];
    if (!heading) {
      headingStack.pop();
      continue;
    }

    if (heading.level < nextHeadingLevel) {
      break;
    }

    heading.sectionTo = previousLineTo;
    heading.sectionToLine = previousLineNo;
    headingStack.pop();
  }
}

/**
 * Close open list items whose indentation is >= the given indent threshold.
 * Sets bodyTo/toLine for each closed item.
 */
function closeListItemsToIndent(
  listItems: Nv3OrgListItem[],
  itemStack: number[],
  indent: number,
  closeTo: number,
  closeToLine: number,
): void {
  while (itemStack.length) {
    const topIdx = itemStack[itemStack.length - 1];
    if (topIdx === undefined) break;
    const topItem = listItems[topIdx];
    if (!topItem || topItem.indent < indent) break;
    topItem.bodyTo = closeTo;
    topItem.toLine = closeToLine;
    itemStack.pop();
  }
}

function closeAllListItems(
  listItems: Nv3OrgListItem[],
  itemStack: number[],
  closeTo: number,
  closeToLine: number,
): void {
  while (itemStack.length) {
    const idx = itemStack.pop();
    if (idx === undefined) continue;
    const item = listItems[idx];
    if (!item) continue;
    item.bodyTo = closeTo;
    item.toLine = closeToLine;
  }
}

function finalizeOpenHeadings(headings: Nv3OrgHeading[], headingStack: number[], doc: Text): void {
  while (headingStack.length) {
    const index = headingStack.pop();
    if (index === undefined) continue;

    const heading = headings[index];
    if (!heading) continue;

    heading.sectionTo = doc.length;
    heading.sectionToLine = doc.lines;
  }
}

function parseOrgDoc(doc: Text): Nv3OrgParseResult {
  const todoKeywords = new Set<string>(DEFAULT_TODO_KEYWORDS);

  const headings: Nv3OrgHeading[] = [];
  const timestamps: Nv3OrgTimestamp[] = [];
  const listItems: Nv3OrgListItem[] = [];
  const markups: Nv3OrgMarkup[] = [];
  const footnoteDefinitions: Nv3OrgFootnoteDefinition[] = [];
  const footnoteReferences: Nv3OrgFootnoteReference[] = [];
  const topLevelProperties: Nv3OrgPropertiesDrawer[] = [];
  const propertiesDrawers: Nv3OrgPropertiesDrawer[] = [];
  const directives: Nv3OrgDirective[] = [];
  const sourceBlocks: Nv3OrgSourceBlock[] = [];
  const specialBlocks: Nv3OrgSpecialBlock[] = [];
  const tables: Nv3OrgTable[] = [];
  const links: Nv3OrgLink[] = [];
  const excludedRanges: Nv3OrgExcludedRange[] = [];
  const diagnostics: Nv3OrgDiagnostic[] = [];

  const headingStack: number[] = [];

  let openTopProperties: OpenTopLevelProperties | null = null;
  let openSourceBlock: OpenSourceBlock | null = null;
  let openSpecialBlock: { kind: Nv3OrgSpecialBlockKind; fromLine: number; from: number } | null = null;
  let openTable: OpenTable | null = null;
  const listItemStack: number[] = [];

  let seenHeading = false;
  let activeHeadingIndex: number | null = null;

  for (let lineNo = 1; lineNo <= doc.lines; lineNo++) {
    const line = doc.line(lineNo);
    const lineText = line.text;
    const lineTrimmed = lineText.trim();

    if (openSourceBlock) {
      if (SOURCE_BLOCK_END_PATTERN.test(lineText)) {
        sourceBlocks.push({
          from: openSourceBlock.from,
          to: line.to,
          fromLine: openSourceBlock.fromLine,
          toLine: lineNo,
          closed: true,
          language: openSourceBlock.language,
        });

        pushExcludedRange(excludedRanges, {
          from: openSourceBlock.from,
          to: line.to,
          reason: "source-block",
        });

        openSourceBlock = null;
      }
      continue;
    }

    if (openSpecialBlock) {
      const endMatch = lineText.match(SPECIAL_BLOCK_END_PATTERN);
      if (endMatch && (endMatch[1] ?? "").toLowerCase() === openSpecialBlock.kind) {
        specialBlocks.push({
          kind: openSpecialBlock.kind,
          from: openSpecialBlock.from,
          to: line.to,
          fromLine: openSpecialBlock.fromLine,
          toLine: lineNo,
          closed: true,
        });
        openSpecialBlock = null;
      }
      continue;
    }

    if (openTopProperties) {
      if (PROPERTIES_END_PATTERN.test(lineText)) {
        const drawer: Nv3OrgPropertiesDrawer = {
          from: openTopProperties.from,
          to: line.to,
          fromLine: openTopProperties.fromLine,
          toLine: lineNo,
          closed: true,
          entries: openTopProperties.entries,
          headingIndex: activeHeadingIndex,
        };
        propertiesDrawers.push(drawer);
        if (activeHeadingIndex === null) {
          topLevelProperties.push(drawer);
        }

        pushExcludedRange(excludedRanges, {
          from: openTopProperties.from,
          to: line.to,
          reason: "top-properties-drawer",
        });

        openTopProperties = null;
        continue;
      }

      const propertyMatch = lineText.match(PROPERTY_ENTRY_PATTERN);
      if (propertyMatch) {
        const key = propertyMatch[1] ?? "";
        const value = propertyMatch[2] ?? "";

        if (key) {
          const keyToken = `:${key}:`;
          const keyStartOffset = lineText.indexOf(keyToken);
          if (keyStartOffset >= 0) {
            const valueStartRaw = keyStartOffset + keyToken.length;
            const leading = lineText.slice(valueStartRaw).length - lineText.slice(valueStartRaw).trimStart().length;
            const trimmedValue = value.trim();

            const valueFrom = line.from + valueStartRaw + leading;
            const valueTo = valueFrom + trimmedValue.length;

            openTopProperties.entries.push({
              key,
              value: trimmedValue,
              line: lineNo,
              from: line.from + keyStartOffset,
              to: line.to,
              valueFrom,
              valueTo,
            });
          }
        }
      }

      continue;
    }

    const todoDeclarationMatch = lineText.match(TODO_KEYWORD_DECLARATION_PATTERN);
    if (todoDeclarationMatch) {
      const declaration = todoDeclarationMatch[1] ?? "";
      for (const keyword of parseTodoKeywordDeclarations(declaration)) {
        todoKeywords.add(keyword);
      }
    }

    // Top-of-file directives: # comments and #+KEYWORD: lines before first heading
    if (!seenHeading && lineTrimmed.length > 0 && lineTrimmed[0] === "#") {
      directives.push({ line: lineNo, from: line.from, to: line.to });
    }

    if (TOP_LEVEL_PROPERTIES_START_PATTERN.test(lineText)) {
      openTable = finalizeOpenTable(tables, openTable);

      openTopProperties = {
        fromLine: lineNo,
        from: line.from,
        entries: [],
      };
      continue;
    }

    const heading = parseHeadingLine(lineText, line.from, todoKeywords);
    if (heading) {
      openTable = finalizeOpenTable(tables, openTable);

      seenHeading = true;
      closeHeadingsToLine(headings, headingStack, heading.level, doc, lineNo);

      const parentIndex = headingStack.length
        ? (headingStack[headingStack.length - 1] ?? null)
        : null;

      const index = headings.length;
      headings.push({
        index,
        line: lineNo,
        from: line.from,
        to: line.to,
        level: heading.level,
        todoKeyword: heading.todoKeyword,
        todoFrom: heading.todoFrom,
        todoTo: heading.todoTo,
        title: heading.title,
        titleFrom: heading.titleFrom,
        titleTo: heading.titleTo,
        tags: heading.tags,
        tagRanges: heading.tagRanges,
        parentIndex,
        sectionFrom: line.from,
        sectionTo: doc.length,
        sectionToLine: doc.lines,
        scheduledTimestampIndex: null,
        deadlineTimestampIndex: null,
      });

      headingStack.push(index);
      activeHeadingIndex = index;
    }

    const srcStartMatch = lineText.match(SOURCE_BLOCK_START_PATTERN);
    if (srcStartMatch) {
      openTable = finalizeOpenTable(tables, openTable);
      openSourceBlock = {
        fromLine: lineNo,
        from: line.from,
        language: (srcStartMatch[1] ?? "").trim().toLowerCase() || null,
      };
      continue;
    }

    const specialStartMatch = lineText.match(SPECIAL_BLOCK_START_PATTERN);
    if (specialStartMatch) {
      openTable = finalizeOpenTable(tables, openTable);
      openSpecialBlock = {
        kind: (specialStartMatch[1] ?? "").toLowerCase() as Nv3OrgSpecialBlockKind,
        fromLine: lineNo,
        from: line.from,
      };
      continue;
    }

    if (TABLE_ROW_PATTERN.test(lineText)) {
      const row = parseTableRow(lineText, line.from, lineNo);
      if (row) {
        if (!openTable) {
          openTable = {
            fromLine: lineNo,
            from: row.from,
            toLine: lineNo,
            to: row.to,
            rows: [row],
          };
        } else {
          openTable.rows.push(row);
          openTable.toLine = lineNo;
          openTable.to = row.to;
        }
      }
      continue;
    }

    openTable = finalizeOpenTable(tables, openTable);

    const localBlockedRanges: TextRange[] = [];

    const scannedLinks = scanOrgLinksInLine(lineText, line.from, lineNo);
    if (scannedLinks.links.length) {
      for (const link of scannedLinks.links) {
        links.push(link);

        if (!link.supported) {
          diagnostics.push({
            severity: "warning",
            code: "org.unsupported-link-type",
            message: `Unsupported org link type in target '${link.target}'.`,
            line: lineNo,
            from: link.from,
            to: link.to,
          });
        }
      }

      localBlockedRanges.push(...scannedLinks.ranges);
    }

    // Block bare URLs from markup scanning (prevents //.../ being parsed as italic)
    const BARE_URL_PATTERN = /https?:\/\/[^\s<>\[\]"'`)(}{]+/g;
    BARE_URL_PATTERN.lastIndex = 0;
    let bareUrlMatch: RegExpExecArray | null;
    while ((bareUrlMatch = BARE_URL_PATTERN.exec(lineText)) !== null) {
      const range = clampRange(bareUrlMatch.index, bareUrlMatch.index + bareUrlMatch[0].length);
      if (range) localBlockedRanges.push(range);
    }

    if (activeHeadingIndex !== null) {
      const planningEntries = scanPlanningTimestampsInLine(
        lineText,
        line.from,
        lineNo,
        activeHeadingIndex,
      );

      for (const entry of planningEntries) {
        const timestampIndex = timestamps.length;
        timestamps.push(entry.timestamp);
        localBlockedRanges.push(entry.localRange);

        const targetHeading = headings[activeHeadingIndex];
        if (!targetHeading) continue;

        if (entry.keyword === "SCHEDULED") {
          targetHeading.scheduledTimestampIndex = timestampIndex;
        } else {
          targetHeading.deadlineTimestampIndex = timestampIndex;
        }
      }
    }

    const inlineTimestampScan = scanInlineTimestampsInLine(
      lineText,
      line.from,
      lineNo,
      activeHeadingIndex,
      localBlockedRanges,
    );
    if (inlineTimestampScan.timestamps.length) {
      timestamps.push(...inlineTimestampScan.timestamps);
      localBlockedRanges.push(...inlineTimestampScan.ranges);
    }

    const definitionMatch = lineText.match(FOOTNOTE_DEFINITION_PATTERN);
    if (definitionMatch) {
      const leading = definitionMatch[1] ?? "";
      const name = definitionMatch[2] ?? "";
      const bodyRaw = definitionMatch[3] ?? "";

      if (name) {
        const token = `[fn:${name}]`;
        const tokenOffset = lineText.indexOf(token, leading.length);
        if (tokenOffset >= 0) {
          const tokenFrom = line.from + tokenOffset;
          const tokenTo = tokenFrom + token.length;
          const bodyStartRaw = tokenOffset + token.length;
          const bodyLeading = lineText.slice(bodyStartRaw).length - lineText.slice(bodyStartRaw).trimStart().length;
          const body = bodyRaw.trim();
          const bodyFrom = line.from + bodyStartRaw + bodyLeading;

          footnoteDefinitions.push({
            name,
            line: lineNo,
            from: tokenFrom,
            to: tokenTo,
            body,
            bodyFrom,
            bodyTo: bodyFrom + body.length,
          });

          const range = clampRange(tokenOffset, tokenOffset + token.length);
          if (range) {
            localBlockedRanges.push(range);
          }
        }
      }
    }

    const footnoteRefs = scanFootnoteReferencesInLine(
      lineText,
      line.from,
      lineNo,
      localBlockedRanges,
    );
    if (footnoteRefs.length) {
      footnoteReferences.push(...footnoteRefs);
      for (const reference of footnoteRefs) {
        const localFrom = reference.from - line.from;
        const localTo = reference.to - line.from;
        const range = clampRange(localFrom, localTo);
        if (range) {
          localBlockedRanges.push(range);
        }
      }
    }

    if (heading) {
      // Headings close all open list items
      closeAllListItems(listItems, listItemStack, line.from, Math.max(1, lineNo - 1));
    } else {
      const listItem = parseListItemLine(lineText, line.from, lineNo);
      if (listItem) {
        // Close items at same or deeper indent
        closeListItemsToIndent(listItems, listItemStack, listItem.indent, line.from, Math.max(1, lineNo - 1));

        // Determine parent and depth
        const parentIdx = listItemStack.length > 0 ? listItemStack[listItemStack.length - 1]! : null;
        const parentItem = parentIdx !== null ? listItems[parentIdx] : null;
        listItem.parentIndex = parentIdx !== null && parentItem && parentItem.indent < listItem.indent ? parentIdx : null;
        listItem.depth = listItem.parentIndex !== null && parentItem ? parentItem.depth + 1 : 0;
        listItem.index = listItems.length;

        listItems.push(listItem);
        listItemStack.push(listItem.index);
      } else if (listItemStack.length > 0) {
        // Non-list line: check if it's a continuation (indented past current item's content indent)
        // or if it closes the list (empty line or insufficient indent)
        const topIdx = listItemStack[listItemStack.length - 1]!;
        const topItem = listItems[topIdx]!;
        const lineIndent = expandIndent(lineText.match(/^[\t ]*/)?.[0] ?? "");

        if (lineTrimmed === "") {
          // Empty lines close all list items
          closeAllListItems(listItems, listItemStack, line.to, lineNo);
        } else if (lineIndent >= topItem.contentIndent) {
          // Continuation line — extend the current item's body
          topItem.bodyTo = line.to;
          topItem.toLine = lineNo;
        } else {
          // Insufficient indent — close items above this indent
          closeAllListItems(listItems, listItemStack, line.from, Math.max(1, lineNo - 1));
        }
      }
    }

    const nextMarkups: Nv3OrgMarkup[] = [];

    nextMarkups.push(
      ...scanDelimitedMarkupInLine(lineText, line.from, lineNo, "*", "bold", localBlockedRanges),
    );
    nextMarkups.push(
      ...scanDelimitedMarkupInLine(lineText, line.from, lineNo, "/", "italic", localBlockedRanges),
    );
    nextMarkups.push(
      ...scanDelimitedMarkupInLine(lineText, line.from, lineNo, "~", "code", localBlockedRanges),
    );
    nextMarkups.push(
      ...scanDelimitedMarkupInLine(lineText, line.from, lineNo, "=", "verbatim", localBlockedRanges),
    );
    nextMarkups.push(
      ...scanDelimitedMarkupInLine(lineText, line.from, lineNo, "+", "strike", localBlockedRanges),
    );
    nextMarkups.push(...scanInlineParenLatex(lineText, line.from, lineNo, localBlockedRanges));
    nextMarkups.push(...scanInlineDollarLatex(lineText, line.from, lineNo, localBlockedRanges));

    if (nextMarkups.length) {
      nextMarkups.sort((left, right) => left.from - right.from || left.to - right.to);

      const accepted: Nv3OrgMarkup[] = [];
      for (const markup of nextMarkups) {
        const overlapsAccepted = accepted.some(
          (existing) => markup.from < existing.to && markup.to > existing.from,
        );
        if (overlapsAccepted) continue;
        accepted.push(markup);
      }

      markups.push(...accepted);
    }

    if (!lineTrimmed) {
      continue;
    }
  }

  openTable = finalizeOpenTable(tables, openTable);

  if (openSourceBlock) {
    const lastLine = doc.line(doc.lines);

    sourceBlocks.push({
      from: openSourceBlock.from,
      to: lastLine.to,
      fromLine: openSourceBlock.fromLine,
      toLine: doc.lines,
      closed: false,
      language: openSourceBlock.language,
    });

    pushExcludedRange(excludedRanges, {
      from: openSourceBlock.from,
      to: lastLine.to,
      reason: "source-block",
    });

    diagnostics.push({
      severity: "warning",
      code: "org.unclosed-source-block",
      message: "Found '#+BEGIN_SRC' without matching '#+END_SRC'.",
      line: openSourceBlock.fromLine,
      from: openSourceBlock.from,
      to: lastLine.to,
    });
  }

  if (openTopProperties) {
    const unclosedDrawer: Nv3OrgPropertiesDrawer = {
      from: openTopProperties.from,
      to: doc.length,
      fromLine: openTopProperties.fromLine,
      toLine: doc.lines,
      closed: false,
      entries: openTopProperties.entries,
      headingIndex: activeHeadingIndex,
    };
    propertiesDrawers.push(unclosedDrawer);
    if (activeHeadingIndex === null) {
      topLevelProperties.push(unclosedDrawer);
    }

    pushExcludedRange(excludedRanges, {
      from: openTopProperties.from,
      to: doc.length,
      reason: "top-properties-drawer",
    });

    diagnostics.push({
      severity: "warning",
      code: "org.unclosed-top-properties",
      message: "Found top-level ':PROPERTIES:' without matching ':END:'.",
      line: openTopProperties.fromLine,
      from: openTopProperties.from,
      to: doc.length,
    });
  }

  closeAllListItems(listItems, listItemStack, doc.length, doc.lines);

  if (openSpecialBlock) {
    specialBlocks.push({
      kind: openSpecialBlock.kind,
      from: openSpecialBlock.from,
      to: doc.length,
      fromLine: openSpecialBlock.fromLine,
      toLine: doc.lines,
      closed: false,
    });
  }

  finalizeOpenHeadings(headings, headingStack, doc);

  const definitionNames = new Set<string>();
  for (const definition of footnoteDefinitions) {
    definitionNames.add(definition.name);
  }

  const unresolvedFootnotes = [...new Set(
    footnoteReferences
      .map((reference) => reference.name)
      .filter((name) => !definitionNames.has(name)),
  )].sort((left, right) => left.localeCompare(right));

  const mergedExcludedRanges = mergeExcludedRanges(excludedRanges);

  const supportedLinkCount = links.reduce((count, link) => count + (link.supported ? 1 : 0), 0);
  const tableRowCount = tables.reduce((count, table) => count + table.rows.length, 0);

  return {
    todoKeywords: [...todoKeywords].sort((left, right) => left.localeCompare(right)),
    headings,
    timestamps,
    listItems,
    markups,
    footnoteDefinitions,
    footnoteReferences,
    unresolvedFootnotes,
    topLevelProperties,
    propertiesDrawers,
    directives,
    sourceBlocks,
    specialBlocks,
    tables,
    links,
    excludedRanges: mergedExcludedRanges,
    diagnostics,
    counts: {
      headingCount: headings.length,
      listItemCount: listItems.length,
      markupCount: markups.length,
      footnoteDefinitionCount: footnoteDefinitions.length,
      footnoteReferenceCount: footnoteReferences.length,
      propertiesDrawerCount: topLevelProperties.length,
      sourceBlockCount: sourceBlocks.length,
      specialBlockCount: specialBlocks.length,
      tableCount: tables.length,
      tableRowCount,
      linkCount: links.length,
      supportedLinkCount,
      timestampCount: timestamps.length,
    },
  };
}

const parseCache = new WeakMap<Text, Nv3OrgParseResult>();

/** Share the current immutable document's index across Org consumers. */
export function parseOrgText(doc: Text): Nv3OrgParseResult {
  let parsed = parseCache.get(doc);
  if (!parsed) {
    parsed = parseOrgDoc(doc);
    parseCache.set(doc, parsed);
  }
  return parsed;
}

export function parseOrgDocument(docText: string): Nv3OrgParseResult {
  const doc = Text.of(docText.split(/\r?\n/));
  return parseOrgText(doc);
}
