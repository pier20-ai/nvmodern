import {
  StateEffect,
  StateField,
  type EditorState,
  type Extension,
  type Text,
  type TransactionSpec,
} from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { createNv3AnnotationMarginNotes, type Nv3MarginNoteItem } from "./annotationMarginNotes.ts";
import { createNv3AnnotationWidgetMarks, type Nv3WidgetMarkItem } from "./annotationWidgetMarks.ts";
import { createNv3AnnotationComposer, editNv3AnnotationInComposer } from "./annotationComposer.ts";
import { nv3AnnotationStart } from "./annotationRanges.ts";

export { nv3AnnotationStart };

// Annotations are a visual layer over the document: labelled marks that an
// agent (or the user) places to point at passages while discussing them
// elsewhere. They never touch the document text or undo history. Each one is
// anchored by quoting its text, so it survives edits around it and can be
// re-found after the document is replaced wholesale.

export type Nv3AnnotationStyle = "highlight" | "underline" | "box";
export type Nv3AnnotationColor = "yellow" | "blue" | "green" | "pink" | "purple" | "orange" | "red";
export type Nv3AnnotationAuthor = "agent" | "user";

export const NV3_ANNOTATION_STYLES: readonly Nv3AnnotationStyle[] = ["highlight", "underline", "box"];
export const NV3_ANNOTATION_COLORS: readonly Nv3AnnotationColor[] = [
  "yellow",
  "blue",
  "green",
  "pink",
  "purple",
  "orange",
  "red",
];

export interface Nv3AnnotationAnchor {
  /** Exact text to mark. Whitespace differences (line wrapping) are tolerated. */
  quote: string;
  /** Text expected just before the quote, used to pick among repeats. */
  prefix?: string;
  /** Text expected just after the quote, used to pick among repeats. */
  suffix?: string;
  /** 1-based occurrence to use when the quote repeats. */
  occurrence?: number;
}

export interface Nv3AnnotationSpec extends Nv3AnnotationAnchor {
  id: string;
  label: string;
  style: Nv3AnnotationStyle;
  color: Nv3AnnotationColor;
  /** The explanation (agent) or question (user) shown beside the passage. */
  note?: string;
  author: Nv3AnnotationAuthor;
  /** A reply to the note, e.g. the agent answering a user's question. */
  answer?: string;
  /** Who wrote the answer, shown with it. */
  answeredBy?: string;
  /** The note changed after it was answered, so the answer may no longer fit. */
  answerStale?: boolean;
}

export interface Nv3AnnotationInput extends Nv3AnnotationAnchor {
  id?: string;
  label?: string;
  style?: Nv3AnnotationStyle;
  color?: Nv3AnnotationColor;
  note?: string;
  author?: Nv3AnnotationAuthor;
  answer?: string;
  answeredBy?: string;
  answerStale?: boolean;
}

export interface Nv3AnnotationMatch {
  from: number;
  to: number;
  /** Number of places the quote was found before disambiguation. */
  candidates: number;
}

export type Nv3AnnotationAddStatus = "anchored" | "ambiguous" | "notFound" | "invalid";

export interface Nv3AnnotationAddResult {
  id: string | null;
  label: string | null;
  status: Nv3AnnotationAddStatus;
  line?: number;
  endLine?: number;
  candidates?: number;
  message?: string;
}

export interface Nv3AnnotationSnapshot {
  id: string;
  label: string;
  style: Nv3AnnotationStyle;
  color: Nv3AnnotationColor;
  author: Nv3AnnotationAuthor;
  note?: string;
  answer?: string;
  answeredBy?: string;
  answerStale?: boolean;
  quote: string;
  /** Current document text under the mark; differs from quote after edits. */
  text: string | null;
  line: number | null;
  endLine: number | null;
  detached: boolean;
}

export interface Nv3AnnotationRemoveFilter {
  ids?: string[];
  labels?: string[];
  author?: Nv3AnnotationAuthor;
}

interface PlacedAnnotation {
  spec: Nv3AnnotationSpec;
  /** -1 when the anchored text was deleted and could not be re-found. */
  from: number;
  to: number;
}

interface AnnotationState {
  items: PlacedAnnotation[];
  focusedId: string | null;
}

// ── Anchoring ─────────────────────────────────────────────────────────

