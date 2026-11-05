/**
 * Language-agnostic document scan index.
 *
 * Defines the common occurrence types and index interface that both the
 * Markdown scanner and a future Org-mode scanner can produce. Consuming
 * plugins program against `DocumentScanIndex` instead of coupling to a
 * specific file format's scanner output.
 *
 * The index is stored in a CM6 StateField and rebuilt on every doc change.
 * A `documentScannerFacet` lets the host provide the right scanner for the
 * active language; plugins read the result through `resolveDocumentScanIndex`.
 */
import { Facet, StateField, type EditorState, type Extension, type Text } from "@codemirror/state";
import { ViewPlugin, type ViewUpdate } from "@codemirror/view";

// ── Occurrence types ──────────────────────────────────────────────────────

export interface TagOccurrence {
  tag: string;
  from: number;
  to: number;
  line: number;
}

export interface MentionOccurrence {
  mention: string;
  from: number;
  to: number;
  line: number;
}

export interface TaskOccurrence {
  from: number;
  to: number;
  line: number;
  checked: boolean;
}

export interface HeadingOccurrence {
  text: string;
  from: number;
  to: number;
  line: number;
  level: number;
}

export interface BlockIDOccurrence {
  id: string;
  from: number;
  to: number;
  line: number;
  lineFrom: number;
}

export type LinkKind = "wikilink" | "transclusion" | "preview";

export interface LinkOccurrence {
  kind: LinkKind;
  target: string;
  from: number;
  to: number;
  line: number;
}

export interface InlineLinkOccurrence {
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

export interface CodeBlockOccurrence {
  fromLine: number;
  toLine: number;
  language: string | null;
  closed: boolean;
}

export interface TransclusionOccurrence {
  target: string;
  from: number;
  to: number;
  line: number;
}

export type LatexFragmentKind =
  | "inline-dollar"
  | "inline-paren"
  | "block-dollar"
  | "block-bracket";

export interface LatexFragmentOccurrence {
  kind: LatexFragmentKind;
  source: string;
  from: number;
  to: number;
  line: number;
  toLine?: number;
}

// ── Index ─────────────────────────────────────────────────────────────────

export interface DocumentScanIndex {
  tags: TagOccurrence[];
  headingTags: TagOccurrence[];
  mentions: MentionOccurrence[];
  tasks: TaskOccurrence[];
  headings: HeadingOccurrence[];
  blockIDs: BlockIDOccurrence[];
  links: LinkOccurrence[];
  inlineLinks: InlineLinkOccurrence[];
  codeBlocks: CodeBlockOccurrence[];
  transclusions: TransclusionOccurrence[];
  latexFragments: LatexFragmentOccurrence[];
}

export const EMPTY_SCAN_INDEX: DocumentScanIndex = {
  tags: [],
  headingTags: [],
  mentions: [],
  tasks: [],
  headings: [],
  blockIDs: [],
  links: [],
  inlineLinks: [],
  codeBlocks: [],
  transclusions: [],
  latexFragments: [],
};

// ── Scanner facet ─────────────────────────────────────────────────────────

export type DocumentScanner = (doc: Text) => DocumentScanIndex;

/**
 * Provide a language-specific scanner. The last-provided scanner wins.
 * When no scanner is configured, `resolveDocumentScanIndex` returns
 * `EMPTY_SCAN_INDEX`.
 */
export const documentScannerFacet = Facet.define<DocumentScanner, DocumentScanner | null>({
  combine: (values) => values[values.length - 1] ?? null,
});

// ── State field ───────────────────────────────────────────────────────────

export const documentScanField = StateField.define<DocumentScanIndex>({
  create(state) {
    const scanner = state.facet(documentScannerFacet);
    return scanner ? scanner(state.doc) : EMPTY_SCAN_INDEX;
  },

  update(value, transaction) {
    if (!transaction.docChanged) return value;
    const scanner = transaction.state.facet(documentScannerFacet);
    return scanner ? scanner(transaction.state.doc) : EMPTY_SCAN_INDEX;
  },
});

// ── Accessors ─────────────────────────────────────────────────────────────

/** Returns the scan index if the field is installed, or null. */
export function getDocumentScanIndex(state: EditorState): DocumentScanIndex | null {
  return state.field(documentScanField, false) ?? null;
}

/**
 * Returns the scan index, always. Uses the state field if available,
 * otherwise runs the scanner directly against the document.
 */
export function resolveDocumentScanIndex(state: EditorState): DocumentScanIndex {
  const cached = state.field(documentScanField, false);
  if (cached) return cached;

  const scanner = state.facet(documentScannerFacet);
  return scanner ? scanner(state.doc) : EMPTY_SCAN_INDEX;
}

// ── Scan extension (installs field + optional onChange) ────────────────────

export interface DocumentScanExtensionOptions {
  onChange?: (index: DocumentScanIndex) => void;
}

export function createDocumentScanExtension(
  options: DocumentScanExtensionOptions = {},
): Extension {
  const extensions: Extension[] = [documentScanField];

  if (options.onChange) {
    const { onChange } = options;

    extensions.push(
      ViewPlugin.fromClass(
        class {
          constructor(view: import("@codemirror/view").EditorView) {
            onChange(view.state.field(documentScanField));
          }

          update(update: ViewUpdate) {
            if (!update.docChanged) return;
            onChange(update.state.field(documentScanField));
          }
        },
      ),
    );
  }

  return extensions;
}
