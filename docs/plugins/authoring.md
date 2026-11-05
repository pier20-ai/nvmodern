# Writing nvModern plugins

A plugin is one JavaScript file that teaches nvModern a new command. Captures,
templates, global hotkeys and small workflows all live in plugins; the app
supplies the panels, pickers and file access they need.

This guide is for plugin authors. For how the host works inside the app, read
`docs/architecture/plugins.md`. The exact API is `NVModern/Plugins/nv.d.ts`;
when this guide and the type definitions disagree, the definitions win.

## Your first plugin

1. Open the plugins folder: Settings > Plugins > Open Plugins Folder, or
   `~/.config/nvmodern/plugins/` (it sits next to `config.toml`).
2. Create `hello.js`:

   ```js
   nv.actions.register({
     id: "greet",
     title: "Say hello",
     palette: { category: "Create", icon: "hand.wave" },
     async run() {
       const name = await nv.ui.prompt({ placeholder: "Your name" });
       if (name) await nv.ui.notify(`Hello, ${name}`);
     },
   });
   ```

3. Save. nvModern reloads plugins and their shortcuts on save; no restart.
   Plugin saves leave the action socket and open editors' contexts alone.
4. Press `Cmd+Shift+K`, type `hello`, press Return.

If nothing appears, run `nv3 action app.plugins.list` in a terminal: it lists
loaded plugins and any load errors with line numbers.

For type checking and autocompletion in your editor, add two lines at the top
of the file:

```js
// @ts-check
/// <reference path="/path/to/nvmodern/NVModern/Plugins/nv.d.ts" />
```

## How a plugin is shaped

- **One file, one plugin.** The file name is the plugin name: an action
  `id: "daily"` in `capture.js` becomes the method `plugin.capture.daily`.
- **Register at load, act later.** The file runs once when loaded. Its job
  then is to call `nv.actions.register`. Everything else happens inside a
  `run` function, when someone invokes the action.
- **Declare user preferences.** Use `nv.settings.define` for fields editable
  in Settings > Plugins. Behavior and shortcut declarations stay in the file.
- **No state across reloads.** Saving any plugin file reloads all of them in a
  fresh JavaScript context. Keep durable state in notes.
- **No ambient access.** There is no `require`, `fetch`, filesystem or shell.
  A plugin can only do what `nv` offers.

Each file has its own `nv` and `console`. `console.log` goes to the app log
with a `[NVModern][Plugin][<name>]` prefix.

## Actions

```js
nv.actions.register({
  id: "stream",                        // letters, digits, - _ .
  title: "Add to stream",
  summary: "Append a timestamped thought to the stream file.",
  palette: { category: "Capture", icon: "square.and.pencil", key: "s" },
  globalHotkey: "cmd+ctrl+opt+shift+s",
  keybinding: "cmd+shift+s",
  args: [{ name: "text", kind: "string", summary: "Text to append" }],
  async run({ args, source, now }) {
    const text = args.text ?? (await nv.ui.input({ placeholder: "Add to stream.." }));
    if (!text) return;
    await nv.files.append("~/notes/stream.md", `\n[${nv.date.format("MMM d, yyyy EEE HH:mm", now)}]\n${text}\n`);
    return { appended: true };
  },
});
```

An action is an ordinary nvModern action once registered. The same `run`
answers all of these:

| Trigger | How |
|---|---|
| Palette | `palette: { category }` lists it. `Capture` is what `Cmd+N` shows; the other categories appear under `Cmd+Shift+K`. `key` is a one-character accelerator, so `Cmd+N` `s` Return is a two-keystroke capture. |
| Global hotkey | `globalHotkey` works from any application, even with no nvModern window open. |
| In-app shortcut | `keybinding` works while an nvModern window is key. A `[[keybindings]]` row in `config.toml` for the same method overrides it. |
| Command line | `nv3 action plugin.stream.stream --json '{"text":"from a script"}'` |
| Other plugins | `nv.actions.invoke("plugin.stream.stream", { text })` |

`run` receives one context object:

- `args`: whatever the caller passed. Palette and hotkey runs pass none.
- `source.kind`: `keybinding`, `socket`, `automation`, `internal`, and so on.
  A global hotkey arrives as `keybinding` with identifier `global:<keys>`.
- `now`: the invocation time. Prefer it to `new Date()`.

A returned value becomes the action's result (visible to `nv3 action` and to
`nv.actions.invoke`). A thrown error or rejected promise fails the action: the
app beeps and logs the message.

