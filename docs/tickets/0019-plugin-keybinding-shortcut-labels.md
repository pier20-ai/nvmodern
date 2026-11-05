---
id: 0019
title: Show Plugin Keybindings as Palette Shortcut Labels
status: open
type: improvement
area: palette
priority: P3
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/palette.md
---

# Show Plugin Keybindings as Palette Shortcut Labels

## Goal

Palette rows show a shortcut glyph for actions bound in `[[keybindings]]`,
`CommandCatalog` defaults, or the static menu table, but not for a plugin's
own `keybinding`. The row for a plugin action with `keybinding: "cmd+shift+d"`
shows nothing.

## Context

- `NVModern/App/PaletteShortcutResolver.swift`:
  `shortcutLabel(forMethod:projectRootPath:)` resolves user keybindings, then
  `CommandCatalog`, then a static table; results are cached per project root
  and invalidated by `PaletteShortcutResolver.invalidate()` in
  `AppDelegate.reloadActionConfiguration()`.
- `PluginHost.shared.keybindings` is `[ActionKeybindingDefinition]` with
  `invocation.methodName` and `keystroke`.
- `AppDelegate` already drops a plugin binding when a configured row targets
  the same method, so the user row must win here too.

## Steps

1. In `shortcutLabel`, after the user `[[keybindings]]` lookup and before
   `CommandCatalog`, look up `PluginHost.shared.keybindings` by method.
2. Format with the same glyph formatter the other sources use.
3. Ensure `invalidate()` is called wherever plugins reload (it is in
   `reloadActionConfiguration`; if ticket 0017 lands first, call it from the
   new plugin-only reload too).
4. Add a unit test in `NVModernTests` (there is `KeystrokeFormattingTests.swift`
   for the formatter) covering: plugin binding shown; user binding for the
   same method wins.

## Acceptance

- A plugin action with `keybinding` shows its glyphs in `Cmd+Shift+K` and in
  the `Cmd+N` frame.
- Adding a `[[keybindings]]` row for that method changes the glyphs to the
  configured ones after reload.

## Non-goals

- Showing `globalHotkey` in the palette (it is not an in-app shortcut).
