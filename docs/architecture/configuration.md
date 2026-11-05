# nvModern configuration

nvModern reads its app configuration from:

```text
~/.config/nvmodern/config.toml
```

This file controls:

- which project or projects are available
- which project opens by default
- mention autocomplete names
- text substitutions
- plugin enablement, declared settings, and keybindings
- action socket configuration
- Claude Code / Codex agent CLI settings
- live file sync behavior
- search facet mappings for the SQLite/FTS search system
- per-filetype appearance defaults (theme and font for `.org`, `.md`, …)

---

## Loading behavior

At startup, nvModern loads `~/.config/nvmodern/config.toml`.

If the file is missing or invalid, nvModern falls back to a default directory and records a warning internally.

Project selection works like this:

1. If a window/project root override is explicitly provided, nvModern tries to use it.
2. Otherwise it uses the configured default project.
3. If no valid config exists, it falls back to a local directory such as `~/Documents`.

---

## Top-level keys

### `root`
The default project root.

```toml
root = "/Users/alex/Documents/Notes"
```

- Must point to a directory.
- If `projects` is also defined, `root` chooses which project should be the default one.
- If `root` is omitted but `projects` exists, the first valid project becomes the default.

### `projects`
Optional list of named projects that should appear in nvModern.

```toml
[[projects]]
name = "Notes"
path = "/Users/alex/Documents/Notes"

[[projects]]
name = "Work"
icon = "briefcase.fill"
path = "/Users/alex/Documents/WorkVault"
```

Each project supports:

- `name` — display name in the UI
- `path` — absolute or `~`-expanded directory path
- `icon` — optional SF Symbol name
- `search_facets` — optional per-project search facet mapping

### `users`
List of names offered by @mention autocomplete.

```toml
users = ["alex", "sam"]
```

### `[filetypes.<ext>]`
Appearance defaults for one file extension. Markdown and Org share one
typography system, so any theme styles both; a file type can still pick its
own theme or swap in a different text face.

```toml
[filetypes.org]
theme = "cyanotype"
font_family = "IBM Plex Mono"
```

- Keys are lowercased file extensions without the dot (`org`, `md`, `txt`).
- `theme` replaces `editor_theme` for that file type. `system` means no theme even when `editor_theme` is set; omitted inherits `editor_theme`. An id that resolves to no file logs a warning and falls back to `editor_theme`.
- `font_family` replaces the theme's text and heading faces at the theme's sizes. The swapped face is scaled to the theme's x-height (`--nv3-font-size-adjust`), so a monospace face sits at the same optical size as the theme's own.
- A document's own theme (Document Inspector or frontmatter `theme:`) and frontmatter `font-family` still win over these defaults.
- Settings > Appearance has Org Files and Markdown Files sections for these keys.
- The retired top-level `org_font_family` key is read as `[filetypes.org] font_family` and logs a warning; saving from Settings writes the new form.

### `themes_dir`
Directory that holds user editor themes, forming one set with the themes
bundled in the app package (`Resources/BuiltinThemes/`). Each `.css` file is a
theme; the filename without the extension is the theme id.

```toml
themes_dir = "~/.config/nvmodern/themes"
```

- Defaults to `~/.config/nvmodern/themes` when omitted.
- Relative paths resolve against the directory containing `config.toml`.
- A user file sharing a bundled theme's id shadows the bundled one, so a built-in can be customized by dropping in a same-named file.
- The id `system` is reserved and means "no theme".
- Theme files are plain CSS that override the public `--nv3-*` tokens; see `NVModern/WebEditor/THEMING.md` for the authoring contract and token reference.
- Files are watched on disk, so theme edits apply to open editors without restarting or saving `config.toml`.

### `editor_theme`
The selected editor theme, referenced by id. Themes form one set across the bundled `BuiltinThemes` (newsprint, laurenziana, riso, cyanotype, kunsthalle, dispatch, outliner, catppuccin, nord, mayfair) and the user themes directory; every consumer — Settings > Appearance, the Document Inspector, frontmatter `theme:`, and the actions below — offers the same set.

```toml
editor_theme = "newsprint"
```

- Omitted, empty, or `system` means "no theme" — only bundled defaults apply.
- A value that resolves to no file logs a warning and falls back to bundled defaults.
- The legacy top-level `theme` key still works and aliases into `editor_theme` when that key is unset.
- Selection is also available as actions: `workspace.theme.list`, `workspace.theme.select` (`id` argument; `"none"` or `"system"` clears), and `workspace.theme.cycle` (`reverse` argument), usable from the actions palette, keybindings, plugins, and the action socket.
- The Document Inspector and frontmatter `theme:` can override the selection per document with any theme id.

