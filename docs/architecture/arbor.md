# Arbor Technical Architecture

Status: Implementation snapshot
Last reviewed: 2026-08-13

## Purpose

Arbor is a Roam-style outliner whose documents can become programs.

The current implementation connects the outliner interaction loop to a Racket-owned fact world and materializes explicit query, pure-expression, and capability-gated effect runs as persisted outline nodes. It does not implement the full subscription architecture from the design notes.

This document separates current behavior from the target architecture.

## Design constraints

The Arbor design notes define these load-bearing rules:

- The document always renders.
- Trusted application chrome is not programmable by a document.
- Gestures remain uniform across projections.
- Meaning belongs to the document.
- Execution belongs to the kernel.
- Presentation owns no durable state.
- Identity belongs to the sync layer.
- Kernel fact and proof caches never sync; explicitly materialized results are source.
- Typing never waits for the kernel.
- The editor survives a kernel failure.
- Arbor never loses user bytes.

## Current system

The active Arbor path is:

```text
.outline path detection
        |
        v
WebEditor App
        |
        v
ArborSurface
        |
        +--> ArborOutlineStore
        +--> ArborVisibleIndex
        +--> ArborMarkdown parser
        +--> ArborMarkdownView
        |
        +--> source codec --> host persistence
        |
        +--> explicit producer/run --> materialization state machine
        |                              |
        |                              v
        +<-- ordinary persisted result blocks
        |
        v
ArborHost --> document/replace + producer/run --> persistent Racket kernel
```

The renderer applies edits locally, then sends the same serialized source revision to persistence and the kernel. Kernel failure never blocks editing or persistence.

## Document detection

Arbor uses the `.outline` file extension.

`ArborDocumentSource.swift` and `documentType.ts` recognize this extension. They add `#lang arbor/0` when a document does not contain the directive.

The WebEditor application routes an Arbor document to `ArborSurface`.

`ArborSurface` parses the opened document source into its local editing store. The development shell still provides a fixed playground when no document is open.

## Outline model

`ArborOutlineStore` owns the temporary authored outline.

The store uses normalized maps:

- A page map keyed by `ArborPageId`.
- A block map keyed by `ArborBlockId`.
- Linked sibling and child identifiers for each block.
- A bounded undo and redo history.
- Per-page structural revisions.

Structural edits relink affected blocks. They do not copy the full document.

The store supports:

- Page creation and rename.
- Block insertion and deletion.
- Text edits.
- Block split and merge.
- Indent and outdent.
- Move up and move down.
- Collapse and expand.
- Undo and redo.

The store emits `content`, `structure`, and `view` changes.

This store is an editor model. It is not the final CRDT authority from the design notes.

## Visible outline

`ArborVisibleIndex` converts the linked block tree into visible rows.

The index caches rows by page and zoom root. It invalidates structural results with a page revision.

A content edit does not rebuild visible order. A structural edit rebuilds only the affected page.

The surface currently renders all visible rows. `ArborVirtualizer` exists in the library but the simplified surface does not use it.

## Editing surface

`ArborSurface.tsx` coordinates editing and navigation.

Each block has two modes:

- Rendered mode shows parsed content.
- Edit mode shows raw source in a plain-text `contenteditable` element.

A click on ordinary rendered text starts editing. A blur returns the block to rendered mode.

The surface owns temporary view state:

- The active block.
- The current page.
- The zoom root.
- Pending caret placement.
- Element references.
- The current typing history group.

The surface sends each text change directly to `ArborOutlineStore`. It does not wait for the kernel.

## Structural gestures

The surface translates keyboard gestures into store edits:

- `Enter` splits a block.
- `Shift+Enter` inserts a line break.
- `Tab` indents.
- `Shift+Tab` outdents.
- Backspace at offset zero merges with the previous block.
- `Option+ArrowUp` and `Option+ArrowDown` move a block.
- Arrow keys move the caret between visible blocks.
- `Command+Z` and `Command+Shift+Z` use store history.
- Key bindings are declared in `src/arbor/keymap.ts` (editor, selection, completion, and date-leader scopes). `ArborSurface` supplies what each command does, and F1 help reads the same tables.
- `Command+Enter` runs the active producer and refreshes its live children.
- `Command+Shift+Enter` runs it as a new generation.

The bullet controls collapse and zoom. Its context menu controls copy, delete, move up, and move down.

## Markdown pipeline

The Markdown pipeline has two parts:

```text
block source
    |
    v
parseArborMarkdown
    |
    v
source-ranged Arbor Markdown AST
    |
    v
ArborMarkdownView
    |
    v
rendered React nodes
```

`src/lib/arbor/markdown/parser.ts` uses the Lezer CommonMark parser.

The parser adds Arbor inline syntax:

- `[[page links]]`
- `((block references))`
- `#tags`
- `^^highlights^^`
- Inline and display math

The parser returns framework-neutral nodes with exact source ranges. The React renderer does not parse text.

The parser also supports CommonMark and GFM structures. Current rendering includes headings, emphasis, code, links, images, strikethrough, math, and fenced code.

