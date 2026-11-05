# nvModern Editor Theme CSS

`config.toml` can point `editor_theme_css` at a CSS file. nvModern injects that
file after the bundled editor CSS.

## Themes

A theme is a single CSS file that overrides the public `--nv3-*` tokens. The
filename (without the `.css` extension) is the theme id. Themes live in two
places and form one set:

- bundled themes in the app package (`Resources/BuiltinThemes/`: newsprint,
  laurenziana, riso, cyanotype, kunsthalle, dispatch, outliner, catppuccin, nord, mayfair), and
- user themes in the themes directory (`~/.config/nvmodern/themes` by default,
  configurable via `themes_dir`).

A user file with the same id as a bundled theme shadows it, so customizing a
built-in is a matter of dropping in a same-named file. The id `system` is
reserved and always means "no theme — bundled defaults".

Select a theme globally with `editor_theme = "<id>"` in `config.toml`, from
Settings > Appearance, or with the `workspace.theme.select` /
`workspace.theme.cycle` actions. The same set is offered per document in the
Document Inspector and via frontmatter `theme:`; a per-document selection
overrides the global one. Effective CSS is the selected theme followed by
`editor_theme_css`, then injected after the bundled editor CSS, so token
overrides win by source order. Theme files are watched: edits apply to open
editors without a restart.

Optional display metadata for Settings > Appearance and the Document Inspector
rides in the CSS itself:

```css
--nv3-theme-name: Solarized Dusk;
--nv3-theme-subtitle: Low-glare technical reading;
--nv3-theme-swatch: #2f766f;    /* up to three: -2, -3 */
```

Use the example theme created by "Open Themes Folder…" as a starting point, or
copy the default reference block at the end of this document and delete
anything the theme does not change.

Markdown and Org share one typography system: the same faces, sizes and
heading scale apply to both, and Org adds styling only for its own syntax. A
file type can still pick its own theme or face with `[filetypes.<ext>]` in
`config.toml` (for example `[filetypes.org] font_family = "IBM Plex Mono"`);
see `docs/architecture/configuration.md`.

Markdown frontmatter can override the active document appearance with the
highest precedence:

```yaml
---
theme: solarized
width: wide
font-family: Avenir Next, Georgia, serif
---
```

`theme` accepts any theme id — a bundled theme, a user theme, or `system` to
opt back into defaults. Supported `width` values are `narrow`, `comfortable`,
`wide`, `extra-wide`, and `full`. `font-family` sets the document sans/display
font tokens; code and monospace tokens are unchanged.

Prefer overriding the public `--nv3-*` custom properties instead of targeting
CodeMirror internals directly. Public tokens are declared in cascade layers, so
either plain CSS or `@layer nvmodern.user` works for token overrides. Use plain
CSS for any advanced selector overrides so it can follow normal source-order
cascade after the bundled editor CSS.

```toml
editor_theme_css = "editor-theme.css"
```

```css
@layer nvmodern.user {
  :root,
  [data-theme="light"] {
    --nv3-color-bg: #fbfaf8;
    --nv3-color-surface: #f2f0ec;
    --nv3-color-surface-hover: #e9e5dd;
    --nv3-color-text: #242321;
    --nv3-color-text-muted: #77736b;
    --nv3-color-text-subtle: #a79f94;
    --nv3-color-border: #ded9d1;
    --nv3-color-accent: #2f766f;
    --nv3-color-blue: var(--nv3-color-accent);
    --nv3-selection-bg: rgba(47, 118, 111, 0.18);

    --nv3-editor-max-width: 780px;
    --nv3-md-h1-color: #243f3b;
    --nv3-md-h2-color: #243f3b;
    --nv3-md-inline-code-color: #a3483f;
  }

  [data-theme="dark"] {
    --nv3-color-bg: #171615;
    --nv3-color-surface: #22201e;
    --nv3-color-surface-hover: #2b2825;
    --nv3-color-text: #ece7df;
    --nv3-color-text-muted: #aaa199;
    --nv3-color-text-subtle: #7d756e;
    --nv3-color-border: #34302d;
    --nv3-color-accent: #70bdb4;
    --nv3-color-blue: var(--nv3-color-accent);
    --nv3-selection-bg: rgba(112, 189, 180, 0.22);
  }
}
```

