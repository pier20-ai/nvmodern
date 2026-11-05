# nvModern search guide

This guide is for everyday nvModern users.

nvModern search is designed to let you:

- find files by fragments of name, path, or content
- narrow results with simple filters
- keep using a simple folder tree without depending on exact paths

---

## Basic search

Type into the search field at the top of a workspace tab.

Examples:

- `storefront`
- `tax planning`
- `weekly review`
- `worldpay contract`

## Quick Find and Actions palettes

Quick Find (`Cmd+K`), Actions (`Cmd+Shift+K`), and the palette's folder,
theme, and capture pickers use the same field-aware completion. The query is
split into space-separated terms; every term must match, but terms can appear
in different name or path fields.

Matches rank in predictable tiers:

- an exact field beats an exact token
- an exact token beats a token prefix
- a prefix beats a contiguous substring
- a substring beats a fuzzy subsequence within that field

Paths are separate root-to-leaf fields, so `weekly market` can match a file named
`Weekly Review.md` inside a `23-Market-Research` folder without fuzzy characters
jumping between unrelated path segments. At equal specificity, a file or
folder's leaf wins over its parent, then its grandparent. A slash query such as
`workbench/alex/crv` additionally requires those path parts in that order.

With an empty query, Quick Find keeps its categorized suggestions. Typing
switches to one flat relevance-ranked list with a 35 ms coalescing delay; fuzzy
matching and ranking run off the main actor so input stays responsive. The
empty Actions menu keeps its categories and up to three recent actions, while
a typed action query becomes one global relevance-ranked list.

### How basic search works

By default:

- multiple words are treated as an **AND** search
- word order usually does **not** matter
- matches in file names and paths are intended to rank strongly
- content matches are also included when text can be extracted

So:

```text
app tasks
```

tries to find files related to both `app` and `tasks`, whether those appear in:

- the file name
- the folder path
- the file contents

---

## Phrase search

Use quotes when you want to search for a phrase.

Examples:

```text
"storefront pack"
"data protection policy"
```

Phrase search is useful when:

- word order matters
- you remember a specific title fragment
- you want fewer broad matches

---

## Facet filters

You can narrow search using `key:value` filters.

Supported filters:

- `class:`
- `workspace:`
- `entity:`
- `asset:`
- `library:`
- `ext:`
- `root:`
- `is:`

### Common examples

#### By file type

```text
worldpay ext:pdf
```

Find PDF files related to Worldpay.

#### By class

```text
contract class:record
```

Find records related to contracts.

#### By workspace

```text
options workspace:23-market-research
```

Search only inside the `23-market-research` workspace.

#### Archived material

```text
storefront is:archived
```

Search archived Storefront material.

#### By root

```text
transcript root:50-system
```

Search only under the configured `50-system` root.

---

## Combining terms and filters

You can mix plain words and facet filters freely.

Examples:

```text
storefront pack ext:pdf
tax planning class:workspace
policy entity:21-acme-ltd-uk ext:pdf
quarterly library:42-briefs-reports
```

A good pattern is:

1. start broad
2. add one filter
3. add another only if needed

---

## Good search habits

### 1. Start with fragments, not perfect titles
Instead of trying to remember an exact file name, try:

```text
weekly march trading
```

instead of:

```text
2026-03-weekly-trading-review.md
```

### 2. Add `ext:` early when you know the file type
If you know it was a PDF or markdown file, add that immediately.

Examples:

```text
signed nda ext:pdf
meeting notes ext:md
```

### 3. Use `class:` when you know what kind of thing it is
Examples:

```text
class:record invoice
class:library broadcom
class:asset logo
```

### 4. Use quotes for memorable titles
Examples:

```text
"Trading Literature"
"Options Book"
```

---

## What the filters mean

The exact available values depend on how your nvModern project is configured.

### `class:`
The broad kind of item.

Typical values:

- `workspace`
- `record`
- `asset`
- `library`
- `system`
- `archive`

### `workspace:`
A configured active-work bucket.

Examples:

- `21-storefront`
- `23-market-research`
- `app`
- `research`

### `entity:`
A configured records/entity bucket.

