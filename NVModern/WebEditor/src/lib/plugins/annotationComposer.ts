import { Facet, StateEffect, StateField, type EditorState, type Extension } from "@codemirror/state";
import {
  Decoration,
  EditorView,
  keymap,
  showTooltip,
  ViewPlugin,
  type Tooltip,
  type TooltipView,
} from "@codemirror/view";
import { nv3AnnotationStart } from "./annotationRanges.ts";

// The composer is how a reader annotates: select a passage, press Mod-Shift-m
// (or run the host's command), type a question, Enter. Enter on an empty box
// saves a plain highlight. With the caret inside one of their own marks, the
// same keys reopen its question for editing. The passage stays marked while
// the box is open.
//
// Selections inside widgets that publish their source (see
// annotationWidgetMarks.ts) work too: the widget's focused text field, with
// `data-nv3-source-from`/`-to`, or its element marked `data-nv3-source-active`.

export interface Nv3EditableAnnotation {
  id: string;
  from: number;
  to: number;
  note: string;
}

export interface Nv3AnnotationComposerOptions {
  save(view: EditorView, from: number, to: number, text: string): void;
  edit(view: EditorView, id: string, text: string): void;
  /** The reader's own annotation at a caret position, to edit instead of adding. */
  editableAt(state: EditorState, pos: number): Nv3EditableAnnotation | null;
  placeholder?: string;
}

interface ComposerState {
  from: number;
  to: number;
  /** Set when editing an existing annotation's question. */
  editId?: string;
  initial?: string;
  /** Changes on every open, so a box already showing resets its text. */
  token: number;
}

const composerConfig = Facet.define<Nv3AnnotationComposerOptions, Nv3AnnotationComposerOptions | null>({
  combine: (values) => values[0] ?? null,
});

const setComposerEffect = StateEffect.define<ComposerState | null>();

const composerField = StateField.define<ComposerState | null>({
  create: () => null,
  update(value, transaction) {
    let next = value;
    if (next && transaction.docChanged) {
      const from = transaction.changes.mapPos(next.from, 1);
      const to = transaction.changes.mapPos(next.to, -1);
      next = to > from ? { ...next, from, to } : null;
    }
    for (const effect of transaction.effects) {
      if (effect.is(setComposerEffect)) next = effect.value;
    }
    return next;
  },
});

const pendingMark = Decoration.mark({ class: "nv3-annotation-pending" });
const FOCUS_GRACE_MS = 600;
let nextToken = 1;

interface ComposerTarget {
  from: number;
  to: number;
  /** Where the caret was when nothing was selected. */
  caret?: number;
}

/** The range a new annotation would cover: the selection, else the caret's line. */
export function nv3AnnotationComposerRange(state: EditorState): ComposerTarget | null {
  const selection = state.selection.main;
  if (!selection.empty) {
    return { from: nv3AnnotationStart(state.doc, selection.from, selection.to), to: selection.to };
  }
  const line = state.doc.lineAt(selection.head);
  const lead = line.text.length - line.text.trimStart().length;
  const trail = line.text.length - line.text.trimEnd().length;
  const to = line.to - trail;
  const from = nv3AnnotationStart(state.doc, line.from + lead, to);
  return to > from ? { from, to, caret: selection.head } : null;
}

function trimmedRange(state: EditorState, from: number, to: number): { from: number; to: number } {
  const text = state.doc.sliceString(from, to);
  const lead = text.length - text.trimStart().length;
  const trail = text.length - text.trimEnd().length;
  return { from: from + lead, to: Math.max(from + lead, to - trail) };
}

/** A selection inside a widget that publishes its source, mapped to the document. */
export function nv3WidgetSelectionRange(view: EditorView): ComposerTarget | null {
  const active = view.root.activeElement;
  if (!(active instanceof HTMLElement) || !view.contentDOM.contains(active)) return null;
  const root = active.closest<HTMLElement>("[data-nv3-source-root]");
  if (!root) return null;
  let start: number;
  try {
    start = view.posAtDOM(root);
  } catch {
    return null;
  }

  const sourceOf = (element: HTMLElement) => {
    const from = Number(element.dataset.nv3SourceFrom);
    const to = Number(element.dataset.nv3SourceTo);
    if (!Number.isFinite(from) || !Number.isFinite(to)) return null;
    return trimmedRange(view.state, start + from, start + to);
  };

  // A text field editing a slice of source: its selection maps by offset.
  if ((active instanceof HTMLTextAreaElement || active instanceof HTMLInputElement) && active.dataset.nv3SourceFrom) {
    const range = sourceOf(active);
    if (!range) return null;
    const selectionStart = active.selectionStart ?? 0;
    const selectionEnd = active.selectionEnd ?? selectionStart;
    if (selectionEnd > selectionStart) {
      return {
        from: Math.min(range.to, range.from + selectionStart),
        to: Math.min(range.to, range.from + selectionEnd),
      };
    }
    return range.to > range.from ? { ...range, caret: Math.min(range.to, range.from + selectionStart) } : null;
  }

  const selected = root.querySelector<HTMLElement>("[data-nv3-source-active]");
  const range = selected ? sourceOf(selected) : null;
  return range && range.to > range.from ? { ...range, caret: range.from } : null;
}

function openComposer(view: EditorView, state: Omit<ComposerState, "token">) {
  view.dispatch({ effects: setComposerEffect.of({ ...state, token: nextToken++ }) });
}

