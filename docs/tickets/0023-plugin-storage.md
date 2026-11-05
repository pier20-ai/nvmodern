---
id: 0023
title: Per-Plugin Persistent Storage (nv.storage)
status: open
type: feature
area: plugins
priority: P3
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/plugins.md
---

# Per-Plugin Persistent Storage (nv.storage)

## Goal

Plugins lose all state on reload. Give each plugin a small JSON key–value
store that survives reloads and relaunches:

```ts
nv.storage.get(key: string): Promise<JSONValue | null>
nv.storage.set(key: string, value: JSONValue): Promise<void>
nv.storage.remove(key: string): Promise<void>
nv.storage.keys(): Promise<string[]>
```

## Context

- App support directory: `~/Library/Application Support/nvModern/` (session
  store lives there; see `WorkspaceSessionStore`).
- Plugin names are file names reduced to `[A-Za-z0-9_-]`
  (`PluginHost.Source.pluginName`), safe as file names.

## Steps

1. `Core/Plugins/PluginStorage.swift`: one JSON file per plugin at
   `<App Support>/nvModern/plugins/<name>.json`, a `[String: ActionValue]`
   dictionary. Load lazily on first access, write atomically on every `set`
   and `remove`. Cap a store at 1 MB; `set` beyond that throws
   `invalid_arguments` with the size in `details`.
2. Host blocks `storageGet/Set/Remove/Keys(plugin, …)`; prelude `nv.storage`.
   Values round-trip through `ActionValue` (so `undefined` is rejected,
   `null` is stored).
3. `nv.d.ts` and docs (`authoring.md`: when to use storage vs a note;
   `plugins.md`: file location and limits).
4. Tests: round trip across `host.reload`; isolation between two plugins;
   size cap.

## Acceptance

- A plugin can remember "last used folder" across reloads and relaunches.
- Deleting a plugin file does not delete its store (explicit, documented).

## Non-goals

- Syncing storage, or exposing it in Settings.
