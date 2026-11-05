/**
 * Declarative key bindings for the Arbor outline. `ArborSurface` dispatches through these tables and the
 * help provider (`help.ts`) reads the same tables, so the documented keys cannot drift from the real ones.
 *
 * Bindings are tried in order; the first whose chord matches and whose command returns `true` wins.
 * A command returns `false` to decline (for example Backspace away from the start of a block), letting
 * later bindings and the browser default run.
 */

export interface ArborKeyEvent {
  readonly key: string;
  readonly code: string;
  readonly metaKey: boolean;
  readonly ctrlKey: boolean;
  readonly altKey: boolean;
  readonly shiftKey: boolean;
}

/** A modifier left `undefined` is ignored; `true` requires it and `false` forbids it. */
export interface ArborChord {
  readonly key?: string;
  readonly code?: string;
  /** Command on macOS or Control elsewhere: either `metaKey` or `ctrlKey`. */
  readonly mod?: boolean;
  readonly meta?: boolean;
  readonly ctrl?: boolean;
  readonly alt?: boolean;
  readonly shift?: boolean;
}

export interface ArborBindingHelp {
  /** Help topic id in the `arbor` provider. */
  readonly topic: string;
  readonly action: string;
}

export interface ArborBinding<Command extends string> {
  readonly command: Command;
  readonly chord: ArborChord;
  /** Where this appears in help. Bindings that should not be documented set `hidden` instead. */
  readonly help?: ArborBindingHelp;
  readonly hidden?: true;
}

export function chordMatches(chord: ArborChord, event: ArborKeyEvent): boolean {
  if (chord.key !== undefined && event.key.toLowerCase() !== chord.key.toLowerCase()) return false;
  if (chord.code !== undefined && event.code !== chord.code) return false;
  if (chord.mod !== undefined && (event.metaKey || event.ctrlKey) !== chord.mod) return false;
  if (chord.meta !== undefined && event.metaKey !== chord.meta) return false;
  if (chord.ctrl !== undefined && event.ctrlKey !== chord.ctrl) return false;
  if (chord.alt !== undefined && event.altKey !== chord.alt) return false;
  if (chord.shift !== undefined && event.shiftKey !== chord.shift) return false;
  return true;
}

export function dispatchKey<Command extends string>(
  bindings: readonly ArborBinding<Command>[],
  event: ArborKeyEvent,
  run: (command: Command) => boolean,
): boolean {
  for (const binding of bindings) {
    if (chordMatches(binding.chord, event) && run(binding.command)) return true;
  }
  return false;
}

const KEY_LABELS: Record<string, string> = {
  ArrowUp: "↑", ArrowDown: "↓", ArrowLeft: "←", ArrowRight: "→",
  Backspace: "⌫", Delete: "⌦", Escape: "Esc", Enter: "Enter", Tab: "Tab",
};

/** macOS-style display string, e.g. `⇧ ⌘ Z`. */
export function formatChord(chord: ArborChord): string {
  const parts: string[] = [];
  if (chord.ctrl) parts.push("⌃");
  if (chord.alt) parts.push("⌥");
  if (chord.shift) parts.push("⇧");
  if (chord.mod || chord.meta) parts.push("⌘");
  if (chord.code === "Semicolon") parts.push(";");
  else if (chord.key !== undefined) parts.push(KEY_LABELS[chord.key] ?? (chord.key.length === 1 ? chord.key.toUpperCase() : chord.key));
  return parts.join(" ");
}

// Keys while editing inside a block.
export type ArborEditorCommand =
  | "dateLeader" | "bold" | "italic" | "redo" | "undo" | "runRefresh" | "runAppend" | "blur"
  | "newline" | "split" | "outdent" | "indent" | "mergePrevious" | "moveUp" | "moveDown"
  | "extendUp" | "extendDown" | "stepLeft" | "stepRight" | "stepUp" | "stepDown";

export const ARBOR_EDITOR_BINDINGS: readonly ArborBinding<ArborEditorCommand>[] = [
  { command: "dateLeader", chord: { code: "Semicolon", meta: true, ctrl: false, alt: false, shift: false },
    help: { topic: "dates", action: "Open date shortcuts" } },
  { command: "bold", chord: { key: "b", mod: true, alt: false, shift: false }, help: { topic: "format-text", action: "Bold" } },
  { command: "italic", chord: { key: "i", mod: true, alt: false, shift: false }, help: { topic: "format-text", action: "Italic" } },
  { command: "redo", chord: { key: "z", mod: true, shift: true }, help: { topic: "undo-redo", action: "Redo" } },
  { command: "undo", chord: { key: "z", mod: true }, help: { topic: "undo-redo", action: "Undo" } },
  { command: "runAppend", chord: { key: "Enter", mod: true, shift: true },
    help: { topic: "run-producer", action: "Run as new generation (when the block is a producer)" } },
  { command: "runRefresh", chord: { key: "Enter", mod: true },
    help: { topic: "run-producer", action: "Run and refresh results (when the block is a producer)" } },
  { command: "blur", chord: { key: "Escape" }, help: { topic: "stop-editing", action: "Leave the block" } },
  { command: "newline", chord: { key: "Enter", shift: true }, help: { topic: "split-block", action: "New line within the block" } },
  { command: "split", chord: { key: "Enter", shift: false }, help: { topic: "split-block", action: "Split block at the caret" } },
  { command: "outdent", chord: { key: "Tab", shift: true }, help: { topic: "indent-outdent", action: "Outdent" } },
  { command: "indent", chord: { key: "Tab", shift: false }, help: { topic: "indent-outdent", action: "Indent" } },
  { command: "mergePrevious", chord: { key: "Backspace" },
    help: { topic: "merge-block", action: "Merge with the previous block (caret at start)" } },
  { command: "moveUp", chord: { key: "ArrowUp", alt: true }, help: { topic: "move-block", action: "Move up" } },
  { command: "moveDown", chord: { key: "ArrowDown", alt: true }, help: { topic: "move-block", action: "Move down" } },
  { command: "extendUp", chord: { key: "ArrowUp", shift: true },
    help: { topic: "select-blocks", action: "Select the block above (caret at the top edge)" } },
  { command: "extendDown", chord: { key: "ArrowDown", shift: true },
    help: { topic: "select-blocks", action: "Select the block below (caret at the bottom edge)" } },
  { command: "stepLeft", chord: { key: "ArrowLeft", mod: false, alt: false, shift: false },
    help: { topic: "move-caret", action: "Previous block (caret at start)" } },
  { command: "stepRight", chord: { key: "ArrowRight", mod: false, alt: false, shift: false },
    help: { topic: "move-caret", action: "Next block (caret at end)" } },
  { command: "stepUp", chord: { key: "ArrowUp", mod: false, alt: false, shift: false },
    help: { topic: "move-caret", action: "Previous block (caret on first line)" } },
  { command: "stepDown", chord: { key: "ArrowDown", mod: false, alt: false, shift: false },
    help: { topic: "move-caret", action: "Next block (caret on last line)" } },
];