Malformed syntax remains literal text. This preserves the rule that the document always renders.

## Rendered interactions

`ArborMarkdownView` reports navigation intent to `ArborSurface`.

It reports three intent types:

- External link.
- Page link.
- Block reference.

Interactive marks stop the row mouse event. A link click does not start block editing.

The surface resolves local page links and block references against the in-memory store.

An unresolved page link or block reference goes to `ArborHost`.

External links go to `ArborHost` in nvModern. The development shell opens them in a browser tab.

## Source ranges and caret placement

Each rendered leaf carries its source start and end offsets.

When the user clicks rendered text, the surface converts the DOM position to a source offset. It then places the caret at that offset in raw source.

This keeps parsing and caret mapping separate. The renderer does not search source text to recover positions.

Math and image widgets clamp their click position to their source range.

## Host boundary

`ArborHost` defines the current JavaScript host boundary.

It contains methods for:

- Document writes.
- Kernel evaluation.
- Document replacement, query inspection, explicit producer runs, and source-backed intents.
- Wikilink navigation.
- Inline-link navigation.

`nvmodernArborHost` implements this boundary with the WebEditor bridge.

The surface persists each debounced source revision first, then sends that same revision to `document/replace`. An explicit run flushes this pipeline, calls `producer/run`, applies a current response as one outline transaction, and persists the resulting blocks. `query/run` and `view/get` remain inspection APIs for tests and the development harness.

## Materialized results

Document loading, expansion, source editing, and fact-world changes never execute
a producer. `Command+Enter` performs Run; `Command+Shift+Enter` performs Run as
New.

Racket returns a stable key and backend-formatted Markdown for each result. A
scalar produces one result; a query produces one result per row. The renderer
does not inspect Datalog facts or invent a query presentation.

The materialization reducer has three states:

- `live` output is reconciled by Run.
- `snapshot` output is preserved by Run as New.
- `detached` output is user-owned and never reconciled.

Managed output uses the ordinary block renderer with quieter foreground text.
Focusing it permits editing; the first text or structural mutation detaches it in
the same undo transaction. A normal rerun preserves live block IDs. If output was
detached, the next run appends a new live sibling.

Managed result subtrees are excluded from canonical facts, preventing queries
from consuming their own projections. Detached output becomes ordinary authored
data and enters the fact world.

A query may take direct child attributes as default inputs and use one
source-defined `project` template to format each row. When one result row has one
block-valued origin, its live child persists that source block ID and a
`source-text` update policy. Editing the child stays local; blur sends
`intent/apply`. The kernel returns a candidate source replacement, and the host
compares, writes, and reindexes it. Any conflict preserves the edited text and
detaches the result.

An effect producer begins with `!`. Its arguments are typed JSON data assembled
from literals, `$name` inputs, `(list ...)`, and `(record ...)`; these forms are
read as inert data. The kernel validates time, filesystem, process, HTTP,
clipboard, notification, curated native action, and configured model handlers,
then returns a bounded plan. It never performs the host operation. The trusted
host prompts for guarded capabilities, enforces workspace, timeout, and output
limits, executes, and returns a typed result for kernel formatting. Expansion
remains inert, and effects use the same Run and Run as New state machine.

`outline/*` producers are explicit source transactions. The kernel resolves
`(self)`, stable block IDs, or a same-document query into at most 100 operations,
applies them to a candidate source, and recompiles after each operation. The host
previews that exact candidate, compares it with the source on disk, persists and
reindexes it, and acknowledges completion. The renderer installs the accepted
source as one undoable store edit; it never interprets or reconstructs the
transaction.

## Development shell

`ArborDevSurface.tsx` gives `ArborSurface` a development host backed by the shell server.

Opened `.outline` documents save through the file endpoint. The no-file playground remains in memory.

The development server starts the Racket kernel on demand, seeds it with the
`.outline` files under `EDITOR_ROOT`, and shows every JSON request, response, and
kernel diagnostic in a visible transcript. It also provides a small `query/run`
harness. Accepted documents replay automatically after a kernel restart.

## Source codec

`sourceCodec.ts` parses and serializes the current `#lang arbor/0` outline format.

The format uses:

- `-` for a block.
- Two spaces for each nesting level.
- `|` for a continuation line.
- `^uid` for a stable block identifier.
- `~c1~...` after the stable ID for basic materialization metadata.
- `~c2~...` for a source-backed result's origin block ID and update policy.

For example:

```text
^answer~c1~l~sum~scalar~2~<input-hash>~7
```

The stable ID is `answer`. The metadata records live state, producer provenance,
result key, generation, input hash, and fact-world revision. Indentation remains
the only structural parent relationship.

The parser reports diagnostics and produces an outline snapshot.

The serializer writes each block identifier. This differs from the design goal of writing visible identifiers only after a reference needs them.

The active document path uses this codec for initial parsing and every persisted revision.

## Native kernel path

nvModern contains a persistent Racket process path.

`ArborKernelSupervisor.swift` starts a Racket process and exchanges newline-delimited JSON messages.