Examples:

- `21-acme-ltd-uk`
- `acme-inc`

### `asset:`
A configured asset bucket.

Examples:

- `31-brand-media`
- `templates`

### `library:`
A configured library bucket.

Examples:

- `42-briefs-reports`
- `books`

### `ext:`
The file extension, without the dot.

Examples:

- `pdf`
- `md`
- `docx`
- `csv`

### `root:`
A configured top-level root label.

Examples:

- `10-workspaces`
- `20-records`
- `reference`

### `is:`
Special state filters.

Current common value:

- `archived`

---

## Example searches

### Find a PDF about tax planning

```text
tax planning ext:pdf
```

### Find active market research notes

```text
options workspace:23-market-research class:workspace
```

### Find archived Storefront files

```text
storefront is:archived
```

### Find a specific known phrase

```text
"data protection policy"
```

### Find a book or report

```text
broadcom class:library
```

### Find a template asset

```text
nda template class:asset
```

---

## What search can see

nvModern indexes and searches:

- file names
- relative paths
- plain text files
- many Markdown notes
- PDFs where text extraction is available
- some document formats where text extraction is available

Search quality is best for:

- Markdown
- text files
- PDFs with extractable text

Search may be weaker for:

- scanned PDFs without usable text
- binary file formats
- images without text extraction

---

## How the index is built and kept fresh

The index lives in a SQLite/FTS database under
`~/Library/Caches/nvmodern/<hash of root>/search-v2.sqlite`, written by
`SearchIndexStore` and driven by `NoteSearchEngine`.

**Batched, resumable rebuilds.** A full rebuild walks documents in `rel_path`
order and commits every 200 of them in its own transaction, recording the last
committed path in `index_meta` (`rebuild_cursor_path` plus the facet-map
fingerprint it belongs to). If a rebuild is interrupted — quitting, a superseding
request, a cancelled task — the next one resumes after the cursor instead of
re-extracting everything. `facet_map_fingerprint`, the marker that makes the
index count as usable, is written only when the final batch lands, so a partial
index never reports itself as complete. Changing `search_facets` in config
invalidates every extracted record, so it drops the cursor and starts over.

**Coalescing, not cancelling.** Every tree scan asks the engine to update the
index, and scans are frequent (window reloads, and every filesystem batch). A
request that arrives while a pass is running for the same root and the same facet
map no longer cancels it: it is folded into a single follow-up reconcile that
runs once the pass finishes. Only a facet-map change, a different root, or an
explicit full rebuild cancels work in flight. A reconcile skips documents whose
size and mtime are unchanged, so the follow-up is usually close to free.

**Self-writes are not reindexing events.** When a filesystem batch contains only
paths nvModern itself just saved, it can never trigger a rebuild — at most it
upserts exactly those paths, and a save that produced identical bytes is skipped
after a content-hash comparison.

**Searches never wait for the writer.** The search path opens the database
without running schema DDL or metadata writes and sets `busy_timeout` before any
statement, so a rebuild holding the write lock cannot turn a search into an
error. Searches issued during a rebuild answer from the batches already
committed, and the palette's empty state says how far along the rebuild is
("Indexing 340 of 1,200 notes…").

---

## If a search feels too broad

Try one or more of these:

- add another word
- add `ext:pdf` or `ext:md`
- add `class:...`
- add `workspace:...` or `entity:...`
- use quotes

Example:

Too broad:

```text
contract
```

Better:

```text
worldpay contract class:record ext:pdf
```

---

## If a search finds nothing

Try:

- removing quotes
- removing one filter
- using fewer words
- using shorter fragments
- checking whether the expected file type is correct

Example:

Too narrow:

```text
"storefront outbound pricing pack" ext:pdf class:record
```

Try instead:

```text
storefront pricing pack
```

or:

```text
storefront pack ext:pdf
```

---

## Summary

The simplest mental model is:

- type a few remembered words
- add filters only when needed
- use quotes for exact phrases
- use `ext:` and `class:` often

Search is meant to complement the folder tree, not replace it.

The tree gives files a stable home.
Search helps you find them from partial memory.
