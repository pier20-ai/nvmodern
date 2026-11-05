---
id: 0031
title: Side Stack — Shift-Click References Beside the Document
status: open
type: feature
area: workspace
priority: P1
created: 2026-10-27
updated: 2026-10-27
related:
  - 0030-retire-companions-and-redesign-cross-surface-interactions.md
  - ../architecture/action-system.md
---

# Side Stack — Shift-Click References Beside the Document

## Goal

Read a note while glancing at the notes it links to, without leaving it. Modelled
on Roam Research's right sidebar: Shift-click a wikilink and the target note
joins a stack of cards in a column on the right of the tab. This replaces the
companion (child pane) model, which ticket 0030 retires.

## Decisions (agreed with the user)

- **Owned by the tab, not the document.** Navigating the main view leaves the
  stack alone. The stack persists with the tab's session.
- **Read-only cards (v1).** Cards render the note with the full editor (wikilinks,
  tables, math, callouts) but cannot be edited; no write-back or sync.
- **Shift-click is the gesture.** Plain click keeps navigating the main view.
- **One stack per tab.**

## Behaviour

- Shift-click a wikilink in the main document: the target note is pushed onto
  the top of the stack. If it is already in the stack, scroll to its card and
  flash it instead of adding a duplicate.
- A card shows a header (title, collapse toggle, "open in main", close ×) and
  the note body, read-only. Clicking the title (or ⌘-click) opens the note in the
  main view.
- Links inside a card: click opens in the main view; Shift-click pushes another
  card.
- Heading and block links (`[[note#heading]]`, `[[note#^block]]`) focus the card
  on that section, with a "show whole note" control.
- Palette: a note verb "Open in side stack" (and Shift-Return on a note row).
- A toggle shortcut shows/hides the column; another moves focus between the main
  document and the stack.
- Narrow windows: the column overlays the document as a sheet instead of
  squeezing it.
- Annotation margin notes in the main editor keep working; they adapt to the
  narrower editor on their own.

## Architecture

- **One stack web view per tab**, separate from the main content controller, so
  the stack sits beside any content kind (Markdown, Org, PDF, CSV). It renders
  every card as its own read-only CodeMirror instance from the library in
  `NVModern/WebEditor/src/lib/`.
- A new WebEditor entry point (alongside `main.tsx`, `diff.tsx`, `canvas.tsx`)
  hosts the stack UI. Swift pushes the stack state (cards: path, title, body,
  optional heading/block focus, collapsed) through the structured bridge;
  the stack emits events (open in main, close, collapse, link opened, Shift-link
  opened, ready, height/scroll as needed).
- The wikilink open event carries the click's modifier keys so Swift can route a
  Shift-click to the stack.
- The tab's controller owns the stack session (retained across tab switches like
  other content runtimes); `WorkspaceSessionStore` persists the card list per
  tab (paths, collapse state, focus), with decode fallback.
- Same note open in main and in a card is fine: the card is read-only and
  reloads when the file changes on disk or is saved from the main editor.

## Delivery

1. Retire companions (ticket 0030): UI, models, session fields (keep old
   sessions decodable), actions, palette entries, and the `open_child_pane` /
   `close_child_pane` MCP tools. Preserve any useful behaviour (diff review)
   elsewhere or note its removal.
2. Stack web surface: read-only card rendering, header controls, focus on
   heading/block, events.
3. Native integration: tab-owned column, Shift-click routing, palette verb,
   shortcuts, session persistence, narrow-window sheet. **Built** — see
   "Native integration" below.
4. Validate with `make`, `make test-web`, the relevant XCTests, and a live run.

## Stack bridge protocol

Status: the web side (delivery step 2) is built; the native side (step 3)
builds against this section.

### Entry and transport

- Load `stack.html` from the bundled `NVModern/Resources/WebEditor/` (built by
  `make web-editor` next to `index.html`; it loads `stack.js` and `stack.css`).
  One WKWebView per tab.
- Transport is the main editor's: the `nvmodern` script message handler and
  `window.nvmodernReceive`, so a plain `WebEditorBridge` hosts it (commands
  with `sendCommand`, events through `onEvent`, requests through `onRequest`).
  The page posts `{kind: "ready"}` once it listens; `WebEditorBridge` queues
  commands until then.
- Register the `nvmodern-file://` scheme handler (`PreviewFileSchemeHandler`)
  on the stack's web view so images in cards load, exactly as for the editor.
- Source files: `NVModern/WebEditor/src/stack.tsx` (bridge wiring),
  `src/stack/StackSurface.tsx` (UI), `src/stack/model.ts` (payload
  normalisation, tested), `src/lib/sections.ts` (heading/block ranges,
  tested), `src/styles/stack.css`.

