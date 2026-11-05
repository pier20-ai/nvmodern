import React, { useEffect, useMemo, useRef, useState } from "react";
import { SearchQuery, setSearchQuery } from "@codemirror/search";
import { Compartment, EditorState } from "@codemirror/state";
import { EditorView, placeholder } from "@codemirror/view";
import {
  applyCalcHelpInsertion,
  dismissCalcHelp,
  type HelpOpenRequest,
  collectMarkdownOutlineHeadings,
  collectOrgOutlineHeadings,
  createNv3EditorState,
  createMarkdownLineUnwrapExtension,
  createOrgLineUnwrapExtension,
  detectNv3FileType,
  nv3BlockReferenceMatches,
  nv3HeadingReferenceMatches,
  parseNv3WikilinkTarget,
  resolveActiveTocHeadingId,
  resolveDocumentScanIndex,
  setNv3InteractionMode,
  applyNv3InspectorStylesheet,
  applyNv3UserStylesheet,
  beginNv3AnnotationComposer,
  nv3AnnotationsChanged,
  createToggleDelimitedMarkupCommand,
  markdownTableContextFromEventTarget,
  prefixMarkdownSelectionLines,
  runMarkdownTableCommand,
  quoteMarkdownSelection,
  toggleMarkdownBold,
  toggleMarkdownHighlight,
  toggleMarkdownItalic,
  unquoteMarkdownSelection,
  type MarkdownTableCommand,
  type MarkdownTableDomContext,
  type Nv3AutocompleteProvider,
  type Nv3InteractionMode,
  type Nv3TextSubstitutionRule,
  type Nv3OutlineHeading,
  type Nv3WikilinkReferenceKind,
} from "./lib/index.ts";
import { bridge } from "./bridge.ts";
import {
  applyHostColorScheme,
  resolveInlineWorkspaceHref,
  resolvePreviewImageUrl,
  resolveTransclusionOverBridge,
  resolveWikilinkHref,
  resolveWorkspaceRelativePath,
} from "./editorHost.ts";
import {
  handleEditorAnnotationRequest,
  rememberEditorAnnotations,
  restoreEditorAnnotations,
} from "./editorAnnotations.ts";
import { ArborSurface } from "./arbor/ArborSurface.tsx";
import { nvmodernArborHost } from "./arbor/bridgeHost.ts";
import { isArborDocumentPath } from "./arbor/documentType.ts";
import { queryEditorContextFromView } from "./editorContext.ts";
import { EPUBSurface } from "./epub/EPUBSurface.tsx";

let latestMarkdownTableContextMenuTarget: MarkdownTableDomContext | null = null;
let latestOrgTodoMenuTarget: {
  view: EditorView;
  from: number;
  to: number;
} | null = null;

type EditorKind =
  | "folder"
  | "text"
  | "pdf"
  | "csv"
  | "image"
  | "epub"
  | "diff"
  | "unsupported"
  | "textNote"
  | "nonTextFile";

type NormalizedEditorKind = "folder" | "text" | "pdf" | "csv" | "image" | "epub" | "diff" | "unsupported";
type EditorPresentationMode = "document" | "quickCapture";

interface EditorScrollState {
  kind?: "markdown" | "pdf" | "epub";
  ratio?: number;
  href?: string;
  cfi?: string;
  progression?: number;
}

export interface EditorContext {
  kind?: EditorKind;
  title?: string;
  path?: string;
  body?: string;
  users?: string[];
  substitutionRules?: Nv3TextSubstitutionRule[];
  isEditable?: boolean;
  mimeType?: string;
  fileSize?: number;
  previewURL?: string;
  scrollState?: EditorScrollState;
  cursorPlacement?: "start" | "end";
  presentationMode?: EditorPresentationMode;
  showToc?: boolean;
  userThemeCSS?: string;
  documentInspectorTheme?: string;
  documentInspectorCSS?: string;
  unwrapMarkdownLines?: boolean;
  diff?: {
    left?: EditorDiffFile;
    right?: EditorDiffFile;
  };
}

interface EditorDiffFile {
  path?: string;
  title?: string;
  body?: string;
}

interface DocumentNavigationOrigin {
  path: string;
  selection: EditorState["selection"];
  scrollTop: number;
  scrollLeft: number;
}

interface DocumentSearchMatch {
  id: string;
  text: string;
  preview: string;
  line: number;
  from: number;
  to: number;
}

const CSV_CHARACTER_LIMIT = 1_000_000;
const CSV_ROW_LIMIT = 300;
const CSV_COLUMN_LIMIT = 60;
const TOC_REFRESH_DEBOUNCE_MS = 1_500;
const DOC_CHANGE_DEBOUNCE_MS = 450;
const ACTIVE_EDITING_IDLE_MS = 900;
const DOCUMENT_NAVIGATION_SEARCH_RESULT_LIMIT = 200;
const EDITOR_LATENCY_SAMPLE_INTERVAL = 12;
const EDITOR_LATENCY_LOG_THRESHOLD_MS = 20;

interface EditorJumpRequest {
  id: string;
  path: string;
  kind: "heading" | "block" | "line";
  query: string;
}

function markdownScanIndexForView(view: EditorView) {
  const scanIndex = resolveDocumentScanIndex(view.state);
  return {
    headingOccurrences: scanIndex.headings,
    blockIDOcurrences: scanIndex.blockIDs,
  };
}

function jumpToMarkdownReference(view: EditorView, request: EditorJumpRequest): boolean {
  if (request.kind === "line") {
    const lineNumber = Number.parseInt(request.query, 10);
    if (!Number.isFinite(lineNumber)) return false;
    const safeLineNumber = Math.max(1, Math.min(view.state.doc.lines, Math.trunc(lineNumber)));
    const line = view.state.doc.line(safeLineNumber);
    view.dispatch({
      selection: { anchor: line.from },
      scrollIntoView: true,
    });
    view.focus();
    return true;
  }

  const index = markdownScanIndexForView(view);

  if (request.kind === "heading") {
    const match = index.headingOccurrences.find((occurrence) => {
      return nv3HeadingReferenceMatches(request.query, occurrence.text);
    });
    if (!match) return false;

    view.dispatch({
      selection: { anchor: match.from },
      scrollIntoView: true,
    });
    view.focus();
    return true;
  }

  const blockMatch = index.blockIDOcurrences.find((occurrence) => {
    return nv3BlockReferenceMatches(request.query, occurrence.id);
  });
  if (!blockMatch) return false;

  view.dispatch({
    selection: { anchor: blockMatch.lineFrom },
    scrollIntoView: true,
  });
  view.focus();
  return true;
}

function linePreviewText(lineText: string, fromOffset: number, toOffset: number): string {
  const contextCharacters = 56;
  const start = Math.max(0, fromOffset - contextCharacters);
  const end = Math.min(lineText.length, toOffset + contextCharacters);
  const prefix = start > 0 ? "..." : "";
  const suffix = end < lineText.length ? "..." : "";
  return `${prefix}${lineText.slice(start, end)}${suffix}`.trim();
}

function collectDocumentSearchMatches(state: EditorState, rawQuery: string): DocumentSearchMatch[] {
  const searchText = rawQuery.trim();
  if (!searchText) return [];

  const matches: DocumentSearchMatch[] = [];
  const documentText = state.doc.toString();
  const normalizedDocumentText = documentText.toLocaleLowerCase();
  const normalizedSearchText = searchText.toLocaleLowerCase();
  let from = 0;

  while (matches.length < DOCUMENT_NAVIGATION_SEARCH_RESULT_LIMIT) {
    const matchFrom = normalizedDocumentText.indexOf(normalizedSearchText, from);
    if (matchFrom < 0) break;

    const matchTo = matchFrom + searchText.length;
    const line = state.doc.lineAt(matchFrom);
    const fromOffset = Math.max(0, matchFrom - line.from);
    const toOffset = Math.max(fromOffset, matchTo - line.from);
    const text = state.sliceDoc(matchFrom, matchTo);

    matches.push({
      id: `${matchFrom}-${matchTo}-${matches.length}`,
      text,
      preview: linePreviewText(line.text, fromOffset, toOffset),
      line: line.number,
      from: matchFrom,
      to: matchTo,
    });

    from = Math.max(matchTo, matchFrom + 1);
  }

  return matches;
}

function activeSearchMatchIndex(matches: readonly DocumentSearchMatch[], state: EditorState): number {
  if (!matches.length) return -1;
  const selection = state.selection.main;
  return matches.findIndex((match) => match.from === selection.from && match.to === selection.to);
}

function asUsers(users: unknown): string[] {
  if (!Array.isArray(users)) return [];
  return users.filter((value): value is string => typeof value === "string");
}

function asSubstitutionRules(rules: unknown): Nv3TextSubstitutionRule[] {
  if (!Array.isArray(rules)) return [];

  return rules.filter((value): value is Nv3TextSubstitutionRule => {
    return Boolean(
      value &&
        typeof value === "object" &&
        typeof (value as { from?: unknown }).from === "string" &&
        (value as { from: string }).from.length > 0 &&
        typeof (value as { to?: unknown }).to === "string",
    );
  });
}

function clampScrollRatio(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.max(0, Math.min(1, value));
}

function markdownScrollRatioForContext(context: EditorContext): number | null {
  if (context.scrollState?.kind !== "markdown") return null;
  return clampScrollRatio(context.scrollState.ratio);
}

function normalizeContextKind(kind: EditorContext["kind"]): NormalizedEditorKind {
  switch (kind) {
    case "folder":
      return "folder";
    case "text":
    case "textNote":
      return "text";
    case "pdf":
      return "pdf";
    case "csv":
      return "csv";
    case "image":
      return "image";
    case "epub":
      return "epub";
    case "diff":
      return "diff";
    case "nonTextFile":
    case "unsupported":
    default:
      return "unsupported";
  }
}

