# NV3 Editor API Reference

This document is the full API and integration guide for the internal `@nv3/editor` library.

---

## 1) Package entrypoint

```ts
import {
  createNv3EditorState,
  createNv3EditorExtensions,
  createNv3EditorRuntime,
  reconfigureNv3Language,
  reconfigureNv3Slot,
} from "@nv3/editor";
```

Root re-export: `index.ts` → `src/lib/index.ts`.

---

## 2) Core editor factory APIs

### `createNv3EditorExtensions(options?)`

Builds a full `Extension[]` stack for CodeMirror.

```ts
const extensions = createNv3EditorExtensions({ filePath: "notes/today.md" });
```

### `createNv3EditorState(options?)`

Builds `EditorState` with all configured NV3 extensions.

```ts
const state = createNv3EditorState({
  doc: "# Notes",
  filePath: "notes/today.md",
});
```

### Markdown-only convenience

- `createNv3MarkdownExtensions(options?)`
- `createNv3MarkdownState(options?)`

These force `fileType: "markdown"`.

---

## 3) Options (`Nv3EditorExtensionsOptions`)

| Option | Type | Purpose |
|---|---|---|
| `filePath` | `string` | Current file path (used by filetype detection + resolver context) |
| `fileType` | `"markdown" \| "org" \| "plain"` | Override language mode |
| `onDocChange` | `(doc: string) => void` | Doc change callback |
| `onTagsChange` | `(index: Nv3TagIndex) => void` | Markdown tag index callback |
| `onFrontmatterChange` | `(result: Nv3FrontmatterResult) => void` | Frontmatter parse/validation callback |
| `onLatexChange` | `(index: Nv3LatexIndex) => void` | LaTeX fragment index callback |
| `latexPreviewMode` | `"none" \| "katex"` | LaTeX visual mode |
| `onCodeBlocksChange` | `(index: Nv3CodeBlockIndex) => void` | Code fence index callback |
| `onLinksChange` | `(index: Nv3LinkIndex) => void` | Wikilink/transclusion/preview index callback |
| `onOrgParseChange` | `(result: Nv3OrgParseResult) => void` | Org structural parse result callback |
| `onWikilinkOpen` | `(input: Nv3WikilinkOpenInput) => void` | Click handler for `[[...]]` links |
| `onInlineLinkOpen` | `(input: Nv3InlineLinkOpenInput) => void` | Click handler for markdown inline links |
| `resolveWikilinkHref` | `(input: Nv3WikilinkHrefInput) => string` | Compute link `href` for wikilink anchors |
| `resolveTransclusion` | `(input) => Promise<Nv3TransclusionResolved \| null>` | Fetch transclusion content |
| `saveTransclusion` | `(input) => Promise<void>` | Persist edited transclusion content |
| `maxTransclusionDepth` | `number` | Nested transclusion depth cap |
| `createNestedTransclusionState` | `(input) => EditorState` | Override nested transclusion editor state creation |
| `frontmatterSchema` | `Nv3FrontmatterSchema` | Zod schema for frontmatter validation |
| `autocompleteProviders` | `readonly Nv3AutocompleteProvider[]` | Typed provider list |
| `autocompleteActivateOnTypingDelay` | `number` | Typing debounce for autocomplete activation |
| `onAutocompleteError` | `(error: Nv3AutocompleteError) => void` | Provider error callback |
| `pluginSlots` | `Nv3PluginSlotExtensions` | Inject extra extensions per slot |
| `extraExtensions` | `Extension[]` | Extra extensions appended at end |
| `runtime` | `Nv3EditorRuntime` | Reusable runtime compartments for live reconfigure |
| `minimalPlugins` | `boolean` | Disable markdown plugin stack (used for nested transclusion state) |

Also available on state factory:

| Option | Type |
|---|---|
| `doc` | `string` |

---

## 4) Runtime + live reconfiguration

### `createNv3EditorRuntime()`

Creates compartment bundle:

- `language` compartment
- slot compartments: `conceal`, `tags`, `frontmatter`, `latex`, `codeBlocks`, `transclusion`, `tables`, `codeExecution`

### `reconfigureNv3Language(view, runtime, fileType)`

Live swap language compartment.

