---
id: 0011
title: Add Atomic Arbor Outline Transactions
status: done
type: feature
area: arbor
priority: P0
created: 2026-08-13
updated: 2026-08-13
completed: 2026-08-13
blocked_by:
  - ./0010-arbor-typed-effect-runtime.md
related:
  - ../architecture/arbor.md
---

# Add Atomic Arbor Outline Transactions

## Goal

Allow an explicit producer run to change its accepted `.outline` document without
moving structural authority into the renderer or OS effect broker.

## Syntax

```racket
! (outline/insert-child (self) "New child")
! (outline/set-text (block "task") "Done #done")
! (outline/transact
     (add-tag (query "open-tasks") "done")
     (move (block "task") (block "archive")))
```

Targets are `(self)`, `(block "uid")`, or `(query "query-uid")`. Query targets use
the first block-valued result column and must resolve inside the producer document.

## Transaction contract

- Operations are `insert-child`, `insert-after`, `set-text`, `add-tag`, `move`, and `delete`.
- One run expands to at most 100 operations against one accepted document revision.
- The kernel validates targets, ancestry, cycles, derived-node ownership, and the final candidate source.
- The host receives a trusted plan, shows a concise preview, compares the expected source,
  writes once, reindexes, and completes the transaction.
- Any denial, stale revision, invalid candidate, or write failure leaves the old document accepted.
- The renderer receives the authoritative source and installs it as one undoable store transaction.

## Generated-node semantics

Inserted blocks are live managed nodes keyed by producer, operation position, and target.
Run refreshes an unedited managed node, editing detaches it, and Run as New creates a
new generation. Kernel-generated stable IDs remain opaque to the renderer.

## Non-goals

- Multi-document atomic writes.
- Background mutation, schedules, or execution on expansion.
- Arbitrary source patches supplied by documents or the renderer.
