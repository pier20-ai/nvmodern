/**
 * nvModern plugin API — design contract.
 *
 * A plugin is one plain JavaScript file in `~/.config/nvmodern/plugins/`
 * (or bundled with the app). The app evaluates each file once, inside its own
 * function scope, in a shared JavaScriptCore context. The file's job at load
 * time is to call `nv.actions.register(...)`; everything else happens later,
 * when one of those actions runs.
 *
 * This file is for authoring and review. JavaScriptCore never reads it. Use it
 * from a plugin with:
 *
 *     // @ts-check
 *     /// <reference path="./nv.d.ts" />
 *
 * Ground rules
 * - A plugin action is an ordinary action. It lands in `ActionRegistry` as
 *   `plugin.<file name>.<id>`, so the palette, `[[keybindings]]`, the socket
 *   and `nv3 action` reach it exactly as they reach a built-in.
 * - A plugin can only touch what `nv` exposes. There is no `require`, no
 *   `fetch`, no filesystem or process access outside this API.
 * - Everything that reaches the host returns a Promise. Pure helpers
 *   (`nv.date.format`, `nv.files.resolve`) are synchronous.
 * - Plugins hold no state across reloads. Saving a plugin file tears down
 *   every plugin (actions, hotkeys, transient plugin surfaces) and evaluates them
 *   all again in a fresh context. Persistent document windows stay open.
 *
 * Deliberately not in v1: event hooks (`onSave`, `onOpen`), persistent
 * storage, network, editor-side extensions (CodeMirror), custom views.
 *
 * Type-checks against `"lib": ["es2022"]` with no DOM lib.
 */

declare const nv: NV.API;

/** Routed to the app log with a `[NVModern][Plugin][<name>]` prefix. */
declare const console: {
  log(...values: unknown[]): void;
  warn(...values: unknown[]): void;
  error(...values: unknown[]): void;
};

declare function setTimeout(callback: () => void, milliseconds?: number): number;
declare function clearTimeout(handle: number): void;

declare namespace NV {
  interface API {
    /** The plugin this file was loaded as. */
    readonly plugin: PluginInfo;
    readonly actions: Actions;
    readonly ui: UI;
    readonly files: Files;
    readonly workspace: Workspace;
    readonly clipboard: Clipboard;
    readonly date: DateTools;
    readonly settings: Settings;
  }

  interface PluginInfo {
    /** File name without extension; the middle part of every method name. */
    readonly name: string;
    /** Absolute path of the plugin file. */
    readonly path: string;
    /** Bundled with the app rather than loaded from the user's folder. */
    readonly isBuiltin: boolean;
  }

  // ───────────────────────────── values ─────────────────────────────

  /** What crosses the bridge: the same tree as Swift's `ActionValue`. */
  type JSONValue =
    | null
    | boolean
    | number
    | string
    | JSONValue[]
    | { [key: string]: JSONValue };

  type JSONObject = { [key: string]: JSONValue };

  // ───────────────────────────── actions ─────────────────────────────

  interface Actions {
    /**
     * Register an action. Call at load time. Registering the same `id` twice
     * in one plugin replaces the earlier registration.
     */
    register<Args extends JSONObject = JSONObject>(spec: ActionSpec<Args>): void;

    /**
     * Run any registered action — built-in (`workspace.note.open`) or plugin
     * (`user.<id>`), or plugin (`plugin.<name>.<id>`). Rejects with an
     * `ActionFailure` when the action fails. This is the general escape
     * hatch: the built-in catalog in `docs/architecture/action-system.md` is
     * part of the plugin API.
     */
    invoke<Result extends JSONValue = JSONValue>(
      method: string,
      args?: JSONObject
    ): Promise<Result>;
  }

  type SettingField = { key: string; title: string } & (
    | { kind: "text" | "folder"; default: string }
    | { kind: "bool"; default: boolean }
    | { kind: "number"; default: number }
    | { kind: "choice"; default: string; options: string[] }
  );

  interface Settings {
    /** Declare fields once, synchronously during load. */
    define(fields: SettingField[]): void;
    /** Snapshot of stored overrides over defaults. Invalid known values use defaults. */
    get<T extends JSONObject = JSONObject>(): T;
  }

