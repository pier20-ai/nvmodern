/**
 * Markdown timestamp decoration, editing, and leader-key shortcuts.
 *
 * Timestamps use `[date]` (inactive) and `<date>` (active) delimiters.
 * The leader key (`Cmd+;`) exposes shortcuts for inserting dates, opening
 * the date picker, and inserting block references.
 */
import {
  EditorState,
  Facet,
  type Extension,
  type SelectionRange,
  Text,
  type Text as CMText,
  type TransactionSpec,
} from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  ViewPlugin,
  type ViewUpdate,
} from "@codemirror/view";
import {
  createMarkdownScannerContext,
  isMarkdownLineScannable,
  type Nv3ScannerLineContext,
} from "./scannerContext.ts";
import { hasRangeOverlap, isEscaped, resetIfStalled } from "./scanUtils.ts";
import { focusEditorWithoutScroll, resolveEventElement } from "./viewUtils.ts";
import {
  formatTimestamp,
  currentTimeLocal,
  humanDateLabelForISODate,
  isValidISODate,
  parseTimestampLiteral,
  shiftISODate,
  todayISODateLocal,
  weekdayForISODate,
  type ParsedTimestamp,
  type TimestampKind,
} from "./dateUtils.ts";
import { insertBlockReference } from "./blockReferences.ts";
import { parseOrgText } from "../org/parser.ts";

// ── Re-exports (public API compat) ───────────────────────────────────────

export {
  isValidISODate,
  shiftISODate,
  type TimestampKind as Nv3MarkdownTimestampKind,
} from "./dateUtils.ts";

// ── Types ─────────────────────────────────────────────────────────────────

export interface Nv3MarkdownTimestampOccurrence {
  kind: TimestampKind;
  syntax: "markdown" | "org";
  isoDate: string;
  weekday: string;
  startTime: string | null;
  endTime: string | null;
  raw: string;
  from: number;
  to: number;
  line: number;
}

export type Nv3ParsedMarkdownTimestamp = ParsedTimestamp;

export interface Nv3MarkdownDatePickerRequest {
  kind: TimestampKind;
  isoDate: string;
  weekday: string;
  startTime: string | null;
  endTime: string | null;
  raw: string;
}

export interface Nv3DatePickerSelection {
  isoDate: string;
  startTime?: string | null;
  endTime?: string | null;
}

export interface MarkdownDatesExtensionOptions {
  syntax?: "markdown" | "org";
  pickDate?: (request: Nv3MarkdownDatePickerRequest) => Promise<Nv3DatePickerSelection | null>;
}

// ── Facet ─────────────────────────────────────────────────────────────────

const markdownDatesOptionsFacet = Facet.define<
  MarkdownDatesExtensionOptions,
  MarkdownDatesExtensionOptions
>({
  combine: (values) => values[0] ?? {},
});

// ── Constants ─────────────────────────────────────────────────────────────

const INACTIVE_TIMESTAMP_PATTERN = /\[([^\]\n]+)\]/g;
const ACTIVE_TIMESTAMP_PATTERN = /<([^>\n]+)>/g;
const LEADER_TIMEOUT_MS = 1_500;

// ── Editor helpers ────────────────────────────────────────────────────────

function isEditorReadOnly(state: EditorState): boolean {
  return state.facet(EditorState.readOnly);
}

// ── Timestamp occurrence helpers ──────────────────────────────────────────

function timestampTouchesRange(occ: Nv3MarkdownTimestampOccurrence, range: SelectionRange): boolean {
  if (range.empty) return range.from >= occ.from && range.from <= occ.to;
  return range.from < occ.to && range.to > occ.from;
}

function collectTouchedTimestamps(
  occurrences: readonly Nv3MarkdownTimestampOccurrence[],
  ranges: readonly SelectionRange[],
): Nv3MarkdownTimestampOccurrence[] {
  return occurrences.filter((occ) => ranges.some((r) => timestampTouchesRange(occ, r)));
}

function firstTimestampTouchingRange(
  occurrences: readonly Nv3MarkdownTimestampOccurrence[],
  range: SelectionRange,
): Nv3MarkdownTimestampOccurrence | null {
  for (const occ of occurrences) {
    if (timestampTouchesRange(occ, range)) return occ;
  }
  return null;
}

