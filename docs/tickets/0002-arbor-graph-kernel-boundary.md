---
id: 0002
title: Remove the Browser Graph Prototype
status: done
type: cleanup
area: arbor-graph
priority: P0
created: 2026-08-12
updated: 2026-08-12
related:
  - ../architecture/arbor.md
  - ./0003-arbor-racket-datalog-foundation.md
---

# Remove the Browser Graph Prototype

## Goal

Remove the unused DataScript graph so Arbor has no competing semantic authority before the Racket graph is built.

## Ownership

- Source owns authored bytes and stable identity.
- Racket will own Arbor semantics and Datalog evaluation.
- The renderer owns Markdown presentation, structural gestures, local view state, and optimistic editing.

## Work

- Delete `NVModern/WebEditor/src/arbor/graph/`.
- Delete the graph worker entry point and its build step.
- Remove DataScript from the WebEditor dependencies and lockfile.
- Remove graph-only host and performance fields.
- Delete the obsolete `ArborSurface.tsx.bkp`; Git preserves the checkpoint.
- Preserve the active surface, outline store, source codec, Markdown parser, and kernel prototype.

## Acceptance

- No source reference to DataScript, `ArborGraphClient`, or the graph worker remains.
- The web build emits no graph worker.
- Active Arbor behavior is unchanged.
- Arbor typecheck, focused tests, web build, native tests, full build, and `git diff --check` retain their established status.

## Non-goals

- Replacing the graph in this change.
- Changing the Racket protocol.
- Changing renderer behavior.
- Adding a temporary browser index.