/** Open the composer: edit the reader's annotation at the caret, else annotate the selection. */
export function beginNv3AnnotationComposer(view: EditorView): boolean {
  const config = view.state.facet(composerConfig);
  if (!config) return false;
  const target = nv3WidgetSelectionRange(view) ?? nv3AnnotationComposerRange(view.state);
  if (!target) return false;
  const existing = target.caret != null ? config.editableAt(view.state, target.caret) : null;
  if (existing) {
    openComposer(view, { from: existing.from, to: existing.to, editId: existing.id, initial: existing.note });
  } else {
    openComposer(view, { from: target.from, to: target.to });
  }
  return true;
}

/** Reopen an existing annotation's question for editing. */
export function editNv3AnnotationInComposer(view: EditorView, annotation: Nv3EditableAnnotation): void {
  openComposer(view, {
    from: annotation.from,
    to: annotation.to,
    editId: annotation.id,
    initial: annotation.note,
  });
}

function closeComposer(view: EditorView) {
  if (view.state.field(composerField, false)) view.dispatch({ effects: setComposerEffect.of(null) });
}

function isComposerShortcut(event: KeyboardEvent): boolean {
  const mod = /Mac|iPhone|iPad/.test(navigator.platform) ? event.metaKey : event.ctrlKey;
  return mod && event.shiftKey && !event.altKey && event.key.toLowerCase() === "m";
}

// Widgets swallow their own key events before CodeMirror's keymap sees them,
// so the shortcut is also caught on the way down to a widget.
const widgetShortcut = ViewPlugin.define((view) => {
  const onKeyDown = (event: KeyboardEvent) => {
    if (!isComposerShortcut(event)) return;
    const target = event.target instanceof Element ? event.target : null;
    if (!target?.closest("[data-nv3-source-root]")) return;
    if (beginNv3AnnotationComposer(view)) {
      event.preventDefault();
      event.stopPropagation();
    }
  };
  view.dom.addEventListener("keydown", onKeyDown, true);
  return { destroy: () => view.dom.removeEventListener("keydown", onKeyDown, true) };
});

export function createNv3AnnotationComposer(options: Nv3AnnotationComposerOptions): Extension {
  // One create function for the composer's lifetime, so CodeMirror keeps the
  // same tooltip (and the text typed so far) as the range moves.
  const create = (view: EditorView): TooltipView => {
    const dom = document.createElement("div");
    dom.className = "nv3-annotation-composer";

    const input = document.createElement("textarea");
    input.className = "nv3-annotation-composer-input";
    input.rows = 2;
    input.setAttribute("aria-label", "Annotation question");

    const hint = document.createElement("div");
    hint.className = "nv3-annotation-composer-hint";
    hint.textContent = "↵ save · ⇧↵ new line · esc cancel";

    dom.append(input, hint);

    let token = 0;
    const reset = (state: ComposerState) => {
      token = state.token;
      input.value = state.initial ?? "";
      input.placeholder = state.editId
        ? "Edit your question, or clear it to keep a plain highlight"
        : (options.placeholder ?? "Ask about this, or press ↵ to just highlight");
      resize();
    };

    const resize = () => {
      input.style.height = "auto";
      input.style.height = `${input.scrollHeight}px`;
    };

    const submit = () => {
      const state = view.state.field(composerField, false);
      if (!state) return;
      const text = input.value.trim();
      closeComposer(view);
      if (state.editId) options.edit(view, state.editId, text);
      else options.save(view, state.from, state.to, text);
      view.focus();
    };

    input.addEventListener("input", resize);
    input.addEventListener("keydown", (event) => {
      event.stopPropagation();
      if (event.isComposing) return;
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        submit();
      } else if (event.key === "Escape") {
        event.preventDefault();
        closeComposer(view);
        view.focus();
      }
    });
    let mountedAt = 0;
    input.addEventListener("blur", () => {
      const state = view.state.field(composerField, false);
      if (input.value.trim() !== (state?.initial ?? "").trim()) return;
      // A host restoring focus to the editor right after opening the box (a
      // command palette closing, say) is not the reader leaving it.
      if (performance.now() - mountedAt < FOCUS_GRACE_MS) {
        requestAnimationFrame(() => input.focus());
        return;
      }
      // Clicking away from an untouched box is a cancel; a drafted question stays.
      setTimeout(() => closeComposer(view), 0);
    });

    const initial = view.state.field(composerField, false);
    if (initial) reset(initial);

    return {
      dom,
      mount() {
        mountedAt = performance.now();
        input.focus();
        input.setSelectionRange(input.value.length, input.value.length);
        resize();
      },
      update(update) {
        const state = update.state.field(composerField, false);
        if (state && state.token !== token) {
          reset(state);
          mountedAt = performance.now();
          input.focus();
        }
      },
    };
  };

  const tooltip = showTooltip.compute([composerField], (state): Tooltip | null => {
    const range = state.field(composerField);
    if (!range) return null;
    return { pos: range.to, above: false, strictSide: false, arrow: false, create };
  });

  const pending = EditorView.decorations.compute([composerField], (state) => {
    const range = state.field(composerField);
    return range && !range.editId ? Decoration.set([pendingMark.range(range.from, range.to)]) : Decoration.none;
  });

  return [
    composerConfig.of(options),
    composerField,
    tooltip,
    pending,
    widgetShortcut,
    keymap.of([{ key: "Mod-Shift-m", run: beginNv3AnnotationComposer }]),
  ];
}