### Palette details

- `category`: `Capture`, `Create`, `Open`, `File`, `Document`, `Format`,
  `Window`, `Chat` or `Appearance`.
- `when`: hide the row unless an expression over the workspace holds, for
  example `activeDocument.kind == "workspaceNote"` or
  `activeEditor.surface == "text" && activeEditor.isEditable`.
- `nounArguments`: `{ note: "path" }` lists the action in a note's verbs
  frame (`Cmd+K`, pick a note, Tab) and passes that note's path as
  `args.path`. Default to the active document when it is absent, so plain
  invocation still works.
- `rank`: lower sorts first within the category. Default 100.

## Settings

Declare fields once, synchronously, while your file loads. `define` throws if
called again or from an action. `get()` is synchronous and returns a fresh
snapshot; read it inside `run` so the contract is clear.

```js
nv.settings.define([
  { key: "folder", title: "Daily folder", kind: "folder", default: "Daily" },
  { key: "label", title: "Label", kind: "text", default: "Daily" },
  { key: "openInNewTab", title: "Open in new tab", kind: "bool", default: false },
  { key: "limit", title: "Recent entries", kind: "number", default: 10 },
  { key: "style", title: "Timestamp", kind: "choice", options: ["org", "iso"], default: "org" },
]);

nv.actions.register({
  id: "daily", title: "Daily note", palette: { category: "Create" },
  async run({ now }) {
    const settings = nv.settings.get();
    const extension = settings.style === "org" ? "org" : "md";
    return nv.actions.invoke("workspace.note.create", {
      folder: settings.folder,
      fileName: `${nv.date.format("yyyy-MM-dd", now)}.${extension}`,
      body: String(settings.label), open: true,
      openIn: settings.openInNewTab ? "newTab" : "currentTab",
    });
  },
});
```

Kinds are `text`, `bool`, `number` (finite), `choice` (unique string options),
and `folder` (workspace-relative). Keys must be unique and defaults must match
the kind. Folder settings use the action's workspace, like other relative file
references; the Settings picker chooses within the default workspace and stores
a relative path. Use an explicit named project in your action when necessary.

Values live under `[plugins.settings.<name>]` in `config.toml`. Every UI change
writes immediately and reloads plugins and shortcuts. External disk edits update
the UI live too. There is no plugin-side `set` method. Invalid stored values
use declared defaults without destroying the original value. Unknown keys and
settings for missing/disabled plugins are preserved. Disabling a plugin stops
its actions and hotkeys without deleting its file. Disabled files never execute
to discover settings; enable one to see its form.

## Calling built-in actions

`nv.actions.invoke(method, args)` runs any registered action. The built-in
catalog in `docs/architecture/action-system.md` is part of the plugin API.
The ones plugins reach for most:

| Method | Use |
|---|---|
| `workspace.note.create` | `{ folder, fileName, body, open, openIn }` — creates a note through the workspace, so the index updates at once |
| `workspace.note.open` | `{ relativePath, openIn }` |
| `workspace.note.current` | the selected tab's document |
| `workspace.editor.selection.get` / `.replace` | read or replace the editor selection |
| `workspace.search.query` | `{ query }` full-text search |
| `workspace.note.refile` | `{ path, folder }` |

`nv.workspace` wraps the common ones with typed results: `project()`,
`projects()`, `open(file)`, `activeDocument()`, `selection()`,
`replaceSelection(text)`.

## Asking the user

| Call | Looks like | Works without a window |
|---|---|---|
| `nv.ui.input(options)` | Floating glass text box | Yes |
| `nv.ui.panel(file)` | Floating editor on one file | Yes |
| `nv.ui.window(file, options)` | Persistent single-file window; resolves on open | Yes |
| `nv.ui.pick(items)` | Palette list of your rows | No |
| `nv.ui.prompt()` | One line typed in the palette | No |
| `nv.ui.pickNote()` / `pickFolder()` | Palette note or folder search | No |
| `nv.ui.confirm(message)` | Alert | Yes |
| `nv.ui.notify(message)` | System notification banner | Yes |

Every one of these returns a promise. Dismissal resolves `null` (or `false`
for `confirm`), never rejects, so a plugin reads naturally:

```js
const text = await nv.ui.input({ placeholder: "Thought" });
if (!text) return;
```

Useful `input` options:

- `submitKey: "return"` makes it a one-line box (Shift+Return for a newline).
  The default is `cmd+return`, which leaves Return free for multi-line text
  with list continuation.
