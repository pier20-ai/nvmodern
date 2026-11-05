/**
 * Factory helpers for the common CM6 decoration-plugin pattern.
 *
 * Most plugins in this library follow the same structure:
 *   1. Compute data from EditorState  (scan/parse/build)
 *   2. Build a DecorationSet from that data
 *   3. Optionally notify a callback when the data changes
 *   4. Skip notification when the data signature hasn't changed
 *
 * These two helpers eliminate that boilerplate:
 *   - `decorationPlugin`  – no data tracking, just decorations
 *   - `trackedDecorationPlugin` – decorations + data + onChange + signature dedup
 */
import type { DecorationSet } from "@codemirror/view";
import type { EditorState, Extension } from "@codemirror/state";
import { ViewPlugin, type ViewUpdate } from "@codemirror/view";

// ── Simple decoration plugin ──────────────────────────────────────────────

export function decorationPlugin(spec: {
  /** Build decorations from the current editor state. */
  create(state: EditorState): DecorationSet;
  /** Also rebuild on selection changes? Default: false. */
  selectionSensitive?: boolean;
}): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;

      constructor(view: import("@codemirror/view").EditorView) {
        this.decorations = spec.create(view.state);
      }

      update(update: ViewUpdate) {
        if (!update.docChanged && !(spec.selectionSensitive && update.selectionSet)) return;
        this.decorations = spec.create(update.state);
      }
    },
    { decorations: (v) => v.decorations },
  );
}

// ── Tracked decoration plugin ─────────────────────────────────────────────

export function trackedDecorationPlugin<T>(spec: {
  /** Build decorations and associated data from the current editor state. */
  create(state: EditorState): { data: T; decorations: DecorationSet };
  /** Also rebuild on selection changes? Default: false. */
  selectionSensitive?: boolean;
  /** Called when the data changes (gated by `signature` if provided). */
  onChange?(data: T): void;
  /** String fingerprint for change detection. If omitted, onChange fires every rebuild. */
  signature?(data: T): string;
}): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      data: T;
      private sig: string;

      constructor(view: import("@codemirror/view").EditorView) {
        const result = spec.create(view.state);
        this.decorations = result.decorations;
        this.data = result.data;
        this.sig = spec.signature?.(result.data) ?? "";
        spec.onChange?.(result.data);
      }

      update(update: ViewUpdate) {
        if (!update.docChanged && !(spec.selectionSensitive && update.selectionSet)) return;

        const result = spec.create(update.state);
        this.decorations = result.decorations;
        this.data = result.data;

        if (!update.docChanged || !spec.onChange) return;

        if (spec.signature) {
          const nextSig = spec.signature(result.data);
          if (nextSig !== this.sig) {
            this.sig = nextSig;
            spec.onChange(result.data);
          }
        } else {
          spec.onChange(result.data);
        }
      }
    },
    { decorations: (v) => v.decorations },
  );
}
