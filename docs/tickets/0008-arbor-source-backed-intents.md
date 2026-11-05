---
id: 0008
title: Route Source-Backed Result Edits Through Kernel Intents
status: done
type: feature
area: arbor
priority: P0
created: 2026-08-12
updated: 2026-08-12
completed: 2026-08-12
blocked_by:
  - ./0007-arbor-query-projections.md
related:
  - ../architecture/arbor-design-notes.md
---

# Route Source-Backed Result Edits Through Kernel Intents

## Goal

Provide the first honest bidirectional Put: editing a live query result that
projects one authored block updates that source block. Unsupported or failed
updates detach locally instead of discarding text.

## Contract

```text
intent/apply(documentID, revision, resultID, kind, value) -> source replacement
```

Build 3 supports `set-text` only. The kernel resolves the result's persisted
origin, validates its update policy, and returns a candidate source replacement.
The trusted host compares, writes, and reindexes that document before reporting
success. The renderer sends the intent on blur and never edits another file
directly.

## Acceptance

- Typing remains local and never waits for the kernel.
- A successful Put updates the origin document and keeps the result managed.
- A stale target, missing origin, snapshot, or rejected write detaches the result.
- The user's edited text is preserved on every failure path.
- Source replacement changes only the target block's canonical lines.
- Kernel, native host, and development host test the same contract.

## Non-goals

- Structural Put, cross-document undo, or collaborative conflict resolution.
- Inferring updates for scalar or multi-origin rows.
