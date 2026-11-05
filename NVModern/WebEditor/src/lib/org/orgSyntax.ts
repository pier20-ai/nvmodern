import { StateField, type EditorState, type Extension, type Text } from "@codemirror/state";
import {
  createIncrementalParse,
  updateIncrementalParse,
  type IncrementalParseState,
  type OrgEdit,
} from "uniorg-parse";

export const ORG_TODO_STATES = ["TODO", "DOING", "DONE", "POSTPONED", "DROPPED"];
const parseOptions = { trackPosition: true, todoKeywords: ORG_TODO_STATES };

// Text values are immutable. Cache only exact document versions; an edit always
// publishes current syntax in its own transaction, before decorations render.
const syntaxCache = new WeakMap<Text, IncrementalParseState>();

export function getOrgSyntax(doc: Text): IncrementalParseState {
  let syntax = syntaxCache.get(doc);
  if (!syntax) {
    syntax = createIncrementalParse(doc.toString(), parseOptions);
    syntaxCache.set(doc, syntax);
  }
  return syntax;
}

export const orgSyntaxField = StateField.define<IncrementalParseState>({
  create: (state) => getOrgSyntax(state.doc),
  update(previous, transaction) {
    if (!transaction.docChanged) return previous;
    const edits: OrgEdit[] = [];
    transaction.changes.iterChanges((from, to, _newFrom, _newTo, inserted) => {
      edits.push({ from, to, insert: inserted.toString() });
    });
    const syntax = updateIncrementalParse(previous, edits);
    syntaxCache.set(transaction.state.doc, syntax);
    return syntax;
  },
});

export function getOrgSyntaxForState(state: EditorState): IncrementalParseState {
  return state.field(orgSyntaxField, false) ?? getOrgSyntax(state.doc);
}

export const orgSyntaxExtension: Extension = orgSyntaxField;