### Commands (Swift → JS)

| Command | Payload | Effect |
|---|---|---|
| `setHostAppearance` | `{colorScheme: "light" \| "dark"}` | Same as the main editor: sets `data-theme` on `<html>`. Send on load and whenever the window appearance changes. |
| `setTheme` | `{userThemeCSS?: string \| null}` | Applies the theme CSS through the library's `applyNv3UserStylesheet`, i.e. the same CSS the main editor gets as `setContext.userThemeCSS` (global theme + `editor_theme_css`). Empty/null removes it. Per-document inspector CSS (`setDocumentAppearance`) is not applied to cards. |
| `setStack` | `{cards: Card[], revealId?: string}` | Full-state replace. `cards` is in display order, index 0 at the top. Cards keep their editor across updates as long as `id` is stable; a changed `body` updates the card in place (e.g. after a save or a disk change), a changed `path` or `fileType` rebuilds it. `revealId` scrolls that card into view (use it after a push). Unknown `revealId` is ignored. |
| `flashCard` | `{id: string}` | Scrolls the card into view and pulses its background (the "already in the stack" case). |
| `focusStack` | `{id?: string}` | Focuses the title of card `id` (or the first card) so keyboard users land in the stack after Swift makes the web view first responder. |

`Card`:

```ts
{
  id: string;            // stable per card (e.g. path + focus); defaults to path
  path: string;          // workspace-relative path; required
  title?: string;        // defaults to the file name without extension
  body: string;          // full note text (always the whole note, never a slice)
  fileType?: "markdown" | "org" | "plain"; // defaults from the path extension
  focus?: { heading?: string; block?: string } | null; // block without "^"
  collapsed: boolean;
  showWholeNote?: boolean; // optional; omit to let the stack keep it locally
}
```

Malformed cards (no `path`) and duplicate ids are dropped. CRLF is
normalised. Swift always sends the whole note; the stack cuts the section
itself (heading subtree up to the next heading of the same or higher level —
the same rule as `markdownHeadingSectionRange` — or the block carrying the
`^id`). When the section no longer exists the card shows the whole note with
a short notice.

### Events (JS → Swift)

All events go through `{kind: "event", event, payload}`.

