# nvModern features

Everything nvModern does today, grouped by what you're trying to do. Shortcuts use Mac notation (`⌘` Command, `⇧` Shift, `⌥` Option). Items marked **preview** work but are still rough or need extra setup.

## Write

**Markdown and Org, as equals.** Both share one typography system and the same themes. Markdown syntax fades away when the cursor isn't on it. Headings fold with a click.

- **Callouts**: `> [!tip] Title`, and they nest.
- **Tables** that edit like a grid, in Markdown and Org (`⌘⌥T`). Rows, columns, alignment and cells all have palette actions you can bind to keys.
- **Footnotes** with hover previews. Unresolved ones are flagged.
- **LaTeX** math that renders in place, even inside table cells.
- **Mermaid diagrams** that render live and follow light or dark mode.
- **Code blocks** with syntax highlighting for C++, CSS, Go, HTML, Java, JavaScript and TypeScript, JSON, PHP, Python, Rust, SQL, XML, YAML, Zig and more.
- **Frontmatter** shown as a tidy property list, with tags as pills. Move the cursor in to edit the YAML.
- **Highlights** (`==text==`, `⌘⇧H`), coloured `#tags`, and `@mentions` that complete from your team list.
- **Structural lists**: `Tab` and `⇧Tab` move an item together with its children, and numbering fixes itself.
- **Task checkboxes**, and TODO-state headings in Markdown (`# [TODO] …`).
- **Text substitutions**: `->` becomes →, and you can add your own, such as `;sig` expanding to your signature.
- **Images**: paste one and it's saved into `.attachments/` and shown inline. Unused attachments are cleaned up later.
- **Unwrap**: hard-wrapped prose reads as flowing paragraphs, without changing the file.

**Org mode, without Emacs.**

- Click a TODO keyword to change its state. The states come from your file's own `#+TODO:` line.
- SCHEDULED, DEADLINE and CLOSED lines, tags and property drawers are styled.
- Checkboxes, list editing and tables work as they do in Markdown.

**Link your thinking.**

- **Wikilinks**: `[[Note]]`, `[[Note#Heading]]` and `[[Note#^block]]`, with autocomplete.
- **Block references**: press `⌘;`, then `R`.
- **Editable transclusions**: `![[Note]]` embeds another note, and edits you make inside it are saved back to that note.

**Dates.** `⌘;` is a leader key:

- `.` inserts today
- `'` inserts the date and time
- `D` opens the native date picker