`ArborKernelProtocol.swift` defines `evaluate`, `document/replace`, `query/run`,
`view/get`, `producer/run`, `intent/apply`, `effect/complete`, `effect/cancel`,
and `mutation/complete` requests and responses.

The supervisor:

- Locates Racket.
- Locates the bundled kernel script.
- Starts and restarts the process.
- Replays accepted workspace documents after a restart.
- Tracks requests by identifier.
- Applies a request timeout.
- Converts process and protocol failures into diagnostics.

One supervisor is shared by every tab in a workspace. Initial workspace indexing
loads `.outline` documents at revision zero; an opened renderer then replaces its
document with the newer authored revision. Indexing updates the fact world but
does not run producers.

This remains a request protocol with explicit materialization. It is not the later incremental subscription protocol from the design notes.

The WebEditor bridge calls it for document replacement and the development query harness.

## Current authority

The current implementation assigns authority as follows:

- The persisted `.outline` source owns authored and materialized block state.
- `ArborOutlineStore` owns the immediate optimistic editing copy and history.
- `ArborVisibleIndex` owns derived visible order.
- The Markdown AST owns parsed inline presentation structure.
- `ArborSurface` owns selection, focus, completion, and navigation state.
- The host owns persistence, capability decisions, effects, and navigation outside the document.
- The Racket kernel owns canonical facts, query evaluation, pure expression evaluation, mutation planning, and materialized result shape.

## Future authority

The future system can replace storage and transport without changing materialized
result semantics:

- The CRDT owns source identity and collaborative edits.
- The lossless concrete syntax tree owns source structure and trivia.
- The Racket kernel owns evaluation, graph facts, and provenance.
- Explicit producer runs continue to create ordinary source nodes.
- The renderer owns only local echo, selection, focus, and transient layout.

The renderer must send source edits without waiting for semantic results.
The kernel may answer inspections asynchronously, but only an explicit run
materializes output.

## Migration boundaries

The current outliner can evolve without a large surface rewrite if these boundaries remain stable:

1. Keep block identity separate from React identity.
2. Keep structural commands inside one outline edit API.
3. Keep Markdown parsing outside React components.
4. Keep rendered gestures as explicit intents.
5. Keep host operations behind `ArborHost`.
6. Keep facts and ephemeral projections out of `ArborOutlineStore`; persisted
   materialized blocks are source.

The store can later become an adapter over a local CRDT replica.

The host can later replace the local store with a CRDT adapter without changing
the producer state machine.

The Markdown parser can later consume ranges from the lossless kernel syntax tree.

## Known architecture gaps

The current implementation has these deliberate gaps:

- Block identifiers do not come from a sync layer.
- The Markdown AST is not a lossless document concrete syntax tree.
- The kernel protocol is request-based instead of subscription-based.
- Materialized results record producer provenance but not derivation proofs.
- Parameter-input controls are absent; defaults and row templates live in source.
- Provider APIs, streaming effects, incremental subscriptions, and automatic stale-result indicators are absent.
- External edit import and CRDT sync are absent.

These gaps are acceptable for the editing playground. They are not acceptable as the final architecture.

## Verification

Use these commands:

```bash
make test-web TEST_ARGS='src/lib/arbor src/arbor'
make test-arbor-kernel
make test
```

The parser tests cover Markdown and Arbor inline syntax.

The store tests cover structural edits and history.

State-machine tests cover Run, Run as New, detachment, stable identity, and
query-row reconciliation. Document-sync tests cover source/revision parity,
explicit materialization, authoritative transaction install, undo, and
kernel-down persistence. Native and Racket tests cover workspace loading,
typed effect handlers, query-selected transactions, action/model execution, and
live replace/query/view/producer flow.

## Key files

- `NVModern/WebEditor/src/arbor/ArborSurface.tsx`
- `NVModern/WebEditor/src/arbor/ArborMarkdownView.tsx`
- `NVModern/WebEditor/src/arbor/ArborBlockContextMenu.tsx`
- `NVModern/WebEditor/src/arbor/host.ts`
- `NVModern/WebEditor/src/arbor/bridgeHost.ts`
- `NVModern/WebEditor/src/arbor/documentSync.ts`
- `NVModern/WebEditor/src/lib/arbor/store.ts`
- `NVModern/WebEditor/src/lib/arbor/materialization.ts`
- `NVModern/WebEditor/src/lib/arbor/visibleIndex.ts`
- `NVModern/WebEditor/src/lib/arbor/sourceCodec.ts`
- `NVModern/WebEditor/src/lib/arbor/markdown/`
- `NVModern/Core/Arbor/ArborDocumentSource.swift`
- `NVModern/Core/Arbor/ArborKernelProtocol.swift`
- `NVModern/Core/Arbor/ArborKernelSupervisor.swift`
- `NVModern/Core/Arbor/ArborWorkspaceDocumentLoader.swift`
- `ArborKernel/`

## Related documents

- [Roam UI gap inventory](../tickets/0001-arbor-roam-ui-gap-inventory.md)
- [Graph and kernel boundary](../tickets/0002-arbor-graph-kernel-boundary.md)
- “The Outline Is the AST” Arbor design notes
