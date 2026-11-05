---
id: 0028
title: CSV Grid Open Tasks
status: open
type: epic
area: csv
priority: P3
created: 2026-10-08
updated: 2026-10-08
related:
  - ../../NVModern/UI/CSV/README.md
---

# CSV Grid Open Tasks

Moved from `docs/proposals/csv-open-tasks.md` when `docs/proposals/` was
removed. The "Current state" list below predates two decisions recorded in
`AGENTS.md`: `CSVGridTransferCodec.parseRows(...)` is the active parser and
the `TabularData` fast path is intentionally not used by default. Re-verify
each item against `NVModern/UI/CSV/` before starting one, and split anything
you take on into its own ticket.

This document tracks remaining and deferred work for nvModern's native CSV grid.

## Current state

Implemented:
- Native AppKit CSV grid preview
- Header row handling for plain CSV
- Header-only CSV empty-row behavior
- Read-only and basic editing flow
- Cell selection and rectangular range selection
- CSV copy / CSV+TSV paste
- Row/column insert/delete via context menus
- Basic filter and sort UI
- `[[...]]` wikilink rendering + open
- `status` and `tags` renderers
- Better CSV parsing using `TabularData` for file load

## High-priority hardening

1. **Link UX polish**
   - Confirm reliable open-in-new-tab behavior for `[[...]]`
   - Add explicit context menu items:
     - Open Link
     - Open Link in New Tab
   - Support cmd-click consistently

2. **Cursor polish**
   - Ensure non-editing grid always shows spreadsheet-style cursor
   - Consider custom fat-plus cursor asset instead of crosshair

3. **Parser/serialization hardening**
   - Audit save path for exact CSV roundtrip behavior
   - Verify multiline, quotes, commas, unicode, BOM
   - Verify no data corruption after edit/save/reopen
   - Consider adopting `SwiftCSV` if more real-world parser issues appear

4. **Selection + keyboard behavior**
   - Arrow-key navigation
   - Shift-arrow range expansion
   - Tab / Shift-Tab
   - Enter / Shift-Enter movement
   - Escape cancel edit
   - Better first responder behavior

5. **Performance cleanup**
   - Profile wide CSVs and long drag selections
   - Reduce unnecessary reloads
   - Make overlay updates cheaper
   - Column width heuristics for wide tables

## Data/rendering features deferred to phase 2+

1. **Formula support**
   - Parse `{{...}}`
   - Same-row references by column name
   - Error states
   - Recalculation model
   - Save/raw-vs-evaluated semantics

2. **More column renderers**
   - `range`
   - `sparkline:bar`
   - `sparkline:line`
   - richer `text` formatting

3. **Frontmatter/schema editing UI**
   - Column rename UI
   - Column format picker UI
   - Status color map editor
   - Preserve arbitrary frontmatter better

4. **Richer wikilink behavior**
   - Relative/context-aware resolution rules if needed for CSV
   - Hover previews
   - broken-link state

5. **Sort/filter improvements**
   - Per-column filter controls
   - Clear sort/filter affordances
   - Non-destructive sort mode vs destructive sort
   - Better typing of numeric/date columns

6. **Clipboard/interoperability**
   - Multi-format pasteboard payloads
   - Better interoperability with Numbers/Excel
   - Copy with/without headers

7. **Undo/redo**
   - Cell edit undo
   - Structural edit undo
   - Integration with `UndoManager`

8. **Session/state persistence**
   - Column widths
   - Sort/filter state
   - Selected cell/range
   - Scroll position for CSV grids

## UX improvements

1. Better header styling/theme tuning
2. Better empty states
3. Better row/column context menus
4. Inline validation indicators
5. Formula bar / raw cell editor
6. Sticky/frozen first column if needed

## Testing needed

1. Real-world CSV fixtures
2. Very wide rows
3. Multiline cells
4. Embedded quotes / escaped quotes
5. Unicode / RTL / emoji
6. Large files
7. Copy/paste with Numbers and Excel
8. Save/reopen roundtrip tests
9. Extended frontmatter files
10. Status/tags renderer regression tests

## Decision points

1. **Parser choice**
   - Keep `TabularData` for file parsing
   - or switch to `SwiftCSV`
   - or use one as primary and the other as fallback

2. **Sort semantics**
   - current implementation mutates row order
   - decide if this should become view-only instead

3. **CSV vs extended-table format boundary**
   - stay with `.csv`
   - or introduce a dedicated extended-table extension later
