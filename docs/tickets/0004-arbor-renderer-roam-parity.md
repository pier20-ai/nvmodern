---
id: 0004
title: Improve Renderer-Only Roam Parity
status: done
type: feature
area: arbor-editor
priority: P0
created: 2026-08-12
updated: 2026-08-12
related:
  - ./0001-arbor-roam-ui-gap-inventory.md
  - ./0005-arbor-kernel-renderer-integration.md
---

# Improve Renderer-Only Roam Parity

## Goal

Improve the local editing loop without making the renderer depend on Racket or Datalog.

## Boundaries

The renderer owns Markdown presentation, caret and IME behavior, completion presentation, selection, structural gestures, collapse, zoom, virtualization, clipboard behavior, and optimistic editing.

This work must remain fully usable while the kernel is absent or stopped.

## Work

### 1. Trigger completion

- Add one caret-anchored completion controller for `[[`, `((`, `#`, and `/`.
- Read current page, block, and tag candidates from `ArborOutlineStore`; keep slash commands static.
- Keep the provider interface replaceable so a later provider may call the query API.
- Preserve IME composition and the editor undo stack.

### 2. Multi-block selection

- Add range and additive selection over stable block IDs.
- Support keyboard extension and clearing.
- Add delete, indent, outdent, move, copy, and cut.
- Add one explicit store transaction boundary so each bulk structural command is one undo step.
- Prevent a selected child from being applied twice when its ancestor is also selected.

### 3. Drag and drop

- Drag complete subtrees from the bullet.
- Distinguish before, after, first-child, and last-child destinations.
- Reject moves into the dragged subtree.
- Use the same destination model for pointer and keyboard operations.
- Auto-scroll near the viewport edges.

## Acceptance

- The completion menu opens and filters in the same frame, stays anchored to the caret, and handles Enter, Escape, arrows, and IME safely.
- Bulk commands are one undo step and selection survives unrelated edits.
- Pointer and keyboard moves produce the same source operation.
- Dragging cannot create a cycle.
- All interactive controls keep an adequate desktop hit area without overlapping adjacent controls.
- No renderer file imports the kernel or a graph client.
- Focused store, interaction, typecheck, performance, and build gates pass.

## Deferred

- Resolved block-reference contents.
- Backlinks and reference sections.
- Query projections.
- Derived task state.
- Cross-document semantic navigation.
