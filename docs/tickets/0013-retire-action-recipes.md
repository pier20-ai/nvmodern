---
id: 0013
title: Retire TOML Action Recipes in Favour of Plugins
status: open
type: cleanup
area: plugins
priority: P1
created: 2026-10-08
updated: 2026-10-08
related:
  - ../architecture/plugins.md
  - ../architecture/action-system.md
  - ../architecture/configuration.md
---


# Retire TOML Action Recipes in Favour of Plugins

## Implementation — 2026-10-08

All four configured recipes are ported to
`NVModern/Plugins/examples/selection-formatting.js` and installed as
`~/.config/nvmodern/plugins/selection-formatting.js`:

- User Quote Selected
- Important Callout Selected
- Checklist Selected Lines
- Mark Selected Reviewed

Palette titles, summaries, category, icons, keywords, ranks, document subject,
and text/editability availability are preserved. The first three invoke the
existing `markdown.selection.prefixLines` primitive, preserving its multi-range
and single-undo behavior. Reviewed retains its empty-selection guard and local
`yyyy-MM-dd HH:mm` timestamp, using the invocation time.

The user's config was backed up before removing the four `[[actions]]` tables:
`~/.config/nvmodern/config.toml.pre-recipe-migration-20261008-215513.bak`.
A parsed comparison proved every other config value unchanged; non-action
sections were retained byte-for-byte. No legacy action keybindings or
`user.<id>` method bindings existed in the config.

Recipe models, runner, registration, dispatcher cases, runtime/config fields,
and `automation.recipe.run` are removed. The expression evaluator and palette
availability context remain. Legacy `[[actions]]` tables load with a warning,
are ignored, and are omitted from subsequent Settings writes. Legacy
`action = "..."` keybindings (the actual old field name) warn and are skipped.
Handwritten architecture, configuration, authoring docs, and AGENTS.md now
point multi-step workflows to plugins.

## Validation

`make test` passed: 388 tests, two existing skips, zero failures.
`make typecheck-plugins` passed. The focused replacement-plugin test exercises
all four handlers, checks exact prefix arguments, reviewed formatting and its
empty-selection guard. The legacy-config test checks warnings and omission
from encoded config. Existing MCP regression coverage checks that the retired
method is absent. Remaining manual editor/palette verification awaits an unlocked Mac. The
replacement's multiline/multi-range and Undo behavior delegates to the existing
editor primitive; this migration does not change that implementation. The
retirement and migration are implemented; the ticket stays open until the
remaining smoke checks can be completed.

## Non-goals

Changing expression or palette availability semantics, or adding a second
workflow execution system.