function previewURLForContext(context: EditorContext): string | null {
  if (typeof context.previewURL === "string" && context.previewURL.length > 0) {
    return context.previewURL;
  }

  if (!context.path) return null;
  const params = new URLSearchParams({ path: context.path });
  return `nvmodern-file://preview?${params.toString()}`;
}

const toggleMarkdownStrikethrough = createToggleDelimitedMarkupCommand({
  open: "~~",
  close: "~~",
});

const toggleMarkdownInlineCode = createToggleDelimitedMarkupCommand({
  open: "`",
  close: "`",
});

function contextMenuSelectionText(): string {
  return window.getSelection?.()?.toString().trim() ?? "";
}

function contextMenuPointFromEvent(event: MouseEvent): { x: number; y: number } {
  let x = Number.isFinite(event.clientX) ? event.clientX : 0;
  let y = Number.isFinite(event.clientY) ? event.clientY : 0;

  if (x > 0 || y > 0) {
    return { x, y };
  }

  const anchor = event.target instanceof Element ? event.target : document.activeElement;
  if (anchor instanceof Element) {
    const rect = anchor.getBoundingClientRect();
    x = rect.left + Math.min(Math.max(rect.width / 2, 12), 24);
    y = rect.top + Math.min(Math.max(rect.height / 2, 12), 24);
  }

  return { x, y };
}

function selectedLineRanges(view: EditorView): Array<{ from: number; to: number }> {
  const ranges = view.state.selection.ranges
    .map((range) => {
      const startLine = view.state.doc.lineAt(range.from);
      const endPos = Math.max(range.from, range.to > range.from ? range.to - 1 : range.to);
      const endLine = view.state.doc.lineAt(endPos);
      return { from: startLine.from, to: endLine.to };
    })
    .sort((left, right) => left.from - right.from);

  const merged: Array<{ from: number; to: number }> = [];
  for (const range of ranges) {
    const previous = merged[merged.length - 1];
    if (previous && range.from <= previous.to + 1) {
      previous.to = Math.max(previous.to, range.to);
      continue;
    }
    merged.push({ ...range });
  }

  return merged;
}

function toggleMarkdownLinePrefix(view: EditorView, prefix: string, matcher?: RegExp): boolean {
  const lineRanges = selectedLineRanges(view);
  if (lineRanges.length === 0) return false;

  const normalizedMatcher = matcher ?? new RegExp(`^(\\s*)${prefix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`);
  const changes: Array<{ from: number; to?: number; insert?: string }> = [];

  const nonEmptyLines = lineRanges.flatMap((range) =>
    view.state.doc.sliceString(range.from, range.to).split("\n").filter((line) => line.trim().length > 0),
  );
  if (nonEmptyLines.length === 0) return false;

  const shouldRemove = nonEmptyLines.every((line) => normalizedMatcher.test(line));

  for (const range of lineRanges) {
    let offset = range.from;
    for (const lineText of view.state.doc.sliceString(range.from, range.to).split("\n")) {
      if (lineText.trim().length > 0) {
        const match = lineText.match(normalizedMatcher);
        if (shouldRemove && match) {
          changes.push({ from: offset, to: offset + match[0].length, insert: match[1] ?? "" });
        } else if (!shouldRemove) {
          const indentLength = lineText.match(/^\s*/)?.[0].length ?? 0;
          changes.push({ from: offset + indentLength, insert: prefix });
        }
      }
      offset += lineText.length + 1;
    }
  }

  if (changes.length === 0) return false;
  view.dispatch({ changes, scrollIntoView: true });
  view.focus();
  return true;
}

