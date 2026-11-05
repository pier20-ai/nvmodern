---
id: 0029
title: Replace Chat Documents with Agent Terminals and Editor MCP
status: open
type: epic
area: agents
priority: P2
created: 2026-10-18
updated: 2026-10-27
related:
  - 0030-retire-companions-and-redesign-cross-surface-interactions.md
  - 0024-plugin-actions-on-mcp.md
  - 0026-file-sync-conflict-policies-and-merge.md
  - ../architecture/action-system.md
  - ../architecture/configuration.md
---

# Replace Chat Documents with Agent Terminals and Editor MCP

> **Update 2026-10-27.** Chat Documents and companions are gone, removed ahead
> of this work rather than after it: the chat UI and palette mode, the
> `workspace.chat.*` actions, the per-turn Claude/Codex adapters, session
> discovery and transcript hydration, `WebEditor/src/chat/`, and the
> `[agents]`/`[chat]` config tables. Delivery step 3 below is therefore done.
> The terminal and the editor-MCP round trip remain the plan; binary location
> (`AgentBinaryLocator`, removed) will need to come back for the launch presets.

## Goal

Replace the custom interactive Chat Document with an embedded terminal in
which users run their own agents. Start with Claude Code and Codex launch
presets, retain a plain shell, and make nvModern's editor available through
`nv3 mcp`. Agents own their conversation UI and behavior; nvModern owns
documents, context transfer, and reliable application of edits.

This is a proposed implementation direction. Prove terminal embedding and
the editor round trip before retiring the existing interactive chat path.
The companion UI is being retired separately in ticket 0030; the terminal
must not depend on it.

## Problem and current implementation

The user reports that Chat Documents don't work reliably and that the
integration becomes stale as agents change. The current implementation
owns several provider-specific layers:

- `UI/Chat/ChatSessionController.swift` launches a process for each turn and
  maintains conversation and streaming state.
- `Core/Agents/ClaudePrintAdapter.swift` and `CodexExecAdapter.swift` decode
  provider events into `AgentChatEvent` for our own chat renderer.
- Session stores, discovery, forking, and transcript hydration interpret
  provider-owned files, while `WebEditor/src/chat/` supplies another chat UI.

Embedding the actual interactive CLI removes the need to reproduce its
conversation and approval interface. Small launch integrations will still
need maintenance, but provider event streams and private transcript formats
must not remain prerequisites for starting and using an agent.

## Direction

### Native terminal and session ownership

Use the full rendered macOS libghostty embedding interface behind a small
AppKit wrapper. Pin an upstream revision and integrate its build through
`make`; `libghostty-vt` alone supplies terminal state and parsing rather than
the complete rendered surface. Verify the embedding API and packaging at
implementation time because the upstream interfaces are still evolving.

Start with a terminal in an ordinary native workspace tab. Preserve AppKit
tab creation, drag, reorder, close, and restore behavior. Any additional
presentation should follow the interaction design in ticket 0030.

A controller-owned session retains the terminal surface and running process
across tab changes and view attachment changes. Define explicit close and
quit behavior for running sessions. Restoring a terminal entry or resuming
an agent conversation after relaunch is distinct from keeping its process
alive; don't imply process persistence that isn't implemented.

Launch in an explicit project directory, using the user's installed agent,
configuration, authentication, and normal permission behavior. Claude and
Codex presets should be thin launch configurations. A plain shell and a
configurable command keep other agents usable without adding another event
decoder. Handle missing binaries and MCP connection failures visibly.

### Strengthen the existing MCP boundary

`Core/Actions/ActionMCPServer.swift` already bridges stdio MCP to the local
action socket. `ActionMCPCatalog.swift` exposes context, selections, notes,
search, headings, backlinks, navigation, and note creation. Extend this
surface through the existing action system, and keep it usable by agents
launched in external terminals as well.

Prioritize live buffer reads, explicit document targets, revision-checked
edits, undoable transactions, and diff review. Specify whether each read
returns the live buffer or disk content, including truncation and revision
metadata. External agent file writes must follow the same reload/conflict
rules as other external changes; coordinate with ticket 0026.

Today's MCP defaults are unsuitable for delayed responses: project targeting
defaults to the frontmost workspace, and selection replacement targets the
focused editor. A context attachment must capture its originating project,
document, surface, range, and revision. Returning an edit must validate that
target and handle intervening edits without silently changing another tab.

Configure `nv3 mcp` for the launched agent with explicit workspace/session
binding. Decide how that binding reaches the stdio server without replacing
the user's unrelated agent settings. Keep agent-specific setup isolated.

### Transfer context and results explicitly

Coordinate the user-facing commands with ticket 0030. Support sending an
editor selection or attaching a document reference, with its captured
context, to a chosen terminal. Start with user-directed paste into the
agent's composer, leaving submission to the user; define behavior when the
terminal is running a shell or isn't ready for input.

For the return path, support inserting or quoting explicitly selected
terminal text. Substantial agent output should become a document or an MCP
edit proposal that nvModern can review and apply. Don't scrape terminal
output to infer assistant messages or tool results, which would recreate
the provider-specific integration this work removes.

## Delivery and acceptance

1. **Prove embedding.** Build one retained terminal surface and run both
   interactive agents in the correct directory. Verify keyboard input, IME,
   clipboard, scrolling, resizing, display scale changes, focus, and native
   tab switching/closing. Resolve app-versus-terminal shortcut ownership.
2. **Prove the editor round trip.** Send a selection containing unsaved
   edits, read its bound context through MCP, and return an undoable edit or
   reviewable diff. Switching tabs or modifying the source while the agent
   works must produce correct targeting or an explicit conflict.
3. **Retire custom chat execution.** Once the replacement works, remove the
   process-per-turn adapters and interactive renderer where no longer used.
   Preserve access to existing conversations through a documented migration
   or provider-owned history/resume path. Don't delete provider session data.
4. **Validate integration.** Run `make`, applicable web/native tests, and a
   live Debug-app smoke test. Verify launch/restore and external-file-change
   behavior, then update action, configuration, and agent documentation.

## References

- [Ghostty architecture and embedding](https://ghostty.org/docs/about)
- [Current libghostty status](https://github.com/ghostty-org/ghostty#cross-platform-libghostty-for-embeddable-terminals)
- [cmux: an existing native macOS libghostty consumer](https://github.com/manaflow-ai/cmux)
- [Codex MCP configuration](https://developers.openai.com/codex/mcp/)

These references informed the proposal on 2026-10-18; verify current APIs
before implementation.