// The second key after the date leader (⌘;).
export type ArborLeaderCommand = "insertToday" | "insertTodayWithCalendar" | "cancelLeader";

export const ARBOR_LEADER_BINDINGS: readonly ArborBinding<ArborLeaderCommand>[] = [
  { command: "insertToday", chord: { key: ".", mod: false, alt: false },
    help: { topic: "dates", action: "After ⌘ ;, insert today" } },
  { command: "insertTodayWithCalendar", chord: { key: "d", mod: false, alt: false },
    help: { topic: "dates", action: "After ⌘ ;, insert today and open the calendar" } },
  { command: "cancelLeader", chord: { key: "Escape" }, hidden: true },
];

// While the completion list ([[, ((, #, /) is open.
export type ArborCompletionCommand = "next" | "previous" | "accept" | "dismiss";

export const ARBOR_COMPLETION_BINDINGS: readonly ArborBinding<ArborCompletionCommand>[] = [
  { command: "next", chord: { key: "ArrowDown" }, help: { topic: "links", action: "Next suggestion (list open)" } },
  { command: "previous", chord: { key: "ArrowUp" }, help: { topic: "links", action: "Previous suggestion (list open)" } },
  { command: "accept", chord: { key: "Enter" }, help: { topic: "links", action: "Insert suggestion (list open)" } },
  { command: "dismiss", chord: { key: "Escape" }, help: { topic: "links", action: "Dismiss list" } },
];

// With whole blocks selected and focus on the outline rather than inside a block.
export type ArborSelectionCommand =
  | "redo" | "undo" | "copy" | "cut" | "delete" | "outdent" | "indent"
  | "moveUp" | "moveDown" | "clear" | "extendUp" | "extendDown";

export const ARBOR_SELECTION_BINDINGS: readonly ArborBinding<ArborSelectionCommand>[] = [
  { command: "redo", chord: { key: "z", mod: true, shift: true }, hidden: true },
  { command: "undo", chord: { key: "z", mod: true }, hidden: true },
  { command: "copy", chord: { key: "c", mod: true }, help: { topic: "act-on-selection", action: "Copy selected blocks" } },
  { command: "cut", chord: { key: "x", mod: true }, help: { topic: "act-on-selection", action: "Cut selected blocks" } },
  { command: "delete", chord: { key: "Backspace" }, help: { topic: "act-on-selection", action: "Delete selected blocks" } },
  { command: "delete", chord: { key: "Delete" }, help: { topic: "act-on-selection", action: "Delete selected blocks" } },
  { command: "outdent", chord: { key: "Tab", shift: true }, help: { topic: "act-on-selection", action: "Outdent selection" } },
  { command: "indent", chord: { key: "Tab", shift: false }, help: { topic: "act-on-selection", action: "Indent selection" } },
  { command: "moveUp", chord: { key: "ArrowUp", alt: true }, help: { topic: "act-on-selection", action: "Move selection up" } },
  { command: "moveDown", chord: { key: "ArrowDown", alt: true }, help: { topic: "act-on-selection", action: "Move selection down" } },
  { command: "clear", chord: { key: "Escape" }, help: { topic: "act-on-selection", action: "Clear selection" } },
  { command: "extendUp", chord: { key: "ArrowUp", shift: true }, help: { topic: "select-blocks", action: "Extend the range up" } },
  { command: "extendDown", chord: { key: "ArrowDown", shift: true }, help: { topic: "select-blocks", action: "Extend the range down" } },
];

const ALL_BINDINGS: readonly ArborBinding<string>[] = [
  ...ARBOR_EDITOR_BINDINGS, ...ARBOR_LEADER_BINDINGS, ...ARBOR_COMPLETION_BINDINGS, ...ARBOR_SELECTION_BINDINGS,
];

export function arborBindings(): readonly ArborBinding<string>[] {
  return ALL_BINDINGS;
}

/** Documented key rows for one help topic, in table order. */
export function arborShortcutsForTopic(topic: string): { keys: string; action: string }[] {
  return ALL_BINDINGS.flatMap((binding) => binding.help?.topic === topic
    ? [{ keys: formatChord(binding.chord), action: binding.help.action }]
    : []);
}
