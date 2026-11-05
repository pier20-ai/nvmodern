# AGENTS.md — nvModern

Canonical guidance for agents working in this native-shell tree. `CLAUDE.md` points here to keep one source of truth.

## Rules

These are hard constraints. Do not violate them.

1. **Naming**: Source folder/scheme/target = `NVModern`. User-facing app name = `nvModern`. Keep `project.yml` and `Makefile` in sync.
2. **Build system**: Always use `make` commands. Never invoke `xcodebuild` or `bun` directly.
3. **Native tabs are AppKit tabs**: One workspace window is one native tab. Do not replace AppKit window tabbing with a custom tab strip.
4. **Editor library is in-tree**: `NVModern/WebEditor/src/lib/` is the single source of truth. No external sync exists.
5. **Library code must stay framework-agnostic**: Nothing in `NVModern/WebEditor/src/lib/` may import from the bridge, nvModern adapter, shell app, or other app-specific code.
6. **WKWebView requires IIFE**: The web bundle must build as `format: "iife"` (not ESM). WKWebView blocks module scripts from `file://` with CORS errors.
7. **Do not commit generated/dependency artifacts**: do not commit `node_modules` or generated `NVModern/Resources/WebEditor/` files.
8. **Vendored patches are intentional**: `NVModern/WebEditor/patches/` contains Bun patched dependencies (currently CodeMirror view scrolling fixes). Do not remove or bypass them unless you replace the behavior and verify wrapped scrolling.
9. **Selected text color is intentional**: the active/selected foreground in the Miller/omnibox chrome is forced white in selected accent states. Do not “fix” it to semantic primary text.
10. **Session schema changes**: If you change the persisted session model incompatibly, bump the filename/version and preserve decode fallback.
11. **Updates are opt-in by key**: `AppUpdater` starts Sparkle only when the build has a non-empty `SUPublicEDKey` (`SPARKLE_PUBLIC_ED_KEY`). Source builds must stay silent; do not hard-code a key or feed in code.
12. **Preserve UX invariants**: native tab drag/reorder/close, titlebar drag and double-click zoom, `Cmd+W/T/K/Shift-K/F`, launchpad new-tab state, palette behavior, Miller navigation, in-document navigation, and editor loading from local resources.

## Build commands

```bash
make setup          # check/install toolchain (Xcode CLT, xcodegen, bun, hdiutil)
make dev            # editor dev server at http://localhost:3000 (HMR)
make test-web       # run WebEditor Bun tests; pass TEST_ARGS='...' to filter
make                # full build: web bundle -> xcodegen -> Debug xcodebuild
make run            # build + launch app
make cli            # copy Debug `nv3` CLI to dist/nv3
make package        # Release build -> dist/nvModern.app + timestamped .dmg (unsigned)
make release        # signed + notarized DMG and Sparkle appcast (docs/releasing.md); never publishes
make install        # Release build -> replaces /Applications/nvModern.app (quit the app first)
make clean          # remove build artifacts (safe — no source deletion)
```

Build/test logs go to `/tmp/nvmodern/` with `latest-*` symlinks.

Override dev shell content root: `EDITOR_ROOT=/path/to/notes make dev`.

## Current architecture

