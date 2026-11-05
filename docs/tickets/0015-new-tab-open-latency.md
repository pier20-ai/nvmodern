---
id: 0015
title: Cut New-Tab Open Latency
status: in_progress
type: perf
area: workspace
priority: P1
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/action-system.md
---

# Cut New-Tab Open Latency

## Completion status — 2026-10-08

Partially complete: implementation, instrumentation, automated validation, and
performance acceptance are finished in commit `26230b8`. Median new-note text
acknowledgement is **98.52 ms** against the 400 ms target; the first-frame proxy
is **133.36 ms**. Empty-tab Miller window display is **33.67 ms** with a warm spare.

The ticket stays `in_progress` only for final manual smoke sign-off. Native tab
drag/reorder and titlebar drag/double-click zoom remain unverified. Finish those
gesture checks and confirm the full `AGENTS.md` smoke checklist before marking
the ticket `done`. No further performance implementation is currently required.

## Goal

Opening a document in a new native tab takes about one second before text is
visible. Measured on 2026-10-05 from the diagnostics breadcrumbs for a plugin
scratchpad capture (`workspace/createNote.timing` + `web.bridge/contextReceived`):

| Step | Time |
|---|---|
| create file on iCloud | 0.5 ms |
| `notesModel.reload()` | 1.1 ms |
| `openDocument(.workspaceNote, disposition: .newTab)` (synchronous) | 372 ms |
| from there to the new tab's `contextReceived` with kind `text` | ≈570 ms |

The same numbers appeared for the old core path, so this is tab creation and
editor start-up, not the plugin bridge. Target: text visible within 400 ms of
the action starting, for a new note opened in a new tab.

## Context

- `NativeWorkspaceWindowView.createNoteThroughActionSystem` logs the timing
  breadcrumb; `openDocument(_:disposition:)` with `.newTab` calls
  `openNewNativeTab(documents:)`.
- New tabs are new `NSWindow`s grouped by `WorkspaceApplicationCoordinator`
  (`NVModern/App/WorkspaceApplicationCoordinator.swift`). There is already a
  pre-warmed spare window: see the comment "A pre-warmed spare resolves its
  window while ordered out" in `NativeWorkspaceWindowView.swift`.
- Each tab hosts a `WKWebView` (`NVModern/UI/Web/EditorWebView.swift`); the
  editor bundle is loaded from `Resources/WebEditor/` and signals `ready`, then
  `contextReceived` after `setContext`.
- The new tab's first `contextReceived` arrives with kind `unsupported` (the
  file is not yet in the index), then `text` ~30 ms later after the rescan.
- `PerformanceDiagnostics` (`NVModern/Core/Diagnostics/PerformanceDiagnostics.swift`)
  already marks `markNewTab(window:event:)` events; `run-perf` and
  `profile-perf` Makefile targets exist.

## Instrumented baseline — 2026-10-08

Captured with `make run-perf` after adding correlated `workspace/newTab.timing`
breadcrumbs. No latency fixes were applied. Three sequential
`workspace.note.create` socket actions created a small Markdown note on the same
iCloud workspace and opened it with `openIn=newTab`. Each sample completed before
the next started. Measurement starts inside the app's create-note handler, before
file creation; socket transport and action dispatch before that handler are excluded.
The disposable notes and tabs were removed after measurement.

All values below are milliseconds. Lifecycle timestamps are cumulative from the
handler's start; `openDocument` is the separately measured synchronous duration.

| Phase | Sample 1 | Sample 2 | Sample 3 | Median |
|---|---:|---:|---:|---:|
| `openDocument` synchronous duration | 243.0 | 173.8 | 175.2 | 175.2 |
| Shell layout begins | 24.04 | 10.78 | 9.57 | 10.78 |
| Shell layout ends | 126.29 | 85.63 | 82.18 | 85.63 |
| Native tab-group attachment ends | 213.93 | 150.75 | 146.37 | 150.75 |
| Window shown / `makeKeyAndOrderFront` returns | 245.36 | 175.78 | 176.78 | 176.78 |
| Preview `WKWebView` created | 77.82 | 42.41 | 37.30 | 42.41 |
| Text `WKWebView` created | 417.18 | 331.07 | 286.91 | 331.07 |
| First `contextReceived` (`unsupported`) | 585.92 | 368.50 | 330.67 | 368.50 |
| Text editor `ready` | 600.49 | 486.88 | 445.88 | 486.88 |
| First `contextReceived` (`text`) | 607.52 | 493.35 | 453.00 | **493.35** |
| Text editor first-frame proxy | 631.60 | 519.57 | 480.12 | **519.57** |

