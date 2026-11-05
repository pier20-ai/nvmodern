import type { HelpProvider, HelpTopic } from "../lib/help/model.ts";
import { arborShortcutsForTopic } from "./keymap.ts";

/**
 * Help for the Arbor outline surface. Keyboard rows are generated from `keymap.ts`, the same tables
 * `ArborSurface` dispatches through, so they cannot drift. Only pointer gestures are listed here by hand.
 */
type Shortcut = { keys: string; action: string };

function topic(
  id: string, title: string, category: string, summary: string,
  gestures: Shortcut[], keywords: string[] = [], aliases: string[] = [],
): HelpTopic {
  return { id, title, category, summary, keywords, signatures: [], aliases, examples: [], insertions: [], shortcuts: [...arborShortcutsForTopic(id), ...gestures] };
}

const topics: HelpTopic[] = [
  topic("split-block", "Split a block", "Editing",
    "Enter splits the block at the caret, moving the text after it into a new block below. Shift+Enter inserts a line break inside the block instead.",
    [],
    ["new block", "enter", "return", "newline"]),
  topic("indent-outdent", "Indent and outdent", "Editing",
    "Tab nests a block under the block above it; Shift+Tab moves it back out a level. With several blocks selected, the whole selection moves together.",
    [],
    ["nest", "level", "child", "promote", "demote"]),
  topic("merge-block", "Merge with the previous block", "Editing",
    "Backspace with the caret at the very start of a block joins it onto the end of the previous block.",
    [], ["join", "backspace"]),
  topic("move-block", "Move blocks up and down", "Editing",
    "Option+Up and Option+Down swap a block (with its children) with its neighbour. This also works on a selection of blocks.",
    [], ["reorder", "swap"]),
  topic("format-text", "Bold and italic", "Editing",
    "Wrap the selection, or the word at the caret, in bold or italic markers.",
    [], ["emphasis", "strong", "format"]),
  topic("undo-redo", "Undo and redo", "Editing",
    "Undo uses the outline's own history, so it reverts structural changes (moves, indents, merges) as well as typing.",
    [], ["history"]),

  topic("move-caret", "Move between blocks", "Navigation",
    "Arrow keys flow across block boundaries: Up and Down move to the neighbouring visible block when the caret is on the first or last visual line, and Left and Right cross at the start or end of a block. Collapsed children are skipped.",
    [],
    ["arrow", "cursor", "caret"]),
  topic("stop-editing", "Stop editing", "Navigation",
    "Escape leaves the block you are editing so the outline itself has focus. Escape again clears any block selection.",
    [], ["blur", "escape"]),
  topic("zoom", "Zoom into a block", "Navigation",
    "Double-click a bullet to show only that block and its children. Use “← Back to outline” at the top to return to the full outline.",
    [{ keys: "Double-click bullet", action: "Zoom into block" }], ["focus", "drill", "breadcrumb"]),
  topic("fold", "Collapse and expand", "Navigation",
    "Click the bullet of a block that has children to collapse or expand it. Collapsed children are hidden from navigation and selection ranges.",
    [{ keys: "Click bullet", action: "Collapse / expand" }], ["fold", "toggle", "children"]),

  topic("select-blocks", "Select blocks", "Selection",
    "Select whole blocks to act on them together. Shift+Up or Down at the edge of a block starts or extends a range; Shift-click a bullet selects a range, and Command-click adds or removes single blocks.",
    [
      { keys: "⇧ click bullet", action: "Select range" },
      { keys: "⌘ click bullet", action: "Add or remove one block" },
    ], ["multi", "range", "highlight"]),
  topic("act-on-selection", "Act on selected blocks", "Selection",
    "With blocks selected, these commands apply to the whole selection and include each block’s children.",
    [], ["copy", "cut", "delete", "bulk"]),
  topic("drag-drop", "Drag and drop", "Selection",
    "Drag a bullet to move that block, or the selected blocks, to a new place; a line shows where it will land. Invalid drops (such as into the block’s own children) are refused.",
    [{ keys: "Drag bullet", action: "Move block(s)" }], ["reorder", "mouse"]),
  topic("context-menu", "Block context menu", "Selection",
    "Right-click a bullet for block actions: copy the text, copy the block ID (for ((block references))), move up or down, or delete.",
    [{ keys: "Right-click bullet", action: "Open block actions" }], ["copy id", "delete", "menu"]),

  topic("links", "Links and references", "Linking",
    "Typing a trigger opens a completion list; Up and Down choose, Enter inserts, Escape dismisses. “[[” links to a page, “((” references a block by ID, “#” inserts a tag already used in the outline, and “/” offers commands (TODO, Heading, Divider).",
    [
      { keys: "[[", action: "Link to a page" }, { keys: "((", action: "Reference a block" },
      { keys: "#", action: "Insert a tag" }, { keys: "/", action: "Slash commands" },
    ], ["wikilink", "backlink", "tag", "autocomplete", "slash", "todo"]),
  topic("dates", "Insert a date", "Linking",
    "Press Command+; to open the date shortcuts, then a second key: “.” inserts today’s date, “D” inserts today and opens the calendar to pick another day. The overlay closes on its own if you wait. Pressing it on an existing timestamp replaces it.",
    [],
    ["timestamp", "calendar", "leader", "today"]),

  topic("run-producer", "Run a producer", "Producers",
    "Producer blocks compute live child results. Run refreshes the results in place; Run as New appends a fresh generation and keeps earlier results. Documents never run producers on load or edit; only these commands do.",
    [],
    ["query", "refresh", "kernel", "materialize", "effect"]),
];

export function createArborHelpProvider(): HelpProvider {
  return { id: "arbor", title: "Outline", topics };
}