// ── Decorations ───────────────────────────────────────────────────────────

function timestampDecoration(occ: Nv3MarkdownTimestampOccurrence) {
  const humanLabel = humanDateLabelForISODate(occ.isoDate) ?? occ.isoDate;
  return Decoration.mark({
    tagName: "span",
    class: `nv3-timestamp nv3-timestamp-${occ.kind}`,
    attributes: {
      "data-nv3-timestamp": "true",
      "data-nv3-timestamp-kind": occ.kind,
      "data-nv3-timestamp-iso": occ.isoDate,
      "data-nv3-timestamp-start-time": occ.startTime ?? "",
      "data-nv3-timestamp-end-time": occ.endTime ?? "",
      "data-nv3-timestamp-from": String(occ.from),
      "data-nv3-timestamp-to": String(occ.to),
      title: `Edit date ${humanLabel}`,
    },
  }).range(occ.from, occ.to);
}

function buildTimestampDecorations(occurrences: readonly Nv3MarkdownTimestampOccurrence[]): DecorationSet {
  return Decoration.set(occurrences.map(timestampDecoration), true);
}

// ── Scanning ──────────────────────────────────────────────────────────────

function scanTimestampPattern(
  line: Nv3ScannerLineContext,
  pattern: RegExp,
  kind: TimestampKind,
  occurrences: Nv3MarkdownTimestampOccurrence[],
): void {
  pattern.lastIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(line.text)) !== null) {
    const raw = match[0] ?? "";
    const innerText = match[1] ?? "";
    if (!raw || !innerText) { resetIfStalled(pattern, match); continue; }

    const parsed = parseTimestampLiteral(raw);
    if (!parsed) { resetIfStalled(pattern, match); continue; }

    const startOffset = match.index;
    const endOffset = startOffset + raw.length;

    if (isEscaped(line.text, startOffset)) { resetIfStalled(pattern, match); continue; }
    if (hasRangeOverlap(line.inlineCodeRanges, startOffset, endOffset)) { resetIfStalled(pattern, match); continue; }

    if (kind === "inactive") {
      const prevChar = startOffset > 0 ? line.text[startOffset - 1] ?? "" : "";
      const nextChar = line.text[endOffset] ?? "";
      if (prevChar === "[" || prevChar === "!") { resetIfStalled(pattern, match); continue; }
      if (nextChar === "(") { resetIfStalled(pattern, match); continue; }
    }

    occurrences.push({
      kind,
      syntax: "markdown",
      isoDate: parsed.isoDate,
      weekday: parsed.weekday,
      startTime: parsed.startTime,
      endTime: parsed.endTime,
      raw,
      from: line.from + startOffset,
      to: line.from + endOffset,
      line: line.lineNo,
    });
    resetIfStalled(pattern, match);
  }
}

export function scanMarkdownTimestamps(doc: CMText | string): Nv3MarkdownTimestampOccurrence[] {
  const source = typeof doc === "string" ? Text.of(doc.split(/\r?\n/)) : doc;
  const context = createMarkdownScannerContext(source);
  const occurrences: Nv3MarkdownTimestampOccurrence[] = [];

  for (const line of context.lines) {
    if (!isMarkdownLineScannable(line)) continue;
    scanTimestampPattern(line, INACTIVE_TIMESTAMP_PATTERN, "inactive", occurrences);
    scanTimestampPattern(line, ACTIVE_TIMESTAMP_PATTERN, "active", occurrences);
  }

  occurrences.sort((a, b) => a.from - b.from);
  return occurrences;
}

function scanOrgTimestamps(doc: CMText | string): Nv3MarkdownTimestampOccurrence[] {
  const source = typeof doc === "string" ? Text.of(doc.split(/\r?\n/)) : doc;
  const parsed = parseOrgText(source);
  return parsed.timestamps.map((timestamp) => ({
    kind: timestamp.kind,
    syntax: "org",
    isoDate: timestamp.date,
    weekday: timestamp.day,
    startTime: timestamp.time,
    endTime: timestamp.endTime,
    raw: timestamp.raw,
    from: timestamp.from,
    to: timestamp.to,
    line: timestamp.line,
  }));
}

