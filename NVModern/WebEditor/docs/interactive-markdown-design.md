# Interactive Markdown Design (nvModern)

_Last updated: 2026-03-05_

This document proposes an **interactive markdown** system for nvModern: executable code blocks + structured outputs + inline interpolation, with host-side execution through the existing bridge.

The target is a simpler notebook model (Jupyter-lite) suitable for:

- org-agenda-like personal planning dashboards
- campaign status reports
- financial KPI monitoring
- basic CRM rollups

---

## 1) Goals and constraints

## Goals

1. Keep markdown as the source-of-truth text model.
2. Execute code in fenced blocks and render rich output inline.
3. Support the 3 required runtimes:
   - **JavaScript** (Bun runtime)
   - **Python**
   - **DuckDB SQL**
4. Provide interpolation from computed values into surrounding markdown text.
5. Reuse existing architecture:
   - CM6 plugin slots (`codeExecution` in `src/lib/index.ts`)
   - web↔host request bridge (`src/bridge.ts`, Swift request handling)
   - shared markdown scanner/index pipeline.

## Non-goals (v1)

- Full notebook document format replacement.
- Arbitrary browser DOM injection by default.
- Unrestricted host access from executed code.

## Constraints to preserve

- no layout jank while editing
- graceful fallback to raw markdown text
- strict execution timeouts / cancellation
- clear trust and permission boundaries

---

## 2) Fenced code syntax

Per product requirement, execution marker is suffix `run` in info string:

````md
```js run
const x = 1 + 1
display.markdown(`x=${x}`)
```
````

````md
```python run
print("Hello")
```
````

````md
```sql run
select * from read_csv_auto('marketing/spend.csv')
```
````

### Why this keeps highlighting working

Existing code-language detection in `src/lib/index.ts` takes the first token in fence info (`js`, `python`, `sql`) before whitespace. So `js run` still highlights as JS, etc.

### Optional metadata

Allow lightweight metadata in the info string:

````md
```js run id=kpis cache=10m
...
```
````

````md
```sql run id=campaign-summary readonly=true
...
```
````

- `id` enables stable references/interpolation
- `cache` enables result reuse
- runtime-specific flags can be added later

---

## 3) Architecture fit in current codebase

## 3.1 Editor/plugin side

Add a new plugin in `codeExecution` slot (currently placeholder):

- parse executable blocks from markdown scan index
- render output widgets under blocks
- keep source text editable
- support rerun controls / error display / loading states

Recommended files:

- `src/lib/plugins/interactiveBlocks.ts` (new)
- `src/lib/plugins/interactiveRuntimeState.ts` (new state field for results)

Also extend shared markdown scanner (`markdownScanner.ts`) to expose executable fence occurrences:

- runtime language (`js`/`python`/`sql`)
- `run` flag
- block range + block id + metadata

## 3.2 Bridge side

Current bridge already supports async request/response envelopes (`method`, `params`, `requestId`), so add methods:

- `interactive.execute`
- `interactive.cancel`
- `interactive.resolveData` (optional later)

Swift host request handler in `WorkspaceView.handleEditorRequest(...)` should route these methods to runtime executors.

## 3.3 Execution semantics (detailed)

Interactive execution must feel predictable. Recommended semantics:

### Default behavior

- **Default mode = manual** for all `run` blocks.
- Opening a document does **not** execute blocks automatically unless explicitly configured.
- Each block shows its state badge: `idle`, `stale`, `queued`, `running`, `ok`, `error`, `canceled`.

### Execution trigger matrix

1. **On document open**
   - if block has no prior result cache: state `idle`
   - if cached result exists and valid: show cached output + `stale=false`
   - if block has `auto` flag (or document-level autorun enabled): enqueue run

2. **On text edits**
   - editing inside a block marks that block `stale`
   - editing outside block marks interpolation refs stale only if they depend on changed block ids
   - no immediate rerun in manual mode

3. **On save**
   - if execution policy is `on-save`, rerun stale auto blocks

4. **Manual actions**
   - `Run block` runs one block immediately
   - `Run all` runs all stale blocks (top-to-bottom)
   - `Cancel` aborts running block
   - `Refresh data` invalidates data-source caches + reruns stale blocks

