import { type Extension } from "@codemirror/state";

/**
 * Adds bottom padding equal to half the viewport height (minimum 140 px)
 * so the last line of a document can be scrolled comfortably into view.
 *
 * The actual value is a pure-CSS expression (`max(140px, 50vh)`) applied
 * in `editor.lib.css` and `notionTheme.ts`.  This function exists only to
 * keep the call-site unchanged; it returns an empty extension.
 */
export function createNv3EditorBottomSpaceExtension(): Extension {
  return [];
}