- `onDismiss: "submit"` saves what was typed when the panel is dismissed by
  Escape or a click elsewhere. Use it for captures, where losing a half-typed
  thought is worse than saving it.
- `id` makes the hotkey a toggle: a second press closes the panel instead of
  stacking another.

The palette pickers bring nvModern forward and need a workspace window; they
reject when none is open. Use `input` for anything that must work from
another application.

## Files

Every `nv.files` call takes a `FileRef`:

| Form | Resolves to |
|---|---|
| `"/abs/path.md"`, `"~/notes/log.md"` | That path |
| `"Inbox/today.md"` | Relative to the frontmost window's project (or the default root when no window is open) |
| `{ project: "Personal Notes", path: "org/daily.org" }` | Relative to a named `[[projects]]` entry, whatever window is in front |

A relative path cannot leave its project.

- `read(file)` returns the text, or `null` when the file does not exist.
- `write(file, text)` replaces the file, creating folders as needed.
- `append(file, text)` adds to the end, in place.
- `edit(file, text => newText)` reads, transforms and writes in one step. Return
  the same text, `null` or `undefined` to leave the file alone. This is the
  right call for changing an existing note.
- `exists(file)` and `resolve(file)` (synchronous, returns the absolute path).

Writes land on disk as external changes. If the file is open in a tab, live
sync reloads the tab, or flags a conflict when that tab has unsaved edits.

Creating a note the workspace should know about immediately is better done
through `workspace.note.create`, which also opens it.

## Dates

`nv.date.format(pattern, date?)` uses Unicode date patterns with a fixed
`en_US_POSIX` locale and the system time zone, so output is stable:

| Pattern | Example |
|---|---|
| `yyyy-MM-dd` | `2026-10-03` |
| `HH:mm` | `14:22` |
| `[yyyy-MM-dd EEE HH:mm]` | `[2026-10-03 Sat 14:22]` |
| `MMM d, yyyy EEE HH:mm` | `Oct 3, 2026 Sat 14:22` |
| `yyyy-MM MMMM` | `2026-10 October` |

Quote literal letters with single quotes: `'week' w`.

## Patterns

### A capture with a template

```js
const TEMPLATES = "50-System/57-Templates";

async function render(name, now) {
  const template = await nv.files.read(`${TEMPLATES}/${name}`);
  if (template === null) throw new Error(`Template ${name} not found`);
  return template
    .replaceAll("{{date}}", nv.date.format("yyyy-MM-dd", now))
    .replaceAll("{{clipboard}}", (await nv.clipboard.read()) ?? "");
}

nv.actions.register({
  id: "daily",
  title: "Daily",
  palette: { category: "Capture", icon: "calendar", key: "d" },
  async run({ now }) {
    const fileName = `${nv.date.format("yyyy-MM-dd", now)}.md`;
    const relativePath = `Daily/${fileName}`;
    if (await nv.files.exists(relativePath)) {
      return nv.actions.invoke("workspace.note.open", { relativePath, openIn: "currentTab" });
    }
    return nv.actions.invoke("workspace.note.create", {
      folder: "Daily", fileName, body: await render("_daily.md", now), open: true, openIn: "currentTab",
    });
  },
});
```

### Filing under a heading (org datetree)

`NVModern/Plugins/examples/org-capture.js` is a complete example: it finds or
creates the year, month and day headings in an org file and appends a
timestamped entry under today. The structure logic is plain string code in
the plugin; the host only provides `nv.files.edit`.

### A verb on the current note

```js
nv.actions.register({
  id: "wordcount",
  title: "Word count",
  palette: { category: "Document", icon: "number", when: "activeDocument", nounArguments: { note: "path" } },
  async run({ args }) {
    const path = args.path ?? (await nv.workspace.activeDocument())?.relativePath;
    if (!path) return;
    const text = (await nv.files.read(path)) ?? "";
    await nv.ui.notify(`${text.split(/\s+/).filter(Boolean).length} words`, { title: path });
  },
});
```

### Capturing from outside nvModern

Any plugin action is callable over the socket, so a browser bookmarklet, an
Alfred workflow or a shell script can feed it:

```sh
nv3 action plugin.clip.web --json '{"url":"https://…","title":"…","selection":"…"}'
```

Declare the arguments in `args` so `nv3 action app.actions.describe` documents
them, and read them from `args` in `run`.

### Feedback