The first-frame proxy runs two animation-frame callbacks after CodeMirror has
mounted and accepted the context body. It indicates a paint opportunity, not a
compositor timestamp or proof that pixels reached the screen. `contextReceived`
is emitted immediately after the adapter queues React state, before rendering.

Trace IDs, in sample order:

- `CB9CCA9D-EF1D-4A3B-B226-973F6C1884A5`
- `8FE348A5-B98D-4287-B029-17047F289D60`
- `75B4B5E7-9F41-43F5-B456-8CEF907A6AC6`

Source breadcrumbs: `~/Library/Application Support/nvModern/Diagnostics/breadcrumbs.jsonl`.
Local extracts: `/tmp/nvmodern/new-tab-baseline-phases.json`; captured process log:
`/tmp/nvmodern/new-tab-baseline.log`.

### Findings

- Document requests explicitly bypass the spare (`spareCanServe` rejects nonempty
  `documents`). Sample 1 had no spare; samples 2 and 3 had an available spare and
  still built a fresh window. The adoption path consumes and discards an empty
  request; it has no document-delivery mechanism for an already-built launchpad.
- The spare warms the native shell, not an editor: the launchpad has no attached
  WebEditor host, and web-view instantiation is lazy.
- All three samples instantiate two web views: an unsupported-document preview,
  then a separate text editor. `reload()` schedules a background scan; the newly
  created file is initially absent from `filesByPath`, so the tab cannot yet
  resolve text context despite the caller knowing its body.
- Web-view allocation itself takes only about 2–4 ms per view. Shell layout takes
  73–102 ms and native tab-group attachment 64–88 ms. Text web-view creation begins
  at 285–415 ms; its bridge becomes ready at 446–600 ms. These phases overlap, so
  the deltas are not all additive and the wait before text creation still needs
  separate scan/apply/load phase attribution.
- A subsequent empty new-tab control **used the spare**: tab-group attachment
  ended at 13.02 ms, showing returned at 46.27 ms, and the second run-loop marker
  ended its trace at 70.81 ms. This measures the launchpad shell only.

The current median misses the 400 ms acceptance target. Next steps are to seed
newly created notes from their known body, then deliver document requests to a
spare with an already-ready text editor. Preserve native AppKit tabs and measure
again before changing session persistence or frame restoration.

Instrumentation now starts document-driven traces, associates window/tab phases,
logs spare eligibility, continues past the shell's second run-loop marker through
text context acceptance and first frame, and expires unfinished traces after
15 seconds. Empty launchpad tabs retain their existing shell completion marker.
Validation: `make` and `make test-web` passed; three document opens, empty spare
adoption, and closing the measurement tabs were exercised. The full shell smoke
checklist and latency acceptance remain open.

### Indexed-note control — direct text startup

A follow-up control created three matching disposable Markdown notes with
`open=false`, allowed the background index to catch up, then opened each through
`workspace.note.open(openIn=newTab)`. All traces confirmed exactly one web-view
creation and no `unsupported` context. These opens still bypassed the native spare.
No implementation changes were made between the baseline and this control.

| Cumulative timestamp (ms) | Control 1 | Control 2 | Control 3 | Median |
|---|---:|---:|---:|---:|
| Text `WKWebView` created | 38.84 | 38.53 | 35.44 | 38.53 |
| Window shown | 166.88 | 159.97 | 149.62 | 159.97 |
| Text bridge `ready` | 376.98 | 307.65 | 300.08 | 307.65 |
| First `contextReceived` (`text`) | 384.33 | 314.70 | 307.36 | **314.70** |
| Text editor first-frame proxy | 417.94 | 343.31 | 334.06 | **343.31** |

Control 2 is the middle sample by both completion measures. Its finer breakdown:

| Phase | Interval from open start (ms) | Duration (ms) |
|---|---|---:|
| Allocate/configure window and install content | 0–11.87 | 11.87 |
| Forced shell layout | 11.87–82.20 | 70.33 |
| Native tab-group attachment | 82.30–123.10 | 40.80 |
| Show/select window | 123.10–159.97 | 36.87 |
| Remaining wait for bridge readiness | 159.97–307.65 | 147.68 |
| Ready to text context acknowledgement | 307.65–314.70 | 7.05 |
| Acknowledgement to first-frame proxy | 314.70–343.31 | 28.61 |

Within layout, web-view construction consumed 2.24 ms (36.29–38.53 ms). From
web-view construction completion to bridge readiness was 269.12 ms; bundle loading
runs concurrently with the shell phases, so this duration must not be added to
the table. File-data availability/context preparation also overlaps: the first
text context was queued at 172.02 ms while the bridge was not ready. The existing
markers do not divide the bundle-to-ready interval into WebKit process setup,
file loading, JavaScript evaluation, imports, and React startup.

Compared with the earlier new-note baseline, this control's median improves text
acknowledgement by 178.65 ms and first frame by 176.26 ms. It isolates the existing
indexed-note path rather than testing an implemented known-body seed: indexing
waits were deliberately excluded, trace start is the document-open path rather
than the create-note handler, and the control ran later in the same process.
It is evidence for eliminating the index miss / preview startup, not proof of
the final new-note action's latency or fulfillment of this ticket's acceptance.

Control trace IDs:

- `B0C89798-1442-4CBF-B94A-595748A483FD`
- `065BC396-D49B-4EBA-A4E8-3C9E612A885F`
- `F46A219E-E361-400D-B352-23FDAD385CCF`

Extract: `/tmp/nvmodern/indexed-open-control-phases.json`. The control tabs and
unchanged notes were removed, and the original selected tab was restored.

## Implementation and remeasurement — 2026-10-08

Implemented both optimizations, retaining native AppKit tabs and all timing markers:

- Successful text creation retains the actual written body in a transient
  `NotesWorkspaceModel` seed until the scan supplies the file. Subsequent local
  writes update that seed. Opening the new note uses it immediately, including
  empty notes; indexed reads return to disk authority. Non-text creation keeps
  its existing content kinds. No session schema changed.
- A same-project spare can now accept a single document through a one-shot
  activation handoff rather than discarding the request. Its tab runtime preloads
  the text web bundle while offscreen. Requests carrying chats, in-document jumps,
  multiple documents, or copied tab state retain the cold path. Failed adoption
  preserves the pending request for cold fallback.
- Initial windows now schedule a spare for their resolved project root. Spare
  replenishment is delayed by 500 ms to avoid building the next shell immediately
  during the opening tab's first frames. A request can still use a spare whose
  bundle is loading; if there is no spare it uses the normal creation path.

Repeated the real `workspace.note.create(openIn=newTab)` benchmark at each stage,
with the same Markdown body and iCloud workspace. Cumulative timings in ms:

| Stage / phase | Sample 1 | Sample 2 | Sample 3 | Median |
|---|---:|---:|---:|---:|
| Original: text acknowledgement | 607.52 | 493.35 | 453.00 | 493.35 |
| Seed only: text acknowledgement | 506.74 | 339.02 | 371.73 | 371.73 |
| Seed only: first-frame proxy | 538.62 | 357.98 | 394.79 | 394.79 |
| Seed + spare: window shown | 86.85 | 73.02 | 86.26 | 86.26 |
| Seed + spare: text acknowledgement | 95.49 | 98.52 | 110.64 | **98.52** |
| Seed + spare: first-frame proxy | 133.36 | 125.44 | 156.16 | **133.36** |

Every seed-only and final sample avoided `unsupported`. Every final sample used
an existing spare and allocated no new web view during the measured open. The
first spare reported its text bridge ready on adoption; the second and third
were still preloading and reached ready at 91.41 and 103.97 ms after action start.
The harness waited 500 ms after each completed sample, so replenishment can be
partially underway at the next request. These are spaced actions in a running
app, not a guarantee for immediate startup or bursts that exhaust the spare.

Final trace IDs:

- `1E5D4DEC-3967-4DCB-8FF9-82012CDA1B4D`
- `9C69F6E7-9491-43E5-A662-26EF7ABBF070`
- `DC9F0DF9-D7C6-49C1-9665-95611B772CFC`