interface NormalizedText {
  text: string;
  /** Original index of each normalized character. */
  map: number[];
}

function normalizeWhitespace(source: string): NormalizedText {
  let text = "";
  const map: number[] = [];
  let pendingSpace = -1;
  for (let index = 0; index < source.length; index += 1) {
    const char = source.charAt(index);
    if (/\s/.test(char)) {
      if (pendingSpace === -1) pendingSpace = index;
      continue;
    }
    if (pendingSpace !== -1) {
      if (text.length > 0) {
        text += " ";
        map.push(pendingSpace);
      }
      pendingSpace = -1;
    }
    text += char;
    map.push(index);
  }
  return { text, map };
}

function collapseWhitespace(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function findAll(haystack: string, needle: string): number[] {
  const positions: number[] = [];
  if (!needle) return positions;
  let index = haystack.indexOf(needle);
  while (index !== -1) {
    positions.push(index);
    index = haystack.indexOf(needle, index + 1);
  }
  return positions;
}

function contextScore(docText: string, from: number, to: number, anchor: Nv3AnnotationAnchor): number {
  let score = 0;
  const prefix = anchor.prefix ? collapseWhitespace(anchor.prefix) : "";
  const suffix = anchor.suffix ? collapseWhitespace(anchor.suffix) : "";
  if (prefix) {
    const before = collapseWhitespace(docText.slice(Math.max(0, from - prefix.length * 2 - 16), from));
    if (before.endsWith(prefix)) score += 2;
    else if (before.endsWith(prefix.slice(-Math.min(prefix.length, 12)))) score += 1;
  }
  if (suffix) {
    const after = collapseWhitespace(docText.slice(to, to + suffix.length * 2 + 16));
    if (after.startsWith(suffix)) score += 2;
    else if (after.startsWith(suffix.slice(0, Math.min(suffix.length, 12)))) score += 1;
  }
  return score;
}

/**
 * Locate a quote in document text. Exact matches win; otherwise whitespace is
 * collapsed on both sides so quotes copied across wrapped lines still anchor.
 */
export function findNv3AnnotationAnchor(docText: string, anchor: Nv3AnnotationAnchor): Nv3AnnotationMatch | null {
  const quote = anchor.quote ?? "";
  if (!quote.trim()) return null;

  let ranges: Array<{ from: number; to: number }> = findAll(docText, quote).map((from) => ({
    from,
    to: from + quote.length,
  }));

  if (ranges.length === 0) {
    const normalizedQuote = collapseWhitespace(quote);
    const normalizedDoc = normalizeWhitespace(docText);
    ranges = findAll(normalizedDoc.text, normalizedQuote).map((start) => ({
      from: normalizedDoc.map[start] ?? 0,
      to: (normalizedDoc.map[start + normalizedQuote.length - 1] ?? 0) + 1,
    }));
  }

  const first = ranges[0];
  if (!first) return null;

  const candidates = ranges.length;
  const requested = anchor.occurrence ? ranges[anchor.occurrence - 1] : undefined;
  if (requested) {
    return { ...requested, candidates };
  }

  if (candidates > 1 && (anchor.prefix || anchor.suffix)) {
    let best = first;
    let bestScore = -1;
    for (const range of ranges) {
      const score = contextScore(docText, range.from, range.to, anchor);
      if (score > bestScore) {
        best = range;
        bestScore = score;
      }
    }
    return { ...best, candidates };
  }

  return { ...first, candidates };
}

function anchorIsDisambiguated(anchor: Nv3AnnotationAnchor): boolean {
  return Boolean(anchor.occurrence || anchor.prefix || anchor.suffix);
}

// ── State ─────────────────────────────────────────────────────────────

const setAnnotationsEffect = StateEffect.define<PlacedAnnotation[]>();
const focusAnnotationEffect = StateEffect.define<string | null>();

function placeSpec(doc: Text, spec: Nv3AnnotationSpec): PlacedAnnotation {
  const match = findNv3AnnotationAnchor(doc.toString(), spec);
  return match
    ? { spec, from: nv3AnnotationStart(doc, match.from, match.to), to: match.to }
    : { spec, from: -1, to: -1 };
}

const annotationField = StateField.define<AnnotationState>({
  create: () => ({ items: [], focusedId: null }),
  update(value, transaction) {
    let next = value;

    if (transaction.docChanged && value.items.length > 0) {
      const changes = transaction.changes;
      const items = value.items.map((item) => {
        if (item.from < 0) return placeSpec(transaction.newDoc, item.spec);
        const from = changes.mapPos(item.from, 1);
        const to = changes.mapPos(item.to, -1);
        if (to > from) return { ...item, from, to };
        return placeSpec(transaction.newDoc, item.spec);
      });
      next = { ...next, items };
    }

    for (const effect of transaction.effects) {
      if (effect.is(setAnnotationsEffect)) {
        next = { ...next, items: effect.value };
        if (next.focusedId && !effect.value.some((item) => item.spec.id === next.focusedId)) {
          next = { ...next, focusedId: null };
        }
      } else if (effect.is(focusAnnotationEffect)) {
        next = { ...next, focusedId: effect.value };
      }
    }

    return next;
  },
  provide: (field) => EditorView.decorations.from(field, buildDecorations),
});

class AnnotationBadgeWidget extends WidgetType {
  constructor(
    readonly id: string,
    readonly label: string,
    readonly color: Nv3AnnotationColor,
    readonly author: Nv3AnnotationAuthor,
    readonly note: string | undefined,
  ) {
    super();
  }

  override eq(other: AnnotationBadgeWidget): boolean {
    return (
      other.id === this.id &&
      other.label === this.label &&
      other.color === this.color &&
      other.author === this.author &&
      other.note === this.note
    );
  }

  toDOM(): HTMLElement {
    const badge = document.createElement("span");
    badge.className = `nv3-annotation-badge nv3-annotation-badge-${this.author}`;
    badge.dataset.nv3AnnotationColor = this.color;
    badge.dataset.nv3AnnotationId = this.id;
    badge.textContent = this.label;
    badge.setAttribute("aria-label", this.note ? `Annotation ${this.label}: ${this.note}` : `Annotation ${this.label}`);
    return badge;
  }

  override ignoreEvent(): boolean {
    return false;
  }
}

function buildDecorations(state: AnnotationState): DecorationSet {
  const ranges = [];
  for (const item of state.items) {
    if (item.from < 0 || item.to <= item.from) continue;
    const { spec } = item;
    const focused = state.focusedId === spec.id;
    const attributes: Record<string, string> = {
      "data-nv3-annotation-color": spec.color,
      "data-nv3-annotation-label": spec.label,
      "data-nv3-annotation-ids": spec.id,
    };
    ranges.push(
      Decoration.widget({
        widget: new AnnotationBadgeWidget(spec.id, spec.label, spec.color, spec.author, spec.note),
        side: -1,
      }).range(item.from),
    );
    ranges.push(
      Decoration.mark({
        class: `nv3-annotation nv3-annotation-${spec.style}${focused ? " nv3-annotation-focused" : ""}`,
        attributes,
      }).range(item.from, item.to),
    );
  }
  return Decoration.set(ranges, true);
}

function marginNotes(state: EditorState): Nv3MarginNoteItem[] {
  const notes: Nv3MarginNoteItem[] = [];
  for (const { spec, from, to } of currentItems(state)) {
    if (from < 0 || !(spec.note?.trim() || spec.answer?.trim())) continue;
    notes.push({
      id: spec.id,
      label: spec.label,
      color: spec.color,
      author: spec.author,
      note: spec.note ?? "",
      ...(spec.answer ? { answer: spec.answer } : {}),
      ...(spec.answeredBy ? { answeredBy: spec.answeredBy } : {}),
      ...(spec.answerStale ? { answerStale: true } : {}),
      editable: spec.author === "user",
      from,
      to,
    });
  }
  return notes;
}

function widgetMarks(state: EditorState): Nv3WidgetMarkItem[] {
  return currentItems(state)
    .filter((item) => item.from >= 0)
    .map(({ spec, from, to }) => ({
      id: spec.id,
      label: spec.label,
      color: spec.color,
      author: spec.author,
      style: spec.style,
      from,
      to,
    }));
}

export function createNv3AnnotationsExtension(): Extension {
  const key = (state: EditorState) => state.field(annotationField, false);
  const focusedId = (state: EditorState) => state.field(annotationField, false)?.focusedId ?? null;
  const notes = createNv3AnnotationMarginNotes({
    key,
    notes: marginNotes,
    focusedId,
    setFocus: (view, id) => view.dispatch({ effects: focusAnnotationEffect.of(id) }),
    remove: (view, id) => {
      removeNv3Annotations(view, { ids: [id] });
    },
    edit: (view, id) => {
      const item = currentItems(view.state).find((candidate) => candidate.spec.id === id);
      if (!item || item.from < 0) return;
      editNv3AnnotationInComposer(view, { id, from: item.from, to: item.to, note: item.spec.note ?? "" });
    },
  });
  return [
    annotationField,
    notes.extension,
    createNv3AnnotationWidgetMarks({ key, items: widgetMarks, focusedId, onApplied: notes.remeasure }),
    createNv3AnnotationComposer({
      save: (view, from, to, text) => {
        addNv3AnnotationAt(view, from, to, { author: "user", ...(text ? { note: text } : {}) });
      },
      edit: (view, id, text) => {
        editNv3AnnotationNote(view, id, text);
      },
      editableAt: (state, pos) => {
        // The innermost of the reader's marks around the caret.
        const found = currentItems(state)
          .filter((item) => item.spec.author === "user" && item.from >= 0 && item.from <= pos && pos <= item.to)
          .sort((left, right) => left.to - left.from - (right.to - right.from))[0];
        return found ? { id: found.spec.id, from: found.from, to: found.to, note: found.spec.note ?? "" } : null;
      },
    }),
  ];
}

// ── Commands ──────────────────────────────────────────────────────────

/** Anything holding editor state that can apply a transaction; an `EditorView` qualifies. */
export interface Nv3AnnotationTarget {
  readonly state: EditorState;
  dispatch(spec: TransactionSpec): void;
}

function currentItems(state: EditorState): PlacedAnnotation[] {
  return state.field(annotationField, false)?.items ?? [];
}

function nextNumericLabel(
  items: PlacedAnnotation[],
  author: Nv3AnnotationAuthor,
  assigned: readonly string[],
): string {
  let highest = 0;
  const labels = items.filter((item) => item.spec.author === author).map((item) => item.spec.label);
  for (const label of [...labels, ...assigned]) {
    const numeric = Number.parseInt(label.replace(/^Q/, ""), 10);
    if (Number.isFinite(numeric)) highest = Math.max(highest, numeric);
  }
  const next = String(highest + 1);
  return author === "user" ? `Q${next}` : next;
}

function defaultColor(label: string, fallbackIndex: number): Nv3AnnotationColor {
  const numeric = Number.parseInt(label.replace(/^\D+/, ""), 10);
  const index = Number.isFinite(numeric) && numeric > 0 ? numeric - 1 : fallbackIndex;
  return NV3_ANNOTATION_COLORS[index % NV3_ANNOTATION_COLORS.length] ?? "yellow";
}

function lineNumber(doc: Text, position: number): number {
  return doc.lineAt(Math.max(0, Math.min(position, doc.length))).number;
}

function buildSpec(
  input: Nv3AnnotationInput,
  items: PlacedAnnotation[],
  assignedLabels: readonly string[],
  index: number,
): Nv3AnnotationSpec {
  const author: Nv3AnnotationAuthor = input.author === "user" ? "user" : "agent";
  // Callers sometimes send numeric labels; treat them as text.
  const label = String(input.label ?? "").trim() || nextNumericLabel(items, author, assignedLabels);
  const style = NV3_ANNOTATION_STYLES.includes(input.style as Nv3AnnotationStyle)
    ? (input.style as Nv3AnnotationStyle)
    : "highlight";
  const color = NV3_ANNOTATION_COLORS.includes(input.color as Nv3AnnotationColor)
    ? (input.color as Nv3AnnotationColor)
    : defaultColor(label, index);
  return {
    id: String(input.id ?? "").trim() || `${author}:${label}`,
    label,
    style,
    color,
    author,
    quote: input.quote,
    ...(input.prefix ? { prefix: input.prefix } : {}),
    ...(input.suffix ? { suffix: input.suffix } : {}),
    ...(input.occurrence ? { occurrence: input.occurrence } : {}),
    ...(input.note ? { note: input.note } : {}),
    ...(input.answer ? { answer: input.answer } : {}),
    ...(input.answeredBy ? { answeredBy: input.answeredBy } : {}),
    ...(input.answerStale ? { answerStale: true } : {}),
  };
}

const ANCHOR_CONTEXT_CHARS = 32;

/**
 * Annotate an exact range, such as the user's selection. The quote and its
 * surrounding text are recorded so the mark can be re-found later.
 */
export function addNv3AnnotationAt(
  view: Nv3AnnotationTarget,
  from: number,
  to: number,
  input: Omit<Nv3AnnotationInput, "quote" | "prefix" | "suffix" | "occurrence">,
): Nv3AnnotationAddResult {
  const doc = view.state.doc;
  if (from >= to || to > doc.length) return { id: null, label: null, status: "invalid", message: "empty range" };
  from = nv3AnnotationStart(doc, from, to);
  const items = currentItems(view.state);
  const spec = buildSpec(
    {
      ...input,
      quote: doc.sliceString(from, to),
      prefix: doc.sliceString(Math.max(0, from - ANCHOR_CONTEXT_CHARS), from),
      suffix: doc.sliceString(to, Math.min(doc.length, to + ANCHOR_CONTEXT_CHARS)),
    },
    items,
    [],
    items.length,
  );
  const next = items.filter((item) => item.spec.id !== spec.id).concat({ spec, from, to });
  next.sort((left, right) => left.from - right.from);
  view.dispatch({ effects: setAnnotationsEffect.of(next) });
  return {
    id: spec.id,
    label: spec.label,
    status: "anchored",
    line: lineNumber(doc, from),
    endLine: lineNumber(doc, to),
    candidates: 1,
  };
}

/** Attach an answer to an annotation (by id or label); an empty answer clears it. */
export function answerNv3Annotation(
  view: Nv3AnnotationTarget,
  idOrLabel: string,
  answer: string,
  answeredBy?: string,
): boolean {
  const items = currentItems(view.state);
  const target =
    items.find((item) => item.spec.id === idOrLabel) ?? items.find((item) => item.spec.label === idOrLabel);
  if (!target) return false;
  const { answer: _previous, answeredBy: _previousBy, answerStale: _stale, ...rest } = target.spec;
  const spec: Nv3AnnotationSpec = answer.trim()
    ? { ...rest, answer, ...(answeredBy ? { answeredBy } : {}) }
    : rest;
  view.dispatch({ effects: setAnnotationsEffect.of(items.map((item) => (item === target ? { ...item, spec } : item))) });
  return true;
}

/**
 * Change an annotation's note (by id or label); empty text removes it. If the
 * note had been answered, the answer is kept but marked stale, since it was
 * written for the earlier wording.
 */
export function editNv3AnnotationNote(view: Nv3AnnotationTarget, idOrLabel: string, note: string): boolean {
  const items = currentItems(view.state);
  const target =
    items.find((item) => item.spec.id === idOrLabel) ?? items.find((item) => item.spec.label === idOrLabel);
  if (!target) return false;
  const text = note.trim();
  if (text === (target.spec.note ?? "").trim()) return true;
  const { note: _previous, ...rest } = target.spec;
  const spec: Nv3AnnotationSpec = {
    ...rest,
    ...(text ? { note: text } : {}),
    ...(rest.answer ? { answerStale: true } : {}),
  };
  view.dispatch({ effects: setAnnotationsEffect.of(items.map((item) => (item === target ? { ...item, spec } : item))) });
  return true;
}

/** Whether a transaction changed the annotations themselves (not just focus). */
export function nv3AnnotationsChanged(startState: EditorState, state: EditorState): boolean {
  const before = startState.field(annotationField, false);
  const after = state.field(annotationField, false);
  return before?.items !== after?.items;
}

/**
 * Add annotations, replacing any with the same id. `replace` first removes
 * every existing annotation by that author (all authors when `true`).
 */
export function addNv3Annotations(
  view: Nv3AnnotationTarget,
  inputs: Nv3AnnotationInput[],
  options: {
    replace?: boolean | Nv3AnnotationAuthor;
    /**
     * Keep annotations whose quote isn't in the document, detached, instead of
     * dropping them. Restoring saved annotations must not lose any just
     * because the text changed while the note was closed; a detached one
     * re-attaches if its text returns.
     */
    keepUnanchored?: boolean;
  } = {},
): Nv3AnnotationAddResult[] {
  const doc = view.state.doc;
  const docText = doc.toString();
  let items = currentItems(view.state);
  if (options.replace === true) {
    items = [];
  } else if (options.replace) {
    items = items.filter((item) => item.spec.author !== options.replace);
  }

  const results: Nv3AnnotationAddResult[] = [];
  // Labels already handed out in this call, including to quotes that failed
  // to anchor, so numbering follows the caller's order.
  const assignedLabels: string[] = [];
  inputs.forEach((input, index) => {
    if (!input || typeof input.quote !== "string" || !input.quote.trim()) {
      results.push({ id: input?.id ?? null, label: input?.label ?? null, status: "invalid", message: "quote is required" });
      return;
    }

    const spec = buildSpec(input, items, assignedLabels, index);
    const { id, label } = spec;
    assignedLabels.push(label);

    const match = findNv3AnnotationAnchor(docText, spec);
    items = items.filter((item) => item.spec.id !== id);
    if (!match) {
      if (options.keepUnanchored) items.push({ spec, from: -1, to: -1 });
      results.push({ id, label, status: "notFound", message: "quote not found in the document" });
      return;
    }

    items.push({ spec, from: nv3AnnotationStart(doc, match.from, match.to), to: match.to });
    const ambiguous = match.candidates > 1 && !anchorIsDisambiguated(spec);
    results.push({
      id,
      label,
      status: ambiguous ? "ambiguous" : "anchored",
      line: lineNumber(doc, match.from),
      endLine: lineNumber(doc, match.to),
      candidates: match.candidates,
      ...(ambiguous ? { message: "quote repeats; marked the first match. Pass prefix, suffix, or occurrence." } : {}),
    });
  });

  items.sort((left, right) => left.from - right.from);
  view.dispatch({ effects: setAnnotationsEffect.of(items) });
  return results;
}

/** Remove annotations matching every given filter; no filter removes all. */
export function removeNv3Annotations(view: Nv3AnnotationTarget, filter: Nv3AnnotationRemoveFilter = {}): number {
  const items = currentItems(view.state);
  const ids = filter.ids?.length ? new Set(filter.ids) : null;
  const labels = filter.labels?.length ? new Set(filter.labels) : null;
  const kept = items.filter((item) => {
    if (ids && !ids.has(item.spec.id)) return true;
    if (labels && !labels.has(item.spec.label)) return true;
    if (filter.author && item.spec.author !== filter.author) return true;
    return false;
  });
  const removed = items.length - kept.length;
  if (removed > 0) view.dispatch({ effects: setAnnotationsEffect.of(kept) });
  return removed;
}

export function listNv3Annotations(state: EditorState): Nv3AnnotationSnapshot[] {
  const doc = state.doc;
  return currentItems(state).map(({ spec, from, to }) => {
    const detached = from < 0;
    return {
      id: spec.id,
      label: spec.label,
      style: spec.style,
      color: spec.color,
      author: spec.author,
      ...(spec.note ? { note: spec.note } : {}),
      ...(spec.answer ? { answer: spec.answer } : {}),
      ...(spec.answeredBy ? { answeredBy: spec.answeredBy } : {}),
      ...(spec.answerStale ? { answerStale: true } : {}),
      quote: spec.quote,
      text: detached ? null : doc.sliceString(from, to),
      line: detached ? null : lineNumber(doc, from),
      endLine: detached ? null : lineNumber(doc, to),
      detached,
    };
  });
}

/** Specs for re-applying annotations to a fresh editor of the same document. */
export function nv3AnnotationSpecs(state: EditorState): Nv3AnnotationSpec[] {
  return currentItems(state).map((item) => item.spec);
}

/** Scroll an annotation (by id or label) to the middle of the view and emphasise it. */
export function revealNv3Annotation(view: Nv3AnnotationTarget, idOrLabel: string): boolean {
  const item =
    currentItems(view.state).find((candidate) => candidate.spec.id === idOrLabel) ??
    currentItems(view.state).find((candidate) => candidate.spec.label === idOrLabel);
  if (!item || item.from < 0) return false;
  view.dispatch({
    effects: [
      focusAnnotationEffect.of(item.spec.id),
      EditorView.scrollIntoView(item.from, { y: "center" }),
    ],
  });
  return true;
}
