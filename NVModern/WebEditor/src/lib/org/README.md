# Org parsing and rendering

The custom parser in `parser.ts` supplies the current command index. Its results
are cached by immutable CodeMirror `Text` identity, so document scanning, dates,
tables, source highlighting, and decorations share one parse per text version.
Treat the returned index as read-only. A cursor move keeps the same text version
and does not parse it again.

`orgSyntax.ts` holds the synchronous incremental parse state from the
[`scutifer/uniorg` fork](https://github.com/scutifer/uniorg). The main renderer and
optional prose unwrapping share its exact current tree. Each edit sends the
CodeMirror change ranges to `updateIncrementalParse` and publishes the new tree
in the same transaction, before decorations render. Cursor moves reuse it.

Ordinary edits reparse the smallest containing section. Heading-level changes,
preamble edits, and uncertain section boundaries use a synchronous full parse.
All source positions, checkbox/TODO click offsets, and line unwrapping therefore
describe the current buffer immediately. There is no delayed parse, stale
snapshot mapping, temporary removal of formatting, or later render refresh.

The fork includes indexed source-position lookup and the previous allocation
improvements: cached object regexps and link expressions, and shared restriction
templates with independent mutable sets for citation parsing. It is distributed
as a built GitHub release package pinned by URL and Bun's integrity lock, so
nvModern does not depend on a local checkout or a moving branch.

This first implementation still builds a new source string and updates suffix
positions. Edits within a single very large section may reparse that entire
section; structural changes may parse the whole document. The custom command
index also still performs one full scan per text version. Further performance
work should preserve immediate, consistent rendering rather than defer it.

Run `make test-web` and `make` from the repository root after changes. The Org
tests cover cursor concealment, current click offsets and line unwrapping,
structural fallbacks, undo/redo, and mutable parser restriction isolation. The
fork's differential tests compare incremental trees with full parses, including
every source position.

## List editing

Org list commands use the Uniorg tree for item ownership and subtree boundaries.
Tab and Shift-Tab move an item's continuation lines and descendants together;
ordered siblings at the source and destination levels renumber in the same
transaction. Enter continues the list, resets new checkboxes, and follows the
Markdown editor's blank-separator behavior for loose lists. Backspace removes
markup without deleting the item's body. Undo restores the complete edit,
including its previous numbering.

Org retains two-space nesting, `1.`/`1)` and alphabetic marker styles, and explicit
`[@5]` or `[@start:5]` counter resets. Literal source/example blocks and unrelated
lists are left alone. `orgListEditing.test.ts` includes direct Markdown parity
checks, cursor/selection cases, and empty-item regressions.