Extracts: `/tmp/nvmodern/new-tab-seeded-phases.json` and
`/tmp/nvmodern/new-tab-warm-editor-phases.json`. Process logs use the matching
`.log` filenames. The original session and tab were restored; disposable files,
benchmark recents, and benchmark scroll entries were removed.

Validation: `make`, `make test` (374 tests, two skipped, zero failures), and the
previous `make test-web` passed. New native tests cover pre-index empty/body text,
returning to disk reads after indexing, non-text/deleted creations, one-shot
request delivery, sidebar handoff, and project/copied-state eligibility.
Manual smoke checks exercised Cmd+T, the native tab-bar add button, Cmd+W,
launchpad/document transitions, palette root/actions presets and dismissal,
Miller mouse/keyboard navigation, in-document find, quit/relaunch tab grouping,
and CSV/image/PDF detachment and reattachment. The saved session contained only
real tabs, excluding the spare. Native drag/reorder and titlebar drag/double-click
zoom were not conclusively verified by automation; their AppKit implementation
is unchanged. Implementation and performance acceptance are complete; only final
manual smoke sign-off remains, as listed in the completion status above.

## Empty tab / Miller columns follow-up — 2026-10-08

Three `workspace.tab.new` opens with the current Debug build, spaced one second
apart after trace completion, all used a warm spare. Timings start inside the
app's new-tab path; socket transport is excluded.

| Phase (ms) | Sample 1 | Sample 2 | Sample 3 | Median |
|---|---:|---:|---:|---:|
| Window shown / `makeKeyAndOrderFront` returns | 56.84 | 33.67 | 30.31 | **33.67** |
| Second run-loop marker | 101.22 | 63.02 | 79.12 | **79.12** |

The new tab contains the launchpad's Miller columns. These native lifecycle
markers do not establish exact compositor presentation time. The three temporary
tabs were closed and the original selected tab restored.

Extract: `/tmp/nvmodern/new-tab-empty-final-phases.json`; process log:
`/tmp/nvmodern/new-tab-empty-final.log`. Trace IDs:
`D83965A8-9AC3-485B-A74B-37581D674EB9`,
`69479AEF-76F4-4D5D-84C5-4B443114B10D`,
`8FEF4F25-E282-46A8-9F71-347E399FF576`.

## Steps

1. Instrument before changing anything. Inside the `.newTab` path add
   breadcrumbs (category `workspace`, event `newTab.timing`) for: window
   created, window shown/attached to the tab group, `WKWebView` created,
   `ready` received, first `setContext` sent, `contextReceived`. Run
   `make run`, open a note in a new tab three times, and record the phases
   from `~/Library/Application Support/nvModern/Diagnostics/breadcrumbs.jsonl`.
   Put the table in this ticket before fixing.
2. Attack the largest phases, in this order of likelihood:
   - If `WKWebView` creation + `ready` dominates: keep one warm, already-ready
     editor web view per window group (the spare-window mechanism may already
     do this; confirm whether the spare is used for action-driven opens or only
     for `Cmd+T`). Use it for the first document of a new tab.
   - If the synchronous 370 ms is AppKit window creation/tabbing: check for
     synchronous work in `onResolved`/`onAttaching` (`NativeWindowConfigurator`,
     session persistence, sidebar sync) that can be deferred with
     `DispatchQueue.main.async`, and whether `restoreWindowFrameIfNeeded` or
     `scheduleWindowStatePersistence` runs synchronously on the main thread.
   - Avoid the `unsupported` → `text` double context: when the path was just
     created by this app, seed the tab from the known body instead of waiting
     for the index.
3. Re-measure with the same procedure and update the table.

## Acceptance

- [x] Median "action start → `contextReceived` kind `text`" for a new note in a
  new tab under 400 ms on the same machine, shown by the updated table
  (98.52 ms).
- [ ] No regression in `Cmd+T` new-tab creation, tab restore at launch, or the
  smoke checklist in `AGENTS.md`. Creation and restore passed; final manual
  smoke sign-off remains.
- [x] Instrumentation stays (it is cheap and it is how this was found).

## Non-goals

- Changing the plugin system or capture plugins.
- Reworking the tab/window architecture.
