---
id: 0020
title: First-Run Plugin Experience: Bundled Capture Plugin and nv.d.ts
status: open
type: feature
area: plugins
priority: P2
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/plugins.md
  - ../plugins/authoring.md
---

# First-Run Plugin Experience: Bundled Capture Plugin and nv.d.ts

## Goal

A fresh install has no captures (`Cmd+N` shows an empty frame) and no type
definitions next to the user's plugins. Ship a built-in capture plugin with
safe defaults, and copy `nv.d.ts` into the user's plugins folder so
`/// <reference path="./nv.d.ts" />` works without the repository.

## Context

- `AppDelegate.reloadPlugins` already looks for
  `Bundle.main.resourceURL/BuiltinPlugins/*.js`; nothing ships there.
- `project.yml` excludes `NVModern/Plugins/**` from sources and does not add
  it as a resource. `NVModern/BuiltinThemes` shows the pattern for a folder
  resource (`type: folder, buildPhase: resources`).
- A user plugin with the same file name replaces a built-in
  (`PluginHost.reload`).
- `NVModern/Plugins/examples/capture-templates.js` assumes a `Templates`
  folder and throws when a template is missing; it is not suitable as a
  default.

## Steps

1. Create `NVModern/Plugins/builtin/capture.js`:
   - `daily` (`Capture`, key `d`): today's `Daily/yyyy-MM-dd.md`, created with
     body `# yyyy-MM-dd\n\n` if missing, via `workspace.note.create`
     (`openIn: "currentTab"`), else `workspace.note.open`.
   - `scratch` (`Capture`, key `s`): `Scratch/yyyy-MM-dd HH-mm-ss.md`, empty
     body, `openIn: "newTab"`, with the copy-suffix loop from the example.
   - Constants at the top; a header comment saying "copy this file to
     `~/.config/nvmodern/plugins/capture.js` to change folders".
   Add `builtin/*.js` to the `tsconfig.json` `include` list so it type-checks.
2. In `project.yml`, add `NVModern/Plugins/builtin` as a folder resource named
   `BuiltinPlugins` (xcodegen: `path: NVModern/Plugins/builtin`, `type: folder`,
   `buildPhase: resources`; if the folder name cannot be renamed on copy, change
   `AppDelegate.reloadPlugins` to look for `builtin` instead). Also add
   `NVModern/Plugins/nv.d.ts` as a resource.
3. On launch, after plugins load, if `~/.config/nvmodern/plugins/` exists and
   `nv.d.ts` there is missing or its contents differ from the bundled copy,
   write the bundled copy there. Never create the folder (Settings' "Open
   Folder" does that). Log one line when written.
4. `app.plugins.list` should mark built-ins (`isBuiltin`) and the override
   relationship: return `plugins: [{ name, path, isBuiltin }]` instead of a
   name list; update the single caller (none in code; docs mention it).
5. Document in `docs/plugins/authoring.md` ("Your first plugin": the
   reference path is now `./nv.d.ts`; a note on overriding `capture.js`) and in
   `docs/architecture/plugins.md` (Discovery).

## Acceptance

- A machine with an empty plugins folder gets `Cmd+N` with Daily and Scratch.
- Creating `~/.config/nvmodern/plugins/capture.js` replaces both built-ins.
- `nv.d.ts` appears in the plugins folder after launch and is refreshed when
  the bundled one changes.
- `make test`, `make package` and `tsc -p NVModern/Plugins` pass.

## Non-goals

- Bundling the org or quick-capture examples (they encode personal paths).
