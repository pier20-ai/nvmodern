# nvModern Action System

This document describes the current action system after the omnibox /
launchpad refactor. It is the reference for adding actions that can be
invoked from menus, the palette, launchpad tiles, keybindings, plugins,
and local automation transports.

The old inline searchbox and details-space actions are gone. Navigation
and discovery now flow through the omnibox palette, the new-tab
launchpad, Miller columns, and the action registry.

---

## Goals

- Give every app command one stable method name.
- Keep UI affordances thin: palette rows and launchpad tiles should call
  actions instead of reimplementing command behavior.
- Keep transport payloads JSON-like through `ActionValue`.
- Avoid raw AppKit identifiers in public API. Public targets use window,
  workspace, project, tab, document, and content selectors.
- Make actions self-describing through descriptors so the palette and
  external clients can eventually build their catalogs from metadata.

---

## Core Types

| File | Role |
|---|---|
| `NVModern/Core/Actions/ActionValue.swift` | JSON-like value tree for args/results |
| `ActionError.swift` | Stable machine-readable failures |
| `ActionSource.swift` | Invocation source: internal, menu, socket, automation, etc. |
| `ActionSocketClient.swift` | Shared Unix-socket client used by CLI and MCP |
| `ActionCLIParser.swift` | `nv3 action` / `nv3 mcp` argument parser |
| `ActionMCPCatalog.swift` | Curated MCP tool allowlist and argument flattening |
| `ActionMCPServer.swift` | Stdio JSON-RPC MCP adapter over `ActionSocketClient` |
| `ActionTarget.swift` | Public target selectors |
| `ActionDescriptor.swift` | Method metadata, args, capabilities, result shape |
| `ActionRequest.swift` | Invocation envelope |
| `ActionRegistry.swift` | Built-in descriptor and handler registry |
| `ActionExecutor.swift` | Resolves target and invokes handlers |

The shared invocation path is:

1. Build `ActionRequest(method:args:target:source:)`.
2. `ActionExecutor.shared.invoke(...)`.
3. `ActionRegistry` finds a descriptor and handler.
4. `DefaultActionTargetResolver` resolves the public target.
5. The handler uses a live `WorkspaceActionRuntime` or content surface.
6. Result or `ActionError` is returned as `ActionValue`.

---

## Runtime Bridge

`WorkspaceActionRouter` tracks live workspace windows and resolves the
frontmost or explicitly targeted runtime. `WorkspaceView` registers a
`ClosureWorkspaceActionRuntime` for each window.

The runtime currently exposes:

- tab operations: new, close, duplicate, select next/previous
- split operations: right, down, focus next/previous split
- document operations: open, reveal in Finder, reload from disk
- note operations: create, duplicate current, create daily, create from
  clipboard, refile, rename (`renameWorkspaceItem(relativePath:to:)` applies
  the window-level follow-up: tabs, history, Miller selection, and any diff
  selection follow the renamed item)
- editor bridge operations: replace selection, toggle highlight, run
  markdown formatting commands
- metadata: selected tab id, ordered tab ids, current document snapshot,
  current editor command target, current project, tab list, editor
  viewport/selection/cursor context
- the selected tab's side stack (`sideStackController()`, ticket 0031)

The action layer should prefer `WorkspaceActionRuntime` over reaching
into SwiftUI state directly.

---

## Current Built-In Actions

### Introspection

| Method | Mutates | Summary |
|---|---:|---|
| `app.health.ping` | no | Check that the action runtime is available |
| `app.actions.list` | no | List registered descriptors, optionally by prefix |
| `app.actions.describe` | no | Return one descriptor |
| `app.help.get` | no | Built-in help: list providers, read a provider as Markdown, or fetch one topic |
| `app.plugins.list` | no | Loaded plugins, load errors, plugin global hotkeys |

### Workspace Tabs

| Method | Mutates | Summary |
|---|---:|---|
| `workspace.tab.new` | yes | Create and select a new launchpad tab |
| `workspace.tab.close` | yes | Close the selected tab |
| `workspace.tab.duplicate` | yes | Duplicate the selected tab in the same pane |
| `workspace.tab.selectNext` | yes | Select the next tab |
| `workspace.tab.selectPrevious` | yes | Select the previous tab |
| `workspace.tab.showAll` | no | Toggle the AppKit tab overview grid |

