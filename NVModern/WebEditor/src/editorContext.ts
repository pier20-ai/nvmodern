import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";

export type EditorContextQueryOptions = {
  includeSelection?: boolean;
  includeViewport?: boolean;
  includeCursor?: boolean;
  radiusLines?: number;
  maxChars?: number;
};

export type EditorTextSlice = {
  startLine: number;
  endLine: number;
  text: string;
  truncated: boolean;
};

export type EditorSelectionSnapshot = {
  text: string;
  startLine: number;
  endLine: number;
  empty: boolean;
};

export type EditorCursorSnapshot = {
  line: number;
  column: number;
  startLine: number;
  endLine: number;
  text: string;
  truncated: boolean;
};

export type EditorContextQueryResult = {
  path: string | null;
  title: string | null;
  selection: EditorSelectionSnapshot | null;
  viewport: EditorTextSlice | null;
  cursor: EditorCursorSnapshot | null;
};

const DEFAULT_RADIUS_LINES = 12;
const DEFAULT_MAX_CHARS = 4000;

export function normalizeEditorContextQuery(
  options?: EditorContextQueryOptions,
): Required<EditorContextQueryOptions> {
  return {
    includeSelection: options?.includeSelection !== false,
    includeViewport: options?.includeViewport !== false,
    includeCursor: options?.includeCursor !== false,
    radiusLines: clampInt(options?.radiusLines, 1, 80, DEFAULT_RADIUS_LINES),
    maxChars: clampInt(options?.maxChars, 256, 32_000, DEFAULT_MAX_CHARS),
  };
}

export function sliceLineRange(
  state: EditorState,
  startLine: number,
  endLine: number,
  maxChars: number,
): EditorTextSlice {
  const lineCount = Math.max(1, state.doc.lines);
  const first = clampInt(startLine, 1, lineCount, 1);
  const last = clampInt(endLine, first, lineCount, first);
  const from = state.doc.line(first).from;
  const to = state.doc.line(last).to;
  return truncateSlice(state.doc.sliceString(from, to), first, last, maxChars);
}

export function selectionSnapshot(state: EditorState): EditorSelectionSnapshot {
  const selection = state.selection.main;
  const startLine = state.doc.lineAt(selection.from).number;
  const endLine = selection.to <= selection.from
    ? startLine
    : state.doc.lineAt(selection.to - 1).number;
  return {
    text: state.sliceDoc(selection.from, selection.to),
    startLine,
    endLine,
    empty: selection.empty,
  };
}

export function sliceAroundCursor(
  state: EditorState,
  options?: { radiusLines?: number; maxChars?: number },
): EditorCursorSnapshot {
  const radiusLines = clampInt(options?.radiusLines, 1, 80, DEFAULT_RADIUS_LINES);
  const maxChars = clampInt(options?.maxChars, 256, 32_000, DEFAULT_MAX_CHARS);
  const head = state.selection.main.head;
  const line = state.doc.lineAt(head);
  const lineCount = Math.max(1, state.doc.lines);
  const startLine = Math.max(1, line.number - radiusLines);
  const endLine = Math.min(lineCount, line.number + radiusLines);
  const slice = sliceLineRange(state, startLine, endLine, maxChars);
  return {
    line: line.number,
    column: head - line.from + 1,
    startLine: slice.startLine,
    endLine: slice.endLine,
    text: slice.text,
    truncated: slice.truncated,
  };
}

export function queryEditorContextFromState(
  state: EditorState,
  meta: {
    path?: string | null;
    title?: string | null;
    options?: EditorContextQueryOptions;
    viewportStartLine?: number;
    viewportEndLine?: number;
  } = {},
): EditorContextQueryResult {
  const options = normalizeEditorContextQuery(meta.options);
  const lineCount = Math.max(1, state.doc.lines);
  const viewportStart = meta.viewportStartLine ?? 1;
  const viewportEnd = meta.viewportEndLine ?? lineCount;

  return {
    path: meta.path ?? null,
    title: meta.title ?? null,
    selection: options.includeSelection ? selectionSnapshot(state) : null,
    viewport: options.includeViewport
      ? sliceLineRange(state, viewportStart, viewportEnd, options.maxChars)
      : null,
    cursor: options.includeCursor
      ? sliceAroundCursor(state, {
          radiusLines: options.radiusLines,
          maxChars: options.maxChars,
        })
      : null,
  };
}

export function queryEditorContextFromView(
  view: EditorView,
  meta: {
    path?: string | null;
    title?: string | null;
    options?: EditorContextQueryOptions;
  } = {},
): EditorContextQueryResult {
  const viewportStart = view.state.doc.lineAt(view.viewport.from).number;
  const viewportEnd = view.viewport.to <= view.viewport.from
    ? viewportStart
    : view.state.doc.lineAt(view.viewport.to - 1).number;
  return queryEditorContextFromState(view.state, {
    ...meta,
    viewportStartLine: viewportStart,
    viewportEndLine: viewportEnd,
  });
}

function truncateSlice(
  text: string,
  startLine: number,
  endLine: number,
  maxChars: number,
): EditorTextSlice {
  if (text.length <= maxChars) {
    return { startLine, endLine, text, truncated: false };
  }
  return {
    startLine,
    endLine,
    text: text.slice(0, maxChars),
    truncated: true,
  };
}

function clampInt(value: number | undefined, min: number, max: number, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, Math.trunc(value)));
}

declare global {
  interface Window {
    nvmodernQueryEditorContext?: (
      options?: EditorContextQueryOptions,
    ) => EditorContextQueryResult | null;
  }
}