### `reconfigureNv3Slot(view, runtime, slot, extensions)`

Live replace a specific slot with a new extension set.

---

## 5) File type helpers

### `detectNv3FileType(filePath)`

Returns:

- `"markdown"` for `.md`, `.markdown`, `.mdown`, `.mkd`
- `"org"` for `.org`
- `"plain"` otherwise

> Note: Org mode now includes a structural parser/index extension. Rendering and interaction plugins are still in progress.

---

## 6) Plugin extension factories (direct use)

You can use plugin factories directly if you compose your own extension stack:

- `createMarkdownCodeFenceExtension`
- `createNv3AutocompleteExtension`
- `createNv3MarkdownScanExtension` (shared markdown scanner/index state)
- `createMarkdownFrontmatterExtension`
- `createMarkdownLatexExtension`
- `createMarkdownLinkExtension`
- `createMarkdownTransclusionExtension`
- `createMarkdownListMarkerExtension`
- `createMarkdownMarksHidingExtension`
- `createMarkdownMentionExtension`
- `createMarkdownTaskCheckboxExtension`
- `createMarkdownTagExtension`
- `createNv3OrgParserExtension`

Theme exports:

- `nv3NotionEditorTheme`
- `nv3MarkdownHighlightStyle`

---

## 7) Utility/scanner APIs

Pure helpers exported for indexing or tests:

- `parseMarkdownFrontmatter(docText, schema?)`
- `extractFrontmatter(docText)`
- `validateFrontmatter(parsed, schema, keyLocations?)`
- `scanMarkdownLatex(docText)`
- `scanMarkdownDocument(doc)`
- `scanMarkdownText(docText)`
- `getNv3MarkdownScanIndex(state)`
- `detectStandaloneTransclusions(docText)`
- `detectMarkdownTaskCheckboxes(docText)`
- `parseOrgDocument(docText)`
- `parseOrgText(doc)`
- `getNv3OrgParseResult(state)`

Default schema export:

- `defaultNv3FrontmatterSchema`

---

## 8) React adapter guidance (high-performance)

The library core is framework-agnostic and does **not** ship a React component today.

Expected pattern (same approach used by the shell):

- Mount `EditorView` imperatively in `useEffect`
- Recreate when file identity changes
- Destroy on unmount
- Avoid controlled React value on every keystroke
- Use `onDocChange` + throttled persistence/autosave

### Minimal adapter example

```tsx
import { useEffect, useRef } from "react";
import { EditorView } from "@codemirror/view";
import { createNv3EditorState } from "@nv3/editor";

export function Nv3Editor({ doc, filePath, onDocChange }: {
  doc: string;
  filePath?: string;
  onDocChange?: (next: string) => void;
}) {
  const mountRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);

  useEffect(() => {
    if (!mountRef.current) return;

    const state = createNv3EditorState({ doc, filePath, onDocChange });
    const view = new EditorView({ state, parent: mountRef.current });
    viewRef.current = view;

    return () => {
      view.destroy();
      viewRef.current = null;
    };
  }, [doc, filePath, onDocChange]);

  return <div ref={mountRef} />;
}
```

---

## 9) Styling contract

### What the library provides

1. **CodeMirror theme extension** (`nv3NotionEditorTheme`) and markdown highlight style.
2. **CSS class hooks** used by plugin decorations/widgets.
3. **Opinionated default stylesheet**: `shell/styles/editor.lib.css`.

Consumers are expected to copy `editor.lib.css` as-is and keep it in sync with editor updates.

### What consumers must include

- Include KaTeX CSS (already imported in `editor.lib.css`)
- Include all `.nv3-*` and `.cm-editor` styles from `editor.lib.css`
- Ensure the theme tokens below exist (or keep the defaults in `editor.lib.css`)

### Core CSS variables

`editor.lib.css` defines defaults for:

- Colors/backgrounds: `--bg`, `--bg-secondary`, `--bg-hover`, `--bg-active`
- Text: `--text`, `--text-secondary`, `--text-tertiary`
- Borders: `--border`, `--border-heavy`
- Accent/state: `--accent`, `--selection`, `--red`, `--yellow`, etc.
- Typography: `--font-sans`, `--font-display`, `--font-mono`
- Syntax tokens: `--cm-keyword`, `--cm-string`, `--cm-number`, `--cm-atom`, `--cm-function`, `--cm-type`
- Misc: `--wikilink-underline`, `--radius`, heading-tag hue variables