```text
NVModern/
  App/                              # App lifecycle, commands, global routing
    NVModernApp.swift                 entry point; menus for project/open/recent/format/find/palette
    AppDelegate.swift                 lifecycle, global key monitor, WebKit dev extras, action config reload
    WorkspaceActionRouter.swift       live-window command/action routing facade
    ActionWorkspaceRuntime.swift      window runtime protocol + snapshots exposed to actions
    ActionWorkspaceActions.swift      workspace/document/markdown built-in action handlers
    ActionDocumentBuiltinActions.swift document-level built-ins (copy path, rename, find, toggles)
    ActionPassageBuiltinActions.swift  passage verbs (quote, transclude, copy) — bound-only
    ActionSideStackActions.swift      side stack actions (`workspace.stack.*`, ticket 0031)
    ActionKeybindingManager.swift     configured action keybindings
    ActionSocketServer.swift          local JSON action socket transport (on by default)
    GlobalHotkeyManager.swift         app-global hotkeys (plugin `globalHotkey`)
    QuickCapturePanelController.swift floating input/editor panels behind `nv.ui.input` / `nv.ui.panel`
    PluginAppEnvironment.swift        app side of the plugin host: panels, open, clipboard
    WorkspaceNotificationRouter.swift notification click/open routing
    WorkspaceOpenDocument.swift       workspace/external/clipboard document model + launch queue
    WindowAccessor.swift              NSWindow configuration helper
    WindowFocusCoordinator.swift      focus/routing helpers for app window kinds

  Core/
    Actions/                          framework-agnostic action system models/executor/registry
      ActionValue.swift               JSON-like transport value tree
      ActionDescriptor.swift          method metadata/capabilities
      ActionRequest.swift             invocation envelope/response
      ActionSocketClient.swift        shared Unix-socket client (CLI / future MCP)
      ActionCLIParser.swift           `nv3 action` argument parser
      ActionTarget.swift              public app/window/workspace/tab/document/content selectors
      ActionRegistry.swift            descriptor + handler registry
      ActionExecutor.swift            target resolution + handler invocation
      *BuiltinActions.swift           app/content/automation built-ins
      MarkdownActionContentSurface.swift content API over active Markdown editor
    Config/NVModernConfig.swift       ~/.config/nvmodern/config.toml loader
    Plugins/                          JavaScriptCore plugin host; `nv` bridge, file access, prelude
    Diagnostics/                      local diagnostics and workspace activation traces
    Palette/PaletteModel.swift        framework-agnostic palette slots/stack/targets/modes/planner
    Notes/NotesWorkspaceModel.swift   indexing, selection, save, wikilink/transclusion, file IO hooks
    Notes/WorkspaceFileIO.swift       filesystem helpers for workspace notes/assets
    Search/NoteSearchEngine.swift     async search actor
    Search/SearchIndexStore.swift     SQLite/FTS index store and facet metadata
    Search/SearchQueryParser.swift    content-search query/facet parser
    Session/WorkspaceSessionStore.swift app-owned window/tab/scroll/recent persistence
    Session/SideStackState.swift      per-tab side stack model (cards, focus, open, width), persisted with the tab
    Sharing/WorkspaceNotificationsStore.swift JSONL sharing/notification state + user notifications

  UI/
    NativeWorkspaceWindowView.swift   NavigationSplitView shell; per-window tab state and persistence
    WorkspaceTabView.swift            per-tab shell: launchpad/browser/content, omnibox, navigator, bridge handling
    WorkspaceTabController.swift      persistent tab content controller + focus/content lifecycle API
    WorkspaceTabContentRuntimes.swift per-tab child runtimes/controllers for text/preview/PDF/CSV/image/canvas
    WorkspaceTabModels.swift          tab state, launchpad vs note surfaces, banners, context menus
    DesignTokens.swift                shared native visual tokens
    LaunchpadView.swift               new-tab action surface and recent/project entry points
    MillerColumnsView.swift           folder/file browser columns
    OmniboxView.swift                 breadcrumb chrome (legacy/tab content path)
    OmniboxTextField.swift            palette input field + key monitor
    Palette/                          command palette: session, resolver, providers, frame view
    SideStack/SideStackController.swift tab-owned side stack: `stack.html` web view, card bodies, events, column layout
    DocumentFindBarView.swift             native-style in-document find bar (`Cmd+F`)
    DocumentNavigatorPopoverView.swift outline/line-jump popover
    WorkspaceItemContextMenu.swift    file/folder context menu actions
    WorkspaceNotificationsPopover.swift sharing notification affordance
    AttachmentGC.swift                attachment cleanup helpers
    CSV/                              native AppKit spreadsheet editor/preview (see `CSV/README.md`)
    Retained/RetainedPDFPreviewSession.swift controller-owned PDFKit surface/session
    Web/
      EditorWebView.swift             WKWebView + Swift<->JS bridge transport/session reuse
      PDFPreviewView.swift            PDF preview with scroll state (legacy/direct wrapper path)
      PreviewFileSchemeHandler.swift  `nvmodern-file://preview?...` local file scheme
      ImagePreviewView.swift          image preview wrapper
      QuickCaptureEditorController.swift WKWebView host for the floating editor panel

  WebEditor/                        # Editor library + nvModern adapter + dev tooling
    src/lib/                          CM6 plugins, calc/org parsers, theme API, public API
      plugins/                        markdown/org tables, callouts, calc, footnotes, highlights, links, etc.
      calc/                           reactive calc parser/runtime + tests
      org/                            org parser + tests
      react/                          library React components (e.g. ToC)
      theme/                          tokenized theme and stylesheet helpers
    src/App.tsx                       nvModern adapter; bridge requests/events; editor/preview dispatch
    src/editorHost.ts                 adapter helpers shared by App.tsx and the side stack (paths, preview scheme, appearance)
    src/stack.tsx, src/stack/         side stack entry + read-only card surface (ticket 0031)
    src/bridge.ts                     JS-side structured bridge transport
    src/main.tsx                      app entrypoint for bundled WKWebView build
    src/styles/editor.lib.css         library design tokens + CM6 visuals
    src/styles/app.css                nvModern adapter layout
    THEMING.md                        editor theme/token customization guide
    patches/                          Bun dependency patches (do not delete casually)
    shell/                            standalone dev shell (not shipped)
    test-files/                       fixtures used by tests and the dev shell (not shipped)
    build.ts                          Bun IIFE build script -> `NVModern/Resources/WebEditor/`
    index.ts                          barrel re-export

  Plugins/                          # Plugin API contract (not compiled into the app)
    nv.d.ts                           TypeScript definitions for the `nv` plugin API
    examples/                         reference plugins, type-checked against nv.d.ts

  Resources/WebEditor/              # GENERATED — consumed by WKWebView at runtime
    index.html, main.js, main.css     (+ stack.html/js/css, diff.*, canvas.*, epub.js)