## Public Tokens

Core colors:

```css
--nv3-color-bg
--nv3-color-surface
--nv3-color-surface-hover
--nv3-color-surface-active
--nv3-color-text
--nv3-color-text-muted
--nv3-color-text-subtle
--nv3-color-border
--nv3-color-border-strong
--nv3-color-accent
--nv3-selection-bg
--nv3-caret-color
```

Accent colors:

```css
--nv3-color-red
--nv3-color-orange
--nv3-color-yellow
--nv3-color-highlight-yellow
--nv3-color-green
--nv3-color-teal
--nv3-color-blue
--nv3-color-purple
--nv3-color-pink
```

Typography and editor measure:

```css
--nv3-font-sans                  /* body text */
--nv3-font-display               /* headings */
--nv3-font-label                 /* labels: Org keywords, tags, table headers */
--nv3-font-mono                  /* code */
--nv3-font-size-adjust           /* the theme's x-height, e.g. 0.45 */
--nv3-content-font-size          /* body size, relative to document scale */
--nv3-content-line-height
--nv3-content-font-size-adjust   /* set by font swaps; leave alone */
--nv3-radius
--nv3-editor-max-width
```

Set `--nv3-font-size-adjust` to the body face's x-height as a fraction of its
size (Michelangelus 0.45, Adobe Caslon 0.414, SF Pro 0.508). Code faces are
scaled to it with `font-size-adjust`, so code sizes can stay near `1em`. When
a filetype default or frontmatter swaps the body font, the swapped face is
scaled to it too, so a monospace face lands at the theme's optical size.
Typography tokens do not change between light and dark, so a theme declares
them once on `:root` and only colours under `[data-theme="light"]` and
`[data-theme="dark"]`.

Name fonts by family, quoted, and end every stack with a generic family.
WebKit hides fonts installed in `~/Library/Fonts` and `/Library/Fonts` from
web pages, so nvModern serves any such family a theme names as `@font-face`
web fonts; fonts in `/System` work by name as they are. Apple's system faces
are reached through generic names instead: `ui-serif` (New York),
`ui-sans-serif` or `-apple-system` (SF Pro) and `ui-monospace` (SF Mono).

`--nv3-editor-max-width` is the only public editor layout token. Other
CodeMirror geometry is intentionally private: gutter width, content side
padding, line padding, editor min-height, cursor width, tab size, and vertical
line spacing are owned by nvModern. Heading prefixes, list markers, folded
syntax, and TOC affordances share tightly tuned geometry.

Org-mode elements:

```css
--nv3-org-h1-color … --nv3-org-h6-color
--nv3-org-h1-spacing
--nv3-org-h2-spacing
--nv3-org-h3-spacing
--nv3-org-h1-rule
--nv3-org-keyword-font-family
--nv3-org-todo-color
--nv3-org-todo-scale
--nv3-org-todo-font-weight
--nv3-org-todo-letter-spacing
--nv3-org-doing-color
--nv3-org-done-color
--nv3-org-done-keyword-color
--nv3-org-planning-color
--nv3-org-planning-keyword-color
--nv3-org-deadline-color
--nv3-org-timestamp-color
--nv3-org-keyword-color
--nv3-org-checkbox-color
--nv3-org-checkbox-checked-color
--nv3-org-list-marker-color
--nv3-org-link-color
--nv3-org-tag-color
--nv3-org-tag-scale
--nv3-org-property-key-color
```