5. **Dependency changes (notes/csv/web data)**
   - v1: explicit refresh/manual rerun
   - v2: optional watchers (file mtimes, polling hooks, webhook signals)

### Auto vs manual controls

Use layered policy controls:

- Workspace setting:
  - `manual` (default)
  - `on-save`
  - `auto-visible` (run visible blocks with debounce)
- Document frontmatter override (optional):
  - `interactive.runPolicy = manual|on-save|auto-visible`
- Per-block override in fence metadata:
  - `run auto`
  - `run manual`

### Scheduling and concurrency

- Concurrency cap (e.g. 2 workers) across all runtimes.
- Same block id cannot run concurrently; newest request supersedes previous.
- Preserve output stability: keep previous output visible while rerunning (with loading overlay).
- `Run all` executes in source order unless explicit dependencies are declared.

### Dependency + rerun model

Allow optional per-block metadata:

- `id=<block-id>`
- `depends=<id1,id2,...>`

Rules:

- running block B with `depends=A` requires latest successful A result
- if A changes, B becomes `stale(dep)`
- interpolation `{{cell:A.x}}` also marks consumers stale when A updates

### Caching semantics

Cache key (host-side):

- workspace root
- file path
- block id (or positional fallback)
- runtime
- normalized code hash
- dependency result hashes
- declared external input fingerprints (optional)

Cache policy:

- default: in-memory + optional persisted cache per workspace
- optional TTL via metadata: `cache=10m`
- stale cache can still render while rerun is in progress

### Failure semantics

- Runtime error does not clear previous successful output by default;
  show error panel with option to reveal stack.
- Parse failures degrade to plain fenced code behavior.
- Bridge timeout/cancellation marks block `canceled` and keeps prior output.

---

## 4) Runtime model (host side)

## 4.1 JavaScript runtime: Bun (required)

Use Bun worker/process execution with strict capability injection.

Suggested host API exposed to JS user code:

- `notes.query(...)` / `notes.read(...)`
- `csv.read(path)`
- `http.fetch(url, options)` (policy-limited)
- `display.*` component emitters
- `cell(name, value)` for interpolation values

Execution guardrails:

- timeout (e.g., 5–15s default)
- memory cap
- cancellation via AbortSignal
- no arbitrary shell/fs unless explicitly permitted

## 4.2 Python runtime

Use isolated Python process (venv-managed). Similar capability model via a thin helper module, e.g. `nvmodern_runtime`:

- `notes_query(...)`
- `csv_read(...)`
- `http_fetch(...)`
- `display_*` helpers
- `cell(...)`

Guardrails mirror JS: timeout, cancel, memory/process limits.

## 4.3 DuckDB SQL runtime

For `sql run`:

- execute in DuckDB connection managed by host
- provide safe table functions for notes/csv views
- return tabular outputs efficiently

Recommended v1 stance:

- read-only SQL by default
- whitelist IO paths
- no arbitrary extension loading

## 4.4 High-level API surface for JS/Python (to avoid repetitive code)

Documents should not need to reimplement joins/grouping/agenda logic repeatedly.
Provide a high-level API layer with **JS/Python parity**.

### API design principles

1. Same conceptual namespaces in JS and Python.
2. Safe defaults and typed returns.
3. Helpers should produce component-ready structures.
4. Low-level escapes still available for advanced users.

### Suggested namespaces

#### `nv.notes`

- `nv.notes.query(filters)`
- `nv.notes.tasks(filters)`
- `nv.notes.frontmatter(filters)`
- `nv.notes.links(filters)`

Common filters:

- `pathPrefix`, `tags`, `status`, `assignee`, `dueFrom`, `dueTo`, `text`, `limit`

#### `nv.csv`

- `nv.csv.read(path, options?)`
- `nv.csv.union(paths)`
- `nv.csv.schema(path)`

#### `nv.web`

- `nv.web.fetchJson(url, options?)`
- `nv.web.fetchCsv(url, options?)`
- `nv.web.fetchText(url, options?)`

All with domain allowlist + timeout defaults.

#### `nv.sql`

- `nv.sql.query(sql, params?)`
- `nv.sql.register(name, rowsOrTable)`
- `nv.sql.readCsv(path)`

This makes DuckDB querying available even from JS/Python blocks.

#### `nv.frame` (dataframe-like utilities)