**Per-document appearance.** The Document Inspector (`⌘\`) sets the theme, page width, text size and unwrap for one document. Frontmatter (`theme:`, `width:`, `font-family:`) can set the same things.

## Calculate

`calc` blocks turn a note into a live notebook. Results update as you type and are saved as readable text after `→`.

- **Exact numbers**: big integers, fractions (`1//3 + 1//6 → 1//2`) and complex numbers.
- **Units with dimension checking**: `10m/s as km/h → 36km/h`, and `1kg + 2m` is an error. SI prefixes work, as do lakh (`L`) and crore (`Cr`).
- **Symbolic maths**: `@simplify`, `@expand`, `@factor`, `@diff(x)` and `@subs(x, 2)`.
- **Functions and pipes**: `payment(p, r, n) = …`, `value |> f`, Python-style list comprehensions, and postfix steps like `@mean @round(1)`.
- **Display formats** that change only how a value looks: `as %`, `as decimal(2)`, `as Cr`, or a function you write.
- **Plots**: line, bar and scatter charts, and plots of symbolic expressions, drawn inline. You can pan them.
- **Inline values**: `{{ expr }}` anywhere in prose.
- **Discovery**: completion, hover docs and argument hints. `F1` opens a reference whose examples you can insert.
- **CSV formulas**: `{{ … }}` in a CSV cell is evaluated for each row.

## Open every file

- **CSV and TSV**: a native spreadsheet with a formula bar, row filtering, undoable row and column edits, `[[wikilinks]]` in cells, status pills and tag chips. Column metadata lives in optional frontmatter. Saving keeps the file's encoding and line endings.
- **PDF**: remembers your scroll position, has an outline, and supports annotations. nvModern never writes to your PDFs.
- **EPUB**: a reader with a table of contents and arrow-key paging. Book content runs in a locked-down sandbox.
- **Images**: PNG, JPEG, GIF, WebP, HEIC, TIFF, BMP and SVG.
- **HTML** preview.
- **Excalidraw canvases** (`.excalidraw`), edited in a native tab. Create one with New File in any folder.
- **Markdown diff**: mark one note with "Select as original", then use "Compare with selected" on another. You get a split or unified diff.
- **Arbor outlines** (`.outline`), **preview**: a block outliner. With [Racket](https://racket-lang.org) installed you also get computed blocks, Datalog queries, and actions that ask before they run.

## Find and navigate

- **The palette** (`⌘K`) finds notes. Prefixes change what it searches: `>` for commands, `/` for passages, `#` for folders.
- **Full-text search** (`⌘⇧F`) uses SQLite FTS. Use `"exact phrases"` and filters such as `ext:pdf`, plus your own facets mapped from folders. Text in PDFs is searchable, and searches keep working while the index rebuilds.
- **Fuzzy file matching** that ranks file names above folders. `a/b/c` matches those path parts in order.
- **Miller columns**: browse folders column by column from the keyboard. Details view (`⌘⌥2`) adds sortable dates and a Markdown preview column.
- **Go to heading** (`⌘⇧O`) previews as you move and returns you to where you were if you cancel. Jump to Line is there too.
- **Open a sibling** (`⌘O`) picks another file in the same folder. **Find** (`⌘F`) searches within a document.
- **The side stack**: Shift-click a link to read it beside the current note, without navigating away (`⌘⌥S` toggles it, `⌘⌥J` focuses it). The stack is saved with the tab.
- **Projects**: several workspaces, each with its own name and SF Symbol icon.
- **Recents**: in the palette and in the File menu.

## Act, at keyboard speed

- **Every command is a sentence**, subject · verb · object. `⌘K` picks a note, `Tab` lists its verbs, and a verb that needs more asks for it in the next step, such as Refile to… → pick a folder.
- **Act on search hits**: `⌘K` `/query` `Tab` lets you quote, transclude or copy a found passage into your note.
- **Batch actions**: `⌘M` turns on multi-select, `Space` marks notes, then refile them or copy their paths all at once.
- **Palette modes**: `⌘P` previews the note behind the palette, `⌘.` keeps the palette open after a command, and `⌘Return` opens in a new tab.
- **One action system behind everything**: about 90 built-in actions, reachable from menus, the palette, keybindings, plugins, the shell and MCP. You can bind any of them to a key in Settings → Shortcuts.

## Work with your AI agent

- **MCP server**: `nv3 mcp` gives Claude Code, Codex or any MCP client 27 tools, covering:
  - context and open tabs
  - search, recent notes and projects
  - reading, creating and opening notes
  - the editor selection, cursor and replace
  - jumping to headings and lines, and the side stack
  - backlinks
  - annotations
  - in-app help
- **Margin notes**: your agent can mark passages and explain them in the margin. The marks never touch your files, and they work in Markdown, Org, plain text and PDF.
- **Ask about a selection** (`⌘⇧M`): leave your agent a question on a passage, and it answers in place. Agents can export the questions and answers as Markdown or JSON.
- **Shell access**: `nv3 action <method>` drives the app from scripts, through a local socket. The socket is on by default and can be turned off.
- **Links**: `nvmodern://file/<path>?line=…&heading=…` links point into your notes. Window → Copy Link copies one.

## Make it yours

- **Ten typographic themes**:

  | Theme | Look |
  |---|---|
  | Newsprint | Editorial |
  | Laurenziana | A Renaissance reading room |
  | Riso | Two-ink risograph |
  | Cyanotype | A blueprint on a drafting grid |
  | Kunsthalle | Swiss poster |
  | Dispatch | A modern newspaper |
  | Outliner | Classic monospace Org |
  | Catppuccin | Latte by day, Mocha by night |
  | Nord | Arctic blues |
  | Mayfair | Private-bank stationery |

  Some themes look their best with fonts you install yourself; without them they fall back to system fonts.
- **Your own themes**: CSS files that use `--nv3-*` tokens and reload live. You can set a theme per file type or per document, and use any font installed on your Mac.
- **Window tint**: the toolbar takes on your page's colour, as Safari does.
- **Plugins in JavaScript**: register commands with palette entries, keybindings and system-wide hotkeys. They can open floating capture panels, editor panels or always-on-top scratchpads, use native pickers, read and write files, and declare their own settings. Settings → Plugins shows their status and any errors.
- **Example plugins**: quick capture, daily notes with templates, an Org-style capture datetree, and selection formatters. Copy them from [`NVModern/Plugins/examples/`](../NVModern/Plugins/examples/).
- **Config**: `~/.config/nvmodern/config.toml` and Settings stay in sync both ways, with undo.

## Feel at home on the Mac

- Real AppKit window tabs, each with its own state (`⌘⇧\` shows them all).
- A native sidebar, toolbar and status bar.
- Session restore: windows, tabs, scroll positions, unsaved text and side stacks come back on relaunch.
- Live sync with your sync service: edits from iCloud Drive, Dropbox, Git or another editor are picked up. Open files offer Reload or Keep Local, or reload automatically if you choose.
- Finder integration: real Finder tags, Show in Finder, Copy Path, Move to Trash, and Open in Zed.
- In-app help in a Liquid Glass drawer on macOS 26 (`F1`).
- Signed, notarized and updated automatically through Sparkle (official releases only).

## Current limitations

- Split panes are not available.
- Capture and daily notes are provided as example plugins, not built-in features.
- Backlinks are available to agents and actions, but there is no backlinks panel yet.
- nvModern runs on Apple Silicon Macs only.

[Back to the README](../README.md)
