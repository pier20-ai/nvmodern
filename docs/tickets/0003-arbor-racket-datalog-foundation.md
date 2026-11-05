---
id: 0003
title: Build the Racket Datalog Foundation
status: done
type: feature
area: arbor-kernel
priority: P0
created: 2026-08-12
updated: 2026-08-12
related:
  - ../architecture/arbor-design-notes.md
  - ./0002-arbor-graph-kernel-boundary.md
  - ./0005-arbor-kernel-renderer-integration.md
---

# Build the Racket Datalog Foundation

## Goal

Compile Arbor source into one canonical Racket-owned fact theory and expose revisioned queries without changing the renderer.

## Boundaries

- Racket parses Arbor meaning: structure, links, block references, tags, attributes, query declarations, computations, and diagnostics.
- The renderer continues to own Markdown presentation and structural editing.
- Query definitions live in the outline. Clients invoke them by stable block ID; clients do not construct semantic queries.
- The public Arbor contract must not expose the chosen Datalog engine's internal representation.

## Fact vocabulary

```text
block-page(block, page)
block-parent(block, parent)
block-order(block, order)
block-text(block, text)
block-tag(block, tag)
block-attribute(block, key, value)
block-link-page(block, page)
block-ref-block(block, target)
```

Each fact retains its source document, block, and range inside the kernel so a document revision can be replaced cleanly.

## Work

### 1. Fact compiler

- Separate outline parsing from pure-expression evaluation.
- Emit canonical facts and diagnostics from parsed blocks.
- Add golden source-to-facts tests.

### 2. Datalog adapter

- Wrap Racket's `datalog` package behind a small Arbor-owned module.
- Support document replacement, assertion, retraction, recursive rules, and queries.
- Rebuild or replace a document's facts as one revision; do not add incremental maintenance yet.

### 3. Query protocol

Add minimal stateful operations:

```text
document/replace
query/run
```

`query/run` accepts a source revision, query block ID, and scalar arguments. It returns columns, rows, diagnostics, the evaluated document revision, and the world revision.

The stock Racket engine returns answers but not recursive proof derivations, so Build 1 does not claim provenance for query rows.

## Logging

Log request ID, document ID, revision, operation duration, fact count, query ID, row count, and outcome. Do not log document or block text by default.

## Acceptance

- Source fixtures deterministically produce the expected facts and diagnostics.
- Recursive ancestry, backlinks, tags, attributes, page links, and block references are queryable.
- Replacing a document retracts facts that disappeared.
- Malformed source produces diagnostics without corrupting the previous accepted world.
- Stale query revisions are rejected.
- Representative 10k- and 100k-block fixtures establish a baseline.
- Racket tests pass independently of Swift and the renderer.

## Non-goals

- Query-driven UI.
- Subscriptions or incremental query patches.
- Provenance semirings.
- CRDT selection or implementation.
- General view-update policies.
- Persisting the derived graph.