- `nv.frame.groupBy(rows, keys, aggs)`
- `nv.frame.join(left, right, keys, kind?)`
- `nv.frame.sort(rows, by)`
- `nv.frame.window(rows, spec)`

#### `nv.agenda` (org-agenda-like)

- `nv.agenda.build({ window, includeScheduled, includeDeadline, groupBy })`
- `nv.agenda.toTimeline(items)`
- `nv.agenda.summary(items)`

#### `nv.crm`

- `nv.crm.pipeline({ pathPrefix })`
- `nv.crm.followups({ dueWithin })`
- `nv.crm.accountHealth({ pathPrefix })`

#### `nv.finance`

- `nv.finance.kpis({ revenue, cost, cash, targets })`
- `nv.finance.periodCompare({ current, previous })`
- `nv.finance.burn({ cash, expenses })`

#### `nv.marketing`

- `nv.marketing.campaignReport({ spendCsv, perfCsv, groupBy })`
- `nv.marketing.funnel({ events, stages })`
- `nv.marketing.attribution({ touches, conversions })`

### Display/output API

Provide a single `display` namespace for structured output:

- `display.markdown(text)`
- `display.table(rows, options?)`
- `display.metricCard(metric)`
- `display.metricGrid(metrics)`
- `display.chartLine(data, options?)`
- `display.chartBar(data, options?)`
- `display.chartArea(data, options?)`
- `display.agendaList(items, options?)`
- `display.statusBoard(columns, options?)`
- `display.timeline(events, options?)`
- `display.funnel(stages, options?)`
- `display.alert({ level, title, message })`
- `cell(name, value)` for interpolation bindings

### JS + Python parity sketch

JS:

```js
const tasks = await nv.agenda.build({ window: "7d", groupBy: "day" })
display.agendaList(tasks)
cell("due_today", tasks.summary.dueToday)
```

Python:

```python
tasks = nv.agenda.build(window="7d", group_by="day")
display.agenda_list(tasks)
cell("due_today", tasks.summary["dueToday"])
```

(Allow snake_case aliases in Python, but keep capability parity.)

---

## 5) Result protocol (typed output contract)

Use a structured result envelope from host -> web plugin:

```ts
interface InteractiveExecuteResult {
  status: "ok" | "error";
  runtime: "js" | "python" | "duckdb-sql";
  blockId: string;
  startedAt: string;
  finishedAt: string;
  durationMs: number;
  outputs: InteractiveOutput[];
  cells: Record<string, InteractiveCellValue>;
  logs: Array<{ level: "info" | "warn" | "error"; text: string }>;
  error?: {
    message: string;
    stack?: string;
    line?: number;
    column?: number;
  };
}
```

`outputs` should be component-oriented, not arbitrary DOM.

---

## 6) Rendering component model (important for product usefulness)

Table/chart/markdown is a good start, but insufficient for your target workflows.

## 6.1 Core v1 components

1. `markdown`
2. `table`
3. `chart.line`
4. `chart.bar`
5. `chart.area`
6. `metric.card` (single KPI)
7. `metric.grid` (multiple KPI cards)
8. `alert` (success/warn/error/info)
9. `json` (tree/expandable)
10. `text.pre` (logs/raw)

## 6.2 High-value workflow components (v1.5 / v2)

11. `agenda.list` (org-agenda-like task/day grouping)
12. `status.board` (kanban-like groups by status)
13. `timeline` (time-ordered milestones/events)
14. `funnel` (campaign/opportunity stage conversion)
15. `progress` (goal vs actual bars)
16. `record.list` (CRM/account/contact summaries)
17. `delta.badge` (period-over-period change)
18. `sparkline` (tiny inline trend)

These components make campaign, finance, planning, and CRM dashboards much easier to express with little code.

---

## 7) Interpolation model for markdown text

Need simple, stable references from block outputs into prose.

## 7.1 Proposed syntax

```md
MRR this month: {{cell:finance.mrr | currency}}
Open deals: {{cell:crm.open_deals}}
Top campaign CTR: {{cell:campaign.best_ctr | percent(1)}}
```

Where `finance`, `crm`, `campaign` are block ids (or block namespaces), and cell names come from runtime `cell(name, value)` API.

## 7.2 Rules