### Splits

| Method | Mutates | Summary |
|---|---:|---|
| `workspace.split.right` | yes | Create a right-hand split with the current tab |
| `workspace.split.down` | yes | Create a lower split with the current tab |

The AppDelegate still routes the existing keyboard shortcuts for split
creation/focus through `WorkspaceActionRouter`; those should eventually
be represented as descriptors too if external automation needs them.

### Documents and Notes

| Method | Mutates | Summary |
|---|---:|---|
| `workspace.note.open` | yes | Open a workspace note in current or new tab |
| `workspace.note.openInNewTab` | yes | Open a note (or the current document) in a new tab |
| `workspace.note.current` | no | Return the selected tab's document snapshot |
| `workspace.note.get` | no | Read a note by relative path without opening a tab |
| `workspace.search.query` | no | Full-text search the current project's note index |
| `workspace.project.current` | no | Return the active project name and root path |
| `workspace.projects.list` | no | List configured projects, plus current when available |
| `workspace.tabs.list` | no | List open tabs in the target window |
| `workspace.editor.selection.get` | no | Return the current editor selection and line range |
| `workspace.editor.selection.replace` | yes | Replace the selection, or insert at the caret if empty |
| `workspace.editor.cursorContext.get` | no | Return text around the current cursor |
| `workspace.context.current` | no | Return visible context: project, tabs, viewport, selection |
| `workspace.document.jump` | no | Jump to a heading or line in the current document |
| `workspace.note.create` | yes | Create a note by filename/body |
| `workspace.note.createFromClipboard` | yes | Create a note from current text clipboard |
| `workspace.note.duplicateCurrent` | yes | Duplicate the current workspace note |
| `workspace.note.refile` | yes | Move the current workspace note into another folder |
| `workspace.document.reveal` | no | Reveal current file in Finder |
| `workspace.document.openInZed` | no | Open current file in Zed |
| `workspace.document.reload` | yes | Reload current document from disk |
| `workspace.document.diff.selectOriginal` | yes | Remember the current Markdown document as the original diff source |
| `workspace.document.diff.compareWithSelected` | yes | Compare the remembered original with the current Markdown document in a new tab |
| `workspace.document.copyPath` | no | Copy a document's absolute path to the clipboard |
| `workspace.document.copyRelativePath` | no | Copy a document's workspace-relative path to the clipboard |
| `workspace.document.rename` | yes | Rename a workspace note or folder, remapping open tabs and history |
| `workspace.document.openParentFolder` | yes | Open the current note's parent as the last Miller column and select its first item |
| `workspace.document.showInParentFolder` | yes | Open the current note's parent as the last Miller column and select the note |
| `workspace.document.find` | yes | Open the in-document find bar |
| `workspace.document.appearance` | yes | Open the document appearance inspector |
| `workspace.toolbar.compact.toggle` | no | Switch every workspace window between the compact and the regular toolbar |
| `workspace.sidebar.toggle` | yes | Show or hide the workspace sidebar |

`workspace.document.copyPath`, `workspace.document.copyRelativePath`,
`workspace.document.rename`, and `workspace.note.openInNewTab` take an optional
workspace-relative `path` and fall back to the document in the selected tab, so
the palette can bind a note noun to them (`nounArguments: ["note": "path"]`)
without breaking plain invocation. They live in
`NVModern/App/ActionDocumentBuiltinActions.swift`.

`workspace.note.current` stays cheap metadata. Use `workspace.note.get` for
body text without opening a tab, `workspace.context.current` for what is on
screen (viewport, tabs, selection), and `workspace.editor.cursorContext.get`
for a neighborhood around the caret.

`workspace.note.createFromClipboard` accepts an optional `folder` and
optional `openIn` (`currentTab` or `newTab`). Launchpad passes its
inherited folder so new-tab actions happen where the user was browsing.

Captures and scratchpads are plugin actions in the `Capture` category, not
built-ins; see
`docs/architecture/plugins.md`.

`workspace.note.refile` accepts an optional destination `folder`; omitting it
moves the current note to the workspace root. The runtime remaps open tabs,
navigation history, session state, and recent/search state after the move.