project.yml                         # XcodeGen source of truth
Makefile                            # Primary workflow entry point
```

## Workspace/tab runtime model

- `WorkspaceApplicationCoordinator` owns workspace windows and groups them through AppKit window tabbing. `Cmd+T` and the native tab-bar add button use the same creation path; splits are absent from this shell.
- `NativeWorkspaceWindowView` owns the `NavigationSplitView` sidebar, per-window tab state, session persistence, and runtime registration. `NativeWorkspaceToolbarController` owns the native toolbar; the open path appears in the bottom status bar.
- Each window owns a `WorkspaceTabController` and `TabWorkspaceView` for launchpad, Miller browser, documents, palette wiring, and bridge events. Content runtimes detach native-heavy surfaces while inactive but retain controller identity.
- New tabs start as `.launchpad`. Opening a document turns them into `.note`; restored text snapshots must remain available until WebEditor accepts context.
- The side stack (ticket 0031) is a right-hand column of read-only note cards owned by the tab, not the document: `SideStackColumnLayout` in `TabWorkspaceView` places it beside any content kind (it overlays the content as a sheet when the main content would drop below 520pt), and navigating the main view leaves it alone.

## Action system, palette, and launchpad

- There is ONE command palette, and every interaction in it is a sentence: **subject · verb · object**. Quick Find, Actions, Content Search, and Capture are presets of it, not separate surfaces.
- **Root is always files — never files and verbs together.** Empty it lists the active tab's document first (subtitle "current tab", selected by default), then the other open tabs, then `Recent`; typed it lists ranked notes and nothing else. Verbs live one step in, so `⌘K` `⌘K` lands in the current document's actions.
- Slots are frames on a stack. `⇥` commits the current slot and steps into the selection (a noun becomes the bound subject and its verbs list; a verb with an object opens its picker); `⌘K` inside the palette returns to root and never closes. Backspace over an empty query pops a slot. Verbs are sectioned by category (Open, File, Document, Format, Window, Create, Chat, Appearance, Help); a verbs frame bound to the document the tab already shows widens into that tab's whole menu, any other note gets the file categories only.
- Typing at root changes the noun: notes by default, `>` verbs only, `/` passages, `#` folders. A noun's default verb is Open (Open at match for a passage, Browse for a folder).
- Modes layer over the session, not the stack: `⌘P` preview, `⌘M` multi-select (`space` marks note rows, then `⇥` binds them as one batch subject), `⌘.` pin (the palette stays open after a run). `⎋` clears modes, else pops, else closes.
- Discovery and command execution flow through:
  - the palette (`Cmd+K` root, `Cmd+Shift+K` verbs, `Cmd+Shift+F` passages, `Cmd+N` capture),
  - launchpad new-tab surface,
  - Miller columns and context menus,
  - menus and configured keybindings,
  - local action socket (on by default; `nv3 action` CLI).
