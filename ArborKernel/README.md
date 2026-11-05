# Arbor kernel

The Arbor kernel is a persistent Racket process with a versioned JSON-lines protocol. It parses `#lang arbor/0` documents as data and evaluates only a small pure expression grammar. It does not load the document as a Racket module, call `eval`, expose `require`, or provide filesystem, process, environment, or network primitives.

## Protocol

One request and one response occupy one line each. The current protocol identifier is `arbor-kernel/1`.

```json
{"protocol":"arbor-kernel/1","id":"req-7","op":"evaluate","document":{"path":"Demo.outline","revision":7,"source":"#lang arbor/0\n- = (+ 40 2) ^answer\n"},"previousDerivedUIDs":[]}
{"protocol":"arbor-kernel/1","id":"req-7","ok":true,"revision":7,"document":{"path":"Demo.outline"},"blocks":[{"uid":"answer","depth":0,"body":"= (+ 40 2)","line":2,"parentUID":null}],"patches":[{"op":"set-derived","uid":"answer","revision":7,"value":42,"display":"42"}],"queries":[],"diagnostics":[]}
```

Computed blocks begin with `=` and use allowlisted s-expressions. The MVP supports numeric arithmetic and comparison, booleans, `if`, `and`, `or`, string concatenation and length, and `(ref "uid")` references to earlier computed blocks.

## Facts and queries

`document/replace` compiles an accepted document into these engine-neutral facts:

```text
block-page(block, page)
block-parent(block, parent)
block-order(block, order)
block-text(block, text)
block-tag(block, tag)
block-attribute(block, key, value)
block-link-page(block, page)
block-ref-block(block, target)
```

The kernel builds a candidate Datalog theory and swaps it into the accepted world only after parsing, query validation, collision checks, and theory construction succeed. Revisions increase per document. Replaying identical source at the same revision is idempotent; different source at that revision conflicts. `worldRevision` increases whenever an accepted document changes because a query may read facts from other documents.

```json
{"protocol":"arbor-kernel/1","id":"replace-7","op":"document/replace","document":{"id":"demo","path":"Demo","revision":7,"source":"#lang arbor/0\n- Tagged #project ^tagged\n- {{query: (find (?block) (in ?tag) (where (block-tag ?block ?tag)))}} ^projects\n"}}
{"protocol":"arbor-kernel/1","id":"replace-7","op":"document/replace","ok":true,"outcome":"replaced","document":{"id":"demo","path":"Demo"},"revision":7,"worldRevision":1,"factCount":7,"queryIDs":["projects"],"diagnostics":[]}
```

Query declarations use a small data grammar rather than Racket or Datalog source. Result variables belong in `find`, scalar arguments belong in `in`, and `where` accepts only the canonical predicates above plus recursive `block-ancestor`.

```text
{{query: (find (?block) (in ?tag) (where (block-tag ?block ?tag)))}}
{{query: (find (?ancestor) (in ?block) (where (block-ancestor ?block ?ancestor)))}}
```

A direct child attribute supplies a default input, and an optional projection
formats each row as Markdown:

```text
- {{query: (find (?block ?text) (in ?tag)
             (where (block-tag ?block ?tag) (block-text ?block ?text))
             (project "{text}"))}} ^projects
  - tag:: project ^projects-tag
```

Explicit arguments override defaults. A row with one block-valued origin can
materialize as a source-backed result; `intent/apply` validates edits to that
result and returns a candidate document replacement for the trusted host to
compare, write, and reindex.

Clients run a declaration by document revision and stable query block ID:

```json
{"protocol":"arbor-kernel/1","id":"query-7","op":"query/run","documentID":"demo","revision":7,"queryID":"projects","arguments":{"tag":"project"}}
{"protocol":"arbor-kernel/1","id":"query-7","op":"query/run","ok":true,"revision":7,"worldRevision":1,"queryID":"projects","columns":["block"],"rows":[["tagged"]],"diagnostics":[]}
```

Rows are sorted deterministically. The response intentionally omits proof provenance because the stock Racket Datalog engine does not expose recursive derivations; Build 1 does not infer provenance from result strings.

## Effects

Effect producers are explicit and inert until `producer/run`:

```text
! (clock/now)
! (fs/read "Data/report.md")
! (process/run "rg" "TODO" ".")
! (action/run "app.health.ping")
! (model/complete "Summarize this block")
```

Arguments are JSON-shaped data. `$name` resolves a direct child `name:: value`
attribute or an explicit run argument; `(list ...)` and
`(record ("key" value) ...)` construct inert values. The kernel validates the
allowlisted declaration and returns a plan with a timeout, output bound, and
capability. It never performs the operating-system operation.

The host implements clock, workspace filesystem, process, HTTP, clipboard,
notification, curated native action, and configured model handlers. It prompts
before guarded operations, may tighten the plan's limits, and returns a typed
value through `effect/complete`. A top-level list creates one result block per
item; the kernel formats all other values. Denial, cancellation, and failure
leave prior output intact.

## Outline transactions

An effect may ask the kernel to build one candidate source revision:

```text
! (outline/insert-child (self) "Generated")
! (outline/add-tag (query "todos") "done")
! (outline/transact
    (set-text (block "title") "Renamed")
    (move (block "task") (block "archive")))
```

The supported operations are `insert-child`, `insert-after`, `set-text`,
`add-tag`, `move`, and `delete`. Targets are `(self)`, `(block "uid")`, or a
same-document `(query "query-uid")`. The kernel applies at most 100 expanded
operations to a candidate, recompiles it after every step, and returns an exact
preview plus the expected old source. It does not write the file.

The trusted host always previews the change, rejects stale disk source, persists
the candidate, replaces the kernel document, and acknowledges it through
`mutation/complete`. The renderer then installs that accepted source as one
undoable edit. Inserted output carries stable producer metadata, so Run refreshes
it and Run as New preserves the previous generation.

The kernel enforces source, block, expression-node, and expression-depth limits. Invalid syntax and disallowed operators become diagnostics. The native supervisor also imposes a wall-clock timeout and restarts a crashed or timed-out child before the next request.

## Baseline

`benchmarks/fact-compiler.rkt` measures fact compilation and construction of the stock Datalog theory. A local single-process run on 2026-08-12 produced:

| Blocks | Facts | Source bytes | Compile | Theory build |
|---:|---:|---:|---:|---:|
| 10,000 | 30,000 | 197,794 | 73 ms | 91 ms |
| 100,000 | 300,000 | 2,177,794 | 678 ms | 863 ms |

These are development baselines, not latency targets. The benchmark accepts a block count from 1 through 100,000 when the baseline needs to be refreshed on the target machine.
