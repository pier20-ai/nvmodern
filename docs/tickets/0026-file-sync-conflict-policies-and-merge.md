---
id: 0026
title: Automatic File Reload with Conflict Policies and Three-Way Merge
status: open
type: improvement
area: editor
priority: P2
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/configuration.md
  - ../architecture/plugins.md
---

# Automatic File Reload with Conflict Policies and Three-Way Merge

## Goal

Always reload external file changes when the document has no unsaved edits.
When local edits collide with a disk change, let the user choose a conflict
policy. Replace document banners with transient notifications, while keeping
blocking decisions in native macOS dialogs.

## Context

The current `sync.mode` mixes automatic reload with conflict presentation.
Its `prompt` path treats an editable observer as a potential conflict, while
`live_file` bypasses that path. Neither describes whether the buffer actually
has unsaved changes. Watching, dirty tracking, and safe writes should be the
same under every policy; only collision resolution should vary.

Scratchpads already reload clean changes and retain local edits on conflicts.
Their close/quit recovery dialog offers Keep Editing, Reload from Disk, and
Overwrite with My Changes. Reuse those resolution semantics rather than
introducing shared document ownership.

## Design

### Configuration and dirty state

Replace `sync.mode` with:

```toml
[sync]
conflict = "ask" # ask | keep_local | use_disk | merge
```

Use a `FileConflictPolicy` enum with `ask`, `keepLocal = "keep_local"`,
`useDisk = "use_disk"`, and `merge`. Keep `ask` as the default. Decode legacy
`prompt` and `live_file` values, including their existing aliases, to `ask`
and document the migration; the old unconditional reload behavior must not
silently discard dirty buffers.

Observers must report actual unsaved changes rather than editability. Mark
the buffer dirty on the first editor transaction, before any debounced
bridge delivery, and clear it only after a successful save or explicit
reload. Own writes are acknowledged silently. Clean external changes reload
under every policy, preserving the editor's cursor and scroll state.

For a dirty buffer, `ask` retains both versions until the user decides;
`keep_local` explicitly adopts and saves the local version; `use_disk`
explicitly discards local edits and reloads disk; `merge` attempts the
three-way operation below. Deleted files, unsupported formats, and missing
merge bases fall back to `ask` when the selected operation cannot apply.
Resolution operations own baseline updates and error handling, so dialogs,
notifications, and the resolver all call the same safe operations. Failed
reads or writes retain the local buffer and unresolved state.

### File-level three-way merge

Retain the last synchronized text as the merge base, then merge that base,
the local buffer, and the latest disk content. A fingerprint alone is not
enough, and Git HEAD is not the base: notes need not live in a repository.

Use a tested conventional line-based merge engine behind a small Swift
interface, initially for Markdown and Org text. Preserve text, whitespace,
and line endings without syntax-tree rewriting. The implementation dependency
still needs selection; the shipped app must not require an installed Git.
[Git's `merge-file`](https://git-scm.com/docs/git-merge-file) describes the
file-level operation we need. The repository-tree and rename handling of
[`ort`](https://git-scm.com/docs/merge-strategies) is outside this scope.

A clean merge adopts and saves the combined result. An unresolved merge
retains base, local, and disk versions and blocks autosave; never write
conflict markers into the note automatically. Recheck disk before applying
a resolution. If disk changed again, refresh the conflict rather than
silently overwriting the newer content.

Reuse the existing diff renderer for the resolution view, but add the
missing resolution behavior: local versus disk comparison, access to the
base, an editable merged result, explicit per-hunk choices, and Apply/Cancel.
The current two-way read-only viewer is a rendering building block, not an
existing merge resolver. Support Org highlighting rather than forcing every
comparison to Markdown. A scratchpad must be able to present this resolver
without becoming a workspace tab.

### Notifications and blocking decisions

Remove document banners and show transient messages in a bottom-right stack
owned by each window's controller and rendered as an overlay. Notifications
must not move the editor, steal focus, or accumulate indefinitely. Coalesce
repeated messages for the same file; routine clean reloads remain silent.

Conflict state stays in the document model after a notification expires.
A notification can offer a Resolve action, but a background watcher event
must not open a modal dialog. When a save, close, or quit requires a decision,
use the existing native AppKit alert pattern with a safe cancel/keep-editing
default. Apply this to primary documents, child panes, and scratchpads.

## Steps

1. Separate external-change detection from conflict policy. Track actual
   dirty state across editable surfaces and centralize successful-resolution
   baseline updates without introducing shared buffers.
2. Add the conflict enum, legacy decoding, Settings choices, and configuration
   documentation. Implement the three non-merge policies with failure-safe
   resolution operations.
3. Replace document banners with a bounded per-window notification stack and
   retain native dialogs for blocking decisions.
4. Add synchronized text baselines, the file-level merge engine, and a resolver
   using the existing diff renderer. Unsupported surfaces use the ask path.

## Acceptance

- Clean external changes reload under every policy and preserve cursor and
  scroll state; own saves produce neither conflicts nor notifications.
- Edits during the bridge/save debounce interval count as dirty, so an
  external change cannot replace an undelivered local edit.
- All four policies have deterministic tests, including missing/deleted
  files and read/write failures. Failure preserves local content and does
  not advance the synchronized baseline.
- Merge fixtures cover Markdown headings, lists, fenced code, Org drawers
  and tables, repeated lines, long paragraphs, Unicode, and CRLF text.
  Nonoverlapping edits combine; overlapping edits require explicit resolution.
- Canceling the resolver preserves the conflict. Disk changes while the
  resolver is open cannot be overwritten without a fresh resolution.
- Notifications remain bounded, coalesce repeated events, and leave editor
  layout and keyboard focus intact. Close/quit still requires a native
  decision while an unresolved conflict prevents saving.
- Workspace documents, child panes, and scratchpads follow the same policy
  semantics, with format-appropriate fallbacks for CSV, canvas, and binary
  surfaces. Scratchpads retain their independent window behavior.

## Non-goals

- Relaunch restoration of scratchpad windows.
- Shared document sessions or shared save ownership between surfaces.
- Git repository integration, tree merges, or rename detection.
- Semantic Markdown/Org merges or automatic conflict-marker writes.
