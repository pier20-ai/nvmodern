---
id: 0001
title: Arbor Roam UI Gap Inventory
status: proposed
type: feature-inventory
area: arbor-editor
priority: P0-P2
created: 2026-08-12
updated: 2026-08-12
related:
  - ../architecture/arbor.md
---

# Arbor Roam UI Gap Inventory

## Goal

Make Arbor a dependable Roam-style outliner before work resumes on computed views.

This ticket covers user interface behavior. It does not cover the kernel, graph inference, sync, or persistence.

## Current baseline

The Arbor playground supports these behaviors:

- Click a rendered block to edit its raw source.
- Blur a block to render its Markdown.
- Split a block with `Enter`.
- Insert a line break with `Shift+Enter`.
- Indent and outdent blocks with `Tab` and `Shift+Tab`.
- Merge a block with the previous block at the start of its text.
- Move between visible blocks with the arrow keys.
- Move blocks with `Option+ArrowUp` and `Option+ArrowDown`.
- Undo and redo store edits.
- Collapse, expand, and zoom through the block bullet.
- Copy, delete, move up, and move down from the bullet menu.
- Render headings, emphasis, links, images, code, math, tags, wikilinks, and block references.
- Follow external links, wikilinks, and local block references without entering edit mode.

The playground uses an in-memory outline. A refresh resets all edits.

## Product rules

New features must preserve these rules:

1. Typing must remain local and immediate.
2. A rendered block becomes editable only after an explicit edit gesture.
3. An interactive rendered mark must not activate block editing.
4. The same gesture must have the same result in each future projection.
5. A missing reference must show a recoverable state.
6. A failed parse must not prevent the document from rendering.
7. Every structural command must produce one undoable edit.

## P0: Core editing loop

### Trigger autocomplete

Add completion menus for:

- `[[` page links.
- `((` block references.
- `#` tags.
- `/` commands.

The menu must filter while the user types. Arrow keys must move through results.

`Enter` must accept the selected result. `Escape` must close the menu without changing text.

The page menu must distinguish an existing page from a page that the user can create.

The block menu must show enough ancestor context to identify duplicate block text.

Acceptance:

- The menu opens in the same frame as the trigger.
- The menu stays anchored to the caret.
- The menu does not steal the editor undo stack.
- Input Method Editor composition does not open or accept a menu by accident.

### Block reference rendering

Render `((uid))` as the referenced block text.

The rendered reference must remain visibly distinct from authored text. A click must navigate to the source block.

The UI must handle these states:

- Resolved reference.
- Missing reference.
- Reference cycle.
- Reference to a collapsed block.
- Reference to a block on another page.

Acceptance:

- A source block edit updates each visible reference.
- A reference cycle renders a compact diagnostic.
- Clicking a reference never activates the containing block editor.

### Backlinks and references

Add a references section for the current page or zoomed block.

Separate these groups:

- Page links.
- Block references.
- Tag references.
- Unlinked references, when available.

Each result must show its page and ancestor context. A click must navigate to the source block.

Acceptance:

- The panel updates after an edit without a manual refresh.
- Duplicate references from one block appear once.
- Missing targets remain inspectable.

### Multi-block selection

Add range and additive block selection.

Required gestures:

- `Shift+Click` selects a contiguous visible range.
- `Command+Click` toggles one block.
- `Shift+ArrowUp` and `Shift+ArrowDown` extend the selection.
- `Escape` clears the block selection.

Required commands:

- Delete.
- Indent.
- Outdent.
- Move.
- Copy.
- Cut.

Acceptance:

- A bulk command is one undo step.
- A parent and its selected child do not move twice.
- Selection remains stable when an unrelated block changes.

### Drag and drop

Add block drag and drop from the bullet.

The drop indicator must distinguish these destinations:

- Before a block.
- After a block.
- First child of a block.
- Last child of a block.

Acceptance:

- Dragging a parent moves its full subtree.
- A block cannot move into its own subtree.
- Auto-scroll works near the top and bottom edges.
- The keyboard can perform each drag result without a pointer.

## P0: Page navigation

### Page switcher

Add a page search surface with recent pages and fuzzy matching.

The switcher must support:

- Open in the current surface.
- Open in a new tab.
- Create a missing page.
- Return to the previous page.

Acceptance:

- Page navigation does not reset editor history.
- Back and forward restore page and block zoom.
- A renamed page keeps the same identity.

### Navigation context

Show compact context after page or block navigation.

The context must include:

- A back action.
- The current page identity.
- The zoomed block ancestry.

Do not restore a permanent large title above the outline.

## P1: Roam authoring features

### Slash commands

Start with these commands:

- TODO.
- Current date.
- Current time.
- Page link.
- Block reference.
- Code block.
- Math block.
- Divider.

The command system must insert source syntax. It must not insert presentation-only state.

### Tasks

Render TODO and DONE states as interactive controls.

Required behavior:

- `Command+Enter` cycles task state.
- Clicking the control does not enter text editing.
- The source remains plain and readable.
- Queries can distinguish task states later.

### Attributes

Render `key:: value` as an attribute without hiding its source meaning.

Required behavior:

- The key can navigate like a page link.
- The value remains directly editable.
- Duplicate keys show a diagnostic state.
- Attribute changes remain one undoable source edit.

### Aliases and embeds

Support:

- Wikilink aliases.
- External-link aliases.
- Block embeds.
- Page embeds.

An embed must use the same navigation and edit gestures as an outline block.

### Link previews

Add a delayed hover preview for page links and block references.

The preview must:

- Show a small read-only outline.
- Stay keyboard accessible.
- Close without moving the caret.
- Show a clear missing-target state.

## P1: Reference sidebar

Add a secondary pane for pinned pages and references.

Required behavior:

- Open a link in the sidebar without leaving the main page.
- Pin and unpin a page.
- Preserve independent zoom state.
- Navigate references in either pane.

The sidebar must use the same block components and gestures as the main outline.

## P2: Editing parity and polish

### Keyboard parity

Review and define:

- Start and end of block movement.
- Word movement.
- Selection across block boundaries.
- Delete at block boundaries.
- Promote and demote subtree commands.
- Expand and collapse shortcuts.
- Zoom and unzoom shortcuts.

Do not copy browser `contenteditable` behavior when it conflicts with block semantics.

### Clipboard formats

Support:

- Plain text.
- Arbor outline text.
- Markdown list text.
- Structured internal block data.

Paste must preserve hierarchy when the clipboard contains an outline.

### Rich context menu

Add:

- Duplicate.
- Copy block reference.
- Copy block embed.
- Open in sidebar.
- Select subtree.
- Move to page.
- Convert to TODO.

### Daily notes

Add:

- Open today.
- Move one day backward or forward.
- Create a missing daily page.
- Show referenced daily pages.

### Accessibility

Audit:

- Nested interactive controls.
- Screen reader names and roles.
- Focus visibility.
- Full keyboard operation.
- Reduced motion.
- High contrast.

The rendered block container must not conflict with links and buttons inside the block.

## Deferred UI work

These features depend on later Arbor phases:

- Computed block decorations.
- Capability prompts.
- Derived-content badges.
- Projection switching.
- Table, board, calendar, and timeline views.
- Provenance and justification views.
- Override and residue controls.
- Collaboration presence.

## Recommended delivery order

1. Trigger autocomplete.
2. Block reference rendering.
3. Backlinks and references.
4. Multi-block selection.
5. Drag and drop.
6. Page switcher and navigation history.
7. Tasks and attributes.
8. Sidebar, embeds, and previews.
9. Keyboard, clipboard, and accessibility polish.

## Related documents

- [Arbor technical architecture](../architecture/arbor.md)
- “The Outline Is the AST” Arbor design notes
