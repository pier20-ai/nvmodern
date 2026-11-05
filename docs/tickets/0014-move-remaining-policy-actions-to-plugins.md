---
id: 0014
title: Move openInZed and createFromClipboard to Plugins; Drop Dead Write Policy
status: open
type: cleanup
area: plugins
priority: P2
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/plugins.md
  - ./0013-retire-action-recipes.md
---

# Move openInZed and createFromClipboard to Plugins; Drop Dead Write Policy

## Goal

Two built-in actions encode personal policy (which external editor; how a
clipboard note is named). Both are a few lines over existing `nv`
primitives. Move them out of core and remove a write-policy flag nothing sets.

## Context

- `workspace.document.openInZed`: `NVModern/App/ActionWorkspaceActions.swift`
  (descriptor near line 1606; handler earlier in the same file). Opens the
  current document's absolute path in Zed via `NSWorkspace`.
- `workspace.note.createFromClipboard`: same file (descriptor near line 1926).
  Takes `folder`, `openIn`; names the file from the clipboard's first line via
  `clipboardFileName(from:now:)`; opens it.
- Palette rows, MCP catalog (`ActionMCPCatalog.swift` — check whether either
  is listed), `ArborEffectBroker` allowlist, `CommandCatalog.swift`, and
  `docs/architecture/action-system.md` reference them.
- `DocumentSurfaceBridgeService.WritePolicy.allowsWorkspaceWrites`
  (`NVModern/UI/Web/DocumentSurfaceBridgeService.swift`) is only ever `true`
  since scratchpads were removed.
- Launching an external app is not in `nv` today. Opening a file in another
  app needs one small primitive (see step 1); do not add a general shell.

## Steps

1. Add `nv.workspace.openExternally(file, options?: { app?: string })` to the
   API: `nv.d.ts`, `PluginPrelude.swift`, a host block in `PluginHost.swift`,
   and `PluginHostEnvironment.openExternally(fileURL:appName:)` implemented in
   `PluginAppEnvironment` with `NSWorkspace.shared.open(_:withApplicationAt:)`
   (look the app up by name with `NSWorkspace.urlForApplication(withBundleIdentifier:)`
   falling back to `/Applications/<name>.app`); without `app`, use
   `NSWorkspace.shared.open(url)`. Add a `PluginHostTests` case through the
   stub environment.
2. Write the two plugins in `NVModern/Plugins/examples/` (type-checked) and
   copy them into `~/.config/nvmodern/plugins/`:
   - `open-in-zed.js`: palette category `File`, `when: "activeDocument"`,
     `nounArguments: { note: "path" }`; resolves `args.path` or
     `nv.workspace.activeDocument()` and calls `openExternally(path, { app: "Zed" })`.
   - `clipboard-note.js`: palette category `Create`; reads `nv.clipboard.read()`,
     derives the file name the way `clipboardFileName(from:now:)` does (first
     non-empty line, sanitised, 48 chars, `-yyyyMMdd-HHmmss.md` suffix,
     `clipboard` when empty), then `nv.actions.invoke("workspace.note.create", ...)`
     with `openIn: "currentTab"`.
3. Delete both built-in actions, their descriptors, `clipboardFileName`,
   their MCP/Arbor/CommandCatalog entries, and their rows in
   `docs/architecture/action-system.md`. Update
   `NVModernTests/PaletteActionCatalogTests.swift` (`folderVerbs` list and any
   method lists naming them).
4. Remove `WritePolicy.allowsWorkspaceWrites` and the two guards that read it.
5. Document `openExternally` in `docs/plugins/authoring.md` (Calling built-in
   actions / workspace section) and `docs/architecture/plugins.md` (host table).

## Acceptance

- `make test` and `tsc -p NVModern/Plugins` pass.
- "Open in Zed" and "Note from clipboard" behave as before from the palette.
- `grep -rn 'openInZed\|createFromClipboard\|allowsWorkspaceWrites' NVModern NVModernTests docs` is empty.

## Non-goals

- Moving `markdown.selection.*` or any editor-bridge command.
- A general process/shell primitive.