### Markdown Editing

| Method | Mutates | Summary |
|---|---:|---|
| `markdown.selection.quote` | yes | Prefix every selected line with `> ` |
| `markdown.selection.unquote` | yes | Remove one leading blockquote marker from every selected line |
| `markdown.selection.prefixLines` | yes | Prefix the first and continuation lines of each selection atomically |
| `markdown.table.insert` | yes | Insert a Markdown table at the current cursor or selection |
| `markdown.table.row.insertAbove` | yes | Insert a table row above the focused row |
| `markdown.table.row.insertBelow` | yes | Insert a table row below the focused row |
| `markdown.table.row.delete` | yes | Delete the focused body row |
| `markdown.table.row.moveUp` | yes | Move the focused body row up |
| `markdown.table.row.moveDown` | yes | Move the focused body row down |
| `markdown.table.column.insertLeft` | yes | Insert a column to the left of the focused column |
| `markdown.table.column.insertRight` | yes | Insert a column to the right of the focused column |
| `markdown.table.column.delete` | yes | Delete the focused column |
| `markdown.table.column.moveLeft` | yes | Move the focused column left |
| `markdown.table.column.moveRight` | yes | Move the focused column right |
| `markdown.table.column.alignLeft` | yes | Set the focused column alignment to left |
| `markdown.table.column.alignCenter` | yes | Set the focused column alignment to center |
| `markdown.table.column.alignRight` | yes | Set the focused column alignment to right |
| `markdown.table.cell.clear` | yes | Clear the focused table cell |

`markdown.table.insert` accepts optional `rows` and `columns` arguments
and defaults to a 2 x 2 body table. It is available only when the active
target is an editable Markdown text surface that supports selection
replacement. Format > Add Table and the palette action use this same
behavior.

The structural table actions operate on the currently focused Markdown
table cell in the active editor. They reuse the WebEditor table engine,
so they require an active editable Markdown text surface with a focused
table cell.

### Side Stack

The side stack is a column of read-only note cards beside a tab's content
(ticket 0031). Shift-clicking a wikilink pushes a card; these actions expose
the same operations everywhere else. They live in
`App/ActionSideStackActions.swift` and act on the target window's
`SideStackController`.

| Method | Mutates | Summary |
|---|---:|---|
| `workspace.stack.push` | yes | Push `path` (optional `heading` / `block` focus) on top of the stack, or reveal the existing card for the same path + focus |
| `workspace.stack.toggle` | yes | Show or hide the column (cards stay) |
| `workspace.stack.focus` | yes | Move keyboard focus between the main document and the stack |
| `workspace.stack.close` | yes | Remove card `id` (default: the top card); the last close hides the column |
| `workspace.stack.clear` | yes | Remove every card and hide the column |
| `workspace.stack.list` | no | Cards (top first: id, path, title, heading/block, collapsed), `isOpen`, `width` |

`workspace.stack.push` binds a note noun (`nounArguments: ["note": "path"]`),
so a note's verbs frame offers "Open in side stack"; with no `path` it pushes
the current note. `path` may also be a note name or `Note#Heading`. Only
Markdown, Org, and plain-text notes become cards. Shift-Return on a note row
in the palette runs the same push. View > Toggle Side Stack (`⌘⌥S`) and View >
Focus Side Stack (`⌘⌥J`) run `toggle` and `focus`; both keys are listed in
`PaletteShortcutResolver.menuOwnedKeystrokes` and reserved in
`CommandCatalog.reservedKeystrokes`.

### Recent Files

| Method | Mutates | Summary |
|---|---:|---|
| `workspace.recent.list` | no | Return recent workspace/external files |
| `workspace.recent.open` | yes | Open a recent file by id or relative path |

Recent files are stored in `session-v4.json` as `recentDocuments`.
Workspace notes and external Markdown files are recorded; clipboard
documents are intentionally not persisted.

### Content Surface

| Method | Mutates | Summary |
|---|---:|---|
| `content.surface.capabilities` | no | Report available content APIs |
| `content.node.get` | no | Fetch one structural content node |
| `content.query` | no | Run a structural/semantic content query |

Content actions are designed for heading extraction, backlinks,
structural queries, and future semantic joins. They should stay
framework-agnostic and should not depend on `WorkspaceView`.

