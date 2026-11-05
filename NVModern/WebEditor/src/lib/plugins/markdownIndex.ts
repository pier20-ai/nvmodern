/**
 * Markdown document scanning — CM6 integration.
 *
 * Installs the `documentScannerFacet` with the Markdown scanner and the
 * `documentScanField` StateField. Consuming plugins use
 * `resolveDocumentScanIndex(state)` to access the index.
 *
 * This file also re-exports the legacy `nv3MarkdownScanStateField` and
 * `getNv3MarkdownScanIndex` for backward compatibility with code that
 * reads the raw `Nv3MarkdownScanIndex` type.
 */
import {
  StateField,
  type EditorState,
  type Extension,
} from "@codemirror/state";
import { ViewPlugin, type ViewUpdate } from "@codemirror/view";
import {
  scanMarkdownDocument,
  type Nv3MarkdownScanIndex,
} from "./markdownScanner.ts";

// ── Legacy state field (backward compat) ──────────────────────────────────

export const nv3MarkdownScanStateField = StateField.define<Nv3MarkdownScanIndex>({
  create(state) {
    return scanMarkdownDocument(state.doc);
  },

  update(value, transaction) {
    if (!transaction.docChanged) return value;
    return scanMarkdownDocument(transaction.state.doc);
  },
});

export function getNv3MarkdownScanIndex(state: EditorState): Nv3MarkdownScanIndex | null {
  return state.field(nv3MarkdownScanStateField, false) ?? null;
}

// ── Extension ─────────────────────────────────────────────────────────────

export interface Nv3MarkdownScanExtensionOptions {
  onChange?: (index: Nv3MarkdownScanIndex) => void;
}

export function createNv3MarkdownScanExtension(
  options: Nv3MarkdownScanExtensionOptions = {},
): Extension {
  const extensions: Extension[] = [nv3MarkdownScanStateField];

  if (options.onChange) {
    const { onChange } = options;

    extensions.push(
      ViewPlugin.fromClass(
        class {
          constructor(view: import("@codemirror/view").EditorView) {
            const index = getNv3MarkdownScanIndex(view.state);
            if (index) onChange(index);
          }

          update(update: ViewUpdate) {
            if (!update.docChanged) return;
            const index = getNv3MarkdownScanIndex(update.state);
            if (index) onChange(index);
          }
        },
      ),
    );
  }

  return extensions;
}