### Shell-only styles

`editor.shell.css` is only for the demo app chrome (`.app`, sidebar, inspector, toolbar, etc.).
Do not treat it as part of the library styling contract.

---

## 10) Resolver contracts

### Wikilinks

### `resolveWikilinkHref(input)`

Called while rendering `[[target]]` links.

`input`:

- `target: string`
- `occurrence: Nv3LinkOccurrence`
- `filePath?: string`

Returns `href: string` for anchor rendering.

### `onWikilinkOpen(input)`

Called on click.

`input` includes `target`, resolved `href`, `occurrence`, native `event`, and `view`.

---

### Inline links (`[label](url)`)

### `onInlineLinkOpen(input)`

Called when the inline-link open affordance (`↗`) is clicked.

`input` includes:

- `href`
- `label`
- `from` / `to`
- `event`
- `view`

If not provided, default behavior opens `window.open(href, "_blank", "noopener,noreferrer")`.

---

### Transclusion (`![[target]]`, standalone lines)

### `resolveTransclusion(input)`

`input`:

- `target: string`
- `filePath?: string`
- `depth: number`
- `signal: AbortSignal`
- `requestKind: "transclusion.resolve"`

Return:

- `null` → unresolved/missing
- `{ content, kind?, filePath? }` → resolved document

### `saveTransclusion(input)`

`input`:

- `target: string`
- `filePath?: string`
- `depth: number`
- `content: string`
- `signal: AbortSignal`
- `requestKind: "transclusion.save"`

Semantics:

- Save is debounced inside widget
- Abort signals should be honored
- Nested editor depth is bounded by `maxTransclusionDepth`

---

### Autocomplete providers

Provider interface (`Nv3AutocompleteProvider`):

- `source: string`
- `trigger: string` (e.g. `[[`, `@`)
- `query(input)` async/sync item source
- optional `mapItem`
- optional custom `match`

Query input includes `signal` for cancellation.

Error path is reported through `onAutocompleteError`.

---

## 11) Supported features (v1 internal scope)

| Area | Status | Notes |
|---|---|---|
| Markdown language + fenced code language mapping | ✅ | primary mode |
| Frontmatter parse + Zod validation | ✅ | diagnostics with location |
| Tags (`#tag`, heading trailing tags) | ✅ | indexed + decorated |
| Mentions (`@user`) styling | ✅ | plus autocomplete via provider |
| Autocomplete framework | ✅ | typed provider model |
| Wikilinks | ✅ | rendered anchor + open callback |
| Inline markdown links | ✅ | label-as-link + open affordance |
| Transclusion `![[...]]` standalone editable blocks | ✅ | nested editor + resolve/save |
| LaTeX scanning | ✅ | inline + block |
| KaTeX preview mode | ✅ | optional (`latexPreviewMode: "katex"`) |
| Task checkboxes | ✅ | clickable widget toggles source |
| Image/PDF rich previews (`![...](...)`) | ⏳ | links indexed, rich preview widget pending |
| Table editor | ⏳ | pending |
| Org parser foundation | ✅ | structural index + typed parse API |
| Org rendering/interaction plugins | ⏳ | heading/list/link widgets still pending |
| Code execution slot features | ⏳ | slot reserved |

---

## 12) Known behavior and caveats

- Org files now maintain a structural parse index (`createNv3OrgParserExtension`), but most visual/editor plugins remain Markdown-only for now.
- Transclusion widgets only activate for **standalone-line** `![[...]]`; inline form remains literal text.
- Autocomplete is suppressed in frontmatter/code contexts.
- Some APIs are broad by design (consumer controls file index, IO, auth, and persistence policy).

---

## 13) Type exports

All key interfaces/types used above are exported from the root module, including:

- File/type model (`Nv3FileType`)
- All index types (`Nv3TagIndex`, `Nv3LatexIndex`, `Nv3LinkIndex`, etc.)
- Resolver input/output types
- Autocomplete types
- Plugin slot/runtime types

Use type imports from `@nv3/editor` directly.