### Plugins

Plugins register actions as `plugin.<file>.<id>`; they are ordinary registry
entries, reachable from every surface listed here. Compose built-in actions
inside a plugin's `run` function for multi-step workflows. See
`docs/architecture/plugins.md` and `docs/plugins/authoring.md`.

---

## Socket and CLI

The app listens on a Unix domain socket at
`~/Library/Application Support/nvModern/action.sock` by default. Each
request is one JSON line (`id`, `method`, `args`, `target`, `source`);
each response is one JSON line (`ok`, `result` / `error`).

The socket is on unless config sets `[socket] enabled = false`. Incoming
requests are tagged `source.kind = "socket"`. Clients should set
`source.metadata.client` to `"cli"` or `"mcp"`; the server will not let a
socket caller claim `internal` / `menu`.

The helper binary is named `nv3` (not `nvmodern`) because macOS
filesystems are case-insensitive: copying `nvmodern` into
`nvModern.app/Contents/MacOS/` overwrites the GUI executable.

`nv3 action` is a thin client of that socket:

```bash
nv3 action app.health.ping
nv3 action workspace.search.query --query inbox
nv3 action workspace.note.get --json '{"relativePath":"Inbox.md"}'
```

If the app is not running, the client exits 2 with a missing-socket
message.

### MCP

`nv3 mcp` is a stdio MCP server over the same socket. It exposes a
curated allowlist, not the full action catalog. Table-alignment, tab
chrome, plugins, and generic `invoke_action` stay off it. Friendly MCP
arguments such as `path` and `project` are flattened onto action args and
`ActionTarget` in the adapter only.

```bash
nv3 mcp
claude mcp add nvmodern -- /Applications/nvModern.app/Contents/MacOS/nv3 mcp
```

The app must be running. Tool results are JSON text. Socket requests from
this process are tagged `source.metadata.client = "mcp"`.

| MCP tool | Action |
|---|---|
| `ping` | `app.health.ping` |
| `get_context` | `workspace.context.current` |
| `get_project` | `workspace.project.current` |
| `list_projects` | `workspace.projects.list` |
| `get_open_tabs` | `workspace.tabs.list` |
| `search_notes` | `workspace.search.query` |
| `get_active_note` | `workspace.note.current` |
| `get_note` | `workspace.note.get` |
| `get_selection` | `workspace.editor.selection.get` |
| `get_cursor_context` | `workspace.editor.cursorContext.get` |
| `replace_selection` | `workspace.editor.selection.replace` |
| `jump_in_document` | `workspace.document.jump` |
| `open_note` | `workspace.note.open` |
| `open_in_side_stack` | `workspace.stack.push` |
| `create_note` | `workspace.note.create` |
| `list_recent` | `workspace.recent.list` |
| `open_recent` | `workspace.recent.open` |
| `get_backlinks` | `content.backlinks.query` |
| `get_heading` | `content.heading.subtree` |

---

## Opening the palette from automation

`workspace.palette.open` opens the palette on a preset frame in the target
window: `preset` is one of `root` (default), `actions`, `content`,
`capture`, `outline`, or `verbs`; `query` seeds the content
preset. It is not listed in the palette itself, but it is keybindable and
reachable over the socket (`nv3 action workspace.palette.open --preset capture`).

## Command Palette Presentation

The command palette is built over the registry: it lists descriptors, it does
not keep a catalog of its own. An action opts in by setting `palette:` on its
`ActionDescriptor`.

```swift
palette: ActionPalettePresentation(
    category: "Document",
    iconSystemName: "pencil",
    when: "activeDocument",
    title: "Rename…",
    keywords: ["rename", "move"],
    nounArguments: ["note": "path"]
)
```

- `category` — orders rows within a subject group. The set is fixed:
  `Create`, `Document`, `Format`, `Table`, `Layout`, `Appearance`,
  `Workspace`.
- `subject` — which of `document` / `window` / `workspace` the verb acts on,
  which is how the palette's root menu is grouped. Omit it and the category
  implies one (Document/Format/Table → document, Layout/Workspace → window,
  the rest → workspace), so no existing descriptor had to change.