Org uses the document typography: the `#+title:` value takes the H1 tokens
and a level-N headline takes Markdown heading N+1, so `*` reads as a section
under the title. Headline colours default to those heading colours. TODO
keywords, tags and cookies are labels in `--nv3-org-keyword-font-family`, sized
as a fraction of the body (`--nv3-org-todo-scale`, `--nv3-org-tag-scale`) so
they read the same at every headline level. Closed headlines (the states
after `|` on the file's `#+TODO:` line) recede to `--nv3-org-done-color`.

Stable class names for theme rules: `.om-title` (line), `.om-title-key`,
`.om-title-text`, `.om-h1`…`.om-h6` (headline lines, spacing),
`.om-hl1`…`.om-hl6` (headline text marks, typography), `.om-heading-done`,
`.om-todo`, `.om-done`, `.om-kw-<state>` (for example `.om-kw-doing`),
`.om-tags`, `.om-cookie`, `.om-planning`, `.om-planning-keyword`,
`.om-timestamp`. Indentation is measured in `ch` on line boxes, so change
faces and sizes on these marks, not on Org lines.

Markdown element typography:

```css
--nv3-md-h1-font-family
--nv3-md-h1-color
--nv3-md-h1-font-size
--nv3-md-h1-line-height
--nv3-md-h1-font-weight
--nv3-md-h1-letter-spacing
```

Each level also has `--nv3-md-h1-font-style`, `--nv3-md-h1-font-feature-settings`
(for example `"dlig", "init"`) and `--nv3-md-h1-text-transform`. The same
heading token pattern exists for `h2` through `h6`, for example
`--nv3-md-h3-font-size` and `--nv3-md-h6-color`. Paragraphs inherit the body
editor font tokens; there is no separate paragraph styling layer.

Inline code:

```css
--nv3-md-inline-code-font-family
--nv3-md-inline-code-color
--nv3-md-inline-code-bg
--nv3-md-inline-code-font-size
--nv3-md-inline-code-heading-font-size
--nv3-md-inline-code-padding
--nv3-md-inline-code-radius
```

Code blocks:

```css
--nv3-md-code-block-font-family
--nv3-md-code-block-color
--nv3-md-code-block-bg
--nv3-md-code-block-font-size
--nv3-md-code-block-line-height
--nv3-md-code-block-border-color
--nv3-md-code-block-border-width
--nv3-md-code-block-radius
--nv3-md-code-block-delimiter-font-size
--nv3-md-code-block-language-letter-spacing
```

Horizontal rules:

```css
--nv3-md-horizontal-rule-width
--nv3-md-horizontal-rule-padding-block
--nv3-md-horizontal-rule-border
--nv3-md-horizontal-rule-active-border
--nv3-md-horizontal-rule-source-color
```

Callouts and blockquotes:

```css
--nv3-md-callout-color-note
--nv3-md-callout-color-tip
--nv3-md-callout-color-warning
--nv3-md-callout-color-danger
--nv3-md-callout-color-example
--nv3-md-callout-color-quote
--nv3-md-callout-color-question
--nv3-md-callout-font-family
--nv3-md-callout-color
--nv3-md-callout-font-size
--nv3-md-callout-line-height
--nv3-md-callout-bg
--nv3-md-callout-border-color
--nv3-md-callout-border-width
--nv3-md-callout-marker-font-weight
--nv3-md-callout-marker-color
--nv3-md-callout-title-font-weight
--nv3-md-callout-title-color
--nv3-md-callout-title-font-family
--nv3-md-callout-title-font-size
--nv3-md-callout-title-letter-spacing
--nv3-md-callout-title-text-transform
--nv3-md-blockquote-font-family
--nv3-md-blockquote-font-style
--nv3-md-blockquote-color
--nv3-md-blockquote-font-size
--nv3-md-blockquote-line-height
--nv3-md-blockquote-bg
--nv3-md-blockquote-border-color
--nv3-md-blockquote-border-width
--nv3-md-blockquote-prefix-active-color
```

`--nv3-md-callout-bg`, `--nv3-md-callout-border-color`, and
`--nv3-md-callout-marker-color` are optional overrides. If they are not set,
nvModern computes them from the callout type color on each rendered callout
line.

Syntax colors:

```css
--nv3-syntax-keyword
--nv3-syntax-string
--nv3-syntax-number
--nv3-syntax-atom
--nv3-syntax-function
--nv3-syntax-type
--nv3-syntax-variable
--nv3-syntax-property
--nv3-syntax-namespace
--nv3-syntax-definition
--nv3-syntax-operator
--nv3-syntax-punctuation
--nv3-syntax-regexp
--nv3-syntax-escape
--nv3-syntax-doc-comment
--nv3-syntax-invalid
--nv3-syntax-inserted
--nv3-syntax-deleted
```

Tables and task checkboxes:

```css
--nv3-table-frame
--nv3-table-header-bg
--nv3-table-header-color
--nv3-table-header-font-family
--nv3-table-header-font-scale
--nv3-table-header-font-style
--nv3-table-header-font-weight
--nv3-table-header-letter-spacing
--nv3-table-header-text-transform
--nv3-table-header-border
--nv3-table-row-border
--nv3-table-column-border
--nv3-task-checkbox-border
--nv3-task-checkbox-checked
--nv3-task-checkbox-tick
--nv3-task-checkbox-radius
```

Markdown affordances:

```css
--nv3-md-highlight-bg
--nv3-md-highlight-color
--nv3-wikilink-underline
--nv3-link-underline-style
--nv3-link-underline-thickness
--nv3-link-color
--nv3-link-hover-color
--nv3-tag-heading-s
--nv3-tag-heading-l
--nv3-tag-heading-border-s
--nv3-tag-heading-border-l
--nv3-tag-heading-border-a
```

## Default Reference

These are the bundled public defaults. A user theme can copy this block and
delete anything it does not need to change.

```css
@layer nvmodern.user {
  :root,
  [data-theme="light"] {
    --nv3-color-bg: #ffffff;
    --nv3-color-surface: #f7f6f3;
    --nv3-color-surface-hover: #efefec;
    --nv3-color-surface-active: #e8e8e5;
    --nv3-color-code-inline-bg: rgba(135, 131, 120, 0.15);
    --nv3-color-code-block-bg: #f7f6f3;
    --nv3-color-text: #2c2c2b;
    --nv3-color-text-muted: #7d7a95;
    --nv3-color-text-subtle: #a19e99;
    --nv3-color-border: #e9e9e7;
    --nv3-color-border-strong: #d9d8d3;
    --nv3-color-accent: #2383e2;
    --nv3-selection-bg: rgba(35, 131, 226, 0.16);
    --nv3-caret-color: var(--nv3-color-accent);

    --nv3-color-red: #eb5757;
    --nv3-color-orange: #d9730d;
    --nv3-color-yellow: #cb912f;
    --nv3-color-highlight-yellow: #fff59d;
    --nv3-color-green: #448361;
    --nv3-color-teal: #0f7b6c;
    --nv3-color-blue: #2383e2;
    --nv3-color-purple: #6940a5;
    --nv3-color-pink: #ad1a72;

    --nv3-syntax-keyword: #8250df;
    --nv3-syntax-string: #0a7d35;
    --nv3-syntax-number: #0a63c9;
    --nv3-syntax-atom: #b54708;
    --nv3-syntax-function: #005cc5;
    --nv3-syntax-type: #953800;
    --nv3-syntax-variable: #24292f;
    --nv3-syntax-property: #0550ae;
    --nv3-syntax-namespace: #953800;
    --nv3-syntax-definition: #0550ae;
    --nv3-syntax-operator: #953800;
    --nv3-syntax-punctuation: #656d76;
    --nv3-syntax-regexp: #116329;
    --nv3-syntax-escape: #116329;
    --nv3-syntax-doc-comment: #6e7781;
    --nv3-syntax-invalid: #cf222e;
    --nv3-syntax-inserted: #1a7f37;
    --nv3-syntax-deleted: #cf222e;

    --nv3-font-sans: ui-sans-serif, -apple-system, "SF Pro Text", "SF Pro Display",
      BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif, "Apple Color Emoji",
      "Segoe UI Emoji";
    --nv3-font-display: "SF Pro Display", "SF Pro Text", -apple-system,
      BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    --nv3-font-mono: "SF Mono", "SFMono-Regular", ui-monospace, Menlo, Monaco,
      Consolas, "Liberation Mono", monospace;
    --nv3-radius: 6px;
    --nv3-editor-max-width: 740px;

    --nv3-md-h1-font-family: var(--nv3-font-display);
    --nv3-md-h1-color: var(--nv3-color-text);
    --nv3-md-h1-font-size: 1.875em;
    --nv3-md-h1-line-height: 1.3;
    --nv3-md-h1-font-weight: 700;
    --nv3-md-h1-letter-spacing: -0.01em;
    --nv3-md-h2-font-family: var(--nv3-font-display);
    --nv3-md-h2-color: var(--nv3-color-text);
    --nv3-md-h2-font-size: 1.5em;
    --nv3-md-h2-line-height: 1.3;
    --nv3-md-h2-font-weight: 600;
    --nv3-md-h2-letter-spacing: inherit;
    --nv3-md-h3-font-family: var(--nv3-font-display);
    --nv3-md-h3-color: var(--nv3-color-text);
    --nv3-md-h3-font-size: 1.25em;
    --nv3-md-h3-line-height: 1.3;
    --nv3-md-h3-font-weight: 600;
    --nv3-md-h3-letter-spacing: inherit;
    --nv3-md-h4-font-family: var(--nv3-font-display);
    --nv3-md-h4-color: var(--nv3-color-text);
    --nv3-md-h4-font-size: 1em;
    --nv3-md-h4-line-height: 1.3;
    --nv3-md-h4-font-weight: 600;
    --nv3-md-h4-letter-spacing: inherit;
    --nv3-md-h5-font-family: var(--nv3-font-display);
    --nv3-md-h5-color: var(--nv3-color-text);
    --nv3-md-h5-font-size: 1em;
    --nv3-md-h5-line-height: 1.3;
    --nv3-md-h5-font-weight: 600;
    --nv3-md-h5-letter-spacing: inherit;
    --nv3-md-h6-font-family: var(--nv3-font-display);
    --nv3-md-h6-color: var(--nv3-color-text);
    --nv3-md-h6-font-size: 1em;
    --nv3-md-h6-line-height: 1.3;
    --nv3-md-h6-font-weight: 600;
    --nv3-md-h6-letter-spacing: inherit;

    --nv3-md-inline-code-font-family: var(--nv3-font-mono);
    --nv3-md-inline-code-color: var(--nv3-color-red);
    --nv3-md-inline-code-bg: transparent;
    --nv3-md-inline-code-font-size: 0.9em;
    --nv3-md-inline-code-heading-font-size: 0.98em;
    --nv3-md-inline-code-padding: 0.12em 0.34em;
    --nv3-md-inline-code-radius: 3px;

    --nv3-md-code-block-font-family: var(--nv3-font-mono);
    --nv3-md-code-block-color: inherit;
    --nv3-md-code-block-bg: transparent;
    --nv3-md-code-block-font-size: 14px;
    --nv3-md-code-block-line-height: 1.6;
    --nv3-md-code-block-border-color: transparent;
    --nv3-md-code-block-border-width: 0;
    --nv3-md-code-block-radius: 0;
    --nv3-md-code-block-delimiter-font-size: 0.8rem;
    --nv3-md-code-block-language-letter-spacing: 0.01em;

    --nv3-md-callout-color-note: var(--nv3-color-blue);
    --nv3-md-callout-color-tip: var(--nv3-color-green);
    --nv3-md-callout-color-warning: var(--nv3-color-orange);
    --nv3-md-callout-color-danger: var(--nv3-color-red);
    --nv3-md-callout-color-example: var(--nv3-color-pink);
    --nv3-md-callout-color-quote: var(--nv3-color-text-muted);
    --nv3-md-callout-color-question: var(--nv3-color-purple);
    --nv3-md-callout-font-family: inherit;
    --nv3-md-callout-color: inherit;
    --nv3-md-callout-font-size: inherit;
    --nv3-md-callout-line-height: inherit;
    --nv3-md-callout-border-width: 2px;
    --nv3-md-callout-marker-font-weight: 600;
    --nv3-md-callout-title-font-weight: 600;
    --nv3-md-callout-title-color: var(--nv3-color-text);
    --nv3-md-blockquote-font-family: inherit;
    --nv3-md-blockquote-color: inherit;
    --nv3-md-blockquote-font-size: inherit;
    --nv3-md-blockquote-line-height: inherit;
    --nv3-md-blockquote-bg: transparent;
    --nv3-md-blockquote-border-color: color-mix(in srgb, var(--nv3-color-accent) 58%, var(--nv3-color-border));
    --nv3-md-blockquote-border-width: 2px;
    --nv3-md-blockquote-prefix-active-color: var(--nv3-color-text-subtle);

    --nv3-wikilink-underline: #37352f40;
    --nv3-link-color: var(--nv3-color-text);
    --nv3-link-hover-color: var(--nv3-color-blue);
    --nv3-tag-heading-s: 84%;
    --nv3-tag-heading-l: 47%;
    --nv3-tag-heading-border-s: 90%;
    --nv3-tag-heading-border-l: 43%;
    --nv3-tag-heading-border-a: 0.95;
  }

  [data-theme="dark"] {
    --nv3-color-bg: #191919;
    --nv3-color-surface: #232323;
    --nv3-color-surface-hover: #2c2c2c;
    --nv3-color-surface-active: #363636;
    --nv3-color-code-inline-bg: rgba(210, 210, 205, 0.18);
    --nv3-color-code-block-bg: #202020;
    --nv3-color-text: #f0efed;
    --nv3-color-text-muted: #ada9e3;
    --nv3-color-text-subtle: #7d7a75;
    --nv3-color-border: #2f2f2f;
    --nv3-color-border-strong: #3a3a3a;
    --nv3-color-accent: #4e9de2;
    --nv3-selection-bg: rgba(78, 157, 226, 0.22);

    --nv3-color-red: #eb5758;
    --nv3-color-orange: #e08a3c;
    --nv3-color-yellow: #d4a72c;
    --nv3-color-highlight-yellow: #b59b2f;
    --nv3-color-green: #4daa6f;
    --nv3-color-teal: #2bc5b4;
    --nv3-color-blue: #4e9de2;
    --nv3-color-purple: #9a6dd7;
    --nv3-color-pink: #d94d9a;

    --nv3-syntax-keyword: #c792ea;
    --nv3-syntax-string: #9ccc65;
    --nv3-syntax-number: #82aaff;
    --nv3-syntax-atom: #f78c6c;
    --nv3-syntax-function: #82aaff;
    --nv3-syntax-type: #ffcb6b;
    --nv3-syntax-variable: #bfc7d5;
    --nv3-syntax-property: #f78c6c;
    --nv3-syntax-namespace: #ffcb6b;
    --nv3-syntax-definition: #82aaff;
    --nv3-syntax-operator: #89ddff;
    --nv3-syntax-punctuation: #676e95;
    --nv3-syntax-regexp: #c3e88d;
    --nv3-syntax-escape: #9ccc65;
    --nv3-syntax-doc-comment: #546e7a;
    --nv3-syntax-invalid: #ff5370;
    --nv3-syntax-inserted: #80cbc4;
    --nv3-syntax-deleted: #f07178;

    --nv3-tag-heading-s: 94%;
    --nv3-tag-heading-l: 71%;
    --nv3-tag-heading-border-s: 98%;
    --nv3-tag-heading-border-l: 77%;
    --nv3-tag-heading-border-a: 0.98;
    --nv3-wikilink-underline: #373737;
  }
}
```

Legacy variables such as `--bg`, `--text`, `--blue`, and `--cm-keyword` remain
as compatibility aliases.
