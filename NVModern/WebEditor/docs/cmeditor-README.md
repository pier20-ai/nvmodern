# NV3 Editor (CodeMirror 6)

`@nv3/editor` is an internal, high-performance, CodeMirror 6-first editor library.

This repository contains:

- **Library** (`src/lib`) — reusable editor core + plugins
- **Shell app** (`shell`) — local integration harness for rapid iteration

The editor is intentionally opinionated (Notion-like styling and Markdown UX).

---

## Current status

This project is being prepared for an internal **v1 release**.

Implemented and usable today:

- Markdown language + code fence language highlighting
- YAML frontmatter parsing + optional Zod schema validation
- Markdown tags (`#tag` + heading trailing tags)
- Mention styling (`@user`) and typed autocomplete support
- Wikilink detection/rendering (`[[target]]`) + open handler
- Inline markdown link rendering + external-open affordance
- Standalone transclusion editing (`![[target]]`) with async resolve/save APIs
- LaTeX scanning + optional KaTeX previews
- Concealed markdown marks for cleaner reading mode
- Task checkbox widgets (`- [ ]`, `- [x]`, ordered variants)
- Shared Markdown scan/index layer reused by tag/link/mention/task/code-fence/transclusion/latex plugins
- Org structural parser/index foundation (`.org`) for headings, lists, links, timestamps, blocks, and tables

Still pending / explicitly not complete in v1 scope:

- Org rendering/interaction plugins (parser foundation is now in place)
- Image/PDF block previews for `![...](...)`
- Table editor v1
- Code execution slot features

---

## Run the shell

```bash
bun install
bun run dev
```

Open: `http://localhost:3000`

---

## Basic library usage (framework-agnostic)

```ts
import { EditorView } from "@codemirror/view";
import { createNv3EditorState } from "@nv3/editor";

const state = createNv3EditorState({
  doc: "# Hello",
  filePath: "notes/hello.md",
  onDocChange(doc) {
    console.log("changed", doc.length);
  },
});

const view = new EditorView({
  state,
  parent: document.getElementById("editor")!,
});
```

---

## Styling

The editor ships with opinionated CSS.

- **Library/editor styles:** `shell/styles/editor.lib.css`
- **Shell-only chrome:** `shell/styles/editor.shell.css`

For consumers of the library, copy `editor.lib.css` **as-is** into your app and keep it updated when the library styles change.

See `API.md` for full styling guidance and CSS variable details.

---

## Documentation

- High-level: this `README.md`
- Full API reference: [`API.md`](./API.md)
- Current roadmap / in-progress items: [`docs/next-steps.md`](./docs/next-steps.md)

---

## Notes

- This package is **internal-only** right now.
- The shell currently builds a lightweight React integration directly; the core library itself remains framework-agnostic.
