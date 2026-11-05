---
id: 0021
title: Dynamic Palette Pickers for Plugins
status: open
type: feature
area: plugins
priority: P2
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/plugins.md
  - ../architecture/palette.md
---

# Dynamic Palette Pickers for Plugins

## Goal

`nv.ui.pick(items)` takes a fixed array. Plugins that search (notes by a
custom ranking, headings in a file, results of `workspace.search.query`) need
rows that depend on the query. Allow a function source:

```ts
pick<V>(source: PickItem<V>[] | ((query: string) => PickItem<V>[] | Promise<PickItem<V>[]>), options?): Promise<V | null>
```

## Context

- `UI/Palette/PluginPickCenter.swift` stores `[PluginPickItem]` per request and
  ranks them in `sections(for:query:)` (synchronous).
- `PaletteResultsResolver.sections(frame:rawQuery:context:)` handles
  `frame.pluginPick` and calls the center for `.items`/`.text`.
- `PaletteResultsResolver.debounceNanoseconds` picks a delay by source kind;
  plugin frames currently get none.
- JS functions can only be called from `PluginHost` (it owns the context and
  the value conversion: `PluginHost.pickItem`, `settle`, `takeException`).
- `PaletteSession` cancels stale resolves by generation; the resolver is
  `async`, so an awaited provider fits.

## Steps

1. `nv.d.ts`: widen `pick`'s first parameter as above. Document that the
   function is called on every keystroke after a short debounce, with the
   trimmed query, and that a slow provider's stale results are discarded.
2. `PluginPrelude.swift`: if `typeof source === "function"`, call
   `host.pickDynamic(options, source)`; else the existing `host.pick("items", ...)`.
3. `PluginHostEnvironment.swift`: add `provider: ((String) async throws -> [PluginPickItem])?`
   to `PluginPickRequest` (nil for static). `PluginHost`: implement
   `pickDynamic` by building a Swift closure that calls the JS function with
   the query, awaits with `settle`, converts with `pickItem`, and throws on JS
   exceptions; pass it in the request.
4. `PluginPickCenter`: store the provider; add
   `func sections(for pick:, query:) async -> [PaletteSection]` that, for a
   provider-backed request, calls the provider and maps items to rows
   (no re-ranking: the plugin owns order). Keep the sync path for arrays.
   Catch provider errors: log via `paletteDebugLog` and return an empty list.
5. `PaletteResultsResolver`: `await` the center; add a 35 ms debounce for
   provider-backed plugin frames (reuse `Debounce.notesNanoseconds`).
6. Empty-state text: `PaletteSession`'s empty message for plugin frames should
   read "No matches for “query”" once a provider returned nothing.
7. Tests: `PluginHostTests` case where a plugin passes a function that returns
   rows based on the query; drive the stub environment's `pick` to call the
   provider with "ab" and assert the rows. A `PluginPickCenter` test for the
   async path and the error path.
8. Docs: `docs/plugins/authoring.md` (Asking the user) with an example built
   on `workspace.search.query`; `docs/architecture/plugins.md` (Palette pickers).

## Acceptance

- A plugin picker backed by `workspace.search.query` filters as you type with
  no visible lag for typical note counts.
- Escape still resolves `null`; stale results from a slow provider never
  replace newer ones.
- `make test` and `tsc -p NVModern/Plugins` pass.

## Non-goals

- Streaming/incremental rows; a provider returns a whole list per query.
