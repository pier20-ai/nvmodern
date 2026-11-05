---
id: 0006
title: Materialize Explicit Producer Runs as Outline Nodes
status: in_progress
type: feature
area: arbor
priority: P0
created: 2026-08-12
updated: 2026-08-12
blocked_by:
  - ./0005-arbor-kernel-renderer-integration.md
related:
  - ../architecture/arbor-design-notes.md
---

# Materialize Explicit Producer Runs as Outline Nodes

## Goal

Run query and pure-expression producers only on an explicit command, then
materialize their output as ordinary persisted outline children. Managed output
starts read-only but detaches into authored data on its first mutation.

## Contract

Add one engine-neutral operation:

```text
producer/run(documentID, revision, producerID, mode, arguments?) -> materialization
```

`mode` is `refresh` for Run and `append` for Run as New. The kernel returns a
generation, input hash, fact-world revision, and one Markdown block per result:

```text
materialization = {
  producerID, mode, generation, inputHash, worldRevision,
  results: [{ key, markdown }]
}
```

The renderer applies the response only when its source revision is still current.
It reconciles the kernel's stable result keys in one undoable outline transaction,
then persists and reindexes the resulting source.

Materialized metadata is encoded beside the stable block ID:

```text
^result-id~c1~l~producer-id~result-key~generation~input-hash~world-revision
```

The stable ID remains `result-id`. `l`, `s`, and `d` mean live, snapshot, and
detached. Indentation remains the only structural parent authority; `producer-id`
records provenance and reconciliation ownership.

## State machine

- Run with no live output inserts a new live child.
- Run with matching live output updates it in place and preserves its block ID.
- Editing or moving managed output changes it to detached in the same undo step.
- Run ignores detached output and appends a new live sibling.
- Run as New changes current live output to snapshots and appends a new live generation.
- Query refresh reconciles one ordinary child per stable result key.

Expansion is always inert. `Command+Enter` runs and `Command+Shift+Enter` runs as
new. Document replacement, workspace indexing, and fact-world changes never run a
producer.

## Work

1. Materialize a selected pure expression or named Datalog query in Racket.
2. Share one persistent kernel supervisor across tabs and seed it with workspace
   `.outline` documents.
3. Persist versioned materialization metadata beside stable block IDs.
4. Reconcile output through a tested state machine and ordinary store edits.
5. Render managed output with the normal block component and quieter foreground.

## Acceptance

- Loading or expanding a producer does not execute it.
- `Command+Enter` materializes a pure expression as a real child block.
- A query materializes one child per deterministic result row.
- Ordinary reruns preserve live block IDs and reconcile disappeared rows.
- Editing or moving a result detaches it; rerunning preserves it and adds live output.
- `Command+Shift+Enter` preserves the prior generation as snapshots.
- A query in one document sees blocks from another workspace document.
- Stale responses cannot mutate a newer source revision.
- Kernel failure preserves authored editing and persisted materialized blocks.
- The development transcript records `producer/run` messages without source text in
  summary logs.
- Kernel, renderer, native bridge, and regression tests pass independently.

## Manual gate

Stop after automated validation. Build 3 does not begin until the user tests the
state transitions, persistence, cross-document queries, and kernel recovery.

## Non-goals

- Incremental query patches or a general subscription protocol.
- Provenance proofs or semirings.
- Effectful `!sh`, network, or model nodes.
- Automatic execution on expansion, source edit, or fact-world change.
- Parameter-input controls and user-defined multi-column projections.
