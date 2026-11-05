---
id: 0027
title: Documentation for the Open-Source Release
status: open
type: docs
area: docs
priority: P1
created: 2026-10-08
updated: 2026-10-08
related:
  - ../../README.md
  - ../../AGENTS.md
  - ../architecture/plugins.md
---

# Documentation for the Open-Source Release

## Goal

The repository is being prepared for a public release. The historical plans
(`docs/archive/`, `docs/proposals/`) and the unlinked `Vendor/Bonsplit/`
package were removed on 2026-10-08. What remains is accurate but uneven:
some areas have deep references, others have nothing. Write the documentation
a newcomer needs, and nothing else.

## What exists

| Document | State |
|---|---|
| `README.md` | Accurate but written for the pre-plugin app; needs a rewrite for a public audience |
| `AGENTS.md` | Current; the agent-facing source of truth. Keep it as the constraints file, not the overview |
| `docs/architecture/plugins.md`, `docs/plugins/authoring.md` | Current and detailed (October 2026) |
| `docs/architecture/palette.md`, `action-system.md`, `configuration.md` | Current after the capture removal; `configuration.md` still has pre-plugin phrasing in places |
| `docs/architecture/arbor.md`, `arbor-design-notes.md`, `ArborKernel/README.md` | Describe the Racket kernel; check which parts are shipped vs planned |
| `docs/architecture/search-guide.md`, `visual-language.md` | Not reviewed since spring; verify against code |
| `NVModern/UI/CSV/README.md` | Component-level notes; current |
| `NVModern/WebEditor/docs/cmeditor-README.md`, `cmeditor-API.md` | Describe the editor library under its old name (`@nv3/editor`, March 2026); partly stale |
| `NVModern/WebEditor/docs/interactive-markdown-design.md` | A design proposal; mark as proposal or remove |
| `NVModern/WebEditor/THEMING.md` | Theme customisation; current |
| `docs/inspiration/synthesis.md` | Early product direction; background only |

## What is missing

1. **A public `README.md`**: what nvModern is (one paragraph, one screenshot),
   who it is for, install (`make setup && make run`, and the DMG from
   `make package`), the thirty-second tour (`Cmd+T`, `Cmd+K`, `Cmd+N`,
   Miller columns, native tabs), the config file, plugins in three lines with
   a link to the authoring guide, how to contribute, licence. Under 150 lines.
2. **`LICENSE`**: the owner must choose the licence; the ticket cannot. Put
   the file at the root and name it in `README.md` and in `project.yml`'s
   Info.plist copyright if present.
3. **`CONTRIBUTING.md`**: toolchain, `make` targets (never `xcodebuild`/`bun`
   directly), where tests live (`NVModernTests`, `make test-web`), the
   smoke checklist from `AGENTS.md`, branch and commit conventions in use
   (conventional commits with emoji, see `git log`), and a pointer to
   `AGENTS.md` for the hard rules.
4. **`docs/architecture/overview.md`**: one page that places the pieces:
   AppKit shell and native tabs, SwiftUI views, the action system, the
   palette, the WebEditor bundle and bridge, live sync and the search index,
   session persistence, plugins, the Arbor kernel. Link to each deeper
   document. Include one diagram (text or SVG) of a keystroke travelling from
   a hotkey to a plugin action to a file write.
5. **`docs/architecture/web-editor.md`**: replace the two `cmeditor-*` files
   with one current document: library layout (`src/lib/` plugins, calc, org,
   theme), the host adapter (`src/App.tsx`, `bridge.ts`), the bridge protocol
   (move the "Bridge protocol" section out of `AGENTS.md` into here and leave
   a pointer), the IIFE constraint, the CodeMirror patch in `patches/`, and
   how to run `make dev`. Delete the `cmeditor-*` files once covered.
6. **`docs/architecture/configuration.md` pass**: remove remaining pre-plugin
   phrasing, confirm every key against `NVModernConfigSchema.swift`, and keep
   the two example configs minimal.
7. **Arbor status note** at the top of `docs/architecture/arbor.md`: what
   ships, what requires Racket, what is design only.

## Steps

1. Write items 1, 3, 4 first; they unblock the release. Item 2 needs the
   owner's decision; leave a `LICENSE` placeholder out of the tree rather
   than guessing.
2. Then 5 and 6, deleting superseded files as each is covered.
3. Then 7 and a verification pass over `search-guide.md` and
   `visual-language.md`: fix or delete, do not leave "may be outdated" notes.
4. Update the "File lookup by task" table in `AGENTS.md` to point at the new
   documents, and remove the Bridge protocol section once `web-editor.md`
   holds it.
5. Run `make test` and `tsc -p NVModern/Plugins` at the end; docs changes
   must not touch behaviour, and the examples must still type-check.

## Acceptance

- A reader with Xcode and no prior contact can build, run, open their notes
  folder, create a capture plugin, and run the tests, using only `README.md`,
  `CONTRIBUTING.md` and `docs/plugins/authoring.md`.
- Every file under `docs/` and `NVModern/WebEditor/docs/` is either current
  or deleted; no document describes a shell or feature that does not exist.
- `grep -rn -i "bonsplit\|quick_capture\|capture.run" docs README.md` is empty.

## Non-goals

- Marketing copy, a website, or screenshots beyond one for the README.
- Documenting unbuilt features (write a ticket instead).