  interface ActionSpec<Args extends JSONObject = JSONObject> {
    /** Unique within the plugin. Method name is `plugin.<plugin>.<id>`. */
    id: string;
    title: string;
    /** One sentence; shown by `app.actions.describe` and MCP-style clients. */
    summary?: string;

    /**
     * Palette row. Omit to keep the action out of the palette while leaving
     * it reachable by hotkey, keybinding, socket and `nv.actions.invoke`.
     */
    palette?: PalettePresentation;

    /**
     * System-wide hotkey, live even when nvModern is in the background.
     * Same syntax as `[[keybindings]]`: `cmd+ctrl+opt+shift+s`.
     */
    globalHotkey?: string;

    /**
     * In-app shortcut, live while an nvModern workspace window is key. A
     * `[[keybindings]]` row in config.toml targeting the method overrides it.
     */
    keybinding?: string;

    /** Declared arguments, for callers that pass them (socket, keybindings). */
    args?: ArgumentSpec[];

    /**
     * The handler. A returned value is the action's result; a thrown error or
     * rejected promise fails the action, beeps, and is logged.
     */
    run(context: ActionContext<Args>): JSONValue | void | Promise<JSONValue | void>;
  }

  interface ActionContext<Args extends JSONObject = JSONObject> {
    args: Partial<Args>;
    /**
     * Who invoked the action. A global hotkey arrives as `keybinding` with
     * the identifier `global:<keystroke>`.
     */
    source: {
      kind: "internal" | "keybinding" | "menu" | "socket" | "webBridge" | "automation" | "test";
      identifier: string | null;
    };
    /** Invocation time. Use this rather than `new Date()` so runs are testable. */
    now: Date;
  }

  /** Mirrors Swift's `ActionPalettePresentation`. */
  interface PalettePresentation {
    /**
     * Section the row lives in. `Capture` is what `Cmd+N` lists; the others
     * are the existing verb categories.
     */
    category:
      | "Capture"
      | "Create"
      | "Open"
      | "File"
      | "Document"
      | "Format"
      | "Window"
      | "Appearance";
    /** SF Symbol name. */
    icon?: string;
    /**
     * One-character accelerator. Typing it in the row's category frame ranks
     * this row first, so `Cmd+N` `n` `⏎` behaves like a chord.
     */
    key?: string;
    /** Extra search terms. */
    keywords?: string[];
    /** Lower sorts first within the category when the query is empty. Default 100. */
    rank?: number;
    /**
     * Availability expression over the automation context, same grammar as
     * built-ins: `activeDocument.kind == "workspaceNote"`.
     */
    when?: string;
    /**
     * Bind a palette noun to one of this action's arguments, which lists the
     * action in that noun's verbs frame: `{ note: "path" }`.
     */
    nounArguments?: Partial<Record<"note" | "folder" | "passage", string>>;
  }

  interface ArgumentSpec {
    name: string;
    summary?: string;
    kind: "string" | "int" | "double" | "bool" | "array" | "object";
    required?: boolean;
  }

  /** Rejection value of `nv.actions.invoke`. Mirrors Swift's `ActionError`. */
  interface ActionFailure extends Error {
    code: string;
    details: JSONObject;
  }

  // ─────────────────────────────── ui ───────────────────────────────

  interface UI {
    /**
     * The floating glass text panel.
     * Resolves with the entered text, or `null` when nothing was entered or
     * the panel was cancelled. Leading and trailing blank lines are trimmed.
     *
     * Works with no workspace window open and with nvModern in the
     * background; it does not bring the app's windows forward.
     */
    input(options?: InputOptions): Promise<string | null>;

    /**
     * The floating editor panel: the real
     * editor on one file, autosaving. Creates the file when it is missing.
     * Resolves when the panel closes.
     */
    panel(file: FileRef, options?: PanelOptions): Promise<void>;

    /**
     * Persistent, resizable single-document window with native traffic lights.
     * Creates a missing file. Resolves on open; rejects on file/project errors.
     * Reuses the window for the resolved file, preserving cursor and undo.
     * With toggle, resolves after the close attempt, even if the user cancels.
     * Stays open on focus loss and plugin reload; no workspace chrome/palette.
     */
    window(file: FileRef, options?: WindowOptions): Promise<void>;

