---
id: 0022
title: Plugin Event Hooks (nv.on)
status: open
type: feature
area: plugins
priority: P3
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/plugins.md
---

# Plugin Event Hooks (nv.on)

## Goal

Let a plugin react to things the app does, starting with the two events
that have concrete uses (stamping a modified date; keeping a daily index):

```ts
nv.on("note.saved", ({ relativePath, absolutePath, projectRootPath }) => void | Promise<void>): () => void
nv.on("note.opened", ({ relativePath, absolutePath, projectRootPath }) => void | Promise<void>): () => void
```

`nv.on` returns an unsubscribe function. Handlers are dropped on reload.

## Context

- Saves: `NotesWorkspaceModel.saveTextNote`, `saveTextNoteAsync`,
  `saveDataNote` (`NVModern/Core/Notes/NotesWorkspaceModel.swift`), each
  after `liveSyncController.completeLocalWrite`.
- Opens: `WorkspaceActionRuntime.openDocument(_:disposition:)` implemented in
  `NativeWorkspaceWindowView`; the tab-side point where a document becomes
  the displayed one is in `WorkspaceTabView` (search `displayedDocument`).
  Emit from the runtime's `openDocument` and from session restore only if a
  use case needs the latter (default: not on restore).
- `PluginHost` runs JS on the main actor; emitting must not block the save.

## Steps

1. `nv.d.ts`: add the `on` signature with the two event names and payloads as
   a discriminated map, and the unsubscribe return.
2. `PluginHost`: keep `handlers: [String: [(id: Int, fn: JSValue, plugin: String)]]`;
   host block `on(plugin, event, fn) -> Int` and `off(id)`; prelude exposes
   `nv.on` returning `() => host.off(id)`. Validate event names; reject
   unknown ones with a `TypeError` at registration.
3. `PluginHost.emit(_ event: String, payload: [String: Any])`: for each
   handler, call on the next main-queue turn (`DispatchQueue.main.async`),
   `settle` a returned promise, log failures as
   `[NVModern][Plugin][<name>] on(<event>) failed: …`. A handler must never
   throw into the emitter.
4. Guard against loops: a handler that saves the same note triggers
   `note.saved` again. Suppress re-entrant emission for the same
   `(event, absolutePath)` while a handler chain for it is running.
5. Call `emit` from the three save methods (after a successful write, with
   the model's `projectRootPath`) and from the runtime's `openDocument` for
   `.workspaceNote` and `.externalMarkdown`.
6. Clear handlers in `PluginHost.unload()`.
7. Tests: `PluginHostTests` cases: handler receives payload; unsubscribe
   stops delivery; a throwing handler does not affect other handlers; the
   re-entrancy guard holds. Use a direct `host.emit(...)` call.
8. Docs: `docs/plugins/authoring.md` (new "Reacting to events" section with
   the loop warning) and `docs/architecture/plugins.md`.

## Acceptance

- A plugin can append a line to a log note when any note is saved without
  recursing.
- Saving performance is unchanged when no handler is registered (emit is a
  dictionary lookup).

## Non-goals

- Events for external (live-sync) changes, app activation, or palette
  activity. Add them when a plugin needs them.
