---
id: 0009
title: Add Capability-Gated Effect Producers
status: done
type: feature
area: arbor
priority: P0
created: 2026-08-12
updated: 2026-08-12
completed: 2026-08-12
blocked_by:
  - ./0006-arbor-explicit-materialized-results.md
related:
  - ../architecture/arbor-design-notes.md
---

# Add Capability-Gated Effect Producers

## Goal

Run explicit `!` producers through a small trusted effect broker and materialize
successful output through the existing live/snapshot/detached state machine.

## Syntax

```text
! (clock/now)
! (fs/read "Data/report.md")
! (process/run "rg" "TODO" ".")
```

Racket validates the declaration and returns an effect plan. The native shell or
development server owns permission prompts and OS execution, then completes the
pending plan through the kernel. The renderer only calls `producer/run`.

## Capability contract

- `clock/now` needs no grant.
- `fs/read` requests the named vault-relative path.
- `process/run` requests the executable and argument vector in the workspace.
- Grants are trusted host state and cannot be minted by a document or renderer.
- The host offers Allow Once, Allow for This Node, or Cancel.

## Execution contract

- Expansion and document replacement are inert.
- A user command creates one execution ID; retries of that ID cannot execute twice.
- Execution has a five-second timeout and a one-megabyte combined output limit.
- Success materializes ordinary result blocks.
- Denial, timeout, non-zero exit, or broker failure preserves prior output.
- Audit logs contain handler, capability ID, duration, byte counts, status, and
  hashes, but not file contents, command output, or secrets.

## Non-goals

- Background jobs, streaming output, schedules, network/model handlers, or
  document-defined handlers.
- Automatic grants or persisted global grants.
