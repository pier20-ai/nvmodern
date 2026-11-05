---
id: 0030
title: Retire Companions and Redesign Cross-Surface Interactions
status: done
type: improvement
area: workspace
priority: P2
created: 2026-10-18
updated: 2026-10-27
related:
  - 0029-agent-terminals-and-editor-mcp.md
  - ../architecture/palette.md
  - ../architecture/action-system.md
  - 0031-side-stack.md
---

# Retire Companions and Redesign Cross-Surface Interactions

## Resolution — 2026-10-27

Companions are removed. The replacement for side-by-side reference reading is
the tab-owned side stack in ticket 0031; the design questions below about
agent transfer and diff review carry over to that ticket and 0029.

Removed:

- `UI/ChildPane/` (controller, models, view, floating AppKit panel) and the
  tab wiring: `WorkspaceTabController.childPaneController`, the `childPane`
  focus area and `DocumentSurfaceID`, editor-command, outline, find and
  navigator routing to a focused companion, companion file-change banners and
  rename remapping.
- Actions `workspace.childPane.open/close/focusToggle/dock/promote/back`, their
  palette rows and `WorkspaceActionRuntime` members, the `childPane` field of
  `workspace.context.current` and the `activeWorkspace.childPane` palette
  variable.
- MCP tools `open_child_pane` and `close_child_pane`.
- "Open as Companion" in the sidebar (notes and chats) and context-ribbon
  menus, and the unused hook on the shared item context menu.
- The chat's "Asking about …" scoped-document chip, which only a companion
  chat set.

Where behaviour moved:

- "New Chat Here" / "Open Chat Here…" (`workspace.chat.newHere`,
  `workspace.chat.openHere`, `Cmd+Shift+L`) open the chat in the current tab,
  replacing what it shows; Back returns to the document.
- Clicking a file an agent edited, in a chat transcript, opens it in a new tab
  instead of a companion, so the chat stays put.
- Automatic staging of edited files (`[chat] auto_stage_edits`) no longer opens
  anything; the key is still parsed so existing configs round-trip, and its
  Settings toggle is gone.
- Diff review never rendered in a companion (`diff` content had no surface), so
  nothing moved; diffs keep opening as ordinary tabs.

Sessions: `companionPanes` and the legacy `childPane` key are no longer written.
They are no longer coding keys either, so older `session-v6.json` files decode
and simply drop them; no version bump was needed. Companion edits were saved to
disk as they happened, so no unsaved content is lost. The plugin API never
exposed companions.

## Goal

Remove the companion interaction model and replace it with a discoverable
way to work across documents, terminals, and review results. The user finds
companions hard to discover and use and reports that they go unused.
Retirement is the intended direction; the replacement interaction needs
design agreement before implementation.

Don't carry companions forward as the host for the agent terminals in
ticket 0029. Moving the same ownership, docking, and focus behavior under
another name would leave the underlying interaction problem unresolved.

## Current implementation and scope

The feature extends beyond a secondary view. `UI/ChildPane/` implements
controllers, models, presentation, and a floating host. Workspace tab state
associates companions with documents or chat sessions, and
`Core/Session/WorkspaceSessionStore.swift` persists `companionPanes` with
legacy `childPane` decoding. Actions, palette availability, context
snapshots, and MCP expose child-pane operations and focus-dependent routing.

Audit those owners before removing UI. Preserve useful document, diff, and
review behavior currently hosted there by giving it a clear destination in
the replacement. Existing action documentation and tests describe the
current behavior, not a requirement to keep the companion model.

## Design work

Design around concrete tasks rather than another general pane manager:

- Read a reference while editing another document, and return to the exact
  editing position without losing work.
- Send a selection or document to a chosen running agent, with a visible
  destination and enough context to understand what was sent.
- Bring selected terminal text into a document, or review and apply an
  agent's proposed change to its original source.
- Compare documents or inspect a diff without creating a hidden dependency
  between their navigation histories and lifetimes.

Explore ordinary native tabs/windows with explicit transfer commands and
visible destination selection first. If simultaneous viewing needs another
surface, demonstrate how users discover, focus, navigate, and close it
without recreating document-owned companions. Don't assume a replacement
split layout or panel is already approved.

Make the design concrete with a walkthrough or prototype covering discovery,
invocation, destination selection, focus after transfer, return navigation,
and closing either surface. Compare a visible control with menu, context
menu, and palette entry points; keyboard shortcuts supplement discovery.
Keep commands in the existing action registry and preserve the palette's
subject–verb–object model.

Context transfer must capture the source independently of keyboard focus.
Changing tabs or closing a source must not redirect a later insertion or
agent edit into whichever document happens to be active. Coordinate target
identities, revision checks, and result review with ticket 0029.

## Retirement and migration

After agreeing on the replacement, remove companion UI, docking, floating,
promotion, and focus-toggle affordances. Audit native menus, palette rows,
configured shortcuts, action snapshots, plugin contracts, and MCP tools
(`open_child_pane` and `close_child_pane`) for an explicit migration or
retirement path. Don't leave discoverable commands that silently do nothing.

Restore legacy companion documents into accessible ordinary destinations
under the new model, preserving recoverable edits and relevant navigation
state. Preserve access to chat history and pending reviews where present.
Deduplicate restored destinations and avoid unexpected window proliferation.
If the persisted session model changes incompatibly, bump its version and
retain older decoding fallback as required by `AGENTS.md`.

Remove obsolete `ChildPane` implementation only after migrating its users;
retain shared content/runtime functionality that ordinary documents or
reviews still need. Update architecture docs and action examples to describe
the resulting interaction rather than the retired feature.

## Acceptance

- A new user can find the document/agent transfer entry points through
  visible UI and complete the walkthrough without knowing about companions.
- Document-to-document reference work and document-to-agent transfer both
  have explicit destinations and predictable focus/return behavior.
- Changing focus, switching projects, closing a destination, and editing a
  source during a delayed response produce no insertion into the wrong file.
- Legacy sessions remain recoverable without recreating companion UI or
  losing unsaved content; incompatible persistence changes retain fallback.
- Companion terminology and dead operations are removed from the shipped
  UI and documented public surfaces, with migration guidance where needed.
- `make`, applicable tests, and live Debug-app smoke tests pass for native
  tabs, palette navigation, document opening, diff review, and restoration.
