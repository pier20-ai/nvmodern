---
id: 0025
title: Plugins Settings Pane with Enable/Disable and Per-Plugin Settings
status: open
type: feature
area: plugins
priority: P2
created: 2026-10-08
updated: 2026-10-08
blocked_by:
  - ./0016-isolate-tests-from-user-plugins.md
  - ./0017-plugin-only-reload-path.md
  - ./0018-surface-plugin-load-errors.md
related:
  - ../architecture/plugins.md
  - ../plugins/authoring.md
---


# Plugins Settings Pane with Enable/Disable and Per-Plugin Settings

## Approved design — 2026-10-08

Use a native sidebar inspired by modern macOS System Settings: Workspaces,
Writing, Appearance, Shortcuts, and Plugins. Writing groups mentions and text
substitutions. Collection rows open details in the content pane, keeping the
window to two columns. Configuration-file utilities live in a toolbar menu.

The user approved **live-by-default** persistence: every change writes to disk;
external edits update the UI. There is no Apply, Save, Revert, pending-edit
state, or external-change banner. Critical changes have dedicated in-window
Undo notices: workspace removal/folder changes, substitution removal, and
plugin-settings reset. Workspace removal never deletes files.

## Implementation

- Structured, published plugin inventory includes source path, built-in/user
  origin, running/disabled/failed state, actions, load error, and declared schema.
  User overrides remain authoritative even when disabled. Sanitized-name
  collisions produce load failures. Disabled files never execute for discovery.
- `[plugins] disabled = ["name"]` removes actions and both shortcut scopes
  without touching plugin files. Re-enable restores them; saved values survive.
- Synchronous, load-only `nv.settings.define` declares unique keys with typed
  defaults for `text`, `bool`, `number`, `choice`, and workspace-relative `folder`.
  `nv.settings.get()` merges valid stored values over defaults; invalid known
  values use defaults. Unknown keys and absent-plugin tables are retained.
- Native controls edit `[plugins.settings.<name>]` immediately. The folder
  picker names its default-workspace reference and rejects escapes. Reset clears
  only the selected plugin's overrides and offers Undo.
- A single config monitor watches external edits, compares bytes to avoid
  duplicate app-write notifications, and classifies plugin-only changes for
  targeted reload. Other preferences follow the general runtime refresh path.
  Writes reread disk and merge unrelated external edits; conflicting values and
  malformed TOML are never silently overwritten.
- `app.plugins.list` adds structured `infos` while retaining its old fields.
  `app.plugins.reload` uses the targeted path. Shortcuts lists plugin actions
  from the registry, separates in-app/global scope, supports explicit unbinding,
  and labels menu-owned shortcuts as built-in rather than editable conflicts.

## Validation

`make` and `make test` passed; the suite has 388 tests, two existing skips, and
zero failures. `make typecheck-plugins` passed. Tests cover schema validation,
default/override merging, disabled user overrides, partial-load cleanup,
config round trips, unknown values, external edit merging/conflicts, duplicate
refresh suppression, malformed TOML protection, and workspace removal Undo.
Live checks confirmed the native sidebar, discovered inventory, all five
controls in the form, and text changes reaching disk while typing without
commit/Save. The first live write exposed a default-workspace identity issue;
it is fixed and covered by reload/repeated-write tests, including a non-first
default workspace. The temporary fixture was removed and the exact migrated
user config restored after checking for unrelated edits.

The Mac relocked during verification. Remaining manual checks: external
config edits reflected in the open window, the other four controls, plugin
disable/re-enable, critical-action Undo, and palette/editor smoke checks.
Implementation and automated validation are complete; the ticket stays open
until those checks can run.

The tests also caught boxed JavaScriptCore numbers `0`/`1` being mistaken for
booleans. `ActionValue` now inspects boxed NSNumber identity before scalar casts;
the settings bridge test covers numeric zero/one and booleans together. The
XCTest app host also avoids claiming/unlinking the user's action socket when
live-config fixtures post notifications. Invalid TOML cannot reactivate disabled
plugins through a plugin-file reload; repairing it refreshes the runtime.

## Non-goals

Plugin installation/marketplaces, per-project plugin sets, and a complete
arbitrary action shortcut editor remain separate work.