### `window_tint`
Whether the window's toolbar and tab bar take the colour of the document's page, like Safari's coloured tab bar.

```toml
window_tint = false
```

- On by default; only `false` is written.
- Each native tab is its own window, so the active tab's document colours the chrome as tabs switch.
- Tabs showing the launchpad, folders or native viewers (PDF, CSV, images, canvases) keep the system colour.
- The tab bar takes only a page colour with some hue in it. Near-neutral pages, like the system theme's white or `#191919`, leave AppKit's own tab bar as it is.
- Settings > Appearance > Tint window toggles it.

### `editor_theme_css`
Optional single CSS file with the highest precedence, applied on top of the selected `editor_theme`.

```toml
editor_theme_css = "~/.config/nvmodern/editor.css"
```

- Relative paths resolve against the directory containing `config.toml`.
- Intended for small personal overrides; prefer full themes in `themes_dir` for reusable palettes.

Effective editor CSS is the selected theme (if any) followed by `editor_theme_css`, injected after the bundled editor styles.

### `sync`
Optional sync behavior configuration.

```toml
[sync]
mode = "prompt"
```

Supported modes:

- `prompt` — default. When an open workspace file changes on disk, nvModern keeps the current editor state and shows the reload/keep-local banner.
- `live_file` — automatically reloads open workspace files from disk when the filesystem watcher reports a modified file, without showing the reload/keep-local banner.

The table shape is intentional so future sync backends can add their own options without turning top-level config into a flat set of one-off keys.

### `substitutions`
Text substitution rules.

```toml
[[substitutions]]
from = ";sig"
to = "Best,\nAlex"
```

Each rule has:

- `from`
- `to`

Empty `from` values are ignored.

### Captures (retired keys)

Capturing is not configured here. Global capture hotkeys, `Cmd+N` captures,
scratchpads and templates are plugins; see `docs/architecture/plugins.md`.

`[capture]` and `[[quick_capture]]` tables from older configs are ignored, and
dropped the next time Settings saves the file.

### `plugins`

Settings > Plugins lists discovered JavaScript files, their source, runtime
status, load errors, actions, and declared settings. Disabling a plugin removes
its actions and hotkeys without deleting its file. Disabled plugins do not run
to discover settings; saved values remain available when re-enabled.

```toml
[plugins]
disabled = ["capture"]

[plugins.settings.capture]
folder = "Daily"
openInNewTab = false
style = "org"
```

`disabled` uses the plugin's sanitized file name (without `.js`). Settings
values are keyed by plugin name. Unknown keys and settings for absent plugins
survive saves. Reset Plugin Settings clears only that plugin's overrides and
offers an in-window Undo.

Plugins declare `text`, `bool`, `number`, `choice`, and workspace-relative
`folder` fields with `nv.settings.define`, then read synchronous snapshots from
`nv.settings.get()`. See `docs/plugins/authoring.md`.

### Live Settings

Settings is a System Settings-style window: a sidebar of General, Workspaces,
Writing, Appearance, Shortcuts, and Plugins, each pane a grouped `Form`
with native switches, pickers, and drill-down pages for a single workspace or
plugin. General covers `[sync]`, `[socket]`, and the config file location;
Shortcuts lists every palette action plus
each plugin's actions, so any of them can be bound without editing TOML.
Free-text fields (names, paths, models) save on Return or when focus leaves the
field. `search_facets` remains file-only.

Each change writes immediately and refreshes the relevant runtime. External
edits to `config.toml` update the UI automatically. There is no Apply, Revert,
pending-edit state, or external-change banner. Workspace removal, substitution
removal, workspace-folder changes, and plugin-settings reset have dedicated
Undo notices; removing a workspace never deletes its files.

One file monitor compares file bytes to suppress duplicate notifications after
an app write. Plugin-only edits refresh plugins and shortcuts; other edits use
the general configuration path. Writes reread disk first and merge unrelated
external edits. Conflicting values or malformed TOML are shown as errors and
never silently overwritten. Invalid external TOML leaves the last valid
runtime running until repaired.

### Retired action tables

Legacy `[[actions]]` tables are ignored with a configuration warning and are
not written back by Settings. Move those workflows to JavaScript plugins.
Legacy keybindings using `action = "..."` are warned about and skipped; use a
`method = "plugin.<file>.<id>"` binding instead.

