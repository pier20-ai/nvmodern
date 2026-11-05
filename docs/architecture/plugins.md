# Plugin system

nvModern's plugin system lets a plain JavaScript file add commands to the app.
Capture, templates, scratchpads and personal workflows are plugins; core owns
only the mechanisms they build on: an action registry, the floating panels,
the palette, safe file access, hotkeys.

This is the architecture reference. Plugin authors should start with
`docs/plugins/authoring.md`; the API contract is `NVModern/Plugins/nv.d.ts`.

## Design

**One behavioral extension point: actions.** A plugin adds commands by
registering actions. An action registered from JavaScript lands in `ActionRegistry` as
`plugin.<file>.<id>` with an ordinary `ActionDescriptor`, so the palette,
keybindings, the socket, `nv3` and other plugins reach it with no plugin-specific
code. There is no second catalog to keep in sync.

**Mechanism in core, policy in plugins.** Core knows how to show a glass text
panel, open the editor on a file, push a palette frame, write a file safely,
and register a Carbon hotkey. Which file a capture goes to, with what
timestamp, under which heading, is the plugin's business. The rule for growing
the API is: add a host primitive only when a plugin needs it.

**JavaScriptCore, in process.** JSC ships with macOS, needs no bundling, and
exposes no ambient capability: a plugin can only call what the host installs.
The cost is no process isolation; a plugin that spins forever blocks the main
thread like any other main-thread bug. For a single-user app that trade was
preferred over a subprocess protocol.

**Files declare behavior; Settings owns preferences.** A plugin may declare
fields through synchronous, load-only `nv.settings.define`. Enablement and
values live in `config.toml`; Settings > Plugins writes changes immediately.
Reload evaluates enabled files again with a fresh settings snapshot.

## Components

| File | Role |
|---|---|
| `NVModern/Plugins/nv.d.ts` | The API contract, in TypeScript. Read by authors and by `tsc`, never by the app. |
| `NVModern/Plugins/examples/*.js` | Reference plugins, type-checked against the contract (`make typecheck-plugins`). |
| `Core/Plugins/PluginHost.swift` | Owns the `JSContext`, loads files, installs the native `host` object, registers actions, bridges promises. |
| `Core/Plugins/PluginPrelude.swift` | JavaScript that shapes `host` into `nv` and gives each plugin its own `nv` and `console`. |
| `Core/Plugins/PluginFileAccess.swift` | `FileRef` resolution and the read/write/edit/append primitives. |
| `Core/Plugins/PluginHostEnvironment.swift` | Protocol for everything the host needs from the running app, plus the request structs for `input`, `panel`, pickers and `confirm`. |
| `Core/Plugins/PluginDirectoryWatcher.swift` | FSEvents watcher on the plugins folder, file-level so in-place saves count. |
| `App/PluginAppEnvironment.swift` | The app's implementation of the environment: panels, pickers, opening files, pasteboard, notifications. |
| `App/QuickCapturePanelController.swift` | The floating input and editor panels, run as sessions. |
| `UI/Palette/PluginPickCenter.swift` | Pending palette picks and their rows. |
| `NVModernTests/PluginHostTests.swift` | Host tests with a stub environment; the org-capture example is the end-to-end case. |

## Lifecycle

### Discovery

`AppDelegate.reloadPlugins(configURL:)` runs inside `reloadActionConfiguration`,
so plugins load at launch and again on every config reload. Sources are:

1. `<app bundle>/Contents/Resources/BuiltinPlugins/*.js` (none ship today);
2. `~/.config/nvmodern/plugins/*.js` (next to `config.toml`; subfolders are
   ignored).

`PluginHost.sources(inDirectory:isBuiltin:)` lists `*.js` in name order. A
user file replaces a built-in with the same name.

### Reload

`PluginHost.reload(sources:configuration:)`:

1. `unload()`: asks the environment to dismiss plugin-owned surfaces (panels,
   pending picks), unregisters every plugin method from the registry, drops
   the hotkey and keybinding lists, timers and the project cache, and
   releases the `JSContext`.
2. Creates a new `JSContext`, installs the `host` object, evaluates the
   prelude to get `makeAPI`.
3. Builds structured `PluginInfo` inventory from effective sources. User
   overrides win even when disabled. Disabled files are recorded without
   evaluation; sanitized-name collisions become structured load failures.
4. For each enabled source: reads the file, wraps it as
   `(function (nv, console) { "use strict"; <file> })` on one line so line
   numbers survive, evaluates it, and calls it with that plugin's `nv` and
   `console`. A throw at load records an error naming the file and line and
   drops any actions the file had registered before failing.

After `reload`, `AppDelegate` re-registers global hotkeys
(`PluginHost.globalHotkeys`) through `GlobalHotkeyManager`, merges plugin
keybindings behind configured `[[keybindings]]` rows (a configured row for the
same method wins), and invalidates the palette shortcut cache.