function toggleMarkdownHeadingLevel(view: EditorView, level: number): boolean {
  const safeLevel = Math.max(1, Math.min(6, level));
  const headingPrefix = `${"#".repeat(safeLevel)} `;
  const lineRanges = selectedLineRanges(view);
  if (lineRanges.length === 0) return false;

  const headingPattern = /^(\s{0,3})(#{1,6})\s+(.*)$/;
  const nonEmptyLines = lineRanges.flatMap((range) =>
    view.state.doc.sliceString(range.from, range.to).split("\n").filter((line) => line.trim().length > 0),
  );
  if (nonEmptyLines.length === 0) return false;

  const shouldRemove = nonEmptyLines.every((line) => {
    const match = line.match(headingPattern);
    return match?.[2]?.length === safeLevel;
  });

  const changes: Array<{ from: number; to?: number; insert?: string }> = [];
  for (const range of lineRanges) {
    let offset = range.from;
    for (const lineText of view.state.doc.sliceString(range.from, range.to).split("\n")) {
      if (lineText.trim().length > 0) {
        const match = lineText.match(headingPattern);
        if (match) {
          changes.push({
            from: offset,
            to: offset + lineText.length,
            insert: shouldRemove ? `${match[1]}${match[3]}` : `${match[1]}${headingPrefix}${match[3]}`,
          });
        } else if (!shouldRemove) {
          changes.push({ from: offset, insert: headingPrefix });
        }
      }
      offset += lineText.length + 1;
    }
  }

  if (changes.length === 0) return false;
  view.dispatch({ changes, scrollIntoView: true });
  view.focus();
  return true;
}

function toggleMarkdownOrderedList(view: EditorView): boolean {
  const lineRanges = selectedLineRanges(view);
  if (lineRanges.length === 0) return false;

  const orderedPattern = /^(\s*)\d+\.\s+/;
  const nonEmptyLines = lineRanges.flatMap((range) =>
    view.state.doc.sliceString(range.from, range.to).split("\n").filter((line) => line.trim().length > 0),
  );
  if (nonEmptyLines.length === 0) return false;

  const shouldRemove = nonEmptyLines.every((line) => orderedPattern.test(line));
  const changes: Array<{ from: number; to?: number; insert?: string }> = [];
  let nextNumber = 1;

  for (const range of lineRanges) {
    let offset = range.from;
    for (const lineText of view.state.doc.sliceString(range.from, range.to).split("\n")) {
      if (lineText.trim().length > 0) {
        const match = lineText.match(orderedPattern);
        if (shouldRemove && match) {
          changes.push({ from: offset, to: offset + match[0].length, insert: match[1] ?? "" });
        } else if (!shouldRemove) {
          const indentLength = lineText.match(/^\s*/)?.[0].length ?? 0;
          changes.push({ from: offset + indentLength, insert: `${nextNumber}. ` });
          nextNumber += 1;
        }
      }
      offset += lineText.length + 1;
    }
  }

  if (changes.length === 0) return false;
  view.dispatch({ changes, scrollIntoView: true });
  view.focus();
  return true;
}

function insertMarkdownTemplate(view: EditorView, templateForSelection: (selection: string) => string): boolean {
  const selection = view.state.selection.main;
  const selectedText = view.state.sliceDoc(selection.from, selection.to);
  view.dispatch({
    changes: { from: selection.from, to: selection.to, insert: templateForSelection(selectedText) },
    selection: { anchor: selection.from },
    scrollIntoView: true,
  });
  view.focus();
  return true;
}

function insertMarkdownCodeBlock(view: EditorView): boolean {
  return insertMarkdownTemplate(view, (selection) => {
    const body = selection.length > 0 ? selection : "\n";
    return `\`\`\`\n${body}\n\`\`\``;
  });
}

function insertMarkdownLink(view: EditorView): boolean {
  return insertMarkdownTemplate(view, (selection) => `[${selection}](url)`);
}

function insertMarkdownWikilink(view: EditorView): boolean {
  return insertMarkdownTemplate(view, (selection) => `[[${selection}]]`);
}

const markdownTableBridgeCommands: Record<string, MarkdownTableCommand> = {
  markdownTableInsertRowAbove: "insertRowAbove",
  markdownTableInsertRowBelow: "insertRowBelow",
  markdownTableDeleteRow: "deleteRow",
  markdownTableMoveRowUp: "moveRowUp",
  markdownTableMoveRowDown: "moveRowDown",
  markdownTableInsertColumnLeft: "insertColumnLeft",
  markdownTableInsertColumnRight: "insertColumnRight",
  markdownTableDeleteColumn: "deleteColumn",
  markdownTableMoveColumnLeft: "moveColumnLeft",
  markdownTableMoveColumnRight: "moveColumnRight",
  markdownTableAlignColumnLeft: "alignColumnLeft",
  markdownTableAlignColumnCenter: "alignColumnCenter",
  markdownTableAlignColumnRight: "alignColumnRight",
  markdownTableClearCell: "clearCell",
};

const markdownTableActiveBridgeCommands: Record<string, MarkdownTableCommand> = {
  markdownTableActiveInsertRowAbove: "insertRowAbove",
  markdownTableActiveInsertRowBelow: "insertRowBelow",
  markdownTableActiveDeleteRow: "deleteRow",
  markdownTableActiveMoveRowUp: "moveRowUp",
  markdownTableActiveMoveRowDown: "moveRowDown",
  markdownTableActiveInsertColumnLeft: "insertColumnLeft",
  markdownTableActiveInsertColumnRight: "insertColumnRight",
  markdownTableActiveDeleteColumn: "deleteColumn",
  markdownTableActiveMoveColumnLeft: "moveColumnLeft",
  markdownTableActiveMoveColumnRight: "moveColumnRight",
  markdownTableActiveAlignColumnLeft: "alignColumnLeft",
  markdownTableActiveAlignColumnCenter: "alignColumnCenter",
  markdownTableActiveAlignColumnRight: "alignColumnRight",
  markdownTableActiveClearCell: "clearCell",
};

function parseCSV(input: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let value = "";
  let inQuotes = false;

  for (let index = 0; index < input.length; index += 1) {
    const char = input[index] ?? "";

    if (inQuotes) {
      if (char === '"') {
        const next = input[index + 1] ?? "";
        if (next === '"') {
          value += '"';
          index += 1;
          continue;
        }

        inQuotes = false;
        continue;
      }

      value += char;
      continue;
    }

    if (char === '"') {
      inQuotes = true;
      continue;
    }

    if (char === ",") {
      row.push(value);
      value = "";
      continue;
    }

    if (char === "\n") {
      row.push(value);
      rows.push(row);
      row = [];
      value = "";
      continue;
    }

    if (char === "\r") {
      const next = input[index + 1] ?? "";
      if (next === "\n") {
        index += 1;
      }

      row.push(value);
      rows.push(row);
      row = [];
      value = "";
      continue;
    }

    value += char;
  }

  row.push(value);

  const isTrailingEmptyLine =
    rows.length > 0 && row.length === 1 && row[0] === "" && (input.endsWith("\n") || input.endsWith("\r"));

  if (!isTrailingEmptyLine) {
    rows.push(row);
  }

  return rows;
}

function tocHeadingsEqual(left: Nv3OutlineHeading[], right: Nv3OutlineHeading[]): boolean {
  if (left.length !== right.length) return false;

  return left.every((heading, index) => {
    const other = right[index];
    return (
      other != null &&
      heading.id === other.id &&
      heading.level === other.level &&
      heading.sourceLevel === other.sourceLevel &&
      heading.text === other.text &&
      heading.from === other.from &&
      heading.to === other.to &&
      heading.line === other.line
    );
  });
}

// The web editor is responsible for Markdown scroll persistence.
// It reports a normalized scroll ratio over the existing Swift bridge and accepts a
// saved ratio back in `context.scrollState` during context activation.
function TextEditorSurface({
  context,
  pendingJump,
}: {
  context: EditorContext;
  pendingJump: EditorJumpRequest | null;
}) {
  const shellRef = useRef<HTMLDivElement | null>(null);
  const mountRef = useRef<HTMLDivElement | null>(null);
  const viewRef = useRef<EditorView | null>(null);
  const unwrapMarkdownLinesCompartment = useMemo(() => new Compartment(), []);
  const contextMetaRef = useRef({
    path: context.path ?? null,
    title: context.title ?? null,
  });
  contextMetaRef.current = {
    path: context.path ?? null,
    title: context.title ?? null,
  };
  const lastAppliedJumpIDRef = useRef<string | null>(null);
  const [editorInitError, setEditorInitError] = useState<string | null>(null);
  const tocHeadingsRef = useRef<Nv3OutlineHeading[]>([]);
  const activeTocHeadingIdRef = useRef<string | null>(null);
  const documentNavigationOriginRef = useRef<DocumentNavigationOrigin | null>(null);
  const documentNavigationSearchQueryRef = useRef("");
  const documentNavigationSearchMatchesRef = useRef<DocumentSearchMatch[]>([]);
  const isActivelyEditingRef = useRef(false);
  const presentationMode: EditorPresentationMode =
    context.presentationMode === "quickCapture" ? "quickCapture" : "document";

  const emitDocumentNavigationState = (view: EditorView) => {
    if (!context.path) return;

    bridge.emit("documentNavigationState", {
      path: context.path,
      outline: tocHeadingsRef.current,
      activeOutlineId: activeTocHeadingIdRef.current,
      searchQuery: documentNavigationSearchQueryRef.current,
      searchMatches: documentNavigationSearchMatchesRef.current,
      activeSearchIndex: activeSearchMatchIndex(documentNavigationSearchMatchesRef.current, view.state),
      lineCount: view.state.doc.lines,
    });
  };

  const updateDocumentNavigationSearch = (view: EditorView, queryText: string) => {
    const trimmedQuery = queryText.trim();
    documentNavigationSearchQueryRef.current = queryText;
    documentNavigationSearchMatchesRef.current = collectDocumentSearchMatches(view.state, queryText);

    view.dispatch({
      effects: setSearchQuery.of(
        new SearchQuery({
          search: trimmedQuery,
          caseSensitive: false,
          literal: true,
        }),
      ),
    });

    const activeMatchIndex = activeSearchMatchIndex(
      documentNavigationSearchMatchesRef.current,
      view.state,
    );
    const activeMatch = activeMatchIndex >= 0
      ? documentNavigationSearchMatchesRef.current[activeMatchIndex]
      : undefined;
    const activeMatchIsVisible = activeMatch != null && view.visibleRanges.some((range) => {
      return activeMatch.from < range.to && activeMatch.to > range.from;
    });

    if (trimmedQuery && !activeMatchIsVisible) {
      const firstMatch = documentNavigationSearchMatchesRef.current[0];
      if (firstMatch) {
        view.dispatch({
          selection: { anchor: firstMatch.from, head: firstMatch.to },
          effects: EditorView.scrollIntoView(firstMatch.from, { y: "center" }),
        });
      }
    }

    emitDocumentNavigationState(view);
  };

  const jumpToDocumentRange = (view: EditorView, from: number, to: number = from) => {
    const safeFrom = Math.max(0, Math.min(view.state.doc.length, from));
    const safeTo = Math.max(0, Math.min(view.state.doc.length, to));
    view.dispatch({
      selection: { anchor: safeFrom, head: safeTo },
      effects: EditorView.scrollIntoView(safeFrom, { y: "center" }),
    });
    emitDocumentNavigationState(view);
  };

  const jumpToDocumentLine = (view: EditorView, lineNumber: number, column?: number) => {
    if (!Number.isFinite(lineNumber)) return;
    const safeLineNumber = Math.max(1, Math.min(view.state.doc.lines, Math.trunc(lineNumber)));
    const line = view.state.doc.line(safeLineNumber);
    const safeColumn = Math.max(0, Math.min(line.length, Math.trunc(column ?? 0)));
    jumpToDocumentRange(view, line.from + safeColumn);
  };

  const users = useMemo(() => asUsers(context.users), [context.users]);
  const usersKey = users.join("\u0001");
  const cursorPlacement = context.cursorPlacement;
  const substitutionRulesKey = JSON.stringify(asSubstitutionRules(context.substitutionRules));
  const substitutionRules = useMemo(
    () => JSON.parse(substitutionRulesKey) as Nv3TextSubstitutionRule[],
    [substitutionRulesKey],
  );

  useEffect(() => {
    const mount = mountRef.current;
    if (!mount) return;

    const filePath = context.path;
    const doc = context.body ?? "";
    const isEditable = Boolean(context.isEditable);
    const fileType = filePath ? detectNv3FileType(filePath) : "plain";
    const isMarkdownFile = fileType === "markdown";
    isActivelyEditingRef.current = false;
    const matchingPendingJump =
      isMarkdownFile &&
      filePath &&
      pendingJump &&
      pendingJump.path === filePath &&
      pendingJump.id !== lastAppliedJumpIDRef.current
        ? pendingJump
        : null;
    const initialMarkdownScrollRatio = markdownScrollRatioForContext(context);
    let isDisposed = false;
    let tocRefreshTimer: ReturnType<typeof setTimeout> | null = null;
    let pendingDocChangeTimer: ReturnType<typeof setTimeout> | null = null;
    let activeEditingResetTimer: ReturnType<typeof setTimeout> | null = null;
    let pendingDocChangeBody: string | null = null;
    let pendingLatencyInputAt: number | null = null;
    let pendingLatencyKey = "";
    let latencySampleSequence = 0;
    let scrollEmitFrame = 0;
    let activeTocSyncFrame = 0;
    let pendingScrollRestoreFrame = 0;
    let pendingScrollRestoreAttempts = 0;
    let pendingLatencyFrame = 0;

    const emitScrollRestoreDebug = (payload: Record<string, unknown>) => {
      if ((window as typeof window & { __nvmodernDebugScrollRestore?: boolean }).__nvmodernDebugScrollRestore !== true) return;
      bridge.emit("debugScrollRestore", payload);
    };

    const clearTocRefreshTimer = () => {
      if (!tocRefreshTimer) return;
      clearTimeout(tocRefreshTimer);
      tocRefreshTimer = null;
    };

    const clearActiveEditingResetTimer = () => {
      if (!activeEditingResetTimer) return;
      clearTimeout(activeEditingResetTimer);
      activeEditingResetTimer = null;
    };

    const shouldTrackEditorLatency = (event: KeyboardEvent): boolean => {
      if (!isEditable || event.isComposing) return false;
      if (event.metaKey || event.ctrlKey || event.altKey) return false;
      if (event.key.length === 1) return true;
      return event.key === "Backspace" || event.key === "Delete" || event.key === "Enter" || event.key === "Tab";
    };

    const scheduleLatencySampleEmit = (docLength: number, inputAt: number, updateSeenAt: number, key: string) => {
      if (!filePath) return;
      if (pendingLatencyFrame) {
        cancelAnimationFrame(pendingLatencyFrame);
      }

      pendingLatencyFrame = requestAnimationFrame(() => {
        pendingLatencyFrame = 0;
        if (isDisposed) return;

        const paintAt = performance.now();
        const totalLatencyMs = paintAt - inputAt;
        const inputToUpdateMs = updateSeenAt - inputAt;
        const updateToPaintMs = paintAt - updateSeenAt;
        latencySampleSequence += 1;

        const shouldEmit =
          latencySampleSequence % EDITOR_LATENCY_SAMPLE_INTERVAL === 0 ||
          totalLatencyMs >= EDITOR_LATENCY_LOG_THRESHOLD_MS;
        if (!shouldEmit) return;

        bridge.emit("editorInputLatency", {
          path: filePath,
          key,
          docLength,
          totalLatencyMs: Number(totalLatencyMs.toFixed(2)),
          inputToUpdateMs: Number(inputToUpdateMs.toFixed(2)),
          updateToPaintMs: Number(updateToPaintMs.toFixed(2)),
          activelyEditing: isActivelyEditingRef.current,
        });
      });
    };

    const applyInteractionMode = (view: EditorView, mode: Nv3InteractionMode) => {
      setNv3InteractionMode(view, mode);
    };

    const scheduleReturnToIdle = (view: EditorView) => {
      clearActiveEditingResetTimer();

      activeEditingResetTimer = setTimeout(() => {
        activeEditingResetTimer = null;
        if (isDisposed) return;
        if (!isActivelyEditingRef.current) return;

        isActivelyEditingRef.current = false;
        applyInteractionMode(view, "idle");
        syncToc(view, true);
        scheduleActiveTocHeadingSync(view);
      }, ACTIVE_EDITING_IDLE_MS);
    };

    const enterActiveEditingMode = (view: EditorView) => {
      if (!isEditable) return;

      isActivelyEditingRef.current = true;
      applyInteractionMode(view, "typing");
      scheduleReturnToIdle(view);
    };

    const enterCompositionMode = (view: EditorView) => {
      if (!isEditable) return;

      clearActiveEditingResetTimer();
      isActivelyEditingRef.current = true;
      applyInteractionMode(view, "composing");
    };

    const exitCompositionMode = (view: EditorView) => {
      if (!isEditable) return;

      isActivelyEditingRef.current = true;
      applyInteractionMode(view, "typing");
      scheduleReturnToIdle(view);
    };

    const emitDocChange = (nextDoc: string) => {
      if (!filePath) return;
      bridge.emit("docChange", {
        path: filePath,
        body: nextDoc,
      });
    };

    const flushPendingDocChange = () => {
      if (pendingDocChangeTimer) {
        clearTimeout(pendingDocChangeTimer);
        pendingDocChangeTimer = null;
      }

      if (pendingDocChangeBody == null) return;
      const body = pendingDocChangeBody;
      pendingDocChangeBody = null;
      emitDocChange(body);
    };

    const scheduleDocChange = (nextDoc: string) => {
      // Captures can close or reload at any time. The native host needs the
      // current buffer immediately; it already debounces disk writes.
      if (presentationMode === "quickCapture") {
        emitDocChange(nextDoc);
        return;
      }
      pendingDocChangeBody = nextDoc;

      if (pendingDocChangeTimer) {
        clearTimeout(pendingDocChangeTimer);
      }

      pendingDocChangeTimer = setTimeout(() => {
        pendingDocChangeTimer = null;
        if (isDisposed) return;
        flushPendingDocChange();
      }, DOC_CHANGE_DEBOUNCE_MS);
    };

    const clearToc = () => {
      tocHeadingsRef.current = [];

      if (activeTocHeadingIdRef.current !== null) {
        activeTocHeadingIdRef.current = null;
      }
    };

    const markdownScrollContainer = (view: EditorView): HTMLElement => view.scrollDOM;

    const emitMarkdownScrollRatio = (view: EditorView, reason: "scroll" | "cleanup" | "restore" = "scroll") => {
      if (!isMarkdownFile || !filePath) return;

      const scroller = markdownScrollContainer(view);
      const maxScrollTop = Math.max(0, scroller.scrollHeight - scroller.clientHeight);

      if (maxScrollTop <= 0) {
        emitScrollRestoreDebug({
          event: "scrollEmitSkipped",
          path: filePath,
          requestedRatio: initialMarkdownScrollRatio,
          maxScrollTop,
          scrollTop: scroller.scrollTop,
          reason,
        });
        return;
      }

      const ratio = Math.max(0, Math.min(1, scroller.scrollTop / maxScrollTop));
      emitScrollRestoreDebug({
        event: "scrollEmit",
        path: filePath,
        requestedRatio: initialMarkdownScrollRatio,
        maxScrollTop,
        scrollTop: scroller.scrollTop,
        reason,
      });
      bridge.emit("scrollStateChange", {
        kind: "markdown",
        path: filePath,
        ratio,
      });
    };

    const scheduleMarkdownScrollEmit = (view: EditorView) => {
      if (!isMarkdownFile) return;
      if (scrollEmitFrame) {
        cancelAnimationFrame(scrollEmitFrame);
      }

      scrollEmitFrame = requestAnimationFrame(() => {
        scrollEmitFrame = 0;
        if (isDisposed) return;
        emitMarkdownScrollRatio(view, "scroll");
      });
    };

    const syncActiveTocHeading = (view: EditorView, headings: Nv3OutlineHeading[] = tocHeadingsRef.current) => {
      if (!isMarkdownFile && fileType !== "org") {
        clearToc();
        return;
      }

      const nextActiveHeadingId = resolveActiveTocHeadingId(headings, view.viewport.from, view.viewport.to);
      if (activeTocHeadingIdRef.current === nextActiveHeadingId) {
        return;
      }

      activeTocHeadingIdRef.current = nextActiveHeadingId;
    };

    const scheduleActiveTocHeadingSync = (view: EditorView) => {
      if (!isMarkdownFile && fileType !== "org") return;
      if (activeTocSyncFrame) {
        cancelAnimationFrame(activeTocSyncFrame);
      }

      activeTocSyncFrame = requestAnimationFrame(() => {
        activeTocSyncFrame = 0;
        if (isDisposed) return;
        const previousID = activeTocHeadingIdRef.current;
        syncActiveTocHeading(view);
        if (previousID !== activeTocHeadingIdRef.current) emitDocumentNavigationState(view);
      });
    };

    const restoreMarkdownScroll = (view: EditorView) => {
      if (!isMarkdownFile || initialMarkdownScrollRatio == null || matchingPendingJump) return;
      if (pendingScrollRestoreFrame) {
        cancelAnimationFrame(pendingScrollRestoreFrame);
      }

      pendingScrollRestoreAttempts = 0;
      emitScrollRestoreDebug({
        event: "restoreScheduled",
        path: filePath,
        requestedRatio: initialMarkdownScrollRatio,
      });

      const attemptRestore = () => {
        pendingScrollRestoreFrame = requestAnimationFrame(() => {
          pendingScrollRestoreFrame = 0;
          if (isDisposed) return;

          const scroller = markdownScrollContainer(view);
          const maxScrollTop = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
          const canApplyImmediately = maxScrollTop > 0 || initialMarkdownScrollRatio === 0;

          emitScrollRestoreDebug({
            event: canApplyImmediately ? "restoreAttemptReady" : "restoreAttemptWaiting",
            path: filePath,
            requestedRatio: initialMarkdownScrollRatio,
            maxScrollTop,
            attempt: pendingScrollRestoreAttempts,
            scrollTop: scroller.scrollTop,
          });

          if (!canApplyImmediately) {
            pendingScrollRestoreAttempts += 1;
            if (pendingScrollRestoreAttempts < 24) {
              attemptRestore();
            }
            return;
          }

          scroller.scrollTop = maxScrollTop * initialMarkdownScrollRatio;
          emitScrollRestoreDebug({
            event: "restoreApplied",
            path: filePath,
            requestedRatio: initialMarkdownScrollRatio,
            maxScrollTop,
            attempt: pendingScrollRestoreAttempts,
            scrollTop: scroller.scrollTop,
          });
          emitMarkdownScrollRatio(view, "restore");
          scheduleActiveTocHeadingSync(view);
          scheduleMarkdownScrollEmit(view);
        });
      };

      attemptRestore();
    };

    const applyInitialCursorPlacement = (view: EditorView) => {
      if (cursorPlacement !== "start" && cursorPlacement !== "end") return;
      if (isDisposed) return;

      view.dispatch({ scrollIntoView: true });
      view.focus();
      scheduleActiveTocHeadingSync(view);
      scheduleMarkdownScrollEmit(view);
    };

    const applyPendingJump = (view: EditorView, request: EditorJumpRequest | null) => {
      if (!request || lastAppliedJumpIDRef.current === request.id) return;
      if (!jumpToMarkdownReference(view, request)) return;

      lastAppliedJumpIDRef.current = request.id;
      scheduleActiveTocHeadingSync(view);
      scheduleMarkdownScrollEmit(view);
    };

    const syncToc = (view: EditorView, refreshHeadings: boolean) => {
      if (!isMarkdownFile && fileType !== "org") {
        clearToc();
        emitDocumentNavigationState(view);
        return;
      }

      const collectToc = isMarkdownFile ? collectMarkdownOutlineHeadings : collectOrgOutlineHeadings;
      let headings = refreshHeadings ? collectToc(view.state) : tocHeadingsRef.current;
      if (refreshHeadings) {
        const didChange = !tocHeadingsEqual(tocHeadingsRef.current, headings);
        if (didChange) {
          tocHeadingsRef.current = headings;
        } else {
          headings = tocHeadingsRef.current;
        }
      }

      syncActiveTocHeading(view, headings);
      emitDocumentNavigationState(view);
    };

    const scheduleTocRefresh = (view: EditorView) => {
      if (!isMarkdownFile && fileType !== "org") return;

      clearTocRefreshTimer();
      tocRefreshTimer = setTimeout(() => {
        tocRefreshTimer = null;
        if (isDisposed) return;
        syncToc(view, true);
      }, TOC_REFRESH_DEBOUNCE_MS);
    };

    if (!isMarkdownFile && fileType !== "org") {
      clearToc();
    }

    const localWikilinkReferenceSuggestions = (rawQuery: string, sourcePath?: string) => {
      if (!filePath || sourcePath !== filePath) return [];

      const parsed = parseNv3WikilinkTarget(rawQuery);
      if (parsed.note) return [];

      const view = viewRef.current;
      if (!view) return [];

      const index = markdownScanIndexForView(view);

      if (parsed.referenceKind === "heading") {
        const query = parsed.referenceQuery.trim().toLocaleLowerCase();
        return index.headingOccurrences
          .filter((occurrence) => {
            if (!query) return true;
            return occurrence.text.toLocaleLowerCase().includes(query);
          })
          .map((occurrence) => ({
            label: occurrence.text,
            insertText: `#${occurrence.text}`,
            filterText: `#${occurrence.text}`,
            detail: "Heading in current note",
            type: "property",
          }));
      }

      if (parsed.referenceKind === "block") {
        const query = parsed.referenceQuery.trim().toLocaleLowerCase();
        return index.blockIDOcurrences
          .filter((occurrence) => {
            if (!query) return true;
            return occurrence.id.toLocaleLowerCase().includes(query);
          })
          .map((occurrence) => ({
            label: `^${occurrence.id}`,
            insertText: `#^${occurrence.id}`,
            filterText: `#^${occurrence.id}`,
            detail: "Block in current note",
            type: "property",
          }));
      }

      return [];
    };

    const mentionProvider: Nv3AutocompleteProvider = {
      source: "nvmodern.mention.users",
      trigger: "@",
      query(input) {
        const query = input.text.trim().toLowerCase();
        return users
          .filter((user) => !query || user.toLowerCase().includes(query))
          .sort((a, b) => a.localeCompare(b))
          .slice(0, 20)
          .map((user) => ({
            label: user,
            insertText: user,
            type: "variable",
            detail: "Configured user",
          }));
      },
    };

    const wikilinkProvider: Nv3AutocompleteProvider = {
      source: "nvmodern.wikilink",
      trigger: "[[",
      async query(input) {
        if (input.text.includes("|")) {
          return [];
        }

        const localItems = localWikilinkReferenceSuggestions(input.text, input.filePath);
        if (localItems.length) {
          return localItems;
        }

        const response = await bridge.request(
          "autocomplete.wikilink",
          {
            query: input.text,
            filePath: input.filePath,
          },
          input.signal,
        );

        const items =
          response &&
          typeof response === "object" &&
          Array.isArray((response as { items?: unknown[] }).items)
            ? ((response as { items: unknown[] }).items ?? [])
            : [];

        return items
          .filter((item): item is { label: string; insertText?: string; detail?: string } => {
            return Boolean(item && typeof item === "object" && typeof (item as { label?: unknown }).label === "string");
          })
          .map((item) => ({
            label: item.label,
            insertText: item.insertText ?? item.label,
            filterText: item.insertText ?? item.label,
            detail: item.detail,
            type: "text",
          }));
      },
    };

    const editorOptions = {
      onHelpOpen: window.webkit?.messageHandlers?.nvmodern
        ? (request: HelpOpenRequest) => bridge.emit("help.open", request)
        : undefined,
      filePath,
      fileType,
      onDocChange(nextDoc: string) {
        scheduleDocChange(nextDoc);
      },
      onWikilinkOpen({ target, href, occurrence, shiftKey, metaKey, altKey, ctrlKey }: {
        target: string;
        href: string;
        occurrence: unknown;
        shiftKey: boolean;
        metaKey: boolean;
        altKey: boolean;
        ctrlKey: boolean;
      }) {
        bridge.emit("wikilinkOpen", { target, href, occurrence, filePath, shiftKey, metaKey, altKey, ctrlKey });
      },
      onInlineLinkOpen({ href, label, from, to }: { href: string; label: string; from: number; to: number }) {
        const resolvedPath = resolveWorkspaceRelativePath(href, filePath);
        bridge.emit("inlineLinkOpen", { href, label, from, to, filePath, resolvedPath });
      },
      onOrgTodoMenuOpen({ from, to, current, states, event, view }: {
        from: number;
        to: number;
        current: string;
        states: readonly string[];
        event: MouseEvent;
        view: EditorView;
      }) {
        latestOrgTodoMenuTarget = { view, from, to };
        bridge.emit("contextMenuRequested", {
          ...contextMenuPointFromEvent(event),
          selectionText: "",
          orgTodo: { current, states },
        });
      },
      resolveWikilinkHref: ({ target }: { target: string }) => resolveWikilinkHref(target),
      resolveInlineLinkHref: ({ href }: { href: string }) => resolveInlineWorkspaceHref(href, filePath),
      resolveImageUrl: (src: string, sourcePath?: string) => resolvePreviewImageUrl(src, sourcePath ?? filePath),
      onImagePaste: isEditable
        ? async (base64Data: string, mimeType: string) => {
            const result = await bridge.request("image.save", {
              data: base64Data,
              mimeType,
              filePath,
            });
            if (!result || typeof result !== "object") return null;
            const payload = result as { path?: unknown };
            return typeof payload.path === "string" ? payload.path : null;
          }
        : undefined,
      resolveTransclusion: resolveTransclusionOverBridge,
      saveTransclusion: ({ target, filePath: sourcePath, depth, content, requestKind, signal }: {
        target: string;
        filePath?: string;
        depth: number;
        content: string;
        requestKind: string;
        signal: AbortSignal;
      }) =>
        bridge
          .request(
            "transclusion.save",
            {
              target,
              filePath: sourcePath,
              depth,
              content,
              requestKind,
            },
            signal,
          )
          .then(() => undefined),
      autocompleteProviders: isMarkdownFile ? [wikilinkProvider, mentionProvider] : undefined,
      autocompleteActivateOnTypingDelay: 140,
      substitutionRules,
      pickDate: isMarkdownFile || fileType === "org"
        ? ({ isoDate, kind, raw, startTime, endTime }: {
            isoDate?: string;
            kind?: string;
            raw?: string;
            startTime?: string | null;
            endTime?: string | null;
          }) =>
            bridge.request("date.pick", {
              isoDate,
              kind,
              raw,
              startTime,
              endTime,
              filePath,
            }).then((result) => {
              if (!result || typeof result !== "object") return null;
              const payload = result as {
                isoDate?: unknown;
                startTime?: unknown;
                endTime?: unknown;
              };
              if (typeof payload.isoDate !== "string") return null;
              return {
                isoDate: payload.isoDate,
                startTime: typeof payload.startTime === "string" ? payload.startTime : null,
                endTime: typeof payload.endTime === "string" ? payload.endTime : null,
              };
            })
        : undefined,
      onAutocompleteError({ providerSource, error }: { providerSource: string; error: unknown }) {
        bridge.emit("autocompleteError", {
          providerSource,
          message: String(error),
        });
      },
      latexPreviewMode: isMarkdownFile || fileType === "org" ? "katex" : "none",
      maxTransclusionDepth: 1,
      extraExtensions: [
        unwrapMarkdownLinesCompartment.of(
          context.unwrapMarkdownLines
            ? isMarkdownFile
              ? createMarkdownLineUnwrapExtension()
              : fileType === "org"
                ? createOrgLineUnwrapExtension()
                : []
            : [],
        ),
        EditorState.readOnly.of(!isEditable),
        placeholder(
          isEditable
            ? presentationMode === "quickCapture"
              ? "Capture a thought..."
              : "Start writing…"
            : "Selection is read-only.",
        ),
        EditorView.contentAttributes.of({
          spellcheck: isEditable ? "true" : "false",
          autocorrect: "off",
          autocapitalize: "off",
        }),
        EditorView.updateListener.of((update) => {
          const isOutlineableFile = isMarkdownFile || fileType === "org";

          if (nv3AnnotationsChanged(update.startState, update.state)) {
            rememberEditorAnnotations(update.view, contextMetaRef.current.path);
          }

          if (update.docChanged) {
            if (documentNavigationSearchQueryRef.current.trim()) {
              updateDocumentNavigationSearch(update.view, documentNavigationSearchQueryRef.current);
            } else {
              documentNavigationSearchMatchesRef.current = [];
              emitDocumentNavigationState(update.view);
            }
          }

          if (!isOutlineableFile) return;

          if (update.viewportChanged && !isActivelyEditingRef.current) {
            scheduleActiveTocHeadingSync(update.view);
          }

          if (update.docChanged) {
            if (pendingLatencyInputAt != null) {
              const inputAt = pendingLatencyInputAt;
              const key = pendingLatencyKey;
              pendingLatencyInputAt = null;
              pendingLatencyKey = "";
              scheduleLatencySampleEmit(update.state.doc.length, inputAt, performance.now(), key);
            }

            if (update.view.composing) {
              enterCompositionMode(update.view);
            } else {
              enterActiveEditingMode(update.view);
            }
            if (!isActivelyEditingRef.current) {
              syncActiveTocHeading(update.view);
              scheduleTocRefresh(update.view);
            }
          }
        }),
      ],
    };

    try {
      const initialSelection =
        cursorPlacement === "end"
          ? { anchor: doc.length }
          : cursorPlacement === "start"
            ? { anchor: 0 }
            : undefined;

      const state = createNv3EditorState({
        doc,
        selection: initialSelection,
        ...editorOptions,
      });

      const view = new EditorView({
        state,
        parent: mount,
      });

      view.contentDOM.spellcheck = isEditable;
      view.contentDOM.setAttribute("spellcheck", isEditable ? "true" : "false");
      applyInteractionMode(view, "idle");

      const handleScroll = () => {
        if (!isActivelyEditingRef.current) {
          scheduleActiveTocHeadingSync(view);
        }
        scheduleMarkdownScrollEmit(view);
      };

      const handleKeyDown = (event: KeyboardEvent) => {
        if (!shouldTrackEditorLatency(event)) return;
        enterActiveEditingMode(view);
        pendingLatencyInputAt = performance.now();
        pendingLatencyKey = event.key;
      };

      const handleCompositionStart = () => {
        enterCompositionMode(view);
      };

      const handleCompositionEnd = () => {
        exitCompositionMode(view);
      };

      if (isMarkdownFile) {
        markdownScrollContainer(view).addEventListener("scroll", handleScroll, { passive: true });
      }
      view.contentDOM.addEventListener("keydown", handleKeyDown, true);
      view.contentDOM.addEventListener("compositionstart", handleCompositionStart, true);
      view.contentDOM.addEventListener("compositionend", handleCompositionEnd, true);

      viewRef.current = view;
      window.nvmodernQueryEditorContext = (options) => {
        const currentView = viewRef.current;
        if (!currentView) return null;
        return queryEditorContextFromView(currentView, {
          path: contextMetaRef.current.path,
          title: contextMetaRef.current.title,
          options,
        });
      };
      window.nvmodernAnnotations = (request) => {
        const currentView = viewRef.current;
        if (!currentView) return null;
        return handleEditorAnnotationRequest(currentView, contextMetaRef.current.path, request);
      };
      restoreEditorAnnotations(view, contextMetaRef.current.path);
      setEditorInitError(null);
      syncToc(view, true);
      emitScrollRestoreDebug({
        event: "editorMounted",
        path: filePath,
        requestedRatio: initialMarkdownScrollRatio,
      });
      restoreMarkdownScroll(view);
      applyPendingJump(view, matchingPendingJump);
      applyInitialCursorPlacement(view);

      return () => {
        isDisposed = true;
        clearTocRefreshTimer();
        clearActiveEditingResetTimer();
        flushPendingDocChange();

        if (scrollEmitFrame) {
          cancelAnimationFrame(scrollEmitFrame);
          scrollEmitFrame = 0;
        }

        if (activeTocSyncFrame) {
          cancelAnimationFrame(activeTocSyncFrame);
          activeTocSyncFrame = 0;
        }

        if (pendingScrollRestoreFrame) {
          cancelAnimationFrame(pendingScrollRestoreFrame);
          pendingScrollRestoreFrame = 0;
        }

        if (pendingLatencyFrame) {
          cancelAnimationFrame(pendingLatencyFrame);
          pendingLatencyFrame = 0;
        }

        if (isMarkdownFile) {
          emitMarkdownScrollRatio(view, "cleanup");
          markdownScrollContainer(view).removeEventListener("scroll", handleScroll);
        }

        view.contentDOM.removeEventListener("keydown", handleKeyDown, true);
        view.contentDOM.removeEventListener("compositionstart", handleCompositionStart, true);
        view.contentDOM.removeEventListener("compositionend", handleCompositionEnd, true);
        view.destroy();
        viewRef.current = null;
        if (window.nvmodernQueryEditorContext) {
          delete window.nvmodernQueryEditorContext;
        }
        if (window.nvmodernAnnotations) {
          delete window.nvmodernAnnotations;
        }
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setEditorInitError(message);
      bridge.emit("editorInitError", {
        message,
        stack: error instanceof Error ? error.stack ?? "" : "",
      });
      return;
    }
  }, [
    context.isEditable,
    context.path,
    presentationMode,
    context.scrollState?.kind,
    context.scrollState?.ratio,
    cursorPlacement,
    substitutionRules,
    substitutionRulesKey,
    usersKey,
  ]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;

    const fileType = context.path ? detectNv3FileType(context.path) : "plain";
    view.dispatch({
      effects: unwrapMarkdownLinesCompartment.reconfigure(
        context.unwrapMarkdownLines
          ? fileType === "markdown"
            ? createMarkdownLineUnwrapExtension()
            : fileType === "org"
              ? createOrgLineUnwrapExtension()
              : []
          : [],
      ),
    });
  }, [context.path, context.unwrapMarkdownLines, unwrapMarkdownLinesCompartment]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;

    const nextDoc = context.body ?? "";
    const currentDoc = view.state.doc.toString();
    if (currentDoc === nextDoc) return;

    const selection = view.state.selection.main;
    const nextAnchor = Math.max(0, Math.min(nextDoc.length, selection.anchor));
    const nextHead = Math.max(0, Math.min(nextDoc.length, selection.head));

    view.dispatch({
      changes: { from: 0, to: currentDoc.length, insert: nextDoc },
      selection: { anchor: nextAnchor, head: nextHead },
    });
  }, [context.body, context.path]);

  // A frame opportunity after CodeMirror mounted and accepted this body.
  // Two rAFs bound a paint opportunity; this is not a compositor paint timestamp.
  useEffect(() => {
    const view = viewRef.current;
    if (context.kind !== "text" || !view || view.state.doc.toString() !== (context.body ?? "")) return;
    let secondFrame = 0;
    const firstFrame = requestAnimationFrame(() => {
      secondFrame = requestAnimationFrame(() => {
        if (viewRef.current !== view || !view.dom.isConnected) return;
        bridge.emit("editorFirstFrame", { kind: context.kind, path: context.path, bodyLength: view.state.doc.length });
      });
    });
    return () => {
      cancelAnimationFrame(firstFrame);
      if (secondFrame) cancelAnimationFrame(secondFrame);
    };
  }, [context.kind, context.path, context.body]);

  useEffect(() => {
    return bridge.onCommand((command, payload) => {
      if (normalizeContextKind(context.kind) !== "text") {
        return;
      }

      const view = viewRef.current;
      if (!view) {
        return;
      }

      if (command === "help.insert" || command === "help.closed") {
        const request = (payload ?? {}) as { token?: unknown; template?: unknown };
        if (typeof request.token !== "string") return;
        if (command === "help.insert" && typeof request.template === "string") {
          applyCalcHelpInsertion(view, request.token, request.template);
        } else {
          dismissCalcHelp(view, request.token);
        }
        return;
      }

      if (command === "documentNavigation") {
        const request = (payload ?? {}) as {
          path?: unknown;
          action?: {
            kind?: unknown;
            query?: unknown;
            id?: unknown;
            from?: unknown;
            to?: unknown;
            line?: unknown;
            column?: unknown;
            focus?: unknown;
          };
        };

        if (typeof request.path === "string" && request.path !== context.path) {
          return;
        }

        const action = request.action;
        if (!action || typeof action.kind !== "string") {
          return;
        }

        switch (action.kind) {
          case "begin": {
            documentNavigationOriginRef.current = {
              path: context.path ?? "",
              selection: view.state.selection,
              scrollTop: view.scrollDOM.scrollTop,
              scrollLeft: view.scrollDOM.scrollLeft,
            };
            const fileType = detectNv3FileType(context.path ?? "");
            tocHeadingsRef.current = fileType === "markdown"
              ? collectMarkdownOutlineHeadings(view.state)
              : fileType === "org" ? collectOrgOutlineHeadings(view.state) : [];
            activeTocHeadingIdRef.current = resolveActiveTocHeadingId(
              tocHeadingsRef.current, view.viewport.from, view.viewport.to,
            );
            emitDocumentNavigationState(view);
            return;
          }

          case "search": {
            updateDocumentNavigationSearch(view, typeof action.query === "string" ? action.query : "");
            return;
          }

          case "jumpToSearchMatch": {
            if (typeof action.from !== "number" || typeof action.to !== "number") return;
            jumpToDocumentRange(view, action.from, action.to);
            return;
          }

          case "jumpToOutlineItem": {
            const id = typeof action.id === "string" ? action.id : "";
            const requestedFrom = typeof action.from === "number" ? action.from : null;
            const heading =
              tocHeadingsRef.current.find((item) => item.id === id) ??
              (requestedFrom == null ? undefined : tocHeadingsRef.current.find((item) => item.from === requestedFrom));
            jumpToDocumentRange(view, heading?.from ?? requestedFrom ?? 0);
            return;
          }

          case "jumpToLine": {
            if (typeof action.line !== "number") return;
            jumpToDocumentLine(view, action.line, typeof action.column === "number" ? action.column : undefined);
            return;
          }

          case "commit": {
            documentNavigationOriginRef.current = null;
            updateDocumentNavigationSearch(view, "");
            if (action.focus !== false) view.focus();
            return;
          }

          case "cancel": {
            const origin = documentNavigationOriginRef.current;
            documentNavigationOriginRef.current = null;
            updateDocumentNavigationSearch(view, "");

            if (origin && origin.path === (context.path ?? "")) {
              view.dispatch({
                selection: origin.selection,
                scrollIntoView: true,
              });
              if (action.focus !== false) view.focus();
              // Flush the selection's viewport measurement before restoring
              // the exact offsets, or pending preview anchoring can move them.
              view.coordsAtPos(origin.selection.main.head);
              view.scrollDOM.scrollTop = origin.scrollTop;
              view.scrollDOM.scrollLeft = origin.scrollLeft;
            }
            return;
          }

          default:
            return;
        }
      }

      if (!context.isEditable) {
        return;
      }

      if (command.startsWith("orgTodoSet.")) {
        const target = latestOrgTodoMenuTarget;
        const state = command.slice("orgTodoSet.".length);
        if (!target || !state) return;
        const current = target.view.state.doc.sliceString(target.from, target.to);
        if (!current) return;
        target.view.dispatch({
          changes: { from: target.from, to: target.to, insert: state },
        });
        target.view.focus();
        bridge.emit("contentInteraction");
        return;
      }

      if (command === "replaceSelection") {
        const request = (payload ?? {}) as { path?: unknown; text?: unknown };
        if (typeof request.text !== "string") {
          return;
        }

        if (typeof request.path === "string" && request.path !== context.path) {
          return;
        }

        view.dispatch({
          ...view.state.replaceSelection(request.text),
          scrollIntoView: true,
        });
        view.focus();
        bridge.emit("contentInteraction");
        return;
      }

      const request = (payload ?? {}) as { path?: unknown };
      if (typeof request.path === "string" && request.path !== context.path) {
        return;
      }

      const commandHandlers: Record<string, () => boolean> = {
        toggleMarkdownBold: () => toggleMarkdownBold({ state: view.state, dispatch: view.dispatch.bind(view) }),
        toggleMarkdownItalic: () => toggleMarkdownItalic({ state: view.state, dispatch: view.dispatch.bind(view) }),
        toggleMarkdownStrikethrough: () => toggleMarkdownStrikethrough({ state: view.state, dispatch: view.dispatch.bind(view) }),
        toggleMarkdownHighlightSelection: () => toggleMarkdownHighlight({ state: view.state, dispatch: view.dispatch.bind(view) }),
        toggleMarkdownInlineCode: () => toggleMarkdownInlineCode({ state: view.state, dispatch: view.dispatch.bind(view) }),
        toggleMarkdownHeading1: () => toggleMarkdownHeadingLevel(view, 1),
        toggleMarkdownHeading2: () => toggleMarkdownHeadingLevel(view, 2),
        toggleMarkdownHeading3: () => toggleMarkdownHeadingLevel(view, 3),
        toggleMarkdownBulletList: () => toggleMarkdownLinePrefix(view, "- "),
        toggleMarkdownNumberedList: () => toggleMarkdownOrderedList(view),
        toggleMarkdownTaskList: () => toggleMarkdownLinePrefix(view, "- [ ] ", /^(\s*)- \[(?: |x|X)\] /),
        toggleMarkdownBlockquote: () => toggleMarkdownLinePrefix(view, "> "),
        quoteMarkdownSelection: () => {
          const changed = quoteMarkdownSelection({ state: view.state, dispatch: view.dispatch.bind(view) });
          if (changed) view.focus();
          return changed;
        },
        prefixMarkdownSelectionLines: () => {
          const prefixRequest = (payload ?? {}) as {
            firstPrefix?: unknown;
            continuationPrefix?: unknown;
          };
          if (typeof prefixRequest.firstPrefix !== "string") return false;
          if (
            prefixRequest.continuationPrefix !== undefined &&
            typeof prefixRequest.continuationPrefix !== "string"
          ) return false;
          const changed = prefixMarkdownSelectionLines(
            { state: view.state, dispatch: view.dispatch.bind(view) },
            {
              firstPrefix: prefixRequest.firstPrefix,
              continuationPrefix: prefixRequest.continuationPrefix,
            },
          );
          if (changed) view.focus();
          return changed;
        },
        unquoteMarkdownSelection: () => {
          const changed = unquoteMarkdownSelection({ state: view.state, dispatch: view.dispatch.bind(view) });
          if (changed) view.focus();
          return changed;
        },
        insertMarkdownCodeBlock: () => insertMarkdownCodeBlock(view),
        insertMarkdownLink: () => insertMarkdownLink(view),
        insertMarkdownWikilink: () => insertMarkdownWikilink(view),
        // False keeps focus where the composer put it: in its question box.
        beginAnnotationQuestion: () => {
          beginNv3AnnotationComposer(view);
          return false;
        },
      };

      const tableCommand = markdownTableBridgeCommands[command];
      if (tableCommand) {
        if (runMarkdownTableCommand(view, tableCommand, latestMarkdownTableContextMenuTarget)) {
          bridge.emit("contentInteraction");
        }
        return;
      }

      const activeTableCommand = markdownTableActiveBridgeCommands[command];
      if (activeTableCommand) {
        if (runMarkdownTableCommand(view, activeTableCommand, null)) {
          bridge.emit("contentInteraction");
        }
        return;
      }

      const handler = commandHandlers[command];
      if (!handler) {
        return;
      }

      if (handler()) {
        view.focus();
        bridge.emit("contentInteraction");
      }
    });
  }, [context.isEditable, context.kind, context.path]);

  useEffect(() => {
    if (!pendingJump || pendingJump.path !== context.path) return;
    if (lastAppliedJumpIDRef.current === pendingJump.id) return;

    const view = viewRef.current;
    if (!view) return;
    if (!jumpToMarkdownReference(view, pendingJump)) return;

    lastAppliedJumpIDRef.current = pendingJump.id;

    if (detectNv3FileType(context.path ?? "") !== "markdown") {
      return;
    }

    requestAnimationFrame(() => {
      const isMarkdownContext = detectNv3FileType(context.path ?? "") === "markdown";
      const collectToc = isMarkdownContext ? collectMarkdownOutlineHeadings : collectOrgOutlineHeadings;
      const headings = tocHeadingsRef.current.length ? tocHeadingsRef.current : collectToc(view.state);
      const nextActiveHeadingId = resolveActiveTocHeadingId(headings, view.viewport.from, view.viewport.to);
      if (activeTocHeadingIdRef.current !== nextActiveHeadingId) {
        activeTocHeadingIdRef.current = nextActiveHeadingId;
      }
    });
  }, [context.path, pendingJump?.id, pendingJump?.kind, pendingJump?.path, pendingJump?.query]);

  return (
    <div className="nvmodern-editor-shell" data-presentation-mode={presentationMode} ref={shellRef}>
      <div className="nvmodern-editor-layout">
        <div className="nvmodern-editor-mount" ref={mountRef} />
      </div>
      {editorInitError ? <div className="nvmodern-editor-error">{editorInitError}</div> : null}
    </div>
  );
}

