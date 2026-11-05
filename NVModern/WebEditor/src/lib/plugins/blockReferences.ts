import { RangeSetBuilder, EditorState, type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet, type EditorView } from "@codemirror/view";
import { resolveDocumentScanIndex } from "./documentIndex.ts";
import { decorationPlugin } from "./scanPlugin.ts";
import { focusEditorWithoutScroll } from "./viewUtils.ts";

const blockReferenceDecoration = Decoration.mark({ class: "nv3-block-reference" });

function buildBlockReferenceDecorations(state: EditorState): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  for (const occ of resolveDocumentScanIndex(state).blockIDs) {
    builder.add(occ.from, occ.to, blockReferenceDecoration);
  }
  return builder.finish();
}

export function createMarkdownBlockReferenceExtension(): Extension {
  return decorationPlugin({ create: buildBlockReferenceDecorations });
}

// ── Block reference insertion command ─────────────────────────────────────

function generateBlockReferenceID(view: EditorView): string {
  const existing = new Set(resolveDocumentScanIndex(view.state).blockIDs.map((o) => o.id));
  for (let attempt = 0; attempt < 32; attempt++) {
    const candidate = Math.random().toString(36).slice(2, 8).toLowerCase();
    if (candidate.length >= 4 && !existing.has(candidate)) return candidate;
  }
  return `ref${Date.now().toString(36).slice(-6)}`;
}

/** Insert a `^block-id` at the end of the current line, or select existing. */
export function insertBlockReference(view: EditorView): boolean {
  if (view.state.facet(EditorState.readOnly)) return false;

  const line = view.state.doc.lineAt(view.state.selection.main.from);
  const existing = resolveDocumentScanIndex(view.state).blockIDs.find((o) => o.line === line.number);

  if (existing) {
    view.dispatch({ selection: { anchor: existing.from, head: existing.to }, scrollIntoView: true });
    focusEditorWithoutScroll(view);
    return true;
  }

  const blockID = generateBlockReferenceID(view);
  const needsLeadingSpace = line.text.length > 0 && !/[\t ]$/.test(line.text);
  const insert = `${needsLeadingSpace ? " " : ""}^${blockID}`;

  view.dispatch({
    changes: { from: line.to, to: line.to, insert },
    selection: { anchor: line.to + insert.length },
    scrollIntoView: false,
  });
  focusEditorWithoutScroll(view);
  return true;
}