The plugins folder is watched by `PluginDirectoryWatcher` (FSEvents with
`kFSEventStreamCreateFlagFileEvents`, 0.3 s latency). A change calls
`AppDelegate.reloadPluginsAndShortcuts` directly: plugins reload, shortcuts and
global hotkeys are rebuilt, and the palette shortcut cache is invalidated.
It does not restart the action socket, refresh theme watchers, or announce a
config change to open editors. `NVModernConfigFileMonitor` watches `config.toml` too. Plugin-only edits send
`.nvModernPluginsConfigDidChange` and use the same targeted path. Other config
changes use `.nvModernConfigDidChange`. Byte comparison prevents a second reload
from the FSEvent after an app-owned write. Invalid TOML leaves the previous
runtime in place and appears as an error in Settings.

The XCTest app host skips plugin discovery and watching entirely, so user and
built-in plugins cannot populate its shared registry or global hotkeys.

### Old contexts

A promise created for a plugin is created in that plugin's context. If plugins
reload while a capture panel is open, the old context stays alive until its
pending work settles, so the text typed into the panel is still delivered and
written by the old code. Nothing is lost on reload; the old context is
released once its last promise settles.

## The bridge

Three layers, each thin.

### 1. The native `host` object

`PluginHost.makeHostObject(in:)` builds one JS object with Swift closures
(`@convention(block)`) as properties. Every closure runs on the main actor
(`MainActor.assumeIsolated`) because JS only ever runs there.

| Member | Kind | Does |
|---|---|---|
| `defineSettings(plugin, fields)`, `getSettings(plugin)` | sync | Validate a load-only schema; merge configured values over defaults |
| `register(plugin, spec, run)` | sync | Builds an `ActionDescriptor` and registers a handler that calls `run` |
| `invoke(plugin, method, args)` | promise | `ActionExecutor.invoke` with source `automation` / `plugin:<name>` |
| `resolve(file)` | sync | Absolute path for a `FileRef` |
| `exists`, `read`, `write`, `append`, `edit` | promise | `PluginFileAccess` |
| `input`, `panel`, `pick`, `confirm`, `notify` | promise | `PluginHostEnvironment` |
| `open(file, inNewTab)` | promise | Environment |
| `project()`, `projects()` | sync | From the cached project list |
| `clipboardRead`, `clipboardWrite` | promise | Environment |
| `formatDate(pattern, ms, locale)` | sync | `DateFormatter`, `en_US_POSIX` by default |
| `log(plugin, level, message)` | sync | `print` with a plugin prefix |
| `setTimeout`, `clearTimeout` | sync | `DispatchQueue.main.asyncAfter`, callbacks kept per host |

Synchronous members report failure by setting `JSContext.current().exception`
to an `Error` whose `code` and `details` mirror `ActionError`. Asynchronous
members return a promise and reject with the same shape.

### 2. The prelude

`PluginPrelude.source` evaluates to `function (host)`, which returns
`makeAPI(info)`. `makeAPI` builds a frozen `nv` object for one plugin:
`actions`, `settings`, `ui`, `files`, `workspace`, `clipboard`, `date`, `plugin`. Most
members are one-line forwards to `host`; `workspace` wraps built-in actions
(`workspace.note.current`, `workspace.editor.selection.*`) into the typed
shapes the definitions promise. `console` is per plugin so log lines carry
the plugin name.

### 3. Promises in both directions

- **Swift work, JS promise.** `PluginHost.promise(_:)` wraps
  `JSValue(newPromiseIn:)` and runs the Swift closure in a `Task { @MainActor }`,
  resolving with a JSON-like value or rejecting with a JS error. JSC drains
  microtasks when the outermost native call returns, so the plugin's
  continuation runs right after `resolve`.
- **JS promise, Swift await.** `settle(_:)` checks for a thenable and
  attaches `then(onFulfilled, onRejected)` blocks that resume a
  `CheckedContinuation`. A non-thenable return value passes straight through.

Measured cost: a no-op plugin action is about 0.02 ms end to end; one `await`
on an `nv` call adds about 0.04 ms.

### Value conversion

Arguments cross as `ActionValue`, the app's JSON-like tree. `JSValue.toObject()`
produces Foundation objects, and `ActionValue.init(_ value: Any?)` maps them
(including `NSNull`, which it did not before plugins). Results go back through
`jsonObject()`. A `Date` in the context object becomes a JS `Date`.

## Actions in detail

`register` validates `id` (`[A-Za-z0-9_-]+`, dot-separated segments allowed)
and `title`, then builds:

```swift
ActionDescriptor(
    method: "plugin.<name>.<id>",
    domain: .automation, mutationKind: .mutating, targetRequirement: .none,
    capabilities: [.automationExecute],
    tags: ["plugin", name] + keywords,
    arguments: <from spec.args>,
    palette: <from spec.palette>
)
```

`palette` maps to `ActionPalettePresentation`: `category`, `icon` to
`iconSystemName`, `when`, `rank`, `nounArguments`, and `keywords` with the
accelerator `key` prepended. The palette ranker scores an exact alias match
highest, which is what makes `Cmd+N` `n` select the row with `key: "n"`.

The registered handler calls `run` with `{ args, source, now }`, awaits a
returned promise, converts the result, and logs an `action.finished`
breadcrumb (category `plugin`) with the duration and outcome. Failures become
`ActionError.executionFailed` with the JS message, or keep the `code` of a
rejected `ActionFailure`.

Re-registering an `id` replaces the earlier registration and its shortcuts.
`unregisterActions(ofPlugin:)` removes a plugin's methods, hotkeys and
keybindings together.

## UI surfaces

### Floating panels

`QuickCapturePanelController` owns two `NSPanel`s: the glass text box and the
editor panel. Both run as a `Session`:

- an **input** session holds `onDismiss` and a `deliver(text) -> Bool`
  closure. Submit (`Cmd+Return`, or Return when `submitKey` is `return`)
  calls `deliver`; a `false` return keeps the panel open with its text.
  Escape, a click elsewhere, or a second press of the same `id` ends the
  session per `onDismiss`.
- an **editor** session opens `QuickCaptureEditorController` on a file with a
  cursor placement and calls `onClose` when the panel goes away.

`PluginAppEnvironment.input/panel` wrap these in continuations. Sessions carry
`isPluginOwned`, so `dismissPluginSurfaces()` on reload closes only plugin
panels. The glass surface (`NSGlassEffectView` on macOS 26, a
`hudWindow` visual effect before) is unchanged from the original quick
capture.

### Persistent document windows

`nv.ui.window` resolves when the app presents a single-document window. The
`ScratchpadWindowController` is owned by `PluginAppEnvironment`, keys windows
by their standardized, symlink-resolved file URL, and owns one
`QuickCaptureEditorController` per window. These windows use the editor's
`quickCapture` presentation but are neither workspace runtimes nor plugin
sessions, so reload leaves them open. Frames are stored through AppKit's
UserDefaults frame autosave, separately from workspace sessions.

Window requests reuse by resolved file unless `toggle: true` is supplied.
Toggling an existing window calls AppKit's `performClose`, so it follows the
same save/conflict checks and focus cleanup as the native close button.

The focus registry distinguishes `.scratchpad` windows. The global key monitor
handles their Close shortcut locally and bypasses workspace command routing;
the workspace router prevents fallback into a tab behind a scratchpad.

`ScratchpadFileSession` keeps the local body and its disk baseline. A file-level
FSEvents watcher on the parent directory catches in-place and atomic saves.
Clean changes reload the editor; dirty changes cancel pending autosaves and
block writes. Each save also checks disk before writing so watcher latency
cannot silently overwrite an already changed file. Failed saves retain the
buffer and prevent close/quit, with a beep and log. An explicit close or quit
with a conflict presents an NSAlert offering Keep Editing, Reload from Disk,
or Overwrite with My Changes. Recovery mutates the baseline only after the
chosen read/write succeeds; failed recovery retains the buffer and blocks
close/quit. Relaunch restoration is not implemented.

### Palette pickers

`nv.ui.pick`, `prompt`, `pickNote` and `pickFolder` are one mechanism:

1. `PluginPickCenter.choose(request, present:)` stores the rows and a
   continuation under a fresh request id, then asks the environment to open
   the palette on `PalettePreset.pluginPick(PalettePluginPick)` in the
   frontmost workspace window (activating the app first).
2. `PalettePresetResolver` turns that preset into a single standalone frame
   (`PaletteFrameSpec.pluginPick`), so Escape closes rather than popping to
   root. The frame's `pluginPick` field marks it.
3. `PaletteResultsResolver` treats the query literally (no `> / @ #` scopes)
   and fills the frame from `PluginPickCenter.sections` for `items` and
   `text`, from the notes provider for `note` (recents when empty, ranked
   notes when typed), and from the folders provider for `folder`.
4. `WorkspaceTabView.handlePaletteActivation` intercepts any activation in a
   `pluginPick` frame: a `.pluginPick` activation resolves with its value, an
   `.openNote`/`.openFolder` resolves with the path, and the palette closes.
5. Cancellation is answered exactly once: `PaletteSession.open` cancels a
   previous pick when the preset changes, `handleDidClose` cancels the current
   one (a no-op after a row answered), and a watchdog cancels a request no tab
   presented within 1.5 s.

