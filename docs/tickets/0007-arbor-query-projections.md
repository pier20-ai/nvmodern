---
id: 0007
title: Add Source-Defined Query Projections and Provenance
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
  - ../architecture/arbor.md
---

# Add Source-Defined Query Projections and Provenance

## Goal

Let a query declare its defaults and row Markdown in the outline while keeping
the renderer ignorant of query shape. Persist enough provenance on block-valued
results for later source updates.

## Contract

Query inputs may use direct authored attribute children as defaults:

```text
- {{query: (find (?block ?text)
             (in ?tag)
             (where (block-tag ?block ?tag)
                    (block-text ?block ?text))
             (project "{text}"))}} ^projects
  - tag:: project ^projects-tag
```

`project` is one string template. Placeholders must name result columns. No
forms, calls, conditionals, or renderer templates are allowed.

Each materialized result may carry an origin block ID and an allowlisted update
policy. Origin document paths remain in the kernel fact world and are not
encoded into source anchors.

## Acceptance

- Explicit arguments override child defaults; missing inputs still fail.
- Unknown arguments and unknown template variables fail closed.
- The kernel formats one Markdown block per row.
- A single block-valued result records its origin block ID.
- Scalar and ambiguous multi-block rows retain detach-only behavior.
- Existing query syntax remains valid.

## Non-goals

- Arbitrary projection code.
- Automatic query execution or subscriptions.
- General provenance proofs.