function PreviewShell({
  context: _context,
  children,
}: {
  context: EditorContext;
  children: React.ReactNode;
}) {
  return (
    <div className="nvmodern-preview-shell">
      <div className="nvmodern-preview-content">{children}</div>
    </div>
  );
}

function ImagePreviewSurface({ context }: { context: EditorContext }) {
  const previewURL = previewURLForContext(context);
  const [failed, setFailed] = useState(false);

  return (
    <PreviewShell context={context}>
      {!previewURL ? (
        <div className="nvmodern-preview-empty">Image path unavailable.</div>
      ) : failed ? (
        <div className="nvmodern-preview-empty">Failed to load image preview.</div>
      ) : (
        <img
          className="nvmodern-image-preview"
          src={previewURL}
          alt={context.title ?? "Image preview"}
          onError={() => {
            setFailed(true);
            bridge.emit("previewLoadError", {
              kind: "image",
              path: context.path,
            });
          }}
        />
      )}
    </PreviewShell>
  );
}

function PdfPreviewSurface({ context }: { context: EditorContext }) {
  const previewURL = previewURLForContext(context);

  return (
    <PreviewShell context={context}>
      {!previewURL ? (
        <div className="nvmodern-preview-empty">PDF path unavailable.</div>
      ) : (
        <iframe
          className="nvmodern-pdf-preview"
          src={previewURL}
          title={context.title ?? "PDF preview"}
          onError={() => {
            bridge.emit("previewLoadError", {
              kind: "pdf",
              path: context.path,
            });
          }}
        />
      )}
    </PreviewShell>
  );
}

