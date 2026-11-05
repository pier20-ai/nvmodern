import { describe, expect, it } from "bun:test";
import {
  ARBOR_EDITOR_BINDINGS, ARBOR_SELECTION_BINDINGS, ARBOR_COMPLETION_BINDINGS, ARBOR_LEADER_BINDINGS,
  arborBindings, arborShortcutsForTopic, dispatchKey, formatChord, type ArborKeyEvent,
} from "./keymap.ts";
import { createArborHelpProvider } from "./help.ts";

function key(key: string, mods: Partial<ArborKeyEvent> = {}): ArborKeyEvent {
  return { key, code: "", metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...mods };
}
function commandFor<C extends string>(bindings: Parameters<typeof dispatchKey<C>>[0], event: ArborKeyEvent): C | undefined {
  let found: C | undefined;
  dispatchKey(bindings, event, (command) => { found = command; return true; });
  return found;
}

describe("arbor keymap dispatch", () => {
  it("resolves editor chords in priority order", () => {
    const editor = (e: ArborKeyEvent) => commandFor(ARBOR_EDITOR_BINDINGS, e);
    expect(editor(key("Enter"))).toBe("split");
    expect(editor(key("Enter", { shiftKey: true }))).toBe("newline");
    expect(editor(key("Enter", { metaKey: true }))).toBe("runRefresh");
    expect(editor(key("Enter", { ctrlKey: true, shiftKey: true }))).toBe("runAppend");
    expect(editor(key("Tab"))).toBe("indent");
    expect(editor(key("Tab", { shiftKey: true }))).toBe("outdent");
    expect(editor(key("z", { metaKey: true }))).toBe("undo");
    expect(editor(key("Z", { metaKey: true, shiftKey: true }))).toBe("redo");
    expect(editor(key("b", { metaKey: true }))).toBe("bold");
    expect(editor(key("b", { metaKey: true, shiftKey: true }))).toBeUndefined();
    expect(editor(key("ArrowUp", { altKey: true }))).toBe("moveUp");
    expect(editor(key("ArrowDown", { shiftKey: true }))).toBe("extendDown");
    expect(editor(key("ArrowLeft"))).toBe("stepLeft");
    expect(editor(key("ArrowLeft", { metaKey: true }))).toBeUndefined();
    expect(editor({ ...key(";"), code: "Semicolon", metaKey: true })).toBe("dateLeader");
    expect(editor({ ...key(";"), code: "Semicolon", metaKey: true, shiftKey: true })).toBeUndefined();
  });
  it("falls through when a command declines, as ⌘Enter does without a producer", () => {
    const order: string[] = [];
    const handled = dispatchKey(ARBOR_EDITOR_BINDINGS, key("Enter", { metaKey: true }), (command) => {
      order.push(command);
      return command === "split";
    });
    expect(handled).toBe(true);
    expect(order).toEqual(["runRefresh", "split"]);
  });
  it("resolves leader, completion, and selection chords", () => {
    expect(commandFor(ARBOR_LEADER_BINDINGS, key("."))).toBe("insertToday");
    expect(commandFor(ARBOR_LEADER_BINDINGS, key("D", { shiftKey: true }))).toBe("insertTodayWithCalendar");
    expect(commandFor(ARBOR_LEADER_BINDINGS, key("d", { metaKey: true }))).toBeUndefined();
    expect(commandFor(ARBOR_COMPLETION_BINDINGS, key("ArrowDown"))).toBe("next");
    expect(commandFor(ARBOR_SELECTION_BINDINGS, key("Backspace"))).toBe("delete");
    expect(commandFor(ARBOR_SELECTION_BINDINGS, key("Delete"))).toBe("delete");
    expect(commandFor(ARBOR_SELECTION_BINDINGS, key("c", { ctrlKey: true }))).toBe("copy");
    expect(commandFor(ARBOR_SELECTION_BINDINGS, key("ArrowUp", { shiftKey: true }))).toBe("extendUp");
  });
});

describe("arbor keymap and help", () => {
  it("formats chords like macOS menus", () => {
    expect(formatChord({ key: "z", mod: true, shift: true })).toBe("⇧ ⌘ Z");
    expect(formatChord({ key: "ArrowUp", alt: true })).toBe("⌥ ↑");
    expect(formatChord({ code: "Semicolon", meta: true })).toBe("⌘ ;");
    expect(formatChord({ key: "Backspace" })).toBe("⌫");
  });
  it("documents every binding in an existing help topic, or marks it hidden", () => {
    const topics = new Set(createArborHelpProvider().topics.map((topic) => topic.id));
    for (const binding of arborBindings()) {
      if (binding.hidden) { expect(binding.help).toBeUndefined(); continue; }
      expect(binding.help).toBeDefined();
      expect(topics.has(binding.help!.topic)).toBe(true);
    }
  });
  it("generates topic shortcuts from the bindings", () => {
    expect(arborShortcutsForTopic("undo-redo").map((s) => s.keys)).toEqual(["⇧ ⌘ Z", "⌘ Z"]);
    const provider = createArborHelpProvider();
    const indent = provider.topics.find((topic) => topic.id === "indent-outdent")!;
    expect(indent.shortcuts).toEqual(arborShortcutsForTopic("indent-outdent"));
  });
});