    /**
     * A palette list of the given rows. Resolves with the chosen row's
     * `value`, or `null` when dismissed. Typing filters by title, `key` and
     * `keywords`.
     *
     * This and the other palette pickers (`prompt`, `pickNote`,
     * `pickFolder`) open in the frontmost workspace window and bring
     * nvModern forward. They reject when no workspace window is open; use
     * `input` for something that must work from any app.
     */
    pick<Value extends JSONValue>(
      items: PickItem<Value>[],
      options?: PickOptions
    ): Promise<Value | null>;

    /**
     * One line of text, typed into the palette. Resolves with the text, or
     * `null` when dismissed or left empty. For a name or a title; `input` is
     * the place for a thought.
     */
    prompt(options?: PromptOptions): Promise<string | null>;

    /**
     * Pick a note in the frontmost window's project: recent notes first, then
     * a ranked search as you type. Resolves with its project-relative path.
     */
    pickNote(options?: PickOptions): Promise<string | null>;

    /**
     * Pick a folder in the frontmost window's project. Resolves with its
     * project-relative path; the project root is `""`.
     */
    pickFolder(options?: PickOptions): Promise<string | null>;

    /** A yes/no alert. Resolves `true` only for the confirm button. */
    confirm(message: string, options?: ConfirmOptions): Promise<boolean>;

    /**
     * A system notification banner — feedback for something that finished
     * with no window to show it in ("Added to stream"). Rejects when
     * notifications are turned off for nvModern.
     */
    notify(message: string, options?: { title?: string }): Promise<void>;
  }

  interface InputOptions {
    placeholder?: string;
    /** Pre-filled text, caret at the end. */
    initialText?: string;
    /**
     * Which key submits. `cmd+return` (default) leaves
     * Return free for multi-line text and list continuation; `return` makes
     * it a one-line box, with Shift+Return for a newline.
     */
    submitKey?: "cmd+return" | "return";
    /**
     * What Escape or clicking away does with typed text. `submit`
     * resolves with it, so a half-typed thought is never lost;
     * `cancel` resolves `null`. Default `cancel`.
     */
    onDismiss?: "submit" | "cancel";
    /**
     * Toggle identity. If an input with the same `id` is already showing,
     * this call dismisses it and resolves `null` — pressing the hotkey a
     * second time closes the panel instead of stacking another.
     */
    id?: string;
  }

  interface PanelOptions {
    /** Where the caret starts. Default `end`. */
    cursor?: "start" | "end";
    /** Toggle identity; see `InputOptions.id`. Defaults to the resolved file path. */
    id?: string;
  }

  interface WindowOptions {
    /** Close an existing window for this file using normal save/conflict checks. Default false. */
    toggle?: boolean;
    /** Stays above normal windows, even in other apps. Default false. */
    alwaysOnTop?: boolean;
    /** Visible on every Space. Independent of alwaysOnTop. Default false. */
    allSpaces?: boolean;
    /** Initial content size. Remembered frame takes precedence on reopening. */
    size?: { width: number; height: number };
    /** Position on the screen containing the pointer; x/y are points from its usable top-left.
     * "right" aligns the outer frame to its top-right. Overrides remembered location;
     * applied on open/reuse and clamped to the usable screen bounds. */
    position?: "right" | { x: number; y: number };
    /** Initial caret position. Reuse preserves the existing caret. Default end. */
    cursor?: "start" | "end";
  }

  interface PickItem<Value extends JSONValue> {
    title: string;
    subtitle?: string;
    /** SF Symbol name. */
    icon?: string;
    /** One-character accelerator, ranked first when typed. */
    key?: string;
    keywords?: string[];
    value: Value;
  }

  interface PickOptions {
    placeholder?: string;
  }

  interface PromptOptions {
    placeholder?: string;
    /** Pre-filled text. */
    initialText?: string;
  }