function scanTimestamps(
  doc: CMText | string,
  syntax: "markdown" | "org",
): Nv3MarkdownTimestampOccurrence[] {
  return syntax === "org" ? scanOrgTimestamps(doc) : scanMarkdownTimestamps(doc);
}

// ── Timestamp editing ─────────────────────────────────────────────────────

const pendingPickerTokenByView = new WeakMap<EditorView, number>();

function commitTimestampEdit(
  view: EditorView,
  occ: Nv3MarkdownTimestampOccurrence,
  selection: Nv3DatePickerSelection,
): void {
  const nextRaw = formatTimestamp({
    kind: occ.kind,
    syntax: occ.syntax,
    isoDate: selection.isoDate,
    startTime: selection.startTime,
    endTime: selection.endTime,
  });
  if (nextRaw === occ.raw) { focusEditorWithoutScroll(view); return; }
  view.dispatch({ changes: { from: occ.from, to: occ.to, insert: nextRaw } });
}

function openTimestampPicker(view: EditorView, occ: Nv3MarkdownTimestampOccurrence): boolean {
  if (isEditorReadOnly(view.state)) return false;
  const { pickDate } = view.state.facet(markdownDatesOptionsFacet);
  if (!pickDate) return false;

  const nextToken = (pendingPickerTokenByView.get(view) ?? 0) + 1;
  pendingPickerTokenByView.set(view, nextToken);

  void (async () => {
    try {
      const picked = await pickDate({
        kind: occ.kind,
        isoDate: occ.isoDate,
        weekday: occ.weekday,
        startTime: occ.startTime,
        endTime: occ.endTime,
        raw: occ.raw,
      });
      if (pendingPickerTokenByView.get(view) !== nextToken) return;
      pendingPickerTokenByView.delete(view);
      if (picked && isValidISODate(picked.isoDate)) commitTimestampEdit(view, occ, picked);
    } catch (error) {
      if (pendingPickerTokenByView.get(view) === nextToken) pendingPickerTokenByView.delete(view);
      console.error("[nv3 dates] native date picker failed", error);
    } finally {
      focusEditorWithoutScroll(view);
    }
  })();

  return true;
}

function resolveTimestampFromTarget(target: EventTarget | null, state: EditorState): Nv3MarkdownTimestampOccurrence | null {
  const element = resolveEventElement(target);
  if (!element) return null;
  const timestamp = element.closest(".nv3-timestamp[data-nv3-timestamp='true']");
  if (!(timestamp instanceof HTMLElement)) return null;

  const from = Number(timestamp.dataset.nv3TimestampFrom ?? NaN);
  const to = Number(timestamp.dataset.nv3TimestampTo ?? NaN);
  if (!Number.isFinite(from) || !Number.isFinite(to)) return null;

  const parsed = parseTimestampLiteral(state.doc.sliceString(from, to));
  if (!parsed) return null;
  const syntax = state.facet(markdownDatesOptionsFacet).syntax ?? "markdown";
  return { ...parsed, syntax, from, to, line: state.doc.lineAt(from).number };
}

function insertTimestampAtMainSelection(
  view: EditorView,
  isoDate = todayISODateLocal(),
  startTime: string | null = null,
  endTime: string | null = null,
): Nv3MarkdownTimestampOccurrence | null {
  const syntax = view.state.facet(markdownDatesOptionsFacet).syntax ?? "markdown";
  const kind: TimestampKind = syntax === "org" ? "active" : "inactive";
  const range = view.state.selection.main;
  const raw = formatTimestamp({ kind, syntax, isoDate, startTime, endTime });
  const cursorAfter = range.from + raw.length;
  view.dispatch({
    changes: { from: range.from, to: range.to, insert: raw },
    selection: { anchor: cursorAfter },
  });

  return {
    kind, syntax, isoDate,
    weekday: weekdayForISODate(isoDate) ?? "",
    startTime,
    endTime,
    raw,
    from: range.from,
    to: range.from + raw.length,
    line: view.state.doc.lineAt(Math.min(range.from, view.state.doc.length)).number,
  };
}

// ── Public commands ───────────────────────────────────────────────────────

export function adjustMarkdownTimestampsByDays(view: EditorView, deltaDays: number): boolean {
  const transaction = buildShiftMarkdownTimestampsTransaction(view.state, deltaDays);
  if (!transaction) return false;
  view.dispatch(transaction);
  return true;
}

