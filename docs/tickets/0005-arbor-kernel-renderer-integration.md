---
id: 0005
title: Connect Arbor Documents, Renderer, and Kernel
status: done
type: integration
area: arbor
priority: P0
created: 2026-08-12
updated: 2026-08-12
blocked_by:
  - ./0003-arbor-racket-datalog-foundation.md
  - ./0004-arbor-renderer-roam-parity.md
related:
  - ../architecture/arbor.md
---

# Connect Arbor Documents, Renderer, and Kernel

## Goal

Connect the real `.outline` document to the local renderer and Racket fact world, then stop for manual review before query-driven views are designed.

## Work

- Replace the fixed playground snapshot with the opened document source.
- Keep local renderer edits immediate and persist accepted source revisions through the existing host boundary.
- Send the same serialized source and revision to `document/replace` after each committed renderer transaction.
- Expose `query/run` through the bridge for tests and a development harness only.
- Correlate renderer, bridge, supervisor, and kernel logs with one request ID.
- Preserve editing when the kernel is unavailable, restarting, or returning diagnostics.

## Independent tests

- Renderer tests use a fake host.
- Kernel tests run without Swift or the renderer.
- Native tests use controlled kernel responses.
- One integration smoke test opens, edits, persists, indexes, and queries a real `.outline` document.

## Acceptance

- The renderer and kernel accept the same monotonically increasing source revision.
- Persisted source remains authoritative when the kernel fails.
- Stale kernel results never replace a newer renderer revision.
- Logs show request ID, revision, timing, counts, and outcome without source text.
- The full automated gates retain their established status.

## Manual gate

After automated validation, implementation stops. Build 2 must not begin until the user tests the editing loop, kernel-down behavior, query correctness, and logs, then explicitly approves the next phase.

The manual gate passed on 2026-08-12. Editing, structural selection, kernel-down
recovery, query correctness, and correlated JSONL logging were verified before
Build 2 planning began.

## Non-goals

- Rendering query-shaped views.
- Query subscriptions.
- Bidirectional update policies for derived views.
- Starting Build 2 before manual approval.