function CsvPreviewSurface({ context }: { context: EditorContext }) {
  const previewURL = previewURLForContext(context);
  const [rows, setRows] = useState<string[][]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [truncated, setTruncated] = useState(false);
  const [columnCount, setColumnCount] = useState(0);

  useEffect(() => {
    if (!previewURL) {
      setRows([]);
      setColumnCount(0);
      setTruncated(false);
      setError("CSV path unavailable.");
      return;
    }

    let isDisposed = false;
    const controller = new AbortController();

    const load = async () => {
      setIsLoading(true);
      setError(null);
      setRows([]);
      setTruncated(false);
      setColumnCount(0);

      try {
        const response = await fetch(previewURL, { signal: controller.signal });
        if (!response.ok) {
          throw new Error(`Failed to load CSV preview (${response.status})`);
        }

        const text = await response.text();
        const truncatedBySize = text.length > CSV_CHARACTER_LIMIT;
        const limitedContent = truncatedBySize ? text.slice(0, CSV_CHARACTER_LIMIT) : text;
        const parsed = parseCSV(limitedContent);

        const truncatedByRows = parsed.length > CSV_ROW_LIMIT;
        const hasWideRow = parsed.some((row) => row.length > CSV_COLUMN_LIMIT);

        const limitedRows = parsed.slice(0, CSV_ROW_LIMIT).map((row) => row.slice(0, CSV_COLUMN_LIMIT));
        const widest = limitedRows.reduce((maxColumns, row) => Math.max(maxColumns, row.length), 0);

        if (isDisposed) return;

        setRows(limitedRows);
        setColumnCount(widest);
        setTruncated(truncatedBySize || truncatedByRows || hasWideRow);
      } catch (loadError) {
        if (isDisposed) return;
        const message = loadError instanceof Error ? loadError.message : String(loadError);
        setError(message);
        bridge.emit("csvParseError", {
          path: context.path,
          message,
        });
      } finally {
        if (!isDisposed) {
          setIsLoading(false);
        }
      }
    };

    void load();

    return () => {
      isDisposed = true;
      controller.abort();
    };
  }, [context.path, previewURL]);

  const effectiveColumnCount = Math.max(1, columnCount);

  return (
    <PreviewShell context={context}>
      {isLoading ? <div className="nvmodern-preview-empty">Loading CSV preview…</div> : null}
      {!isLoading && error ? <div className="nvmodern-preview-empty">{error}</div> : null}
      {!isLoading && !error && rows.length === 0 ? <div className="nvmodern-preview-empty">CSV is empty.</div> : null}

      {!isLoading && !error && rows.length > 0 ? (
        <div className="nvmodern-csv-wrap">
          {truncated ? (
            <div className="nvmodern-csv-truncated">
              Showing a truncated preview (first {CSV_ROW_LIMIT} rows, {CSV_COLUMN_LIMIT} columns, {CSV_CHARACTER_LIMIT.toLocaleString()} characters).
            </div>
          ) : null}
          <table className="nvmodern-csv-table">
            <thead>
              <tr>
                <th className="nvmodern-csv-row-index">#</th>
                {Array.from({ length: effectiveColumnCount }, (_, columnIndex) => (
                  <th key={`header-${columnIndex}`}>Column {columnIndex + 1}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((row, rowIndex) => (
                <tr key={`row-${rowIndex}`}>
                  <td className="nvmodern-csv-row-index">{rowIndex + 1}</td>
                  {Array.from({ length: effectiveColumnCount }, (_, columnIndex) => (
                    <td key={`row-${rowIndex}-col-${columnIndex}`}>{row[columnIndex] ?? ""}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
    </PreviewShell>
  );
}

function DiffPreviewSurface({ context }: { context: EditorContext }) {
  const [layout, setLayout] = useState<"split" | "unified">("split");
  const frameRef = useRef<HTMLIFrameElement | null>(null);
  const left = context.diff?.left;
  const right = context.diff?.right;
  const hasDiff = Boolean(left && right && typeof left.body === "string" && typeof right.body === "string");
  const postDiffContext = () => {
    if (!hasDiff) return;
    frameRef.current?.contentWindow?.postMessage(
      { kind: "nvmodern-diff-context", left, right, layout },
      "*",
    );
  };

  useEffect(() => {
    postDiffContext();
  }, [layout, left?.path, left?.title, left?.body, right?.path, right?.title, right?.body]);

  useEffect(() => {
    const receiveRendererReady = (event: MessageEvent<unknown>) => {
      const data = event.data as { kind?: string } | null;
      if (event.source === frameRef.current?.contentWindow && data?.kind === "nvmodern-diff-ready") {
        postDiffContext();
      }
    };
    window.addEventListener("message", receiveRendererReady);
    return () => window.removeEventListener("message", receiveRendererReady);
  }, [layout, left?.path, left?.title, left?.body, right?.path, right?.title, right?.body]);

  if (!left || !right || !hasDiff) {
    return (
      <PreviewShell context={context}>
        <div className="nvmodern-preview-empty">{context.body || "Loading comparison…"}</div>
      </PreviewShell>
    );
  }

  const leftName = left.title || left.path || "Before.md";
  const rightName = right.title || right.path || "After.md";

  return (
    <PreviewShell context={context}>
      <div className="nvmodern-diff-surface">
        <div className="nvmodern-diff-toolbar">
          <div className="nvmodern-diff-title" title={`${left.path ?? leftName} ↔ ${right.path ?? rightName}`}>
            <span>{leftName}</span>
            <span className="nvmodern-diff-arrow" aria-hidden="true">↔</span>
            <span>{rightName}</span>
          </div>
          <div className="nvmodern-diff-actions">
            <div className="nvmodern-diff-layout-picker" role="group" aria-label="Diff layout">
              <button type="button" aria-pressed={layout === "split"} onClick={() => setLayout("split")}>Split</button>
              <button type="button" aria-pressed={layout === "unified"} onClick={() => setLayout("unified")}>Stacked</button>
            </div>
            <button type="button" className="nvmodern-diff-refresh" onClick={() => bridge.emit("diffRefreshRequested")}>Refresh</button>
          </div>
        </div>
        <div className="nvmodern-diff-view">
          <iframe
            ref={frameRef}
            className="nvmodern-diff-frame"
            src="./diff.html"
            title={`${leftName} compared with ${rightName}`}
            onLoad={postDiffContext}
          />
        </div>
      </div>
    </PreviewShell>
  );
}

function UnsupportedPreviewSurface({ context }: { context: EditorContext }) {
  return (
    <PreviewShell context={context}>
      <div className="nvmodern-preview-empty">{context.body || "Preview unavailable for this file type yet."}</div>
    </PreviewShell>
  );
}

export function App() {
  const [context, setContext] = useState<EditorContext | null>(null);
  const [pendingJump, setPendingJump] = useState<EditorJumpRequest | null>(null);
  const contextPathRef = useRef<string | undefined>(undefined);

  useEffect(() => {
    // F1 that no editor binding claimed (e.g. calc's contextual help) opens the app's help browser.
    const handleHelpKey = (event: KeyboardEvent) => {
      if (event.key !== "F1" || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
      event.preventDefault();
      // Surfaces without a CodeMirror binding (the Arbor outline) pick their own provider.
      const inArbor = event.target instanceof Element && event.target.closest(".arbor-shell");
      bridge.emit("help.browse", inArbor ? { providerID: "arbor" } : {});
    };
    window.addEventListener("keydown", handleHelpKey);
    return () => window.removeEventListener("keydown", handleHelpKey);
  }, []);

  useEffect(() => {
    const notifyInteraction = () => {
      bridge.emit("contentInteraction");
    };

    const handleContextMenu = (event: MouseEvent) => {
      const target = event.target instanceof Element ? event.target : null;
      if (target?.closest(".arbor-shell")) return;
      event.preventDefault();
      event.stopPropagation();
      latestMarkdownTableContextMenuTarget = markdownTableContextFromEventTarget(event.target);
      bridge.emit("contextMenuRequested", {
        ...contextMenuPointFromEvent(event),
        selectionText: contextMenuSelectionText(),
        markdownTable: latestMarkdownTableContextMenuTarget,
      });
    };

    window.addEventListener("pointerdown", notifyInteraction, true);
    window.addEventListener("focusin", notifyInteraction, true);
    window.addEventListener("contextmenu", handleContextMenu, true);

    return () => {
      window.removeEventListener("pointerdown", notifyInteraction, true);
      window.removeEventListener("focusin", notifyInteraction, true);
      window.removeEventListener("contextmenu", handleContextMenu, true);
    };
  }, []);

  useEffect(() => {
    applyNv3UserStylesheet(context?.userThemeCSS);
  }, [context?.userThemeCSS]);

  useEffect(() => {
    applyNv3InspectorStylesheet(context?.documentInspectorCSS);
  }, [context?.documentInspectorCSS]);

  useEffect(() => {
    document.documentElement.setAttribute("data-doc-theme", context?.documentInspectorTheme ?? "system");
  }, [context?.documentInspectorTheme]);

  useEffect(() => {
    contextPathRef.current = context?.path;
  }, [context?.path]);

  useEffect(() => {
    const unsubscribe = bridge.onCommand((command, payload) => {
      if (command === "setHostAppearance") {
        const next = (payload ?? {}) as { colorScheme?: unknown };
        applyHostColorScheme(next.colorScheme);
        return;
      }

      if (command === "setContext") {
        const next = (payload ?? {}) as EditorContext;
        setContext(next);
        bridge.emit("contextReceived", {
          kind: next.kind,
          path: next.path,
          usersCount: Array.isArray(next.users) ? next.users.length : 0,
        });
        return;
      }

      if (command === "setDocumentAppearance") {
        const next = (payload ?? {}) as {
          path?: unknown;
          theme?: unknown;
          css?: unknown;
          unwrapMarkdownLines?: unknown;
        };
        if (typeof next.path === "string" && next.path !== contextPathRef.current) return;
        applyNv3InspectorStylesheet(typeof next.css === "string" ? next.css : undefined);
        document.documentElement.setAttribute(
          "data-doc-theme",
          typeof next.theme === "string" ? next.theme : "system",
        );
        setContext((current) => {
          if (!current) return current;
          if (typeof next.path === "string" && next.path !== current.path) return current;
          return {
            ...current,
            documentInspectorTheme: typeof next.theme === "string" ? next.theme : undefined,
            documentInspectorCSS: typeof next.css === "string" ? next.css : undefined,
            unwrapMarkdownLines: next.unwrapMarkdownLines === true,
          };
        });
        return;
      }

      if (command !== "jumpToMarkdownReference") {
        return;
      }

      const next = (payload ?? {}) as {
        id?: unknown;
        path?: unknown;
        kind?: unknown;
        query?: unknown;
      };

      if (
        typeof next.id !== "string" ||
        typeof next.path !== "string" ||
        (next.kind !== "heading" && next.kind !== "block" && next.kind !== "line") ||
        typeof next.query !== "string" ||
        !next.path ||
        !next.query.trim()
      ) {
        return;
      }

      setPendingJump({
        id: next.id,
        path: next.path,
        kind: next.kind,
        query: next.query,
      });
    });

    bridge.sendReady();

    return unsubscribe;
  }, []);

  const kind = context ? normalizeContextKind(context.kind) : null;

  useEffect(() => {
    const root = document.documentElement;
    if (kind) {
      root.dataset.nvSurface = kind;
    } else {
      delete root.dataset.nvSurface;
    }
    return () => {
      delete root.dataset.nvSurface;
    };
  }, [kind]);

  if (!context || kind == null) {
    return <div className="nvmodern-empty">Loading editor…</div>;
  }

  if (kind === "text" && isArborDocumentPath(context.path)) {
    return (
      <ArborSurface
        key={context.path ?? "arbor-document"}
        context={context}
        host={nvmodernArborHost}
      />
    );
  }

  switch (kind) {
    case "folder":
    case "text":
      return <TextEditorSurface context={context} pendingJump={pendingJump} />;
    case "image":
      return <ImagePreviewSurface context={context} />;
    case "diff":
      return <DiffPreviewSurface context={context} />;
    case "csv":
      return <CsvPreviewSurface context={context} />;
    case "pdf":
      return <PdfPreviewSurface context={context} />;
    case "epub":
      return <EPUBSurface context={context} />;
    case "unsupported":
    default:
      return <UnsupportedPreviewSurface context={context} />;
  }
}