| Event | Payload | Meaning |
|---|---|---|
| `stackOpenInMain` | `{id, path, focus, shiftKey, metaKey, altKey, ctrlKey}` | Title or "open in main" button clicked. Open `path` in the tab's main view; if `focus` is set, jump to it (`jumpToMarkdownReference` with `kind: "heading"`/`"block"`). |
| `stackClose` | `{id}` | Close button. Remove the card and send `setStack`. |
| `stackCollapse` | `{id, collapsed}` | Collapse toggle. The stack applies it immediately; persist it and echo it in the next `setStack`. |
| `stackShowWholeNote` | `{id, showWholeNote}` | "Show whole note" / "Show only …" toggle on a focused card. Applied immediately; Swift may persist and echo it as `showWholeNote`, or ignore it. |
| `stackLinkOpen` | `{id, fromPath, target, href, note, focus, intent, shiftKey, metaKey, altKey, ctrlKey}` | A wikilink inside a card was clicked. `target` is the raw link target (`Note#Heading\|Alias`), `note` its note part (empty for same-note links like `[[#Heading]]` — resolve those to `fromPath`), `focus` the parsed `{heading}`/`{block}` or null, `href` what the main editor would stamp. `intent` is `"push"` for Shift-click, otherwise `"openInMain"`. Resolve with the existing `resolveWikilinkTarget(target, from: fromPath)`; then push a card (or `flashCard` if one with the same path+focus exists) or open in main. |
| `stackInlineLinkOpen` | `{id, fromPath, href, label, resolvedPath, intent, shiftKey, metaKey, altKey, ctrlKey}` | A Markdown `[label](href)` link or an Org link in a card. Same shape as the main editor's `inlineLinkOpen` (`resolvedPath` is workspace-relative, null for external URLs) plus `intent`/modifiers. |
| `contentInteraction` | `{}` | Pointer down or focus inside the stack, for focus routing (same name as the main editor's). |
| `contextMenuRequested` | `{x, y, selectionText, cardId}` | Right click; the default WebKit menu is suppressed. Offer at least Copy when `selectionText` is non-empty. |
| `mainScriptLoadError` | `{src}` | `stack.js` failed to load (posted by `stack.html`). |

### Requests (JS → Swift)

- `transclusion.resolve` — `![[embeds]]` inside cards use the main editor's
  request and payload unchanged, so the existing handler can be reused.
  Without an `onRequest` handler embeds stay unresolved. Cards never send
  `transclusion.save`, `image.save`, `date.pick` or `autocomplete.wikilink`.

### Read-only guarantee

Cards are `EditorState.readOnly` and non-editable, and a change filter
rejects every transaction that is not a host update, so widgets that edit
directly (task checkboxes, Org TODO keywords, table cells) cannot change a
card. No `docChange` is ever emitted.

### Main editor change

`wikilinkOpen` now also carries `shiftKey`, `metaKey`, `altKey` and `ctrlKey`
(`Nv3WikilinkOpenInput` in the library has the same fields). Existing handlers
ignore them. Shift/⌘/⌥-mousedown on a wikilink no longer extends the selection
or adds a cursor, so a Shift-click reaches the handler as a pure link gesture;
route `shiftKey == true` to the stack.

### Dev preview

`make dev`, then open `/stack`: three sample cards from `test-files/` (one
focused on a heading, one collapsed) beside an event log; Shift-click pushes,
duplicates flash, close/collapse work against a local mock host.

## Native integration (delivery step 3)

Status: built; awaiting the live run in step 4.

- **Controller.** `UI/SideStack/SideStackController.swift`, one per tab,
  owned by `WorkspaceTabController.sideStack` and kept across tab switches,
  main-view navigation, and the content-controller reset that follows
  trashing the open note (only closing the tab tears it down). It hosts
  `stack.html` in an `EditorWebContentController` created with
  `entryResource: "stack"`, so the web view gets the same bridge, scheme
  handlers (`nvmodern-file://`, fonts), appearance sync (`setHostAppearance`),
  process-termination reload, and native context menu (read-only: Copy,
  Look Up, Select All) as the editor. `setTheme` carries
  `runtimeConfig.editorThemeCSS(forPath: nil)` on ready and on config change.
- **State.** The card list is `WorkspaceTabState.sideStack`
  (`Core/Session/SideStackState.swift`: cards with path, focus, collapsed,
  showWholeNote; `isOpen`; `width`). Card ids are `path` + `#Heading` /
  `#^block`, so a push with the same path and focus finds the existing card
  (`flashCard`) instead of duplicating it. `PersistedWorkspaceTabState`
  carries it as an optional `sideStack` field (omitted when empty; malformed
  stacks or cards drop out without failing the tab), so no session version
  bump was needed.
- **Bodies.** Never persisted. Read with `WorkspaceFileIO` once the stack's
  page is ready (so a restored stack costs nothing until its column shows),
  updated straight from the main editor's save, and re-read for card paths in
  every `NotesWorkspaceModel.lastLiveSyncUpdate` (external edits, self-write
  confirmations). Renames follow the card; external deletions drop it.
- **Routing.** `wikilinkOpen` with `shiftKey` pushes (heading/block focus
  from the link); non-text targets (PDF, image, CSV…) keep navigating.
  Stack events: `stackOpenInMain` / `stackLinkOpen` (`openInMain`) navigate
  the main view and jump with `jumpToMarkdownReference`; `stackLinkOpen`
  (`push`) and Shift-clicked `stackInlineLinkOpen` push; `stackClose`,
  `stackCollapse`, `stackShowWholeNote` persist and echo; `contentInteraction`
  adopts the window like the editor's; `transclusion.resolve` reuses
  `DocumentSurfaceBridgeService.handleSharedRequest` with a read-only policy
  (every other request is refused).
- **Layout.** `SideStackColumnLayout` wraps the tab's body below the header
  in `TabWorkspaceView` (launchpad, or find bar + any document kind): a
  right column (default 360pt, 260–720pt) behind a
  draggable 1pt divider; the width persists on drag end. When the main
  content would drop below 520pt the column overlays the content from the
  right with a shadow instead. The column shows while `isOpen`; pushing opens
  it, closing the last card hides it.
- **Actions.** `workspace.stack.push {path?, heading?, block?}` (note verb
  "Open in side stack"; accepts a note name or `Note#Heading`),
  `workspace.stack.toggle`, `workspace.stack.focus`, `workspace.stack.close
  {id?}`, `workspace.stack.clear`, `workspace.stack.list`; MCP tool
  `open_in_side_stack`. View menu: Toggle Side Stack `⌘⌥S`, Focus Side Stack
  `⌘⌥J` (both reserved in `CommandCatalog`). Shift-Return on a note row in
  the palette pushes it.
- **Deviations / deferred.** The narrow-window sheet has no dismiss-on-click
  outside; hide it with `⌘⌥S` or by closing cards. `stackOpenInMain` ignores
  ⌘/⌥ (no "open in new tab" from a card yet). Deleted notes drop their card
  rather than showing a "missing" placeholder.