- The palette lists actions straight off `ActionRegistry`: a descriptor is palette-visible when it carries a `palette: ActionPalettePresentation`, and its `when` expression gates availability. There is no separate command catalog — do not add one.
- Add new app commands as action descriptors/handlers in `Core/Actions/` or `App/ActionWorkspaceActions.swift`, with a `palette:` block when they should be listed. Give an argument a `picker:` to have the palette collect it in a pushed frame; declare `nounArguments` to make the action appear in a note's, folder's, passage's, or chat's verbs frame, and default the handler to the current document/folder when that argument is absent. `subject:` overrides the subject group derived from the category; `acceptsBatch:` opts a verb into multi-select runs; `listedOnlyWhenBound:` keeps it out of root entirely.
- Prefer `ActionExecutor` / `WorkspaceActionRuntime` / `WorkspaceActionRouter` over reaching directly into SwiftUI view state.
- Keep action payloads/results JSON-like through `ActionValue`; avoid exposing raw AppKit object identifiers in public action API.
- `ActionAutomationContextBuilder.build(...)` reaches workspace state. Build it from an event handler or the palette's async resolve task, never inside a SwiftUI `body`.
- Capturing is not core: global capture hotkeys, `Cmd+N` captures, scratchpads and templates are plugin actions (category `Capture`). Do not add capture kinds, templates or capture config to core.
- Plugins are plain JavaScript files in `~/.config/nvmodern/plugins/`, run by `PluginHost` in one JavaScriptCore context. A plugin registers actions (`plugin.<file>.<id>`) through `nv.actions.register`; they are ordinary registry entries. `NVModern/Plugins/nv.d.ts` is the API contract — change it and `PluginPrelude.swift`/`PluginHost.swift` together.
- Reference docs: `docs/architecture/plugins.md` (architecture), `docs/plugins/authoring.md` (writing plugins), `docs/architecture/palette.md`, `docs/architecture/action-system.md`, `docs/architecture/configuration.md`.

## Bridge protocol

Swift and JS communicate over a structured message bridge.

**Swift -> JS commands:**
- `setHostAppearance` — host color scheme updates.
- `setContext` — title, path, body/data/preview kind, users, editability, substitutions, scroll restore, user theme CSS.
- `jumpToMarkdownReference` — navigate to Markdown heading/block reference after opening a target document.
- `documentNavigation` — begin/search/jump/commit/cancel in-document navigator actions.
- `replaceSelection` and Markdown formatting commands — editor command surface (`toggleMarkdownBold`, `toggleMarkdownHighlightSelection`, `insertMarkdownLink`, etc.).
- `response` — replies to JS requests by `requestId`.