### Alerts and notifications

`confirm` is an `NSAlert` sheet on the menu's target window (or modal without
one). `notify` requests `UNUserNotificationCenter` authorization for alerts
and posts a banner; it rejects with `capability_denied` when notifications are
off for the app.

## File access

`PluginFileAccess` resolves a `FileRef`:

- absolute and `~` paths as given;
- a relative path against the frontmost window's project root, falling back
  to the default root from config when no window is open;
- `{ project, path }` against the named `[[projects]]` entry
  (case-insensitive).

Relative paths that escape their root are rejected. The project list is read
from config once per reload and cached.

Writes deliberately do not go through `NotesWorkspaceModel.saveTextNote`.
That path registers a self-write with live sync, which tells an open editor it
already has the content; a plugin write is new content the editor has not
seen, so it must look external. `write` is an atomic replace; `append` writes
in place so sync clients keep the file's identity; `edit` reads, calls the
transform synchronously, and writes, all in one turn of the main thread.

## Hotkeys and keybindings

- `globalHotkey` registers through `GlobalHotkeyManager` (Carbon
  `RegisterEventHotKey`). The callback runs the action with source
  `keybinding` / `global:<keystroke>` and beeps on failure. It also requests a
  notification with the action title and error, at most once per method every
  ten seconds.
- `keybinding` becomes an `ActionKeybindingDefinition` with id
  `plugin:<method>`. `AppDelegate` appends plugin bindings after configured
  ones and drops any whose method a configured row already targets.
- The keystroke grammar is shared with `config.toml`: `cmd`, `shift`,
  `opt`/`alt`/`option`, `ctrl`, then a key.

## Security model

Plugins are the user's own code, run with the app's privileges. The boundary
is capability, not sandboxing: JSC has no I/O, and the host installs only the
members above. Relative file paths are confined to a project; absolute paths
are not confined, because quick captures legitimately target files outside
any project. There is no permission prompt, no network and no shell.

## Diagnostics

- `app.plugins.list` (action) returns loaded plugin names, load errors and
  global hotkeys; `nv3 action app.plugins.list` from a terminal.
- Load errors and `console.*` output print to stdout with
  `[NVModern][Plugin]` prefixes.
- New or changed load errors request a "Plugin failed to load" notification
  naming the file and line. Unchanged errors are suppressed across reloads;
  clearing an error rearms its notification if it returns. Successful reloads
  are silent. Notifications use the existing app authorization path; denied
  or failed delivery is logged without interrupting reloads or actions.
- `plugin/action.finished` breadcrumbs record method, outcome and duration in
  the local diagnostics file.
- `workspace/createNote.timing` breadcrumbs time note creation, which is
  where a capture's visible latency comes from (opening a new tab, not the
  bridge).

## Testing

`PluginHostTests` builds a `PluginHost` on a private `ActionRegistry` with a
stub `PluginHostEnvironment`, writes plugin files to a temporary folder and
drives them through `ActionExecutor`; it never depends on user plugins in the
shared app host. Covered: registration and palette
metadata, sync and async results, file operations and path confinement, date
formatting, thrown and rejected errors, load errors, reload semantics,
built-in override, `invoke` chaining, every `nv.ui` call, the pick center's
ranking and single-answer guarantee, and the org-capture example end to end.

`make typecheck-plugins` type-checks the examples against the contract.

## Changing the API

Change these together: `nv.d.ts` (the contract), `PluginPrelude.swift`
(the JS shape), `PluginHost.swift` (the native member), and, when the app
must do something new, `PluginHostEnvironment.swift` with its implementation
in `PluginAppEnvironment.swift` and the stub in the tests. Add a test case
and keep the examples type-checking. Document the addition in
`docs/plugins/authoring.md`.

Hold the line on scope: no event hooks, storage, network, editor-side
(CodeMirror) extensions or custom views until a plugin needs them, and then
design the smallest primitive that serves it.

## Planned

- Event hooks (`onSave`, `onOpen`) once a plugin needs them.

## Settings and inventory

`PluginInfo` holds name, source path, built-in flag, running/disabled/failed
state, registered methods, load error, and declared schema. It is published to
Settings. `app.plugins.list` preserves its `plugins`, `errors`, and
`globalHotkeys` fields and adds `infos`. `app.plugins.reload` requests a targeted
reload. Failed loads remove partial registrations and schemas.

The host validates unique field keys, supported kinds, typed defaults, finite
numbers, and nonempty unique choices. Folder values cannot be absolute or
escape a workspace with `..`. `get()` returns valid configured values over
defaults, substitutes defaults for invalid known values, and retains unknown
keys. Config writes preserve absent-plugin tables. Reset removes only that
plugin's overrides. Disabled plugins are not evaluated to discover schemas.