- `iconSystemName` — SF Symbol for the row.
- `title` — palette-facing name, overriding the descriptor title
  (`descriptor.paletteTitle` resolves the two). `boundTitle` overrides it again
  once a noun is bound ("New note here…" in a folder's verbs frame).
- `keywords` — extra search terms matched alongside title and category.
- `acceptsBatch` — the verb can run over several bound nouns at once, which is
  what a multi-select batch lists.
- `listedOnlyWhenBound` — the verb never appears in the root menu; it exists
  only in a noun's verbs frame (the passage verbs).
- `isDefaultVerb` — the verb Enter runs on a bare noun of that kind.
- `when` / `nounArguments` — see below.

Actions without `palette` stay fully invocable through every transport but are
never listed: introspection and query methods (`app.*`, `content.*`, `*.list`,
`*.get`, `*.current`, `workspace.search.query`, `workspace.recent.*`,
`workspace.editor.*`, `automation.*`) deliberately have none.

### Argument pickers

`ActionArgumentDescriptor.picker` tells the palette how to collect a missing
argument; transports ignore it. The pickers are `text`, `workspaceFolder`,
`editorTheme`, and `documentWidth`.

`descriptor.paletteArgumentToCollect(given:)` returns the first argument still
to collect — a required picker argument first, otherwise any picker argument —
and the palette pushes a frame for it (`PaletteFrameSpec.argument(...)`), then
runs the action with the collected value merged in. Nil means the action runs
immediately. Current picker arguments:

| Method | Argument | Picker |
|---|---|---|
| `workspace.note.create` | `fileName` | `text` |
| `workspace.document.rename` | `name` | `text` |
| `workspace.note.refile` | `folder` | `workspaceFolder` |
| `workspace.theme.select` | `id` | `editorTheme` |

### Availability (`when`)

`when` is an `ActionExpressionEvaluator` expression over the automation
context variables from `ActionAutomationContextBuilder.build(...)`. The grammar
is `&&`, `||`, `!`, `==`, `!=`, string literals, dotted paths, and truthiness.
When it evaluates false the row is hidden; nil means always available.

Variables the palette relies on:

- `activeDocument` — the selected tab's document snapshot, or `null`.
  `activeDocument.kind == "workspaceNote"` gates note-only verbs.
- `activeEditor` — `surface` (a `WorkspaceEditorCommandSurfaceKind` raw value),
  `path`, `isEditable`, `supportsSelectionReplacement`, or `null`.
- `activeWorkspace.hasDiffOriginal`, `activeWorkspace.isSidebarVisible`.

Conditions in use:

| Condition | Applies to |
|---|---|
| `activeEditor.surface == "text" && activeEditor.isEditable` | every `markdown.*` action, `workspace.document.find` |
| `activeEditor.surface == "text"` | `workspace.document.appearance` |
| `activeDocument` | reveal, reload, open in Zed, copy path(s), rename, diff select-original |
| `activeDocument.kind == "workspaceNote"` | refile, duplicate note, open in new tab |
| `activeWorkspace.hasDiffOriginal` | `workspace.document.diff.compareWithSelected` |

`ActionAutomationContextBuilder.build(...)` reads live workspace state
(including `currentEditorCommandTargetSnapshot()`), so build it from an event
handler, never from inside a SwiftUI render pass.

### Nouns and verbs

`nounArguments` maps an `ActionPaletteNoun` (`note`, `folder`, `passage`)
to the argument that receives the noun's value, which is what lets the
palette offer a verbs frame for a selected noun. A note noun carries a
workspace-relative path; a folder noun carries a folder relative path, empty
for the root; a passage carries its note's path and also binds `snippet` and
`term`.

A multi-select batch binds nothing up front: the palette runs an
`acceptsBatch` verb once per member, with that member's own bound arguments.
`workspace.note.refile` takes an optional `path` for exactly this reason.

Handlers must default to the current document (or the current folder) when the
noun argument is absent, so plain invocation from a keybinding or the socket
keeps working. `workspace.note.open` keeps its current-tab default for scripted
callers; the palette's "open" verb is the thin `workspace.note.openInNewTab`.

### Shortcut labels

`PaletteShortcutResolver.shortcutLabel(forMethod:projectRootPath:)` renders the
glyphs on a palette row, resolving in order: user `[[keybindings]]` rows
targeting the method, `CommandCatalog` defaults, then a static table of
menu-owned shortcuts (`Cmd+T`, `Cmd+W`, `Cmd+F`, …). Results
are cached per project root; `AppDelegate` invalidates the cache when the
config reloads.

---

## UI Wiring

### Palette

The palette is one surface built directly on the registry: every descriptor
carrying a `palette:` presentation is a row, and `ActionsPaletteProvider`
evaluates each `when` expression once per resolve against the automation
context variables before listing it. There is no hand-maintained command list
any more.

Rows resolve through `PaletteActionPlanner`: an action whose picker-bearing
argument is still missing pushes an argument frame instead of running, so
`workspace.note.refile`,
`workspace.theme.select`, `workspace.note.create`, and
`workspace.document.rename` all collect their argument in the palette.

Quick Find (`Cmd+K`), Actions (`Cmd+Shift+K`), Content Search
(`Cmd+Shift+F`), and Capture (`Cmd+N`) are presets. Capture
is a standalone frame listing the `Capture` category. Refile has no preset of
its own: it is the "Refile to…" verb in a note's verbs frame.
See `docs/architecture/palette.md`.

### Launchpad

Launchpad quick actions call the same methods where possible:

- New note opens the existing create-note sheet because it needs a user
  filename.
- Clipboard calls `workspace.note.createFromClipboard`.
- Template still opens the create-note sheet until a template source and
  picker exist.

The launchpad Recent section reads `WorkspaceSessionStore.recentDocuments`
for the active project root.

### File Menu

File > Open Recent reads the same persisted recent list and routes each
entry through `WorkspaceActionRouter.performOpenDocument`. If no matching
workspace window exists, it opens a new workspace window for the recent
item's project root.

---

## Recent Files

Recent state lives in the session store rather than a separate database:

```json
{
  "version": 4,
  "recentDocuments": [
    {
      "rootPath": "/path/to/workspace",
      "document": { "...": "WorkspaceOpenedDocument" },
      "title": "options-book-notes.md",
      "openedAt": "2026-04-21T18:20:00Z"
    }
  ]
}
```

Rules:

- Newest item wins.
- Duplicates are keyed by `rootPath + editorPath`.
- The list is capped at 50.
- Clipboard-backed transient documents are skipped.
- v4 loads v3/v2/v1 session files as fallback.

---

## Adding an Action

1. Add or reuse a runtime method in `ActionWorkspaceRuntime` if the
   command needs live UI state.
2. Register an `ActionDescriptor` and handler in
   `ActionWorkspaceActions.swift`.
3. Keep arguments explicit and transport-safe.
4. Return a useful object result, not just `true`, when metadata exists.
5. Wire UI surfaces to the action method instead of duplicating logic.
6. If the command should appear in `Cmd+K`, add a `palette:` presentation with
   a category, an icon, a `when` condition, and `nounArguments` when it acts on
   a note or folder; give any argument the palette must ask for a `picker`.
7. If the command belongs on MCP, add it to `ActionMCPCatalog.swift`.
8. Update this document's catalog.
9. Run `make`.

For actions that need user choices, stop at the UI boundary. Do not hide
product decisions inside silent defaults. Examples: move to folder,
share recipient/expiry, export format/path, template source.

---

## Good Next Actions

These are high-value and fit the existing model:

- `workspace.note.renameCurrent` with explicit `newName`.
- `workspace.note.move` with explicit destination folder.
- `workspace.note.trashCurrent` with a confirmation-owning UI caller.
- `workspace.folder.create` with parent folder and folder name.
- `workspace.template.list` and `workspace.note.createFromTemplate`
  once a template folder convention exists.
- `workspace.share.current` once recipient and expiry args are supplied
  by a UI picker.
- `markdown.heading.promote`, `markdown.heading.demote`,
  `markdown.callout.wrap` as editor bridge commands with descriptor
  metadata.

Avoid adding action methods that encode UI-only details such as hover
state, palette selection, or temporary SwiftUI view identity.

---

## Removed Actions

The refactor removed these stale methods:

- `workspace.details.toggle`
- `workspace.search.focus`

They referred to the old details space and inline searchbox. Their jobs
are now handled by the omnibox/palette and launchpad surfaces.
