# CSV module overview

This folder contains nvModern's native CSV/extended-CSV editor and preview stack.

## Entry points

- `RetainedCSVPreviewSession.swift`
  - defines `CSVPreviewContentController` and `CSVPreviewContentHost`
  - primary workspace-path host for CSV tabs
  - owns the detached native preview view, async load, attach/detach, and focus handoff
- `CSVGridNativeCanvasView.swift`
  - main AppKit spreadsheet implementation
  - owns layout, drawing, selection, editing, autocomplete, context menus, drag reorder, formula bar, filtering, and undo
- `CSVGridModels.swift`
  - document model, save snapshot, row/column mutation helpers
- `CSVGridFileCodec.swift`
  - file load/save for plain CSV and extended CSV with frontmatter
- `CSVGridTransferCodec.swift`
  - clipboard/import/export parser/serializer for separated rows
- `CSVGridFormula.swift`
  - `{{ ... }}` formula parsing and JS evaluation helpers
- `CSVGridPreviewView.swift`
  - lightweight direct `NSViewRepresentable` wrapper for the grid
  - still useful outside the controller-owned workspace path, but not the main tab-hosting architecture

## Supported document shapes

There are two modes:

- `plainCSV`
  - first row is treated as the header row
  - saved back as normal CSV
- `extended`
  - preserves TOML or YAML frontmatter
  - column metadata and status colors live in frontmatter
  - CSV body is saved below the frontmatter fence

## Runtime data flow

Current workspace path:

1. `WorkspaceView` / `WorkspaceTabView` resolve the active document for a persistent `WorkspaceTabController`.
2. `WorkspaceTabController.csvContent` (`WorkspaceCSVTabContentRuntime`) prepares or reuses that tab's `CSVPreviewContentController`.
3. `CSVPreviewContentHost` attaches the controller's native view when the tab is visible.
4. `CSVPreviewContentController` loads through `CSVGridDocument.load(...)`, which uses `CSVGridFileCodec` / `CSVGridTransferCodec`.
5. `CSVGridNativePreviewContainerView` renders and edits the document.
6. On mutation, the grid publishes a `CSVGridSaveSnapshot`.
7. `WorkspaceTabView.scheduleCSVSave(...)` debounces and writes snapshot data back to disk.

Lifecycle notes:

- Tabs use detached-but-preserved content, so tab identity and content controllers stay stable while inactive native views are detached from the hierarchy.
- CSV ownership is per-tab and controller-local; the old workspace-level retained cache/prewarm model is no longer the main path.
- Inactive CSV tabs keep their controller/runtime but detach the heavy native surface until reattached.

## Editing model

The grid is intentionally native AppKit, not `NSTableView`.

Important characteristics:

- body rendering is virtualized and custom-drawn
- top chrome is primarily built from real AppKit subviews
- in-cell editing uses an overlay text view
- formula bar edits the raw cell value
- autocomplete supports wikilinks, status values, and formulas
- row/column insert/delete/move are undoable
- undo is snapshot-based, not diff-based
- workspace hosting is controller-owned: the tab controller keeps the CSV content controller alive, and the host representable only attaches/detaches the native surface

## CSV-specific behavior

- wikilinks like `[[Note]]` render as links and open in a new tab on click
- status columns render pill badges and provide enum completion
- tags columns render chip lists
- formulas are written as `{{ expression }}` and evaluated per row
- row filtering is visual only; row drag-reorder is disabled while filtered
- trailing fully-empty rows are trimmed during serialization

## Parsing / serialization notes

- `CSVGridTransferCodec` is the source of truth for separated-row parsing used by load/paste flows
- the old `TabularData` CSV fast path was removed from the active load path because malformed multiline/ragged CSVs could parse catastrophically
- do not reintroduce `TabularData` as the default parser without hardening it first
- save preserves:
  - original text encoding when possible
  - original newline style
  - UTF-8 BOM if present
  - preserved frontmatter keys outside generated CSV metadata

## Top chrome / layout gotchas

The header and formula area were debugged extensively.

Current guidance:

- keep the top chrome subview-based as the primary implementation
- avoid moving it back to mostly custom drawing unless there is a very strong reason
- body, row gutter, and top chrome use different coordinate spaces and scroll coupling; be careful when changing drag indicators or popup placement

## Known rough edges

- cursor ownership is still somewhat fragile across the canvas, overlay editor, and chrome
- if you touch cursor behavior, audit cursor rects, tracking areas, passthrough views, and overlay editor behavior together

## Good starting points by task

- loading/saving bugs: `CSVGridFileCodec.swift`, `CSVGridModels.swift`
- paste/import/export bugs: `CSVGridTransferCodec.swift`
- formula issues: `CSVGridFormula.swift`, `CSVGridNativeCanvasView.swift`
- selection/editing/autocomplete: `CSVGridNativeCanvasView.swift`
- workspace integration / controller lifecycle: `RetainedCSVPreviewSession.swift`, `WorkspaceTabContentRuntimes.swift`, `WorkspaceTabController.swift`, `WorkspaceTabView.swift`, `WorkspaceView.swift`
