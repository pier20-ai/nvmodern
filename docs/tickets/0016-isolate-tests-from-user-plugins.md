---
id: 0016
title: Do Not Load User Plugins in the Test Host
status: done
type: bug
area: plugins
priority: P1
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/plugins.md
---

# Do Not Load User Plugins in the Test Host

## Completion — 2026-10-08

The XCTest host skips plugin discovery and stops the plugin directory watcher.
Its shared host has no plugin methods, load errors, keybindings, or global
hotkeys; dedicated `PluginHostTests` continue using private hosts and registries.
`Capture` remains an allowed palette category. No additional socket or config
guards were introduced in this ticket.

`make` passed. `make test` passed with a malformed user plugin present before
launch: 377 tests, two skipped, zero failures. The log records "Skipping plugins
in the XCTest host", and a new assertion verifies the shared host and registry
contain no plugins or their shortcuts. Log:
`/tmp/nvmodern/test-20261008-155443.log`. Disposable fixtures were removed.

This isolates plugin discovery; native UI tests still create and focus windows.
It does not make the entire test suite suitable for unattended use on a desktop
being used for other work.

## Goal

`make test` launches the app as the XCTest host. `AppDelegate` then loads
whatever is in the developer's `~/.config/nvmodern/plugins/` into
`ActionRegistry.shared`, so tests that enumerate the shared registry see
machine-specific actions. This already forced a change to
`PaletteActionCatalogTests.testPaletteCategoriesAreFromTheKnownSet`.

## Steps

1. In `AppDelegate.reloadPlugins(configURL:)` return early (loading nothing)
   when `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`.
   Log one line saying plugins are skipped under tests.
2. Do the same for plugin global hotkeys (they are registered from
   `PluginHost.shared.globalHotkeys`, so skipping the load is enough — verify).
3. Consider the same guard for the action socket and config quick paths only
   if they also interfere with tests; otherwise leave them.
4. Add a comment in `PluginHostTests` noting the tests construct their own
   `PluginHost`/`ActionRegistry` and never depend on the shared one.

## Acceptance

- With a deliberately broken file in `~/.config/nvmodern/plugins/`,
  `make test` still passes and `app.plugins.list` from the test host would
  report nothing loaded.
- `PaletteActionCatalogTests` no longer needs user plugin categories; keep
  `Capture` in its allowed set anyway (it is a real category).

## Non-goals

- Changing how production builds discover plugins.
