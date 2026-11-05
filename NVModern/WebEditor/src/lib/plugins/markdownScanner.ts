import { Text } from "@codemirror/state";
import {
  hasRangeOverlap,
  isDigit,
  isEscaped,
  isWordLike,
  rangeContainsIndex,
  resetIfStalled,
  type TextRange,
} from "./scanUtils.ts";
import {
  createMarkdownScannerContext,
  isMarkdownLineScannable,
  type Nv3ScannerLineContext,
} from "./scannerContext.ts";
import type { DocumentScanIndex } from "./documentIndex.ts";

/**
 * #tag grammar
 * - starts with #
 * - tag starts with a letter
 * - allowed chars: letters, digits, _ and -
 * - bounded by whitespace/punctuation/end
 */
const HASH_TAG_PATTERN = /(^|[\s([{>"'])#([A-Za-z][A-Za-z0-9_-]{0,63})(?=$|[\s.,!?;:)}\]"'])/g;
const HEADING_PREFIX_PATTERN = /^\s{0,3}#{1,6}\s+/;
const HEADING_TRAILING_TAGS_PATTERN =
  /\s+(:[A-Za-z][A-Za-z0-9_-]*(?:=[^:\s]+)?(?::[A-Za-z][A-Za-z0-9_-]*(?:=[^:\s]+)?)*:)\s*$/;
const HEADING_TAG_TOKEN_PATTERN = /:([A-Za-z][A-Za-z0-9_-]*(?:=[^:\s]+)?)/g;

const MENTION_PATTERN =
  /(^|[\s([{>"'])@([A-Za-z][A-Za-z0-9._-]{0,63})(?=$|[\s.,!?;:)}\]"'])/g;

const TRANSCLUSION_PATTERN = /!\[\[([^\]\n]+?)\]\]/g;
const WIKILINK_PATTERN = /\[\[([^\]\n]+?)\]\]/g;
const PREVIEW_PATTERN = /!\[([^\]\n]*)\]\(([^)\n]+)\)/g;
const MARKDOWN_LINK_PATTERN = /\[([^\]\n]+)\]\(([^)\n]+)\)/g;

const TASK_MARKER_PATTERN = /^(\s{0,3}(?:[-+*]|\d+[.)])\s+)\[([ xX])\](?=\s|$)/;
const ATX_HEADING_PATTERN = /^\s{0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+[ \t]*)?$/;
const BLOCK_ID_PATTERN = /(?:^|[\t ]+)\^([A-Za-z0-9_-]+)[\t ]*$/;
const OPENING_FENCE_PATTERN = /^\s*```\s*([A-Za-z0-9_+-]+)?\s*$/;
const STANDALONE_TRANSCLUSION_PATTERN = /^\s*(!\[\[([^\]\n]+?)\]\])\s*$/;

const BLOCK_DOLLAR_STANDALONE_PATTERN = /^\s*\$\$\s*$/;
const BLOCK_BRACKET_OPEN_PATTERN = /^\s*\\\[\s*$/;
const BLOCK_DOLLAR_SINGLE_LINE_PATTERN = /^\s*\$\$(.+?)\$\$\s*$/;
const BLOCK_BRACKET_SINGLE_LINE_PATTERN = /^\s*\\\[(.+?)\\\]\s*$/;
const BLOCK_DOLLAR_LEADING_OPEN_PATTERN = /^\s*\$\$/;
const BLOCK_BRACKET_LEADING_OPEN_PATTERN = /^\s*\\\[/;
const BLOCK_DOLLAR_TRAILING_CLOSE_PATTERN = /\$\$\s*$/;
const BLOCK_BRACKET_TRAILING_CLOSE_PATTERN = /\\\]\s*$/;
const BLOCK_DOLLAR_TRAILING_OPEN_PATTERN = /^(.*\S)\s*\$\$\s*$/;
const INLINE_MATH_NUMBER_CONTINUATIONS = new Set([
  "+",
  "-",
  "*",
  "/",
  "=",
  "<",
  ">",
  "^",
  "_",
  "\\",
  "{",
  "(",
  "[",
]);

export interface Nv3MarkdownHashTagOccurrence {
  tag: string;
  from: number;
  to: number;
  line: number;
}

export interface Nv3MarkdownHeadingTagOccurrence {
  tag: string;
  from: number;
  to: number;
  line: number;
}

export interface Nv3MarkdownMentionOccurrence {
  mention: string;
  from: number;
  to: number;
  line: number;
}

export interface Nv3MarkdownTaskCheckboxOccurrence {
  from: number;
  to: number;
  line: number;
  checked: boolean;
}

export interface Nv3MarkdownHeadingOccurrence {
  text: string;
  from: number;
  to: number;
  line: number;
  level: 1 | 2 | 3 | 4 | 5 | 6;
}

export interface Nv3MarkdownBlockIDOccurrence {
  id: string;
  from: number;
  to: number;
  line: number;
  lineFrom: number;
}

export type Nv3MarkdownLinkKind = "wikilink" | "transclusion" | "preview";

export interface Nv3MarkdownLinkOccurrence {
  kind: Nv3MarkdownLinkKind;
  target: string;
  from: number;
  to: number;
  line: number;
}

export interface Nv3MarkdownInlineLinkOccurrence {
  href: string;
  label: string;
  from: number;
  to: number;
  line: number;
  labelFrom: number;
  labelTo: number;
  urlFrom: number;
  urlTo: number;
}

export interface Nv3MarkdownCodeFenceBlock {
  fromLine: number;
  toLine: number;
  language: string | null;
  closed: boolean;
}

export interface Nv3MarkdownStandaloneTransclusionOccurrence {
  target: string;
  from: number;
  to: number;
  line: number;
}

export type Nv3MarkdownLatexFragmentKind =
  | "inline-dollar"
  | "inline-paren"
  | "block-dollar"
  | "block-bracket";

export interface Nv3MarkdownLatexFragment {
  kind: Nv3MarkdownLatexFragmentKind;
  source: string;
  from: number;
  to: number;
  line: number;
  toLine?: number;
}

export interface Nv3MarkdownScanIndex {
  hashTagOccurrences: Nv3MarkdownHashTagOccurrence[];
  headingTagOccurrences: Nv3MarkdownHeadingTagOccurrence[];
  mentionOccurrences: Nv3MarkdownMentionOccurrence[];
  taskCheckboxOccurrences: Nv3MarkdownTaskCheckboxOccurrence[];
  headingOccurrences: Nv3MarkdownHeadingOccurrence[];
  blockIDOcurrences: Nv3MarkdownBlockIDOccurrence[];
  linkOccurrences: Nv3MarkdownLinkOccurrence[];
  inlineLinkOccurrences: Nv3MarkdownInlineLinkOccurrence[];
  codeFenceBlocks: Nv3MarkdownCodeFenceBlock[];
  standaloneTransclusions: Nv3MarkdownStandaloneTransclusionOccurrence[];
  latexFragments: Nv3MarkdownLatexFragment[];
}

function scanTags(
  line: Nv3ScannerLineContext,
  hashTagOccurrences: Nv3MarkdownHashTagOccurrence[],
  headingTagOccurrences: Nv3MarkdownHeadingTagOccurrence[],
): void {
  const text = line.text;

  HASH_TAG_PATTERN.lastIndex = 0;
  let hashMatch: RegExpExecArray | null;
  while ((hashMatch = HASH_TAG_PATTERN.exec(text)) !== null) {
    const prefix = hashMatch[1] ?? "";
    const tag = hashMatch[2] ?? "";
    if (!tag) {
      resetIfStalled(HASH_TAG_PATTERN, hashMatch);
      continue;
    }

    const startOffset = hashMatch.index + prefix.length;
    const endOffset = startOffset + 1 + tag.length;

    if (hasRangeOverlap(line.inlineCodeRanges, startOffset, endOffset)) {
      resetIfStalled(HASH_TAG_PATTERN, hashMatch);
      continue;
    }

    hashTagOccurrences.push({
      tag,
      from: line.from + startOffset,
      to: line.from + endOffset,
      line: line.lineNo,
    });

    resetIfStalled(HASH_TAG_PATTERN, hashMatch);
  }

  if (!HEADING_PREFIX_PATTERN.test(text)) return;

  const trailingTagsMatch = text.match(HEADING_TRAILING_TAGS_PATTERN);
  if (!trailingTagsMatch) return;

  const trailingTagsRaw = trailingTagsMatch[1] ?? "";
  if (!trailingTagsRaw) return;

  const blockStartOffset = text.lastIndexOf(trailingTagsRaw);
  if (blockStartOffset < 0) return;

  HEADING_TAG_TOKEN_PATTERN.lastIndex = 0;
  let headingTagMatch: RegExpExecArray | null;

  while ((headingTagMatch = HEADING_TAG_TOKEN_PATTERN.exec(trailingTagsRaw)) !== null) {
    const tag = headingTagMatch[1] ?? "";
    if (!tag) {
      resetIfStalled(HEADING_TAG_TOKEN_PATTERN, headingTagMatch);
      continue;
    }

    const tokenStartOffset = blockStartOffset + headingTagMatch.index;
    const tokenEndOffset = tokenStartOffset + 1 + tag.length;
    const textStartOffset = tokenStartOffset + 1;
    const textEndOffset = tokenEndOffset;

    if (hasRangeOverlap(line.inlineCodeRanges, tokenStartOffset, tokenEndOffset)) {
      resetIfStalled(HEADING_TAG_TOKEN_PATTERN, headingTagMatch);
      continue;
    }

    headingTagOccurrences.push({
      tag,
      from: line.from + textStartOffset,
      to: line.from + textEndOffset,
      line: line.lineNo,
    });

    resetIfStalled(HEADING_TAG_TOKEN_PATTERN, headingTagMatch);
  }
}

function scanMentions(
  line: Nv3ScannerLineContext,
  mentionOccurrences: Nv3MarkdownMentionOccurrence[],
): void {
  const text = line.text;

  MENTION_PATTERN.lastIndex = 0;
  let mentionMatch: RegExpExecArray | null;

  while ((mentionMatch = MENTION_PATTERN.exec(text)) !== null) {
    const prefix = mentionMatch[1] ?? "";
    const mention = mentionMatch[2] ?? "";
    if (!mention) {
      resetIfStalled(MENTION_PATTERN, mentionMatch);
      continue;
    }

    const startOffset = mentionMatch.index + prefix.length;
    const endOffset = startOffset + 1 + mention.length;

    if (hasRangeOverlap(line.inlineCodeRanges, startOffset, endOffset)) {
      resetIfStalled(MENTION_PATTERN, mentionMatch);
      continue;
    }

    mentionOccurrences.push({
      mention,
      from: line.from + startOffset,
      to: line.from + endOffset,
      line: line.lineNo,
    });

    resetIfStalled(MENTION_PATTERN, mentionMatch);
  }
}

function scanTaskCheckboxes(
  line: Nv3ScannerLineContext,
  taskCheckboxOccurrences: Nv3MarkdownTaskCheckboxOccurrence[],
): void {
  const match = line.text.match(TASK_MARKER_PATTERN);
  if (!match) return;

  const prefix = match[1] ?? "";
  const stateChar = match[2] ?? " ";

  const from = line.from + prefix.length;
  const to = from + 3;

  taskCheckboxOccurrences.push({
    from,
    to,
    line: line.lineNo,
    checked: stateChar !== " ",
  });
}

function scanHeadingsAndBlockIDs(
  line: Nv3ScannerLineContext,
  headingOccurrences: Nv3MarkdownHeadingOccurrence[],
  blockIDOcurrences: Nv3MarkdownBlockIDOccurrence[],
): void {
  const headingMatch = line.text.match(ATX_HEADING_PATTERN);
  if (headingMatch) {
    const hashes = headingMatch[1] ?? "";
    let headingText = headingMatch[2]?.trim() ?? "";
    const trailingTagsMatch = headingText.match(HEADING_TRAILING_TAGS_PATTERN);
    if (trailingTagsMatch?.[0]) {
      headingText = headingText.slice(0, headingText.length - trailingTagsMatch[0].length).trimEnd();
    }

    if (hashes && headingText) {
      headingOccurrences.push({
        text: headingText,
        from: line.from,
        to: line.to,
        line: line.lineNo,
        level: Math.max(1, Math.min(6, hashes.length)) as 1 | 2 | 3 | 4 | 5 | 6,
      });
    }
  }

  const blockIDMatch = line.text.match(BLOCK_ID_PATTERN);
  if (!blockIDMatch) return;

  const fullToken = blockIDMatch[0] ?? "";
  const blockID = blockIDMatch[1] ?? "";
  if (!fullToken || !blockID) return;

  const endOffset = line.text.length;
  const startOffset = endOffset - fullToken.length + fullToken.lastIndexOf("^");
  const tokenEndOffset = startOffset + 1 + blockID.length;

  if (hasRangeOverlap(line.inlineCodeRanges, startOffset, tokenEndOffset)) {
    return;
  }

  blockIDOcurrences.push({
    id: blockID,
    from: line.from + startOffset,
    to: line.from + tokenEndOffset,
    line: line.lineNo,
    lineFrom: line.from,
  });
}

function scanStandaloneTransclusions(
  line: Nv3ScannerLineContext,
  standaloneTransclusions: Nv3MarkdownStandaloneTransclusionOccurrence[],
): void {
  const match = line.text.match(STANDALONE_TRANSCLUSION_PATTERN);
  if (!match) return;

  const token = match[1] ?? "";
  const target = match[2]?.trim() ?? "";
  if (!token || !target) return;

  const tokenStart = line.text.indexOf(token);
  if (tokenStart < 0) return;

  standaloneTransclusions.push({
    target,
    from: line.from,
    to: line.to,
    line: line.lineNo,
  });
}

function scanCodeFenceBlocks(
  lines: readonly Nv3ScannerLineContext[],
): Nv3MarkdownCodeFenceBlock[] {
  const blocks: Nv3MarkdownCodeFenceBlock[] = [];

  let open:
    | {
        fromLine: number;
        language: string | null;
      }
    | null = null;

  for (const line of lines) {
    if (!line.isFenceDelimiter) continue;

    if (!open) {
      const openingMatch = line.text.match(OPENING_FENCE_PATTERN);
      if (!openingMatch) continue;

      open = {
        fromLine: line.lineNo,
        language: openingMatch[1] ?? null,
      };
      continue;
    }

    blocks.push({
      fromLine: open.fromLine,
      toLine: line.lineNo,
      language: open.language,
      closed: true,
    });

    open = null;
  }

  if (open) {
    const tailLine = lines[lines.length - 1]?.lineNo ?? open.fromLine;
    blocks.push({
      fromLine: open.fromLine,
      toLine: tailLine,
      language: open.language,
      closed: false,
    });
  }

  return blocks;
}

function scanInlineParenLatexFragments(
  lineText: string,
  inlineCodeRanges: readonly TextRange[],
): Array<{ from: number; to: number; source: string }> {
  const fragments: Array<{ from: number; to: number; source: string }> = [];

  for (let index = 0; index < lineText.length - 1; index++) {
    if (lineText[index] !== "\\" || lineText[index + 1] !== "(") continue;
    if (rangeContainsIndex(inlineCodeRanges, index)) continue;

    let closeStart = -1;

    for (let cursor = index + 2; cursor < lineText.length - 1; cursor++) {
      if (lineText[cursor] !== "\\" || lineText[cursor + 1] !== ")") continue;
      if (rangeContainsIndex(inlineCodeRanges, cursor)) continue;
      if (isEscaped(lineText, cursor)) continue;

      closeStart = cursor;
      break;
    }

    if (closeStart < 0) continue;

    const from = index;
    const to = closeStart + 2;
    const source = lineText.slice(from, to);
    const body = lineText.slice(index + 2, closeStart);

    if (body.trim().length === 0) {
      index = to - 1;
      continue;
    }

    fragments.push({ from, to, source });
    index = to - 1;
  }

  return fragments;
}

function findNextNonWhitespace(lineText: string, from: number): string | undefined {
  for (let cursor = from; cursor < lineText.length; cursor++) {
    const char = lineText[cursor];
    if (char && !/\s/.test(char)) return char;
  }

  return undefined;
}

function isMathContinuationAfterNumber(char: string | undefined): boolean {
  return Boolean(char && INLINE_MATH_NUMBER_CONTINUATIONS.has(char));
}

function isCurrencyTerminator(char: string | undefined): boolean {
  return !char || /\s/.test(char) || /[.,;:!?)}\]]/.test(char);
}

function currencyAmountEnd(lineText: string, from: number): number | null {
  let cursor = from;
  if (!isDigit(lineText[cursor])) return null;

  while (cursor < lineText.length) {
    const char = lineText[cursor];
    if (isDigit(char)) {
      cursor += 1;
      continue;
    }
    if (char === ",") {
      cursor += 1;
      continue;
    }
    break;
  }

  if (lineText[cursor] === "." && isDigit(lineText[cursor + 1])) {
    cursor += 2;
    while (isDigit(lineText[cursor])) cursor += 1;
  }

  const suffix = lineText[cursor];
  const hasMagnitudeSuffix = Boolean(suffix && /[kKmMbBtT]/.test(suffix));
  if (hasMagnitudeSuffix) cursor += 1;

  if (lineText[cursor] === "+") cursor += 1;

  return cursor;
}

function isLikelyCurrencyDollar(lineText: string, dollarIndex: number): boolean {
  let cursor = currencyAmountEnd(lineText, dollarIndex + 1);
  if (cursor === null) return false;

  const rangeSeparator = /^[ \t]*[-–—][ \t]*\$?/.exec(lineText.slice(cursor));
  if (rangeSeparator) {
    const rangeEnd = currencyAmountEnd(lineText, cursor + rangeSeparator[0].length);
    if (rangeEnd !== null) cursor = rangeEnd;
  }

  const closingMarkup = /^[*_~]+/.exec(lineText.slice(cursor))?.[0];
  if (closingMarkup) {
    const prefix = lineText.slice(0, dollarIndex);
    const rangePrefix = /\$[\d,]+(?:\.\d+)?[kKmMbBtT]?\+?[ \t]*[-–—][ \t]*$/.exec(prefix);
    const openingMarkup = (rangePrefix ? prefix.slice(0, rangePrefix.index) : prefix).match(/[*_~]+$/)?.[0];
    // Only skip actual wrappers: `$2* x$` and `$2_ x$` are still math.
    if (openingMarkup === closingMarkup) cursor += closingMarkup.length;
  }

  const terminator = lineText[cursor];
  if (terminator === "$") return false;
  if (!isCurrencyTerminator(terminator)) return false;

  if (/\s/.test(terminator ?? "")) {
    const nextNonWhitespace = findNextNonWhitespace(lineText, cursor + 1);
    if (isMathContinuationAfterNumber(nextNonWhitespace)) return false;
  }

  return true;
}

function isInlineDollarOpenCandidate(
  lineText: string,
  inlineCodeRanges: readonly TextRange[],
  index: number,
): boolean {
  if (lineText[index] !== "$") return false;
  if (isEscaped(lineText, index)) return false;
  if (rangeContainsIndex(inlineCodeRanges, index)) return false;

  const openPrev = lineText[index - 1];
  const openNext = lineText[index + 1];

  if (!openNext || openNext === "$") return false;
  if (/\s/.test(openNext)) return false;
  if (isLikelyCurrencyDollar(lineText, index)) return false;

  if (isWordLike(openPrev) && isWordLike(openNext)) return false;
  if (isDigit(openPrev) && isDigit(openNext)) return false;

  return true;
}

function isInlineDollarCloseCandidate(
  lineText: string,
  inlineCodeRanges: readonly TextRange[],
  index: number,
): boolean {
  if (lineText[index] !== "$") return false;
  if (isEscaped(lineText, index)) return false;
  if (rangeContainsIndex(inlineCodeRanges, index)) return false;
  if (lineText[index - 1] === "$" || lineText[index + 1] === "$") return false;

  const closePrev = lineText[index - 1];
  const closeNext = lineText[index + 1];
  if (closePrev !== undefined && /\s/.test(closePrev)) return false;
  if (isDigit(closeNext)) return false;
  if (isWordLike(closePrev) && isWordLike(closeNext)) return false;
  if (isDigit(closePrev) && isDigit(closeNext)) return false;

  return true;
}

function scanInlineDollarLatexFragments(
  lineText: string,
  inlineCodeRanges: readonly TextRange[],
): Array<{ from: number; to: number; source: string }> {
  const fragments: Array<{ from: number; to: number; source: string }> = [];

  for (let index = 0; index < lineText.length; index++) {
    if (!isInlineDollarOpenCandidate(lineText, inlineCodeRanges, index)) continue;

    let closeIndex = -1;

    for (let cursor = index + 1; cursor < lineText.length; cursor++) {
      if (isInlineDollarCloseCandidate(lineText, inlineCodeRanges, cursor)) {
        closeIndex = cursor;
        break;
      }
    }

    if (closeIndex < 0) continue;

    const body = lineText.slice(index + 1, closeIndex);
    if (body.trim().length === 0) {
      index = closeIndex;
      continue;
    }

    const from = index;
    const to = closeIndex + 1;
    fragments.push({
      from,
      to,
      source: lineText.slice(from, to),
    });

    index = closeIndex;
  }

  return fragments;
}

type OpenMathBlock = {
  kind: "block-dollar" | "block-bracket";
  from: number;
  line: number;
  openedByStandaloneDelimiter?: boolean;
};

function scanLatexFragments(
  lines: readonly Nv3ScannerLineContext[],
  doc: Text,
): Nv3MarkdownLatexFragment[] {
  const fragments: Nv3MarkdownLatexFragment[] = [];
  let openBlock: OpenMathBlock | null = null;

  for (const line of lines) {
    const lineText = line.text;
    const trimmed = lineText.trim();

    if (openBlock) {
      const isClose =
        (openBlock.kind === "block-dollar" && BLOCK_DOLLAR_TRAILING_CLOSE_PATTERN.test(lineText)) ||
        (openBlock.kind === "block-bracket" && BLOCK_BRACKET_TRAILING_CLOSE_PATTERN.test(lineText));

      if (isClose) {
        fragments.push({
          kind: openBlock.kind,
          source: doc.sliceString(openBlock.from, line.to),
          from: openBlock.from,
          to: line.to,
          line: openBlock.line,
          toLine: line.lineNo,
        });
        openBlock = null;
      }

      continue;
    }

    if (!isMarkdownLineScannable(line)) {
      continue;
    }

    const inlineCodeRanges = line.inlineCodeRanges;

    const singleDollarBlockMatch = lineText.match(BLOCK_DOLLAR_SINGLE_LINE_PATTERN);
    if (singleDollarBlockMatch && (singleDollarBlockMatch[1]?.trim().length ?? 0) > 0) {
      fragments.push({
        kind: "block-dollar",
        source: lineText,
        from: line.from,
        to: line.to,
        line: line.lineNo,
        toLine: line.lineNo,
      });
      continue;
    }

    const singleBracketBlockMatch = lineText.match(BLOCK_BRACKET_SINGLE_LINE_PATTERN);
    if (singleBracketBlockMatch && (singleBracketBlockMatch[1]?.trim().length ?? 0) > 0) {
      fragments.push({
        kind: "block-bracket",
        source: lineText,
        from: line.from,
        to: line.to,
        line: line.lineNo,
        toLine: line.lineNo,
      });
      continue;
    }

    const trailingDollarOpenMatch = lineText.match(BLOCK_DOLLAR_TRAILING_OPEN_PATTERN);
    if (trailingDollarOpenMatch) {
      const openOffset = lineText.lastIndexOf("$$");
      if (openOffset >= 0 && !hasRangeOverlap(inlineCodeRanges, openOffset, openOffset + 2)) {
        openBlock = {
          kind: "block-dollar",
          from: line.from + openOffset,
          line: line.lineNo,
          openedByStandaloneDelimiter: false,
        };
        continue;
      }
    }

    if (BLOCK_DOLLAR_STANDALONE_PATTERN.test(lineText)) {
      openBlock = {
        kind: "block-dollar",
        from: line.from,
        line: line.lineNo,
        openedByStandaloneDelimiter: true,
      };
      continue;
    }

    if (BLOCK_DOLLAR_LEADING_OPEN_PATTERN.test(lineText)) {
      openBlock = {
        kind: "block-dollar",
        from: line.from,
        line: line.lineNo,
        openedByStandaloneDelimiter: false,
      };
      continue;
    }

    if (BLOCK_BRACKET_OPEN_PATTERN.test(lineText)) {
      openBlock = {
        kind: "block-bracket",
        from: line.from,
        line: line.lineNo,
        openedByStandaloneDelimiter: false,
      };
      continue;
    }

    if (BLOCK_BRACKET_LEADING_OPEN_PATTERN.test(lineText)) {
      openBlock = {
        kind: "block-bracket",
        from: line.from,
        line: line.lineNo,
        openedByStandaloneDelimiter: false,
      };
      continue;
    }

    if (!trimmed) continue;

    const parenFragments = scanInlineParenLatexFragments(lineText, inlineCodeRanges);
    for (const fragment of parenFragments) {
      fragments.push({
        kind: "inline-paren",
        source: fragment.source,
        from: line.from + fragment.from,
        to: line.from + fragment.to,
        line: line.lineNo,
      });
    }

    const dollarFragments = scanInlineDollarLatexFragments(lineText, inlineCodeRanges);
    for (const fragment of dollarFragments) {
      fragments.push({
        kind: "inline-dollar",
        source: fragment.source,
        from: line.from + fragment.from,
        to: line.from + fragment.to,
        line: line.lineNo,
      });
    }
  }

  if (openBlock && !openBlock.openedByStandaloneDelimiter) {
    const lastLine = doc.line(doc.lines);
    fragments.push({
      kind: openBlock.kind,
      source: doc.sliceString(openBlock.from, lastLine.to),
      from: openBlock.from,
      to: lastLine.to,
      line: openBlock.line,
      toLine: doc.lines,
    });
  }

  fragments.sort((a, b) => a.from - b.from || a.kind.localeCompare(b.kind));
  return fragments;
}

function tokenSyntaxTouchesInlineCode(
  inlineCodeRanges: readonly TextRange[],
  positions: readonly number[],
): boolean {
  return positions.some((position) => rangeContainsIndex(inlineCodeRanges, position));
}

function scanLinks(
  line: Nv3ScannerLineContext,
  linkOccurrences: Nv3MarkdownLinkOccurrence[],
  inlineLinkOccurrences: Nv3MarkdownInlineLinkOccurrence[],
): void {
  const text = line.text;

  TRANSCLUSION_PATTERN.lastIndex = 0;
  let transclusionMatch: RegExpExecArray | null;
  while ((transclusionMatch = TRANSCLUSION_PATTERN.exec(text)) !== null) {
    const fullToken = transclusionMatch[0] ?? "";
    const target = transclusionMatch[1]?.trim() ?? "";
    if (!fullToken || !target) {
      resetIfStalled(TRANSCLUSION_PATTERN, transclusionMatch);
      continue;
    }

    const startOffset = transclusionMatch.index;
    const endOffset = startOffset + fullToken.length;

    if (hasRangeOverlap(line.inlineCodeRanges, startOffset, endOffset)) {
      resetIfStalled(TRANSCLUSION_PATTERN, transclusionMatch);
      continue;
    }

    linkOccurrences.push({
      kind: "transclusion",
      target,
      from: line.from + startOffset,
      to: line.from + endOffset,
      line: line.lineNo,
    });

    resetIfStalled(TRANSCLUSION_PATTERN, transclusionMatch);
  }

  PREVIEW_PATTERN.lastIndex = 0;
  let previewMatch: RegExpExecArray | null;
  while ((previewMatch = PREVIEW_PATTERN.exec(text)) !== null) {
    const fullToken = previewMatch[0] ?? "";
    const target = previewMatch[2]?.trim() ?? "";
    if (!fullToken || !target) {
      resetIfStalled(PREVIEW_PATTERN, previewMatch);
      continue;
    }

    const startOffset = previewMatch.index;
    const endOffset = startOffset + fullToken.length;

    const alt = previewMatch[1] ?? "";
    const syntaxTouchesInlineCode = tokenSyntaxTouchesInlineCode(line.inlineCodeRanges, [
      startOffset,
      startOffset + 1,
      startOffset + 2 + alt.length,
      endOffset - 1,
    ]);
    if (syntaxTouchesInlineCode) {
      resetIfStalled(PREVIEW_PATTERN, previewMatch);
      continue;
    }

    linkOccurrences.push({
      kind: "preview",
      target,
      from: line.from + startOffset,
      to: line.from + endOffset,
      line: line.lineNo,
    });

    resetIfStalled(PREVIEW_PATTERN, previewMatch);
  }

  MARKDOWN_LINK_PATTERN.lastIndex = 0;
  let markdownLinkMatch: RegExpExecArray | null;
  while ((markdownLinkMatch = MARKDOWN_LINK_PATTERN.exec(text)) !== null) {
    const fullToken = markdownLinkMatch[0] ?? "";
    const label = markdownLinkMatch[1] ?? "";
    const href = markdownLinkMatch[2]?.trim() ?? "";
    if (!fullToken || !label || !href) {
      resetIfStalled(MARKDOWN_LINK_PATTERN, markdownLinkMatch);
      continue;
    }

    const startOffset = markdownLinkMatch.index;
    const endOffset = startOffset + fullToken.length;

    if (startOffset > 0 && text[startOffset - 1] === "!") {
      resetIfStalled(MARKDOWN_LINK_PATTERN, markdownLinkMatch);
      continue;
    }

    const syntaxTouchesInlineCode = tokenSyntaxTouchesInlineCode(line.inlineCodeRanges, [
      startOffset,
      startOffset + 1 + label.length,
      startOffset + 2 + label.length,
      endOffset - 1,
    ]);
    if (syntaxTouchesInlineCode) {
      resetIfStalled(MARKDOWN_LINK_PATTERN, markdownLinkMatch);
      continue;
    }

    const from = line.from + startOffset;
    const to = line.from + endOffset;

    const labelFrom = from + 1;
    const labelTo = labelFrom + label.length;
    const urlFrom = labelTo + 2;
    const urlTo = urlFrom + href.length;

    inlineLinkOccurrences.push({
      href,
      label,
      from,
      to,
      line: line.lineNo,
      labelFrom,
      labelTo,
      urlFrom,
      urlTo,
    });

    resetIfStalled(MARKDOWN_LINK_PATTERN, markdownLinkMatch);
  }

  WIKILINK_PATTERN.lastIndex = 0;
  let wikilinkMatch: RegExpExecArray | null;
  while ((wikilinkMatch = WIKILINK_PATTERN.exec(text)) !== null) {
    const fullToken = wikilinkMatch[0] ?? "";
    const target = wikilinkMatch[1]?.trim() ?? "";
    if (!fullToken || !target) {
      resetIfStalled(WIKILINK_PATTERN, wikilinkMatch);
      continue;
    }

    const startOffset = wikilinkMatch.index;
    const endOffset = startOffset + fullToken.length;

    if (startOffset > 0 && text[startOffset - 1] === "!") {
      resetIfStalled(WIKILINK_PATTERN, wikilinkMatch);
      continue;
    }

    if (hasRangeOverlap(line.inlineCodeRanges, startOffset, endOffset)) {
      resetIfStalled(WIKILINK_PATTERN, wikilinkMatch);
      continue;
    }

    linkOccurrences.push({
      kind: "wikilink",
      target,
      from: line.from + startOffset,
      to: line.from + endOffset,
      line: line.lineNo,
    });

    resetIfStalled(WIKILINK_PATTERN, wikilinkMatch);
  }
}

export function scanMarkdownDocument(doc: Text): Nv3MarkdownScanIndex {
  const context = createMarkdownScannerContext(doc);

  const hashTagOccurrences: Nv3MarkdownHashTagOccurrence[] = [];
  const headingTagOccurrences: Nv3MarkdownHeadingTagOccurrence[] = [];
  const mentionOccurrences: Nv3MarkdownMentionOccurrence[] = [];
  const taskCheckboxOccurrences: Nv3MarkdownTaskCheckboxOccurrence[] = [];
  const headingOccurrences: Nv3MarkdownHeadingOccurrence[] = [];
  const blockIDOcurrences: Nv3MarkdownBlockIDOccurrence[] = [];
  const linkOccurrences: Nv3MarkdownLinkOccurrence[] = [];
  const inlineLinkOccurrences: Nv3MarkdownInlineLinkOccurrence[] = [];
  const standaloneTransclusions: Nv3MarkdownStandaloneTransclusionOccurrence[] = [];

  for (const line of context.lines) {
    if (!isMarkdownLineScannable(line)) continue;

    scanTags(line, hashTagOccurrences, headingTagOccurrences);
    scanMentions(line, mentionOccurrences);
    scanTaskCheckboxes(line, taskCheckboxOccurrences);
    scanHeadingsAndBlockIDs(line, headingOccurrences, blockIDOcurrences);
    scanStandaloneTransclusions(line, standaloneTransclusions);
    scanLinks(line, linkOccurrences, inlineLinkOccurrences);
  }

  linkOccurrences.sort((left, right) => {
    if (left.from !== right.from) return left.from - right.from;
    return left.kind.localeCompare(right.kind);
  });

  return {
    hashTagOccurrences,
    headingTagOccurrences,
    mentionOccurrences,
    taskCheckboxOccurrences,
    headingOccurrences,
    blockIDOcurrences,
    linkOccurrences,
    inlineLinkOccurrences,
    codeFenceBlocks: scanCodeFenceBlocks(context.lines),
    standaloneTransclusions,
    latexFragments: scanLatexFragments(context.lines, doc),
  };
}

export function scanMarkdownText(docText: string): Nv3MarkdownScanIndex {
  const doc = Text.of(docText.split(/\r?\n/));
  return scanMarkdownDocument(doc);
}

/** Adapts a Nv3MarkdownScanIndex to the generic DocumentScanIndex interface. */
export function toDocumentScanIndex(md: Nv3MarkdownScanIndex): DocumentScanIndex {
  return {
    tags: md.hashTagOccurrences,
    headingTags: md.headingTagOccurrences,
    mentions: md.mentionOccurrences,
    tasks: md.taskCheckboxOccurrences,
    headings: md.headingOccurrences,
    blockIDs: md.blockIDOcurrences,
    links: md.linkOccurrences,
    inlineLinks: md.inlineLinkOccurrences,
    codeBlocks: md.codeFenceBlocks,
    transclusions: md.standaloneTransclusions,
    latexFragments: md.latexFragments,
  };
}

/** Scanner function compatible with `documentScannerFacet`. */
export function markdownDocumentScanner(doc: Text): DocumentScanIndex {
  return toDocumentScanIndex(scanMarkdownDocument(doc));
}
