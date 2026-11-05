# Command palette

One surface, one keyboard model, one catalog. Every palette interaction is a
sentence: **subject · verb · object**.

Root is always files, never a mix of files and verbs. The active tab's document
is the first row, so `⌘K` `⇥` reaches its actions; typing changes the noun; Tab
steps into a file's actions and Backspace comes back. Enter runs the sentence
with defaults.

The five flows the surface exists for:

| Flow | Keys |
|---|---|
| actions of this tab | `⌘K` `⌘K` (or `⇥`) `<type>` `⏎` |
| open another file | `⌘K` `<type>` arrows `⏎` |
| refile another file | `⌘K` `<type>` `⇥` `refile` `⏎` pick folder `⏎` |
| search across files | `⌘K` `/<type>` `⏎` |
| act on a searched passage | `⌘K` `/<type>` `⇥` `<type>` `⏎` |

## Slots and the stack

Each slot is a frame (`NVModern/Core/Palette/PaletteModel.swift`,
framework-agnostic): a set of item sources, a query, and a selection.
`PaletteStack` owns them; the query and the selection always belong to the top
frame, so pushing and popping never leaks state between slots.

| Slot | Pushed by | Shows |
|---|---|---|
| root | `Cmd+K` | nouns only — notes by default |
| verbs | Tab on a noun | the verbs that accept that noun, headed by it |
| object | Tab/Enter on a verb that still needs an argument | that argument's picker |

Backspace over an empty query pops a slot. Escape clears modes, else pops, else
closes.

`PaletteSession` (`UI/Palette/PaletteSession.swift`) owns the stack, the modes,
the resolver, and the in-flight resolve task. `WorkspaceTabView` handles only
what needs the tab: presenting the host, activations, and document preview.

## Root layout

Root is the only frame whose layout is not "its sources, in order". It never
federates: no verb sections, no offer to search contents. One list of files.

**Empty** — one headerless run, then one header:

1. The active tab's document, subtitled `current tab`, selected by default.
   Omitted when the tab shows none. Enter on it navigates to where it already
   is, which is to say it closes the palette; Tab opens its actions.
2. The other open tabs, subtitled `open tab`.
3. `Recent` — recently modified notes, subtitled with the folder they live in.

**Typed** — `Notes`, twelve of them, ranked by `PaletteSearchRanker` over
individual name/path segments. Exact and prefix matches dominate fuzzy ones;
leaf segments dominate ancestors at equal specificity. Nothing else: the
placeholder already teaches `/` for contents, and Tab already reaches a note's
verbs.

## Prefixes

The first character of the root query picks the noun kind the slot denotes.

| Prefix | Noun | Default verb (Enter) |
|---|---|---|
| *(none)* | notes | Open |
| `>` | verbs only, grouped by subject | run it |
| `/` | passages (full-text matches) | Open at match — opens the note and seeds the find bar |
| `#` | folders | Browse — select it in the Miller browser |

`Cmd+Shift+K` and `Cmd+Shift+F` are these prefixes: they open root with `>`
and `/` already typed.

`Cmd+N` is a standalone frame, like Outline: it lists every action in the
`Capture` category (plugins register them), with each action's icon and in rank
order, without a `Recent` section. Escape closes it, and Backspace over an empty
query stays put.

A plugin's pickers (`nv.ui.pick`, `prompt`, `pickNote`, `pickFolder`) are
standalone frames too, opened through `PalettePreset.pluginPick`. Any
activation in one answers the plugin instead of opening or running anything;
closing the palette answers `null`. See `docs/architecture/plugins.md`.

`workspace.palette.open --preset verbs` opens root with the verbs frame for the
tab's document already pushed — what `⌘K` `⇥` reaches by hand — so automation
and smoke tests can land on the actions list directly.

## Document outline

`Cmd+Shift+O` opens the Outline preset in the same palette as `Cmd+O` sibling
search. File > Open remains available without a shortcut. Go > Go to Heading
and `workspace.document.outline` open the same preset; automation can also use
`workspace.palette.open --preset outline`.

The empty query lists every heading in document order, indented by its ancestor
count, with the current section selected. Typing uses `PaletteSearchRanker`
over the heading and its ancestors, then shows flat results with a parent
breadcrumb and line number. Markdown includes H1–H6; Org retains arbitrary
depth. The editor supplies live headings, including unsaved changes, separately
from the library's compact three-level ToC presentation.

Arrows preview the selected heading without taking focus from the input. Return
commits and focuses the editor; Escape or outside dismissal restores the
original selection and scroll. Switching to another preset cancels the preview
while keeping palette focus. Outline sessions bind to the originating document
editor. Outline rows do not offer note
multi-selection, pinning, or new-tab activation.

## Subjects

