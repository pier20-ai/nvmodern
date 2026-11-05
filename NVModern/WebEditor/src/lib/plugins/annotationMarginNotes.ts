import type { Extension, EditorState } from "@codemirror/state";
import { EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";

// Margin notes show each annotation's note beside the passage it explains.
// With room, they sit in the margins, aligned to their passage and stacked so
// they never overlap: on the right, or on the left when that side keeps a note
// closer to its passage. In a narrow editor there is no margin worth
// using, so only the focused annotation's note opens, as a card under its
// passage. The notes live in the scroller, outside the editable content.

export interface Nv3MarginNoteItem {
  id: string;
  label: string;
  color: string;
  author: string;
  note: string;
  answer?: string;
  answeredBy?: string;
  /** The note was edited after it was answered. */
  answerStale?: boolean;
  /** Offer an edit button (the reader's own notes). */
  editable?: boolean;
  from: number;
  to: number;
}

export interface Nv3MarginNotesSource {
  /** Changes identity whenever the notes or their positions may have changed. */
  key(state: EditorState): unknown;
  notes(state: EditorState): Nv3MarginNoteItem[];
  focusedId(state: EditorState): string | null;
  setFocus(view: EditorView, id: string | null): void;
  remove(view: EditorView, id: string): void;
  edit(view: EditorView, id: string): void;
}

export type Nv3MarginNotesMode = "margin" | "inline";

/** Below this scroller width the notes collapse to on-demand cards. */
export const NV3_MARGIN_NOTES_MIN_WIDTH = 820;

const NOTE_GAP = 8;

// ── Pure helpers ──────────────────────────────────────────────────────

function escapeHTML(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function renderInline(text: string): string {
  return text
    .split(/(`[^`\n]+`)/)
    .map((part, index) => {
      if (index % 2 === 1) return `<code>${escapeHTML(part.slice(1, -1))}</code>`;
      return escapeHTML(part)
        .replace(/\*\*([^*\n]+?)\*\*/g, "<strong>$1</strong>")
        .replace(/(^|[^*\w])\*([^*\s][^*\n]*?)\*(?![*\w])/g, "$1<em>$2</em>")
        .replace(/(^|[^_\w])_([^_\s][^_\n]*?)_(?![_\w])/g, "$1<em>$2</em>");
    })
    .join("");
}

/**
 * Render a note's light Markdown — paragraphs, `-` lists, **bold**, *italic*,
 * and `code` — to HTML. Everything else is escaped, so notes can't inject markup.
 */
export function renderNv3AnnotationNoteHTML(text: string): string {
  return text
    .trim()
    .split(/\n\s*\n/)
    .filter((block) => block.trim())
    .map((block) => {
      const lines = block.split("\n").map((line) => line.trim());
      if (lines.every((line) => /^[-*•]\s+/.test(line))) {
        const items = lines.map((line) => `<li>${renderInline(line.replace(/^[-*•]\s+/, ""))}</li>`);
        return `<ul>${items.join("")}</ul>`;
      }
      return `<p>${lines.map(renderInline).join("<br>")}</p>`;
    })
    .join("");
}

export type Nv3MarginSide = "left" | "right";

/**
 * Place notes (sorted by anchor top) so none overlaps another on its side.
 * Each goes right unless the left margin would keep it closer to its anchor.
 */
export function placeNv3MarginNotes(
  entries: ReadonlyArray<{ top: number; height: number }>,
  options: { twoSided: boolean; gap?: number },
): Array<{ top: number; side: Nv3MarginSide }> {
  const gap = options.gap ?? NOTE_GAP;
  const floors: Record<Nv3MarginSide, number> = {
    left: Number.NEGATIVE_INFINITY,
    right: Number.NEGATIVE_INFINITY,
  };
  return entries.map((entry) => {
    const right = Math.max(entry.top, floors.right);
    const left = Math.max(entry.top, floors.left);
    const side: Nv3MarginSide = options.twoSided && left < right ? "left" : "right";
    const top = side === "left" ? left : right;
    floors[side] = top + entry.height + gap;
    return { top, side };
  });
}

// ── View plugin ───────────────────────────────────────────────────────

interface NoteElement {
  dom: HTMLElement;
  body: HTMLElement;
  badge: HTMLElement;
  answer: HTMLElement;
  editButton: HTMLButtonElement;
  rendered: string;
}

interface MeasuredLayout {
  mode: Nv3MarginNotesMode | null;
  placements: Array<{
    id: string;
    top: number;
    left: number;
    width: number | null;
    visible: boolean;
    side: Nv3MarginSide | null;
  }>;
}

const MARGIN_GAP = 24;

/**
 * Boxes drawn for an annotation: its badge and marked text, inline or inside
 * widgets. Pieces inside hidden syntax (an inline-code backtick) have no box
 * and are skipped; their zero rect would pin a note to the top of the view.
 */
function annotationRects(view: EditorView, id: string): DOMRect[] {
  return annotationElements(view, id).flatMap((element) => Array.from(element.getClientRects()));
}

function annotationElements(view: EditorView, id: string): HTMLElement[] {
  const escaped = typeof CSS !== "undefined" && CSS.escape ? CSS.escape(id) : id.replace(/["\\]/g, "\\$&");
  return Array.from(
    view.contentDOM.querySelectorAll<HTMLElement>(
      `.nv3-annotation-badge[data-nv3-annotation-id="${escaped}"], [data-nv3-annotation-ids~="${escaped}"]`,
    ),
  );
}

function createMarginNotesPlugin(source: Nv3MarginNotesSource) {
  return ViewPlugin.fromClass(
    class {
      container: HTMLElement;
      elements = new Map<string, NoteElement>();
      mode: Nv3MarginNotesMode | null = null;
      frame = 0;
      resizeObserver: ResizeObserver | null = null;

      constructor(readonly view: EditorView) {
        // Text can move without CodeMirror reporting it (a widget re-laying
        // itself out); any change in the content's size re-places the notes.
        if (typeof ResizeObserver !== "undefined") {
          this.resizeObserver = new ResizeObserver(() => this.scheduleMeasure());
          this.resizeObserver.observe(view.contentDOM);
        }
        this.container = document.createElement("div");
        this.container.className = "nv3-annotation-notes";
        this.container.setAttribute("aria-label", "Annotation notes");
        this.container.addEventListener("mousedown", this.handleMouseDown);
        view.scrollDOM.appendChild(this.container);
        this.sync();
        this.scheduleMeasure();
      }

      update(update: ViewUpdate) {
        const notesChanged = source.key(update.startState) !== source.key(update.state);
        if (notesChanged) this.sync();
        if (notesChanged || update.geometryChanged || update.viewportChanged || update.heightChanged) {
          this.scheduleMeasure();
        }
      }

      destroy() {
        if (this.frame) cancelAnimationFrame(this.frame);
        this.resizeObserver?.disconnect();
        this.container.removeEventListener("mousedown", this.handleMouseDown);
        this.container.remove();
        delete this.view.scrollDOM.dataset.nv3MarginNotes;
      }

      handleMouseDown = (event: MouseEvent) => {
        const target = event.target instanceof Element ? event.target : null;
        const note = target?.closest<HTMLElement>(".nv3-annotation-note");
        const id = note?.dataset.nv3AnnotationId;
        if (!id) return;
        if (target?.closest(".nv3-annotation-note-remove")) {
          event.preventDefault();
          source.remove(this.view, id);
          return;
        }
        if (target?.closest(".nv3-annotation-note-edit")) {
          event.preventDefault();
          source.edit(this.view, id);
          return;
        }
        // Let people select and copy note text; only a plain click toggles focus.
        if (event.detail > 1) return;
        const focused = source.focusedId(this.view.state);
        source.setFocus(this.view, focused === id ? null : id);
      };

      sync() {
        const state = this.view.state;
        const notes = source.notes(state);
        const focused = source.focusedId(state);
        const seen = new Set<string>();

        for (const item of notes) {
          seen.add(item.id);
          let element = this.elements.get(item.id);
          if (!element) {
            const dom = document.createElement("aside");
            const badge = document.createElement("span");
            const body = document.createElement("div");
            body.className = "nv3-annotation-note-body";
            const answer = document.createElement("div");
            answer.className = "nv3-annotation-note-answer";
            const remove = document.createElement("button");
            remove.type = "button";
            remove.className = "nv3-annotation-note-remove";
            remove.textContent = "×";
            remove.title = "Remove";
            remove.setAttribute("aria-label", "Remove annotation");
            const editButton = document.createElement("button");
            editButton.type = "button";
            editButton.className = "nv3-annotation-note-edit";
            editButton.textContent = "✎";
            editButton.title = "Edit";
            editButton.setAttribute("aria-label", "Edit question");
            const actions = document.createElement("div");
            actions.className = "nv3-annotation-note-actions";
            actions.append(editButton, remove);
            dom.append(actions, badge, body, answer);
            this.container.appendChild(dom);
            element = { dom, body, badge, answer, editButton, rendered: "" };
            this.elements.set(item.id, element);
          }
          element.dom.className = `nv3-annotation-note nv3-annotation-note-${item.author}`;
          element.dom.classList.toggle("nv3-annotation-note-focused", focused === item.id);
          element.dom.dataset.nv3AnnotationId = item.id;
          element.dom.dataset.nv3AnnotationColor = item.color;
          element.editButton.hidden = !item.editable;
          element.answer.classList.toggle("nv3-annotation-note-answer-stale", Boolean(item.answerStale));
          element.badge.className = `nv3-annotation-badge nv3-annotation-badge-${item.author}`;
          element.badge.dataset.nv3AnnotationColor = item.color;
          element.badge.textContent = item.label;
          const rendered = JSON.stringify([item.note, item.answer ?? "", item.answeredBy ?? "", Boolean(item.answerStale)]);
          if (element.rendered !== rendered) {
            element.rendered = rendered;
            element.body.innerHTML = renderNv3AnnotationNoteHTML(item.note);
            element.body.hidden = !item.note.trim();
            element.answer.hidden = !item.answer?.trim();
            element.answer.innerHTML = item.answer?.trim()
              ? `<div class="nv3-annotation-note-answer-by"></div>${renderNv3AnnotationNoteHTML(item.answer)}`
              : "";
            const by = element.answer.querySelector(".nv3-annotation-note-answer-by");
            const author = item.answeredBy?.trim() || "Reply";
            if (by) by.textContent = item.answerStale ? `${author} · to an earlier version` : author;
          }
        }

        for (const [id, element] of this.elements) {
          if (seen.has(id)) continue;
          element.dom.remove();
          this.elements.delete(id);
        }
      }

      scheduleMeasure() {
        // Ask from a fresh frame. A request made while CodeMirror's measure
        // loop is running joins that loop, and if the loop gives up (it
        // restarts at most five times) the request is stranded until something
        // else measures, leaving notes where their text used to be.
        if (this.frame) return;
        this.frame = requestAnimationFrame(() => {
          this.frame = 0;
          this.view.requestMeasure({
            key: this,
            read: (view) => this.measure(view),
            write: (layout, view) => this.apply(layout, view),
          });
        });
      }

      measure(view: EditorView): MeasuredLayout {
        const notes = source.notes(view.state);
        if (notes.length === 0) return { mode: null, placements: [] };

        const scroller = view.scrollDOM;
        const mode: Nv3MarginNotesMode =
          scroller.clientWidth >= NV3_MARGIN_NOTES_MIN_WIDTH ? "margin" : "inline";
        const scrollRect = scroller.getBoundingClientRect();
        const contentRect = view.contentDOM.getBoundingClientRect();
        const toY = (clientY: number) => clientY - scrollRect.top - scroller.clientTop + scroller.scrollTop;
        const toX = (clientX: number) => clientX - scrollRect.left - scroller.clientLeft + scroller.scrollLeft;
        // Prefer what is actually drawn (inside a widget, positions only reach its edge).
        const anchorTop = (item: Nv3MarginNoteItem) => {
          const drawn = annotationRects(view, item.id).map((rect) => rect.top);
          if (drawn.length > 0) return Math.min(...drawn);
          return view.coordsAtPos(item.from, 1)?.top ?? view.documentTop + view.lineBlockAt(item.from).top;
        };
        const anchorBottom = (item: Nv3MarginNoteItem) => {
          const drawn = annotationRects(view, item.id).map((rect) => rect.bottom);
          if (drawn.length > 0) return Math.max(...drawn);
          return view.coordsAtPos(item.to, -1)?.bottom ?? view.documentTop + view.lineBlockAt(item.to).bottom;
        };

        if (mode === "inline") {
          const focused = source.focusedId(view.state);
          const inset = 8;
          return {
            mode,
            placements: notes.map((item) => ({
              id: item.id,
              top: toY(anchorBottom(item)) + 6,
              left: toX(contentRect.left) + inset,
              width: Math.max(160, contentRect.width - inset * 2),
              visible: item.id === focused,
              side: null,
            })),
          };
        }

        const noteWidth = this.elements.values().next().value?.dom.offsetWidth ?? 260;
        const rightLeft = toX(contentRect.right) + MARGIN_GAP;
        const leftLeft = toX(contentRect.left) - MARGIN_GAP - noteWidth;
        const twoSided = contentRect.left - scrollRect.left >= noteWidth + MARGIN_GAP * 2;
        const ordered = notes
          .map((item) => ({
            id: item.id,
            top: toY(anchorTop(item)),
            height: this.elements.get(item.id)?.dom.offsetHeight ?? 0,
          }))
          .sort((a, b) => a.top - b.top);
        const placed = placeNv3MarginNotes(ordered, { twoSided });
        return {
          mode,
          placements: ordered.map((entry, index) => {
            const placement = placed[index] ?? { top: entry.top, side: "right" as const };
            return {
              id: entry.id,
              top: placement.top,
              left: placement.side === "left" ? leftLeft : rightLeft,
              width: null,
              visible: true,
              side: placement.side,
            };
          }),
        };
      }

      apply(layout: MeasuredLayout, view: EditorView) {
        const scroller = view.scrollDOM;
        const modeChanged = layout.mode !== this.mode;
        this.mode = layout.mode;
        if (layout.mode) scroller.dataset.nv3MarginNotes = layout.mode;
        else delete scroller.dataset.nv3MarginNotes;

        for (const placement of layout.placements) {
          const element = this.elements.get(placement.id);
          if (!element) continue;
          const style = element.dom.style;
          style.display = placement.visible ? "" : "none";
          style.top = `${placement.top}px`;
          style.left = `${placement.left}px`;
          style.width = placement.width == null ? "" : `${placement.width}px`;
          element.dom.classList.toggle("nv3-annotation-note-left", placement.side === "left");
        }

        // Switching modes moves the text column, so positions read this pass are stale.
        if (modeChanged) this.scheduleMeasure();
      }
    },
  );
}

function createBadgeClickHandler(source: Nv3MarginNotesSource): Extension {
  return EditorView.domEventHandlers({
    mousedown(event, view) {
      const target = event.target instanceof Element ? event.target : null;
      const badge = target?.closest<HTMLElement>(".nv3-annotation-badge[data-nv3-annotation-id]");
      const id = badge?.dataset.nv3AnnotationId;
      if (!id) return false;
      event.preventDefault();
      source.setFocus(view, source.focusedId(view.state) === id ? null : id);
      return true;
    },
  });
}

export interface Nv3AnnotationMarginNotes {
  extension: Extension;
  /** Re-place notes after something outside CodeMirror moved their anchors. */
  remeasure(view: EditorView): void;
}

export function createNv3AnnotationMarginNotes(source: Nv3MarginNotesSource): Nv3AnnotationMarginNotes {
  const plugin = createMarginNotesPlugin(source);
  return {
    extension: [plugin, createBadgeClickHandler(source)],
    remeasure: (view) => view.plugin(plugin)?.scheduleMeasure(),
  };
}