### `keybindings`
Action method keybindings.

```toml
[[keybindings]]
id = "daily-capture"
keystroke = "cmd+shift+d"
method = "plugin.capture.daily"
```

A keybinding supports:

- `id`
- `title`
- `key` or `keystroke` (a method row with neither explicitly unbinds its default)
- `method` for invoking a raw action method
- `args`
- `target`
- `when`

### `socket`
Configures the action socket server. The socket is **on by default** even
if this table is omitted. Set `enabled = false` to turn it off.

```toml
[socket]
enabled = true
path = "~/Library/Application Support/nvModern/action.sock"
```

Fields:

- `enabled` — defaults to `true`
- `path` — defaults to nvModern’s standard socket path if omitted

Invoke actions from the shell with `nv3 action <method> ...` while
the app is running. MCP clients should launch `nv3 mcp` (stdio),
which uses the same socket and a curated tool allowlist.

```json
{
  "mcpServers": {
    "nvmodern": {
      "command": "/Applications/nvModern.app/Contents/MacOS/nv3",
      "args": ["mcp"]
    }
  }
}
```

### Agents and chat (retired keys)

Chat documents were removed on 2026-10-27, and with them the `[agents]` and
`[chat]` tables (CLI paths, provider defaults, `auto_stage_edits`). Run agents
in a terminal instead and connect them to nvModern over MCP (`nv3 mcp`).

Both tables are ignored when present in an older config, and dropped the next
time Settings saves the file.

---

## Search facet mapping

nvModern’s SQLite/FTS search system can infer searchable facets from filesystem path prefixes.

These mappings live under `search_facets`.

You can define them:

- globally at the top level, or
- per project under `projects.search_facets`

Per-project mappings override the global/default ones for that project.

### Supported configurable facet groups

The config loader currently accepts these facet groups:

- `class`
- `workspace`
- `entity`
- `asset`
- `library`
- `root`
- `is`

The search UI/parser currently supports these query facet keys:

- `class:`
- `workspace:`
- `entity:`
- `asset:`
- `library:`
- `ext:`
- `root:`
- `is:`

`ext:` is queryable but is derived from the file extension itself, so it is not configured in `search_facets`.

### Matching behavior

Each mapping table is:

```toml
[search_facets.class]
"some/path/prefix" = "some-value"
```

Rules:

- matching is prefix-based on normalized relative paths
- the longest matching prefix wins
- both `/` and `\\` are normalized to `/`
- leading/trailing slashes are ignored during normalization
- empty values are ignored

### `class`
Maps a path prefix to a search class such as:

- `workspace`
- `record`
- `asset`
- `library`
- `system`
- `archive`

Example:

```toml
[search_facets.class]
"10-Workspaces" = "workspace"
"20-Records" = "record"
"30-Assets" = "asset"
"40-Library" = "library"
"50-System" = "system"
"90-Archive" = "archive"
```

### `workspace`
Maps active workspace prefixes to workspace identifiers.

```toml
[search_facets.workspace]
"10-Workspaces/21-Storefront" = "21-storefront"
"10-Workspaces/23-Market-Research" = "23-market-research"
```

### `entity`
Maps record/entity prefixes.

```toml
[search_facets.entity]
"20-Records/21-Acme-Ltd-UK" = "21-acme-ltd-uk"
```

### `asset`
Maps asset bucket prefixes.

```toml
[search_facets.asset]
"30-Assets/31-Brand-Media" = "31-brand-media"
```

### `library`
Maps library bucket prefixes.

```toml
[search_facets.library]
"40-Library/42-Briefs-Reports" = "42-briefs-reports"
```

### `root`
Maps top-level roots to canonical root labels.

```toml
[search_facets.root]
"10-Workspaces" = "10-workspaces"
"20-Records" = "20-records"
"40-Library" = "40-library"
```

### `is`
Maps prefixes to special state flags.

Right now the most important value is:

- `archived`

Example:

```toml
[search_facets.is]
"90-Archive" = "archived"
```

---

## Example: Structured workspace config

