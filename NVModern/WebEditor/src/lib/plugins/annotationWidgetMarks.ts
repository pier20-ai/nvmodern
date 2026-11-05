import type { EditorState, Extension, Text } from "@codemirror/state";
import { EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";

// Annotation marks are decorations, and decorations do not reach inside a
// widget that replaces its source (a rendered table). Widgets opt in by
// publishing their source: the widget root carries `data-nv3-source-root`, and
// each element showing source text carries `data-nv3-source-from`/`-to`,
// offsets relative to the widget's start. Annotations overlapping that text
// are drawn into the element directly: the matching words when they can be
// found, otherwise the whole element.

export interface Nv3WidgetMarkItem {
  id: string;
  label: string;
  color: string;
  author: string;
  style: string;
  from: number;
  to: number;
}

export interface Nv3WidgetMarksSource {
  key(state: EditorState): unknown;
  items(state: EditorState): Nv3WidgetMarkItem[];
  focusedId(state: EditorState): string | null;
  /** Called after marks change, since they move what other surfaces align to. */
  onApplied(view: EditorView): void;
}

/** Visible text for a slice of Markdown source: emphasis markers and escapes removed. */
export function nv3VisibleSourceText(source: string): string {
  return source.replace(/\\([\\|*_`~=])/g, "$1").replace(/[*`~=]/g, "").trim();
}

/** The source range inside `from..to` once surrounding whitespace is dropped. */
export function nv3TrimmedSourceRange(doc: Text, from: number, to: number): { from: number; to: number } {
  const text = doc.sliceString(from, to);
  const lead = text.length - text.trimStart().length;
  const trail = text.length - text.trimEnd().length;
  return { from: from + lead, to: Math.max(from + lead, to - trail) };
}

type Applied =
  | { kind: "element"; element: HTMLElement; classes: string[]; color: string | undefined; ids: string | undefined }
  | { kind: "wrap"; element: HTMLElement }
  | { kind: "badge"; element: HTMLElement };

function wrapVisibleText(container: HTMLElement, needle: string): HTMLElement | null {
  if (!needle) return null;
  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode() as globalThis.Text | null; node; node = walker.nextNode() as globalThis.Text | null) {
    if (node.parentElement?.closest(".nv3-annotation-badge")) continue;
    const index = node.data.indexOf(needle);
    if (index === -1) continue;
    const middle = node.splitText(index);
    middle.splitText(needle.length);
    const wrapper = document.createElement("span");
    middle.replaceWith(wrapper);
    wrapper.append(middle);
    return wrapper;
  }
  return null;
}

function createBadge(item: Nv3WidgetMarkItem): HTMLElement {
  const badge = document.createElement("span");
  badge.className = `nv3-annotation-badge nv3-annotation-badge-${item.author}`;
  badge.dataset.nv3AnnotationColor = item.color;
  badge.dataset.nv3AnnotationId = item.id;
  badge.textContent = item.label;
  badge.setAttribute("aria-label", `Annotation ${item.label}`);
  return badge;
}

function createWidgetMarksPlugin(source: Nv3WidgetMarksSource) {
  return ViewPlugin.fromClass(
    class {
      applied: Applied[] = [];
      frame = 0;
      /** What the current marks were drawn from; unchanged inputs skip a redraw. */
      drawnFrom: unknown[] = [];

      constructor(readonly view: EditorView) {
        this.schedule();
      }

      update(update: ViewUpdate) {
        const changed = source.key(update.startState) !== source.key(update.state);
        // Widgets re-render on edits and cell activation, which drops what was drawn.
        if (changed || update.transactions.length > 0 || update.viewportChanged || update.geometryChanged) {
          if (changed || this.applied.length > 0 || source.items(update.state).length > 0) this.schedule();
        }
      }

      destroy() {
        if (this.frame) cancelAnimationFrame(this.frame);
        this.clear();
      }

      schedule() {
        // From a fresh frame, never inside a running measure loop (see the
        // margin notes): redrawing marks changes heights, which would restart it.
        if (this.frame) return;
        this.frame = requestAnimationFrame(() => {
          this.frame = 0;
          this.view.requestMeasure({ key: this, read: () => null, write: (_, view) => this.apply(view) });
        });
      }

      clear() {
        for (const entry of this.applied.splice(0).reverse()) {
          if (entry.kind === "badge") {
            entry.element.remove();
          } else if (entry.kind === "wrap") {
            const parent = entry.element.parentNode;
            entry.element.replaceWith(...Array.from(entry.element.childNodes));
            parent?.normalize();
          } else {
            entry.element.classList.remove(...entry.classes);
            if (entry.color === undefined) delete entry.element.dataset.nv3AnnotationColor;
            else entry.element.dataset.nv3AnnotationColor = entry.color;
            if (entry.ids === undefined) delete entry.element.dataset.nv3AnnotationIds;
            else entry.element.dataset.nv3AnnotationIds = entry.ids;
          }
        }
      }

      apply(view: EditorView) {
        const roots = Array.from(view.contentDOM.querySelectorAll<HTMLElement>("[data-nv3-source-root]"));
        const inputs = [source.key(view.state), view.state.doc, source.focusedId(view.state), ...roots];
        const unchanged =
          inputs.length === this.drawnFrom.length &&
          inputs.every((input, index) => input === this.drawnFrom[index]) &&
          this.applied.every((entry) => entry.element.isConnected);
        if (unchanged) return;
        this.drawnFrom = inputs;

        const hadMarks = this.applied.length > 0;
        this.clear();
        const items = source.items(view.state);
        if (items.length === 0) {
          if (hadMarks) source.onApplied(view);
          return;
        }

        const doc = view.state.doc;
        const focused = source.focusedId(view.state);
        const badged = new Set<string>();

        for (const root of roots) {
          let start: number;
          try {
            start = view.posAtDOM(root);
          } catch {
            continue;
          }

          for (const element of Array.from(root.querySelectorAll<HTMLElement>("[data-nv3-source-from]"))) {
            // Text fields publish their source for selections; marks draw on displayed text.
            if (element instanceof HTMLTextAreaElement || element instanceof HTMLInputElement) continue;
            const relativeFrom = Number(element.dataset.nv3SourceFrom);
            const relativeTo = Number(element.dataset.nv3SourceTo);
            if (!Number.isFinite(relativeFrom) || !Number.isFinite(relativeTo)) continue;
            const text = nv3TrimmedSourceRange(doc, start + relativeFrom, start + relativeTo);
            if (text.from >= text.to || text.to > doc.length) continue;

            for (const item of items) {
              if (item.to <= text.from || item.from >= text.to) continue;

              const classes = ["nv3-annotation", `nv3-annotation-${item.style}`];
              if (focused === item.id) classes.push("nv3-annotation-focused");

              const covers = item.from <= text.from && item.to >= text.to;
              const wrapper = covers
                ? null
                : wrapVisibleText(
                    element,
                    nv3VisibleSourceText(doc.sliceString(Math.max(item.from, text.from), Math.min(item.to, text.to))),
                  );

              let marked: HTMLElement;
              if (wrapper) {
                wrapper.classList.add(...classes);
                wrapper.dataset.nv3AnnotationColor = item.color;
                wrapper.dataset.nv3AnnotationIds = item.id;
                this.applied.push({ kind: "wrap", element: wrapper });
                marked = wrapper;
              } else {
                const added = classes.filter((name) => !element.classList.contains(name));
                this.applied.push({
                  kind: "element",
                  element,
                  classes: added,
                  color: element.dataset.nv3AnnotationColor,
                  ids: element.dataset.nv3AnnotationIds,
                });
                element.classList.add(...added);
                element.dataset.nv3AnnotationColor = item.color;
                element.dataset.nv3AnnotationIds = [element.dataset.nv3AnnotationIds, item.id].filter(Boolean).join(" ");
                marked = element;
              }

              if (!badged.has(item.id)) {
                badged.add(item.id);
                const badge = createBadge(item);
                if (marked === element) element.prepend(badge);
                else marked.before(badge);
                this.applied.push({ kind: "badge", element: badge });
              }
            }
          }
        }

        if (hadMarks || this.applied.length > 0) source.onApplied(view);
      }
    },
  );
}

export function createNv3AnnotationWidgetMarks(source: Nv3WidgetMarksSource): Extension {
  return createWidgetMarksPlugin(source);
}
