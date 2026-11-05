---
id: 0012
title: Add Composed Arbor Effects and Host Actions
status: done
type: feature
area: arbor
priority: P0
created: 2026-08-13
updated: 2026-08-13
completed: 2026-08-13
blocked_by:
  - ./0010-arbor-typed-effect-runtime.md
  - ./0011-arbor-outline-transactions.md
related:
  - ../architecture/arbor.md
---

# Add Composed Arbor Effects and Host Actions

## Goal

Connect Datalog-selected block sets, curated nvModern actions, and configured model
providers to the same explicit, capability-gated producer lifecycle.

## Contract

- `(query "uid")` can target a single-document outline transaction without copying query logic into the renderer.
- `action/run` accepts a registered method and optional record arguments. The native host exposes only
  the explicit Arbor action allowlist and still checks the action descriptor before invocation.
- `model/complete` sends the prompt to the host-configured provider command through standard input.
  Provider commands and credentials remain host configuration, never outline data.
- The development host reports native-only actions as unavailable and supports model testing through
  `NVMODERN_ARBOR_MODEL_COMMAND`.
- Successful action and model values return through the typed effect result path.

## Safety

- Actions, model calls, and query-selected writes always require a capability grant.
- Action targets default to the current workspace; documents cannot mint AppKit identifiers.
- The action allowlist excludes automation recipes, action introspection, and arbitrary socket methods.
- Model execution uses no shell interpolation and inherits the existing process and output bounds.

## Non-goals

- Persisted credentials or grants.
- Provider-specific model APIs in the kernel.
- Streaming, schedules, subscriptions, or unattended effects.
