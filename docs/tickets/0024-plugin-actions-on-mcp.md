---
id: 0024
title: Opt-In MCP Exposure for Plugin Actions
status: open
type: feature
area: plugins
priority: P3
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/action-system.md
  - ../architecture/plugins.md
---

# Opt-In MCP Exposure for Plugin Actions

## Goal

`nv3 mcp` exposes a curated static allowlist. A plugin should be able to
offer an action to agents:

```js
nv.actions.register({ id: "clip", title: "Clip web page", mcp: true, args: [...], run })
```

## Context

- `NVModern/Core/Actions/ActionMCPCatalog.swift` is a static list of
  `makeTool(...)` entries, compiled into both the app and the `nv3` CLI
  (`project.yml`, target `NVModernCLI`).
- `nv3 mcp` (`ActionMCPServer.swift`) runs out of process and talks to the
  app over the socket; it can call `app.actions.list` at start-up.
- `ActionDescriptor.arguments` carries name, summary, kind, required: enough
  to synthesise an MCP tool's input schema.

## Steps

1. `nv.d.ts`/prelude/host: accept `mcp?: boolean` in `ActionSpec`; when true,
   add the tag `mcp` to the descriptor's `tags`.
2. `ActionMCPServer`: on `tools/list`, fetch `app.actions.list` over the
   socket, filter descriptors whose `tags` contain `mcp`, and append tools
   named `plugin_<name>_<id>` (lower-cased, `.`→`_`), description from the
   descriptor `summary`, properties from `arguments` (`string`→string,
   `int`→integer, `double`→number, `bool`→boolean, `array`/`object`→object/array
   with no inner schema). Calls route to the descriptor's `method` with the
   arguments passed through as `args`.
3. Cache the dynamic list for the server process lifetime; agents reconnect
   rarely, and a plugin reload changes nothing until then. Document that.
4. Tests: `NVModernTests/ActionMCPTests.swift` has catalog tests; add one
   building tools from a descriptor list containing an `mcp`-tagged plugin
   descriptor.
5. Docs: `action-system.md` MCP section; `authoring.md` ("Capturing from
   outside nvModern").

## Acceptance

- With a plugin action marked `mcp: true`, `nv3 mcp` lists it and an agent
  can call it with its declared arguments.
- Unmarked plugin actions remain invisible to MCP.

## Non-goals

- Exposing all plugin actions by default; exposing `invoke_action`.