  interface ConfirmOptions {
    /** Smaller text under the message. */
    detail?: string;
    /** Default `OK`. */
    confirmLabel?: string;
    /** Default `Cancel`. */
    cancelLabel?: string;
    /** Style the confirm button as destructive. */
    destructive?: boolean;
  }

  // ────────────────────────────── files ──────────────────────────────

  /**
   * Where a text file lives.
   * - `"/abs/path.md"` or `"~/notes/log.md"` — anywhere on disk.
   * - `"Inbox/today.md"` — relative to the active project: the frontmost
   *   workspace window's, else the default root in config.toml.
   * - `{ project: "Personal Notes", path: "org/daily.org" }` — relative to a
   *   named `[[projects]]` entry, whatever window is frontmost.
   */
  type FileRef = string | { project: string; path: string };

  interface Files {
    /** Absolute path for a `FileRef`. Throws for an unknown project name. */
    resolve(file: FileRef): string;

    exists(file: FileRef): Promise<boolean>;

    /** File text as UTF-8, or `null` when the file does not exist. */
    read(file: FileRef): Promise<string | null>;

    /** Replace the whole file, creating it and its parent folders as needed. */
    write(file: FileRef, text: string): Promise<void>;

    /**
     * Read-modify-write in one step. `transform` receives the current text
     * (`""` for a missing file) and returns the new text; returning the same
     * text, `null` or `undefined` writes nothing. Resolves with whether the
     * file changed.
     *
     * This is the one way a plugin should change an existing note. The read,
     * the transform and the atomic replace happen in one turn of the main
     * thread, so nothing else in the app writes in between. The write lands
     * on disk as an external change: live sync reloads a tab that has the
     * file open, or flags a conflict when that tab has unsaved edits.
     */
    edit(
      file: FileRef,
      transform: (text: string) => string | null | undefined
    ): Promise<boolean>;

    /**
     * Add `text` at the end, creating the file and its parent folders as
     * needed. Appends in place rather than replacing the file.
     */
    append(file: FileRef, text: string): Promise<void>;
  }

  // ──────────────────────────── workspace ────────────────────────────
  //
  // Typed sugar over built-in actions. Anything missing here is one
  // `nv.actions.invoke` away.

  interface Workspace {
    /** The frontmost workspace window's project. `workspace.project.current`. */
    project(): Promise<Project | null>;

    /** Every configured project. `workspace.projects.list`. */
    projects(): Promise<Project[]>;

    /**
     * Open a file in a workspace tab, bringing the window forward. A file
     * inside a configured project opens in that project's window.
     */
    open(file: FileRef, options?: OpenOptions): Promise<void>;

    /** The selected tab's document, or `null` on a launchpad tab. `workspace.note.current`. */
    activeDocument(): Promise<DocumentInfo | null>;

    /** The active editor's selection. `workspace.editor.selection.get`. */
    selection(): Promise<Selection | null>;

    /** Replace the selection, or insert at the caret. `workspace.editor.selection.replace`. */
    replaceSelection(text: string): Promise<void>;
  }

  interface Project {
    name: string;
    rootPath: string;
  }

  interface OpenOptions {
    /** Default `currentTab`. */
    in?: "currentTab" | "newTab";
  }

  interface DocumentInfo {
    title: string;
    /** Absolute path, when the document is a file. */
    path: string | null;
    /** Project-relative path, when the document is a workspace note. */
    relativePath: string | null;
    kind: string;
  }

  interface Selection {
    text: string;
    empty: boolean;
  }

  // ──────────────────────── clipboard and dates ────────────────────────

  interface Clipboard {
    /** Plain text on the general pasteboard, or `null`. */
    read(): Promise<string | null>;
    write(text: string): Promise<void>;
  }

  interface DateTools {
    /**
     * Format with a Unicode date pattern (`DateFormatter` syntax):
     * `yyyy-MM-dd`, `HH:mm`, `[yyyy-MM-dd EEE HH:mm]`, `MMM d, yyyy`.
     * Quote literal letters with single quotes. `date` defaults to now.
     * Uses the `en_US_POSIX` locale and the system time zone unless
     * `locale` says otherwise, so output is stable across machines.
     */
    format(pattern: string, date?: Date, options?: { locale?: string }): string;
  }
}