For a capture that runs with no window in front, `nv.ui.notify("Added to
stream")` is the way to say it worked. Throwing an error is the way to say it
did not: a global-hotkey invocation beeps and requests a notification with the
action title and error. Every action failure is also logged.

## Debugging

- A syntax error or exception during loading requests a "Plugin failed to
  load" banner naming the file and line. The same error is suppressed on
  subsequent reloads; fixing it is silent, and a later recurrence alerts again.
- Global-hotkey action failures request a banner with the action title and
  error, limited to one per action every ten seconds. These banners require
  macOS notification authorization for nvModern; when delivery is unavailable,
  errors remain in the log.
- `nv3 action app.plugins.list` — loaded plugins, load errors with line
  numbers, plugin global hotkeys.
- `nv3 action app.actions.list --prefix plugin.` — every registered plugin
  action.
- `nv3 action plugin.<file>.<id>` — run an action and see its result or error
  as JSON.
- Each run logs an `action.finished` breadcrumb with its duration to the
  local diagnostics file (the path is printed at launch).
- `console.log` output and plugin load errors go to the app's stdout; run the
  debug build from a terminal to see them live.

## Gotchas

- Two plugins cannot share a file name. A user plugin with the same name as
  a built-in replaces it.
- Registering the same `id` twice in one file keeps the last registration.
- `run` can be `async`; the action is not finished until the promise settles.
  A hotkey pressed while an `input` from the same action is open toggles it
  closed only if the call passed an `id`.
- Reloading while a panel is open closes the panel; a capture typed into it
  is still delivered to the old plugin code, which finishes its write.
- A plugin's `keybinding` applies only while nvModern is frontmost. For
  system-wide keys use `globalHotkey`. Modifier names are `cmd`, `shift`,
  `opt`/`alt`, `ctrl`.

## Persistent document windows

Use `nv.ui.window(file, options)` for a scratchpad with native traffic lights
and a resizable editor, without workspace chrome or a palette:

```js
nv.actions.register({
  id: "scratchpad",
  title: "Open scratchpad",
  globalHotkey: "cmd+ctrl+space",
  run: () => nv.ui.window({ project: "Notes", path: "scratchpad.md" }, {
    alwaysOnTop: true,
    allSpaces: false,
    size: { width: 420, height: 340 },
    cursor: "end",
  }),
});
```

The promise resolves on presentation and rejects on project or file errors.
Missing files are created. The resolved file identifies the window: another
call focuses it without resetting the caret, scroll or undo history. Repeated
calls apply the window level and Spaces options; size and cursor apply only
when creating the window. A remembered frame takes precedence over size.
The filename supplies the title; there is no separate `id` or title option.

Set `position: "right"` to align the window with the usable top-right corner
of the screen containing the pointer. For exact placement, use
`position: { x: 100, y: 50 }` with `size: { width: 420, height: 340 }`.
Coordinates are screen points measured from that screen's usable top-left;
the outer frame is clamped to the usable bounds. An explicit position applies
on open and reuse and overrides the remembered location. Without it, the
remembered frame is used as before.

Set `toggle: true` to close the window if this file is already open, or open
it otherwise. Closing uses the normal save and conflict checks; canceling a
conflict dialog leaves the window open. The promise resolves after the close
attempt, including a canceled close. For example, a Hyper+T scratchpad:

```js
nv.actions.register({
  id: "toggle-scratchpad",
  title: "Toggle scratchpad",
  globalHotkey: "cmd+ctrl+opt+shift+t",
  run: () => nv.ui.window({ project: "Notes", path: "scratchpad.md" }, {
    toggle: true,
    alwaysOnTop: true,
    size: { width: 420, height: 340 },
  }),
});
```

Clicking another app and reloading plugins leave the window open. `Cmd+W` or
the red button closes it; Escape stays with the editor. `alwaysOnTop` keeps
it above ordinary windows while nvModern is inactive; `allSpaces` separately
makes it visible on every Space. Content size must be at least 240×160.

The editor autosaves and watches the file for external changes. Clean buffers
reload; external changes while local edits are pending block saving and closing
so neither version is overwritten. Closing or quitting with a conflict opens a
native alert: Keep Editing cancels the close, Reload from Disk discards local
edits, and Overwrite with My Changes explicitly replaces the disk version.
Failed recovery or saving keeps the window open with its buffer and reports
the error. This version remembers each file's window frame but does not reopen
scratchpads after relaunch.