- interpolation resolves against latest successful execution for referenced block
- unresolved refs render fallback (`—`) + subtle warning styling
- values are typed (number/string/date/bool) with lightweight formatters
- source markdown remains unchanged; interpolation is a view-layer decoration

---

## 8) Example applications

## 8.1 org-agenda-like dashboard

````md
## Today

```js run id=agenda-today
const tasks = await notes.query({
  tags: ["todo"],
  dueBefore: "today+7d"
})

display.agendaList(tasks)
cell("due_today", tasks.filter(t => t.due === "today").length)
```

Tasks due today: {{cell:agenda-today.due_today}}
````

## 8.2 Campaign status report

````md
```sql run id=campaign-kpis
with spend as (
  select campaign, sum(cost) as spend
  from read_csv_auto('marketing/spend.csv')
  group by 1
), perf as (
  select campaign, sum(clicks) as clicks, sum(conv) as conv
  from read_csv_auto('marketing/perf.csv')
  group by 1
)
select
  p.campaign,
  s.spend,
  p.clicks,
  p.conv,
  p.conv / nullif(p.clicks, 0) as cvr
from perf p
join spend s using (campaign)
order by spend desc;
```
````

Render:
- table of campaigns
- funnel per campaign
- metric cards: total spend, total conv, weighted CVR
- markdown summary block generated from top movers

## 8.3 Financial metrics

````md
```python run id=finance
import pandas as pd

rev = csv_read("finance/revenue.csv")
cost = csv_read("finance/costs.csv")

df = rev.merge(cost, on="month")
df["margin"] = df["revenue"] - df["cost"]

display_metric_grid([
  {"label": "Revenue", "value": float(df.iloc[-1]["revenue"])},
  {"label": "Margin", "value": float(df.iloc[-1]["margin"])},
])
display_line_chart(df[["month", "revenue", "cost", "margin"]])
cell("margin", float(df.iloc[-1]["margin"]))
```

Latest margin: {{cell:finance.margin | currency}}
````

## 8.4 Basic CRM rollup

````md
```js run id=crm
const deals = await notes.query({ folder: "crm/deals" })
const grouped = groupBy(deals, d => d.stage)

display.statusBoard(grouped)
display.table(deals.map(d => ({
  account: d.account,
  owner: d.owner,
  stage: d.stage,
  amount: d.amount,
  next_step: d.nextStep,
})))

cell("open_deals", deals.filter(d => d.stage !== "closed_won" && d.stage !== "closed_lost").length)
```

Open deals: {{cell:crm.open_deals}}
````

---

## 9) Security and trust model

Interactive execution should be **workspace-trust-gated**.

Suggested policy levels:

1. `disabled` – no execution
2. `trusted-local` – notes/csv only
3. `trusted-web` – notes/csv + outbound HTTP (domain policy)
4. `advanced` – explicit opt-in for broader capabilities

Also add per-file execution toggle and visible runtime badge.

---

## 10) Suggested phased plan

## Phase 1 (ship quickly)

- scanner support for executable fences (`<lang> run`)
- JS (Bun) runtime only
- components: markdown/table/metric.card/metric.grid/chart.line/alert
- interpolation cells (`{{cell:block.key}}`)
- bridge methods: `interactive.execute`, `interactive.cancel`

## Phase 2

- add DuckDB SQL runtime
- add Python runtime
- add `agenda.list`, `status.board`, `timeline`, `funnel`

## Phase 3

- caching policy + dependency graph reruns
- richer formatting/interpolation pipeline
- optional MDX-like authoring layer for advanced interactive pages

---

## 11) Open questions

1. Should results persist in file metadata/cache, or be fully ephemeral?
2. Should execution auto-run on open, or manual by default?
3. Should block dependencies be explicit (`dependsOn=`) or inferred from interpolation refs?
4. Do we want reproducibility snapshot mode (pin data + output)?

---

## 12) Implementation pointers in current repo

- Editor slots / wiring: `src/lib/index.ts`
- Shared markdown index: `plugins/markdownScanner.ts`, `plugins/markdownIndex.ts`
- Bridge client: `src/bridge.ts`
- Host request routing: `NVModern/UI/WorkspaceView.swift` (`handleEditorRequest`)
- Web embedding + protocol envelope: `NVModern/UI/Web/EditorWebView.swift`

This is enough to begin Phase 1 without major architectural changes.
