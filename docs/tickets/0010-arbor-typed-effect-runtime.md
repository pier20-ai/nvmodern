---
id: 0010
title: Add a Typed Arbor Effect Runtime
status: done
type: feature
area: arbor
priority: P0
created: 2026-08-13
updated: 2026-08-13
completed: 2026-08-13
blocked_by:
  - ./0009-arbor-capability-effects.md
related:
  - ../architecture/arbor.md
---

# Add a Typed Arbor Effect Runtime

## Goal

Make effect calls data-driven so new host handlers do not add renderer logic.
The kernel validates arguments and capabilities, the host performs the operation,
and the kernel formats the typed result into ordinary materialized blocks.

## Contract

- Effect values are JSON-shaped nulls, booleans, integers, strings, lists, and records.
- `$name` arguments resolve from direct child `name:: value` attributes or explicit run arguments.
- `(list ...)` and `(record ("key" value) ...)` are inert data constructors, never evaluated Racket.
- Each plan declares a timeout and output limit that the host may tighten but never expand.
- `effect/cancel` removes a pending execution; completion and cancellation are idempotent.
- Top-level list results create one result block per item. All other formatting belongs to the kernel.

## Initial catalogue

- Time: `clock/now`, `clock/today`.
- Filesystem: `fs/read`, `fs/list`, `fs/stat`, `fs/glob`, `fs/write`, `fs/append`, `fs/mkdir`.
- Process: `process/run`.
- Network and desktop: `http/request`, `clipboard/read`, `clipboard/write`, `notification/show`.

Every filesystem path is workspace-relative and symlink-contained. HTTP grants are
scoped to method and origin. Writes, clipboard access, process execution, and
network access always require a host-issued capability.

## Verification

- Reader forms, unknown variables, malformed records, unsafe paths, excessive depth,
  and oversized values fail without host execution.
- Typed scalars, arrays, and records materialize deterministically.
- Native and development brokers enforce the same handler, timeout, and output contracts.
- Logs keep full protocol messages in the requested transcript and metadata-only broker audit events.
