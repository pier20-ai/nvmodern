---
id: 0017
title: Reload Plugins Without a Full Config Reload
status: done
type: improvement
area: plugins
priority: P2
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/plugins.md
---

# Reload Plugins Without a Full Config Reload

## Completion status — 2026-10-08

Implementation and automated validation are complete. Plugin directory changes
call `reloadPluginsAndShortcuts(appConfig:)` directly, rebuilding plugins,
keybindings, global hotkeys, and the palette shortcut cache. Full config reloads
call the same helper while retaining their recipe and socket handling. FSEvents
latency remains 0.3 seconds.

`make` and `make test` passed (377 tests, two skipped, zero failures). A live
fixture save loaded its new action and registered both global hotkeys without
any socket restart log entry or `contextReceived` event. The unchanged broken
plugin also produced no repeat notification. Evidence:
`/tmp/nvmodern/plugin-batch-smoke.log` and local diagnostics.

Final validation after the user made the Mac available: a fixture title change
appeared in the palette after saving, the palette action executed, and its
in-app shortcut executed after reload. Socket inode and listener were preserved,
with no new editor context acknowledgement. Saving an inert custom-CSS path in
Settings reloaded plugins and rebuilt their shortcuts/hotkeys through the full
config path; restoring the original setting did the same. The configuration was
then restored byte-for-byte from its backup, and all fixtures were removed.
Evidence: `/tmp/nvmodern/plugin-batch-final-smoke.log` and local diagnostics.

Carbon global-hotkey registration succeeded. App-targeted synthetic key presses
did not trigger Carbon callbacks, so physical global-hotkey invocation remains
part of the final notification sign-off in ticket 0018.

## Goal

Saving a plugin file posts `.nvModernConfigDidChange`, which runs
`AppDelegate.reloadActionConfiguration()` in full: config re-read, socket
stop/start, keybinding rebuild, theme watcher refresh, and a CSS re-push to
every open editor (`WorkspaceTabView` observes the same notification). A plugin
save should only touch plugin state.

## Context

- `AppDelegate.applicationDidFinishLaunching` creates
  `pluginDirectoryWatcher = PluginDirectoryWatcher { post(.nvModernConfigDidChange) }`.
- `reloadActionConfiguration()` does, in order: recipes, `reloadPlugins`,
  keybinding merge (config + plugin defaults), `PaletteShortcutResolver.invalidate()`,
  global hotkeys (unregister all, re-register plugin ones), socket restart.
- `GlobalHotkeyManager.unregister()` drops every hotkey; registration is
  per keystroke with a closure.

## Steps

1. Extract from `reloadActionConfiguration()` a method
   `reloadPluginsAndShortcuts(appConfig:)` that performs: `reloadPlugins`,
   the keybinding merge, `PaletteShortcutResolver.invalidate()`, and global
   hotkey re-registration. `reloadActionConfiguration()` calls it after the
   config is loaded.
2. Make the plugin watcher call `reloadPluginsAndShortcuts(appConfig: NVModernConfigLoader.loadAppConfig())`
   directly instead of posting the notification. Keep the notification path
   for genuine config changes.
3. Debounce is already 0.3 s in `PluginDirectoryWatcher`; keep it.
4. Confirm the editor CSS re-push no longer happens on a plugin save (watch
   `web.bridge/contextReceived` breadcrumbs for open tabs: there should be
   none after saving a plugin file).

## Acceptance

- Saving a plugin file reloads plugins (new action visible in the palette,
  hotkeys work) without restarting the socket or re-pushing editor contexts.
- Editing `config.toml` through Settings still reloads plugins as well.
- `make test` passes.

## Non-goals

- Per-file incremental reload; all plugins still reload together.
