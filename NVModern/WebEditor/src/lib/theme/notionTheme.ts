import { EditorView } from "@codemirror/view";

/**
 * Core editor typography/spacing theme.
 *
 * We keep this in CM's theme system (instead of plain CSS only) so it
 * consistently wins over built-in defaults and extension base styles.
 */
export const nv3NotionEditorTheme = EditorView.theme({
  "&": {
    backgroundColor: "transparent",
    color: "var(--nv3-color-text)",
    fontFamily: "var(--nv3-font-sans)",
  },

  ".cm-scroller": {
    fontFamily: "var(--nv3-font-sans)",
    lineHeight: "var(--nv3-content-line-height)",
  },

  ".cm-content": {
    minHeight: "calc(100vh - 230px)",
    padding: "8px 0 0",
    paddingBottom: "max(140px, 50vh)",
    color: "var(--nv3-color-text)",
    fontSize: "var(--nv3-content-font-size)",
    fontWeight: "400",
    letterSpacing: "-0.002em",
    caretColor: "var(--nv3-caret-color)",
    tabSize: "2",
    fontVariantNumeric: "proportional-nums",
  },

  ".cm-line": {
    padding: "0 2px",
  },

  ".cm-gutters": {
    backgroundColor: "transparent",
    border: "none",
    color: "var(--nv3-color-text-subtle)",
  },

  ".cm-foldPlaceholder": {
    border: "1px solid var(--nv3-color-border)",
    borderRadius: "var(--nv3-radius)",
    backgroundColor: "var(--nv3-color-surface)",
    color: "var(--nv3-color-text-subtle)",
  },

  ".cm-placeholder": {
    color: "var(--nv3-color-text-subtle)",
  },

  ".cm-tooltip": {
    border: "1px solid var(--nv3-color-border)",
    backgroundColor: "var(--nv3-color-bg)",
    color: "var(--nv3-color-text)",
  },

  "&.cm-focused .cm-cursor": {
    borderLeftColor: "var(--nv3-caret-color)",
    borderLeftWidth: "2px",
  },

  "&.cm-focused .cm-dropCursor": {
    borderLeftColor: "var(--nv3-caret-color)",
    borderLeftWidth: "2px",
  },

  "&.cm-focused .cm-selectionBackground": {
    backgroundColor: "var(--nv3-selection-bg)",
  },

  "&.cm-focused .cm-activeLine, &.cm-focused .cm-activeLineGutter": {
    backgroundColor: "transparent",
  },
});