Every palette-visible action belongs to a subject — `document`, `window`, or
`workspace` — declared on `ActionPalettePresentation.subject`, or derived from
its category when it declares none (Document/Format/Table → document,
Layout/Workspace → window, everything else → workspace). This is what groups
the `>` scope, sectioned by category: Open, File, Document, Format, Window, Create, Appearance.

## Nouns and verbs

Items that denote something carry a `PaletteTarget`: a workspace note, an open
tab, a folder, a passage, or a `batch` of them. Tab on a noun pushes
`.verbs(for: target)` — the verbs that declare an argument for that noun kind
in `nounArguments`, each pre-filled with its value.

One exception, and it is the common case. When the bound noun *is* the document
the tab already shows — the first row of an empty root, so `⌘K` `⌘K` — the frame
widens into that tab's whole menu: its file verbs first under the file's name,
then Layout and Tabs, then Create and Appearance. Any other note gets the file categories only. The noun pill names the subject, so no section repeats it.

- A note or tab binds its relative path.
- A folder binds its relative path (`""` for the root).
- A passage binds the note's path plus `snippet` and `term`.
- A batch binds nothing up front: the session runs the verb once per member.

`listedOnlyWhenBound` keeps a verb out of root entirely — the passage verbs
(`workspace.passage.quote`, `.transclude`, `.copy`) use it, because "quote this
into the current note" means nothing without a passage. `boundTitle` lets a verb
read differently once bound ("New note here…" in a folder's verbs frame).

Handlers must still default to the current document or folder when the noun
argument is absent, so plain invocation from a keybinding or the socket keeps
working.

## Batch

`Cmd+M` enters multi-select; Space marks note rows; Tab or Enter binds the
marks as one subject. A single mark binds that noun; several bind
`.batch([…])`, whose verbs frame lists only descriptors with
`acceptsBatch: true` that apply to every member — today
`workspace.note.refile`, `workspace.document.copyPath`, and
`workspace.document.copyRelativePath`.

Running a batch verb invokes the action once per member, sequentially and
awaited, with that member's own bound arguments. A batch survives into an
object frame, so refiling three notes still picks one folder first. Failures
are logged with `paletteDebugLog` and beep once at the end.

## Modes

Modes are layered over the session, not the stack: they survive pushing and
popping and are cleared by Escape.

| Mode | Key | Effect |
|---|---|---|
| preview | `⌘P` | the selected note is pushed into the editor behind the palette and restored on close |
| multi-select | `⌘M` | Space marks note rows; leaving the mode clears the marks |
| pin | `⌘.` | after a run the palette stays open, reset to an empty root |

## Keyboard map

| Key | Effect |
|---|---|
| `↑` / `↓` | move selection (wraps) |
| `⏎` | run the sentence with defaults; in an object frame, run it |
| `⌘⏎` | open the selected note in a new tab |
| `⇥` | commit this slot: a noun becomes the subject, a verb opens its object |
| `⌘K` | inside the palette, back to the root frame; on a lone root it does nothing and never closes |
| `⌫` | with an empty query: back one slot |
| `⎋` | clear modes, else back one slot, else close |
| `space` | in multi-select: mark the selected note. Otherwise an ordinary space |
| `⌘P` / `⌘M` / `⌘.` | preview / multi-select / pin |
| `⌘⇧K` `⌘⇧F` `⌘N` | reset to that preset, carrying the typed text |
| `> / @ #` | change the noun kind the root slot denotes |

Keys are read by a local monitor in `OmniboxNSTextField`, because the field
editor would otherwise consume Return, the arrows, Tab, Space, and Backspace.

## Sources and providers

Each `PaletteSourceKind` has one provider in `UI/Palette/`:

| Source | Provider |
|---|---|
| `.openTabs`, `.recentNotes`, `.notes` | `NotesPaletteProvider` |
| `.passages` | `PassagesPaletteProvider` |
| `.actions(category:)` | `ActionsPaletteProvider` |
| `.folders` | `FoldersPaletteProvider` |
| `.editorThemes` | `EditorThemesPaletteProvider` |
| `.textInput` | `TextInputPaletteProvider` |
| `.outline` | `OutlinePaletteProvider` |

`PaletteResultsResolver` decides which sources a frame consults and in what
order their sections appear, runs them concurrently, and applies the coalescing
delays the old views used (35 ms for notes, 140 ms for passages, none for the
rest). A query change cancels the in-flight resolve.

Providers receive a `PaletteContext` built by the tab **inside the resolve
task**: the action variables reach workspace state through
`ActionAutomationContextBuilder`, which must never run during a render pass.

## Actions come from the registry

`ActionsPaletteProvider` lists every `ActionRegistry` descriptor carrying a
`palette:` presentation. There is no separate command catalog to keep in sync.

- `palette.when` is evaluated once per resolve against the automation context
  variables; a false expression hides the row. A `when` is skipped once a noun
  is bound (the noun replaces the current document), except for the methods in
  `methodsGatedEvenWhenBound`, which still need the live workspace.
- Categories order rows within an empty subject group: Create, Document,
  Format, Table, Layout, Appearance, Workspace. A typed query becomes
  one globally ranked list, so category order cannot outrank relevance.
- Matching runs `PaletteSearchRanker` over the title plus separate alias,
  category, tag, and method properties. It uses exact > token > prefix >
  substring > field-local fuzzy tiers and compares the weakest query term
  first; declared action rank only breaks otherwise equal matches.
- Shortcut glyphs come from `PaletteShortcutResolver`, resolved per item at
  resolve time (the resolver is cached per project root).
- A few verbs show their current value before the chevron —
  `ActionsPaletteProvider.valueProviders` maps a method to a small closure over
  the context (refile → the note's folder, theme → the selected theme, focus
  mode and sidebar → their state).

## Two tiers and a recent block

Every verb has a `rank`. Ranks at or above `ActionPalettePresentation.longTailRank`
(200) are the long tail: copy relative path, reload, open in Zed, the diff pair,
the sixteen table row/column operations, cycle theme, next/previous tab. They
match when you type but never appear in the empty menu. The empty menu opens with a `Recent` section of the last three verbs run
(`PaletteRecentVerbsStore`, three methods in `UserDefaults`), lifted out of
their own sections so nothing repeats.
The standalone `Cmd+N` Capture menu keeps all its actions in rank order instead.

## Argument frames

`PaletteActionPlanner.activation(for:suppliedArgs:target:subjectTarget:)`
decides whether a row runs or pushes. An action with a picker-bearing argument
that is still missing pushes an object frame carrying a
`PalettePendingCommand`; choosing a row in that frame merges the value and runs
the action. Trailing "…" in a title marks the rows that push.

The pickers, declared on `ActionArgumentDescriptor.picker`: `text`,
`workspaceFolder`, `editorTheme`, `documentWidth`.

“Document theme…” and “Page width…” collect a choice and update the active
tab’s inspector settings through the workspace action runtime. These settings
are restored with the tab; frontmatter overrides still take precedence. The
existing “Default editor theme…” action changes the global default in config.toml.

Two pre-fills happen before the planner runs:

- in a noun-bound frame, `PaletteActionPlanner.boundArgs` supplies the noun;
- otherwise a folder-noun action inherits the Miller browser's current folder,
  which is what the old `folderActionArgs()` did for the daily note, the
  clipboard note, and new notes.

## Chrome

The header shows the sentence so far and no more of it than there is. It is
44 pt, has no icon, and draws no box around the input.

- **Root**: the input alone, plus the preset's shortcut glyph at the trailing
  edge. A typed prefix is its own cue, so there is no kind chip.
- **Verbs frame**: one accent-tinted noun pill, `▸`, the input ("Do what?").
- **Object frame**: that pill, `▸`, the verb as plain secondary text, `▸`, the
  input carrying the picker's own question ("Which folder?", "New name").

Rows show the title, an optional snippet line, the verb's value or the row's
meta, shortcut glyphs, and a chevron when the row pushes. Nouns show file-type
icons, and the Capture menu shows each action's icon. Section headers are one
uppercase caption. Multi-select adds a leading ○/●.

The footer holds at most four hints, chosen for the selected row — `⏎ open` /
`run` / `choose`, `⇥ actions` on a noun or `⇥ choose` on a verb, `⌫ back` when
the stack can pop, and `⎋`. `⌘⏎` still opens a note in a new tab; it is simply
not advertised. Active modes read on the right as an accent dot and their names
joined by `·`.

The surface is `.popover` vibrancy tinted 0.18, a 1 pt inner white stroke, and
one soft shadow. Selected rows keep the system accent fill with forced white
text (CLAUDE.md rule 9).

## Files

```text
NVModern/Core/Palette/PaletteModel.swift    slots, stack, targets, modes, planner (no AppKit)
NVModern/UI/Palette/
  PaletteSession.swift                      stack + modes + resolver + resolve task
  PaletteResultsResolver.swift              which sources, what order, debounce
  PalettePresetResolver.swift               preset -> initial stack
  PaletteFrameView.swift                    the surface, sentence header, rows, footer
  PaletteSourceProvider.swift               provider protocol + PaletteContext
  *PaletteProvider.swift                    one per source kind
  PaletteDebug.swift                        breadcrumbs + open notification
NVModern/App/ActionPassageBuiltinActions.swift  the passage verbs
NVModern/UI/OmniboxTextField.swift          the input field and its key monitor
NVModern/UI/WorkspacePaletteHost.swift      window-level overlay host
```