```toml
root = "~/Documents/Workspace"
users = ["alex", "sam"]

[sync]
mode = "live_file"

[[projects]]
name = "Acme"
icon = "building.2.crop.circle"
path = "~/Documents/Workspace"

[projects.search_facets.class]
"10-Workspaces" = "workspace"
"20-Records" = "record"
"30-Assets" = "asset"
"40-Library" = "library"
"50-System" = "system"
"90-Archive" = "archive"

[projects.search_facets.workspace]
"10-Workspaces/10-Workbench" = "10-workbench"
"10-Workspaces/21-Storefront" = "21-storefront"
"10-Workspaces/23-Market-Research" = "23-market-research"
"10-Workspaces/27-Apps/Editor" = "27-apps-editor"

[projects.search_facets.entity]
"20-Records/21-Acme-Ltd-UK" = "21-acme-ltd-uk"
"20-Records/22-Globex-India" = "22-globex-india"

[projects.search_facets.asset]
"30-Assets/31-Brand-Media" = "31-brand-media"
"30-Assets/34-Templates-Playbooks" = "34-templates-playbooks"

[projects.search_facets.library]
"40-Library/41-Books" = "41-books"
"40-Library/42-Briefs-Reports" = "42-briefs-reports"

[projects.search_facets.root]
"10-Workspaces" = "10-workspaces"
"20-Records" = "20-records"
"30-Assets" = "30-assets"
"40-Library" = "40-library"
"50-System" = "50-system"
"90-Archive" = "90-archive"

[projects.search_facets.is]
"90-Archive" = "archived"

[[substitutions]]
from = ";sig"
to = "Alex"

[[keybindings]]
id = "daily-capture"
keystroke = "cmd+shift+d"
method = "plugin.capture.daily"
```

---

## Example: simple config

This example shows a simpler personal/work setup with custom folder semantics.

```toml
root = "~/Documents/Knowledge"
users = ["alex", "priya"]

[[projects]]
name = "Knowledge"
icon = "books.vertical.fill"
path = "~/Documents/Knowledge"

[projects.search_facets.class]
"Inbox" = "workspace"
"Projects" = "workspace"
"Reference" = "library"
"Company-Docs" = "record"
"Assets" = "asset"
"Archive" = "archive"

[projects.search_facets.workspace]
"Projects/App" = "app"
"Projects/Research" = "research"
"Inbox" = "inbox"

[projects.search_facets.entity]
"Company-Docs/Acme-Inc" = "acme-inc"
"Company-Docs/Holding-Co" = "holding-co"

[projects.search_facets.asset]
"Assets/Brand" = "brand"
"Assets/Templates" = "templates"

[projects.search_facets.library]
"Reference/Books" = "books"
"Reference/Articles" = "articles"

[projects.search_facets.root]
"Inbox" = "inbox"
"Projects" = "projects"
"Reference" = "reference"
"Company-Docs" = "company-docs"
"Assets" = "assets"
"Archive" = "archive"

[projects.search_facets.is]
"Archive" = "archived"

[[projects]]
name = "Client Vault"
icon = "briefcase.fill"
path = "~/Documents/ClientVault"

[projects.search_facets.class]
"Active" = "workspace"
"Deliverables" = "asset"
"Contracts" = "record"
"Archive" = "archive"

[projects.search_facets.workspace]
"Active/Alpha" = "alpha"
"Active/Beta" = "beta"

[projects.search_facets.entity]
"Contracts/Alpha-Corp" = "alpha-corp"
"Contracts/Beta-LLC" = "beta-llc"

[projects.search_facets.root]
"Active" = "active"
"Deliverables" = "deliverables"
"Contracts" = "contracts"
"Archive" = "archive"

[projects.search_facets.is]
"Archive" = "archived"

[[substitutions]]
from = ";today"
to = "2026-03-21"

[socket]
enabled = true
path = "~/Library/Application Support/nvModern/action.sock"
```

---

## Practical guidance

### Minimal config
If you just want nvModern to open a single root:

```toml
root = "~/Documents/Notes"
```

### Recommended config
For most real usage, define:

- `projects`
- `users`
- per-project `search_facets`

### Search facet advice
Prefer:

- stable, slug-like values
- short values
- consistent naming

Examples:

- `21-storefront`
- `record`
- `31-brand-media`
- `archived`

Avoid values that vary only by capitalization or spacing.

---

## Plugins

Plugins are JavaScript files in `plugins/` next to `config.toml`
(`~/.config/nvmodern/plugins/*.js`). They are not configured here: a plugin
file carries its own settings. See `docs/architecture/plugins.md`.

## Related docs

- `docs/architecture/action-system.md`
- `docs/architecture/plugins.md`

If you add new config keys in code, update this document alongside `NVModern/Core/Config/NVModernConfig.swift`.