**JS -> Swift events:**
- `ready` / `contextReceived` — editor initialized/context accepted.
- `docChange` — content changed and should be scheduled for save.
- `scrollStateChange` / `documentNavigationState` — scroll persistence and document navigator state.
- `wikilinkOpen` / `inlineLinkOpen` — note navigation or external/local link handling (`wikilinkOpen` carries the click's `shiftKey`/`metaKey`/`altKey`/`ctrlKey`; Shift-click is the side-stack gesture).
- `contextMenuRequested` / `contentInteraction` — native context/focus routing.
- `previewLoadError`, `csvParseError`, `editorInputLatency`, `jsError`, `unhandledRejection`, `consoleError`, `editorInitError`, `mainScriptLoadError` — telemetry/diagnostics.

**JS -> Swift requests:**
- `autocomplete.wikilink` — wikilink completions.
- `transclusion.resolve` / `transclusion.save` — transclusion round-trip.
- `date.pick` — native date picker for date insertion/editing.
- `image.save` — pasted image attachment write into `.attachments/`.

The side stack (`stack.html`, ticket 0031) speaks its own commands/events over the same transport; see "Stack bridge protocol" in `docs/tickets/0031-side-stack.md`. Natively, each tab's `WorkspaceTabController.sideStack` (`UI/SideStack/SideStackController.swift`) hosts it in an `EditorWebContentController` loaded with `entryResource: "stack"`; the card list lives in `WorkspaceTabState.sideStack` and persists with the tab. A Shift-click `wikilinkOpen` pushes a card instead of navigating.

Key files: `NVModern/UI/Web/EditorWebView.swift` (Swift transport/session), `NVModern/WebEditor/src/bridge.ts` (JS transport), `NVModern/WebEditor/src/App.tsx` (JS adapter), `NVModern/UI/WorkspaceTabView.swift` (event/request handling).

## WebEditor notes

- `src/lib/` must remain app-agnostic; `src/App.tsx` is the nvModern-specific adapter.
- Run tests via `make test-web`, not `bun test` directly. Many plugins have colocated `*.test.ts` files.
- The editor supports Markdown and org-mode surfaces, callouts, tables, footnotes, highlights, LaTeX/KaTeX previews, image previews/paste, wikilinks/transclusions, date picking, and reactive calc blocks.
- User CSS overrides are loaded from config and applied through the theme stylesheet helper; see `NVModern/WebEditor/THEMING.md`.
- Keep CSS/layout changes careful around CodeMirror wrapping and scrolling. The CodeMirror view patch in `patches/` is part of that stability story.
- Bundled resources are generated into `NVModern/Resources/WebEditor/` by `make web-editor`/`make`; do not edit or commit generated files.

## Session restore

App-owned persistence lives in `NVModern/Core/Session/WorkspaceSessionStore.swift` at `~/Library/Application Support/nvModern/session-v6.json`, with fallback decoding for older sessions. Each native tab persists as a window state: frame, project root, sidebar state, document/tab state, text snapshots, recents, and scroll positions. `WorkspaceApplicationCoordinator` restores those windows and re-groups tabs by project root. If persisted models change incompatibly, bump the session filename/version and preserve decode fallback.

## Config

`~/.config/nvmodern/config.toml` supports single-root and multi-project setups:

```toml
root = "/path/to/default/notes"
users = ["alex", "priya"]
current_user = "alex"
notifications_file = ".nvmodern-notifications.jsonl"
editor_theme_css = "~/.config/nvmodern/editor.css"

[[projects]]
name = "Notes"
icon = "books.vertical.fill"
path = "/path/to/default/notes"

[[substitutions]]
from = ";sig"
to = "Best,\nAlex"

[[keybindings]]
id = "daily-capture"
keystroke = "cmd+shift+d"
method = "plugin.capture.daily"
```

Also supported: plugin settings (`[plugins]`), action socket (`[socket]`), and per-project/global `search_facets` mappings for SQLite/FTS facets (`class`, `workspace`, `entity`, `asset`, `library`, `root`, `is`; `ext` is derived). See `docs/architecture/configuration.md`.

## File lookup by task

| Task | Start here |
|---|---|
| App, native windows/tabs, toolbar, sidebar | `App/WorkspaceApplicationCoordinator.swift`, `UI/NativeWorkspaceWindowView.swift`, `App/NativeWorkspaceToolbarController.swift`, `App/WindowAccessor.swift` |
| Tab content and lifecycle | `UI/WorkspaceTabView.swift`, `UI/WorkspaceTabController.swift`, `UI/WorkspaceTabContentRuntimes.swift` |
| Miller browser and details sorting | `UI/MillerColumnsView.swift`, `UI/MillerDetailsColumn.swift`, `Core/Notes/NotesWorkspaceModel.swift` |
| Command palette and actions | `docs/architecture/palette.md`, `Core/Palette/`, `UI/Palette/`, `Core/Actions/`, `App/ActionWorkspaceActions.swift` |
| Web editor and bridge | `WebEditor/src/lib/`, `WebEditor/src/App.tsx`, `WebEditor/src/bridge.ts`, `UI/Web/EditorWebView.swift` |
| CSV, PDF, image | `UI/CSV/README.md`, `UI/Retained/`, `UI/Web/` |
| Excalidraw canvases | `UI/Web/CanvasDocumentView.swift`, `WebEditor/src/canvas.tsx`, `WebEditor/build.ts` |
| Plugins and the `nv` API | `docs/architecture/plugins.md`, `docs/plugins/authoring.md`, `NVModern/Plugins/nv.d.ts`, `Core/Plugins/`, `App/PluginAppEnvironment.swift` |
| Session, search, config | `Core/Session/WorkspaceSessionStore.swift`, `Core/Search/`, `Core/Config/NVModernConfig.swift`, `docs/architecture/configuration.md` |
| Build, package, version | `Makefile`, `project.yml`, `NVModern/Info.plist` |

## CSV notes

- The CSV preview/editor is a native AppKit spreadsheet surface in `NVModern/UI/CSV/CSVGridNativeCanvasView.swift`, not `NSTableView`.
- On the main workspace path, CSV hosting is controller-owned (`RetainedCSVPreviewSession.swift` via `WorkspaceCSVTabContentRuntime`), and inactive tabs detach the native surface instead of recreating ownership from a workspace cache.
- Keep the top chrome (header/formula area) primarily subview-based. Reverting it back to mostly custom draw is likely to regress rendering.
- `CSVGridTransferCodec.parseRows(...)` is the active load/parser path. The old `TabularData` fast path is intentionally not used by default.
- Trailing fully-empty rows are trimmed during serialization; interior empty rows must be preserved.
- Cursor ownership in the CSV grid is still fragile. If you touch cursor behavior, audit cursor rects, tracking areas, passthrough subviews, and the overlay editor together.

## Workflow

1. Read this file plus the relevant source files/docs for your task. For pi/agent docs, also read the requested docs before implementing.
2. For workspace/tab changes, identify the correct owner first: AppKit window coordinator, native window shell, `TabWorkspaceView`, tab controller/content runtime, or action runtime.
3. Make the smallest viable change.
4. Run `make` to verify native + web build. Run `make test-web` for editor-library/plugin changes. Use `make run` for manual smoke testing.
5. If packaging changed, run `make package`.
6. Validate no regressions in tab/shell behavior.

## Smoke checklist

After substantial shell changes, verify native tab creation (`Cmd+T` and the tab-bar add button), drag/reorder/close, sidebar visibility across new tabs, launchpad-to-document transition, and quit/relaunch restoration. Check Miller mouse and keyboard navigation, the palette presets and dismissal, in-document find/navigation, and detached CSV/PDF/image content. Verify editor loading from bundled resources and the applicable shortcuts. If packaging changed, run `make package` and inspect its `.app` and `.dmg`.

## Diagnostics

- Web inspector is enabled in debug builds (`AppDelegate` sets `WebKitDeveloperExtras`, `EditorWebView` sets `isInspectable`).
- Bridge diagnostics log with `[NVModern][Web*]` prefixes. Useful for JS runtime errors, script load failures, request/response tracing, context ordering, and scroll restore.
- Local diagnostics are managed by `LocalDiagnosticsCenter` and workspace activation traces by `WorkspaceActivationTraceCenter`.
- Common logs live under `/tmp/nvmodern/` for build/test/package and in the app diagnostics path reported at launch.