export function buildShiftMarkdownTimestampsTransaction(
  state: EditorState,
  deltaDays: number,
): TransactionSpec | null {
  if (isEditorReadOnly(state)) return null;

  const syntax = state.facet(markdownDatesOptionsFacet).syntax ?? "markdown";
  const touched = collectTouchedTimestamps(scanTimestamps(state.doc, syntax), state.selection.ranges);
  if (!touched.length) return null;

  const seen = new Set<string>();
  const changes: Array<{ from: number; to: number; insert: string }> = [];

  for (const occ of touched) {
    const key = `${occ.from}:${occ.to}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const next = shiftISODate(occ.isoDate, deltaDays);
    if (next) {
      changes.push({
        from: occ.from,
        to: occ.to,
        insert: formatTimestamp({
          kind: occ.kind,
          syntax: occ.syntax,
          isoDate: next,
          startTime: occ.startTime,
          endTime: occ.endTime,
        }),
      });
    }
  }

  return changes.length ? { changes } : null;
}

/** @deprecated Use `formatTimestamp` from `dateUtils.ts` */
export const formatMarkdownTimestamp = formatTimestamp;

/** @deprecated Use `parseTimestampLiteral` from `dateUtils.ts` */
export const parseMarkdownTimestamp = parseTimestampLiteral;

export function openOrInsertMarkdownTimestamp(view: EditorView): boolean {
  return insertOrReplaceTodayMarkdownTimestamp(view, { openPicker: true });
}

function insertOrReplaceTodayMarkdownTimestamp(view: EditorView, options: { openPicker: boolean }): boolean {
  if (isEditorReadOnly(view.state)) return false;

  const isoDate = todayISODateLocal();
  const syntax = view.state.facet(markdownDatesOptionsFacet).syntax ?? "markdown";
  const existing = firstTimestampTouchingRange(scanTimestamps(view.state.doc, syntax), view.state.selection.main);

  if (existing) {
    const selection = {
      isoDate,
      startTime: existing.startTime,
      endTime: existing.endTime,
    };
    commitTimestampEdit(view, existing, selection);
    if (options.openPicker) {
      const raw = formatTimestamp({ kind: existing.kind, syntax, ...selection });
      return openTimestampPicker(view, {
        ...existing,
        ...selection,
        isoDate,
        weekday: weekdayForISODate(isoDate) ?? existing.weekday,
        raw,
        to: existing.from + raw.length,
      });
    }
    focusEditorWithoutScroll(view);
    return true;
  }

  const inserted = insertTimestampAtMainSelection(view, isoDate);
  if (!inserted) return false;
  if (options.openPicker) return openTimestampPicker(view, inserted);
  focusEditorWithoutScroll(view);
  return true;
}

function insertCurrentDateTime(view: EditorView): boolean {
  if (isEditorReadOnly(view.state)) return false;
  const inserted = insertTimestampAtMainSelection(
    view,
    todayISODateLocal(),
    currentTimeLocal(),
  );
  if (!inserted) return false;
  focusEditorWithoutScroll(view);
  return true;
}

// ── Leader key + ViewPlugin ───────────────────────────────────────────────

const markdownDatesViewPlugin: ViewPlugin<{
  decorations: DecorationSet;
  handleKeyDown(event: KeyboardEvent): boolean;
}> = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    private leaderActive = false;
    private leaderTimer: number | null = null;
    private leaderOverlay: HTMLDivElement;

    constructor(readonly view: EditorView) {
      const syntax = view.state.facet(markdownDatesOptionsFacet).syntax ?? "markdown";
      this.decorations = buildTimestampDecorations(scanTimestamps(view.state.doc, syntax));
      this.leaderOverlay = this.createLeaderOverlay();
      this.syncLeaderOverlay();
    }

    update(update: ViewUpdate) {
      if (update.docChanged) {
        const syntax = update.state.facet(markdownDatesOptionsFacet).syntax ?? "markdown";
        this.decorations = buildTimestampDecorations(scanTimestamps(update.state.doc, syntax));
      }
    }

    destroy() {
      this.clearLeader();
      this.leaderOverlay.remove();
      pendingPickerTokenByView.delete(this.view);
    }

    handleKeyDown(event: KeyboardEvent): boolean {
      if (this.matchesLeaderKey(event)) { this.armLeader(); event.preventDefault(); return true; }

      if (event.metaKey && event.altKey && !event.ctrlKey && !event.shiftKey) {
        if (event.key === "ArrowLeft") {
          const handled = adjustMarkdownTimestampsByDays(this.view, -1);
          if (handled) { this.clearLeader(); event.preventDefault(); }
          return handled;
        }
        if (event.key === "ArrowRight") {
          const handled = adjustMarkdownTimestampsByDays(this.view, 1);
          if (handled) { this.clearLeader(); event.preventDefault(); }
          return handled;
        }
      }

      if (!this.leaderActive) return false;
      if (["Meta", "Alt", "Control", "Shift"].includes(event.key)) return false;

      this.clearLeader();

      if (!event.metaKey && !event.altKey && !event.ctrlKey) {
        if (event.key === ".") { event.preventDefault(); return insertOrReplaceTodayMarkdownTimestamp(this.view, { openPicker: false }); }
        if (event.key === "'" || event.code === "Quote") { event.preventDefault(); return insertCurrentDateTime(this.view); }
        if (event.key.toLowerCase() === "d") { event.preventDefault(); return insertOrReplaceTodayMarkdownTimestamp(this.view, { openPicker: true }); }
        if (event.key.toLowerCase() === "r") { event.preventDefault(); return insertBlockReference(this.view); }
      }

      if (event.key === "Escape") { event.preventDefault(); return true; }
      return false;
    }

    private matchesLeaderKey(event: KeyboardEvent): boolean {
      return event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey && event.code === "Semicolon";
    }

    private armLeader(): void {
      this.clearLeader();
      this.leaderActive = true;
      this.syncLeaderOverlay();
      this.leaderTimer = window.setTimeout(() => { this.leaderActive = false; this.leaderTimer = null; this.syncLeaderOverlay(); }, LEADER_TIMEOUT_MS);
    }

    private clearLeader(): void {
      this.leaderActive = false;
      if (this.leaderTimer != null) { window.clearTimeout(this.leaderTimer); this.leaderTimer = null; }
      this.syncLeaderOverlay();
    }

    private createLeaderOverlay(): HTMLDivElement {
      const overlay = document.createElement("div");
      overlay.className = "nv3-leader-overlay";
      overlay.setAttribute("aria-hidden", "true");
      overlay.innerHTML = [
        '<div class="nv3-leader-overlay-title">⌘; shortcuts</div>',
        '<div class="nv3-leader-overlay-list">',
        '<div class="nv3-leader-overlay-item"><kbd>.</kbd><span>Insert today</span></div>',
        '<div class="nv3-leader-overlay-item"><kbd>\'</kbd><span>Insert current date + time</span></div>',
        '<div class="nv3-leader-overlay-item"><kbd>D</kbd><span>Insert today + calendar</span></div>',
        '<div class="nv3-leader-overlay-item"><kbd>R</kbd><span>Insert block ref</span></div>',
        '</div>',
      ].join("");
      document.body.appendChild(overlay);
      return overlay;
    }

    private syncLeaderOverlay(): void {
      this.leaderOverlay.setAttribute("data-nv3-open", this.leaderActive ? "true" : "false");
    }
  },
  {
    decorations: (v) => v.decorations,
    eventHandlers: {
      mousedown(event, view) {
        if (isEditorReadOnly(view.state)) return;
        const occ = resolveTimestampFromTarget(event.target, view.state);
        if (!occ || !view.dom.contains(resolveEventElement(event.target))) return;
        event.preventDefault();
        return true;
      },
      click(event, view) {
        const element = resolveEventElement(event.target);
        if (!element || !view.dom.contains(element)) return;
        const occ = resolveTimestampFromTarget(event.target, view.state);
        if (!occ || isEditorReadOnly(view.state)) return;
        event.preventDefault();
        return openTimestampPicker(view, occ);
      },
      keydown(event, view): boolean {
        return view.plugin(markdownDatesViewPlugin)?.handleKeyDown(event) ?? false;
      },
    },
  },
);

export function createMarkdownDatesExtension(options: MarkdownDatesExtensionOptions = {}): Extension {
  return [markdownDatesOptionsFacet.of(options), markdownDatesViewPlugin];
}
