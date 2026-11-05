# nvModern

nvModern is a native macOS workspace for notes and documents. It combines a Miller-column file browser, an editor for Markdown and Org, and a command palette that can find files and run actions on them. Documents open in genuine AppKit window tabs; each tab keeps its own workspace state.

This repository is under active development. The main branch uses a native sidebar, toolbar, status bar, and window tabbing.

## Get running

You need macOS 14 or later on Apple Silicon, Xcode and its command-line tools, XcodeGen, and Bun. `make setup` checks the toolchain and can install XcodeGen and Bun through Homebrew.

```sh
make setup
make run
```

`make run` builds the WebEditor bundle, generates the Xcode project, builds the Debug app, and opens it. The generated project and bundled web resources are build outputs; edit `project.yml` and `NVModern/WebEditor/src/` instead.

To open a particular notes directory, create `~/.config/nvmodern/config.toml`:

```toml
root = "~/Documents/Notes"

[[projects]]
name = "Notes"
path = "~/Documents/Notes"
```

The directory must exist. The app has a fallback root when no config is present, but setting `root` makes the workspace explicit. Multiple projects, themes, keybindings, agents, and search facets are documented in [configuration](docs/architecture/configuration.md). Captures and other personal workflows are [plugins](docs/plugins/authoring.md).

## Use the workspace

`Cmd+T` opens a new native tab on the launchpad. Browse folders in the sidebar or Miller columns and open a file to edit it. `Cmd+K` opens the palette at files; `Cmd+Shift+K` starts at actions, and `Cmd+Shift+F` searches passages. `Cmd+N` lists the captures your plugins register. [Palette architecture](docs/architecture/palette.md) explains its subject–verb–object model.

The editor supports Markdown and Org, a native CSV grid, PDF and image previews, and file-backed Excalidraw canvases (`.excalidraw`). Use New File in a folder to create a canvas, or open an existing canvas through Miller columns, Open, or Finder; it edits and saves in a native workspace tab. Workspace sessions restore open tabs, sidebar state, documents, and scroll positions. A local action socket and the `nv3` CLI expose actions for automation; see the [action system](docs/architecture/action-system.md).

## Work on the code

| Area | Where to start |
|---|---|
| App lifecycle, menus, native windows and toolbar | `NVModern/App/` |
| Sidebar, tabs, Miller browser, palette, document surfaces | `NVModern/UI/` |
| Workspace models, search, session, config, actions | `NVModern/Core/` |
| CodeMirror editor library and host adapter | `NVModern/WebEditor/src/lib/`, `NVModern/WebEditor/src/App.tsx` |
| Xcode project and build workflow | `project.yml`, `Makefile` |
| Architecture notes | `docs/architecture/` |

The editor library in `NVModern/WebEditor/src/lib/` is framework-agnostic; host-specific bridge code lives outside it. The web bundle must be an IIFE for the local WKWebView. Read [AGENTS.md](AGENTS.md) for repo-specific constraints before changing the shell, editor, or generated resources.

Run the checks through `make`:

```sh
make                 # Debug app and web bundle
make test            # Swift tests
make test-web        # WebEditor tests
make typecheck-arbor # Arbor TypeScript check
```

Build and test logs are under `/tmp/nvmodern/`. `make package` produces a Release `.app` and DMG in `dist/`; `make cli` copies the Debug `nv3` tool there. The Racket-based Arbor kernel has an optional `make test-arbor-kernel` check when Racket is installed.

The [inspiration synthesis](docs/inspiration/synthesis.md) records an early product direction and is useful background, but the code and `docs/architecture/` describe current behavior. Open work is tracked in `docs/tickets/`.

## Contributing and licence

Contributions are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md) first, and report security issues as described in [SECURITY.md](SECURITY.md). Participation is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).

nvModern is free software, licensed under the [GNU General Public License v3.0 or later](LICENSE). Third-party components and their licences are listed in [NOTICE](NOTICE).
