// org-mode language support built on uniorg
// (https://github.com/rasendubi/uniorg — a standard Org Syntax parser).
//
// Replaces the previous hand-written orgDecorations layer: heading stars
// (hidden into the gutter, click-to-fold), org-indent-mode indentation,
// TODO keywords (click for a state popover), clickable checkboxes,
// timestamps, inline markup with cursor-aware concealment, links, and
// source blocks. Uses CodeMirror's own fold mechanism.
//
// The parse *index* (orgIndex.ts / org/parser.ts) is untouched — the TOC,
// table editing, list editing, and parse diagnostics still consume it.
import { RangeSet, StateField, type Text, type EditorState, type Extension } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
} from "@codemirror/view";
import {
  codeFolding,
  foldedRanges,
  foldEffect,
  foldService,
  foldable,
  unfoldEffect,
} from "@codemirror/language";
import { parseOrgText } from "./parser.ts";
import {
  ORG_TODO_STATES as TODO_STATES,
  getOrgSyntax,
  getOrgSyntaxForState,
  orgSyntaxExtension,
} from "./orgSyntax.ts";
import { selectionTouchesRange } from "../plugins/viewUtils.ts";

export { TODO_STATES };
const DEFAULT_DONE_STATES = new Set(["DONE", "POSTPONED", "DROPPED"]);

/**
 * Which keywords count as closed, per the document's own `#+TODO:` line.
 *
 * Org puts closed states after the `|`: `#+TODO: TODO DOING | DONE POSTPONED`.
 * Without a bar, only the last keyword is closed. Closed headlines are styled
 * to recede, so this has to follow the file rather than a fixed list.
 */
export function doneStatesFor(docText: string): Set<string> {
  const done = new Set<string>();
  let sawTodoLine = false;
  const pattern = /^#\+(?:TODO|SEQ_TODO|TYP_TODO):[ \t]*(.*)$/gim;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(docText)) !== null) {
    sawTodoLine = true;
    const spec = match[1]!.trim();
    if (!spec) continue;
    const bar = spec.indexOf("|");
    const closed = bar >= 0 ? spec.slice(bar + 1) : spec.split(/\s+/).slice(-1).join(" ");
    for (const raw of closed.split(/\s+/)) {
      // Keywords may carry fast-access keys: `DONE(d)`.
      const keyword = raw.replace(/\(.*\)$/, "");
      if (keyword) done.add(keyword);
    }
  }
  return sawTodoLine ? done : DEFAULT_DONE_STATES;
}

export interface OrgModeOptions {
  /** Called when the user clicks an org link. Defaults to opening http(s) links in a new tab. */
  onLinkOpen?: (input: {
    href: string;
    event: MouseEvent;
    view: EditorView;
  }) => void;
  /** Called when a TODO keyword is clicked. Defaults to the standalone HTML popover. */
  onTodoMenuOpen?: (input: {
    from: number;
    to: number;
    current: string;
    states: readonly string[];
    event: MouseEvent;
    view: EditorView;
  }) => void;
}

interface Entry {
  from: number;
  to: number;
  deco: Decoration;
}

const lineCache = new Map<string, Decoration>();
const markCache = new Map<string, Decoration>();
function line(cls: string): Decoration {
  let decoration = lineCache.get(cls);
  if (!decoration) lineCache.set(cls, decoration = Decoration.line({ class: cls }));
  return decoration;
}
function mark(cls: string): Decoration {
  let decoration = markCache.get(cls);
  if (!decoration) markCache.set(cls, decoration = Decoration.mark({ class: cls }));
  return decoration;
}
const hiddenDelimiter = Decoration.replace({});
const hide = () => hiddenDelimiter;

/**
 * Org indentation must be represented by the line box, not an inline widget.
 *
 * Inline spacer widgets made the first visual row wider without giving soft
 * wraps the same inset. More importantly, CodeMirror's measured text geometry
 * could then disagree with the browser's inline layout, making ArrowUp and
 * ArrowDown jump across whole sections. Line padding keeps every visual row in
 * the same measured block while leaving all source text in normal inline flow.
 */
const sectionIndentDecorationCache = new Map<number, Decoration>();
function sectionIndentDeco(width: number): Decoration {
  const cached = sectionIndentDecorationCache.get(width);
  if (cached) return cached;

  const decoration = Decoration.line({
    attributes: {
      class: "om-section-indent-line",
      style: `--om-section-indent:${width}ch;`,
    },
  });
  sectionIndentDecorationCache.set(width, decoration);
  return decoration;
}

const listLineDecorationCache = new Map<number, Decoration>();
function listLineDeco(prefixColumns: number): Decoration {
  const cached = listLineDecorationCache.get(prefixColumns);
  if (cached) return cached;

  const decoration = Decoration.line({
    attributes: {
      class: "om-list-line",
      style: `--om-list-prefix-width:${prefixColumns}ch;`,
    },
  });
  listLineDecorationCache.set(prefixColumns, decoration);
  return decoration;
}

const listMarkerClasses: Record<"bullet" | "ordered" | "description", string> = {
  bullet: "om-list-marker om-list-marker-bullet",
  ordered: "om-list-marker om-list-marker-ordered",
  description: "om-list-marker om-list-marker-bullet",
};

/**
 * The hanging prefix is drawn as fixed `ch` boxes: one for indentation,
 * marker and spacing, one for a checklist token. Box widths equal their
 * source columns, so body text starts on the padded column even in a
 * proportional face whose glyphs are narrower than `ch`.
 */
const listMarkerDecorationCache = new Map<string, Decoration>();
function listMarkerDeco(kind: "bullet" | "ordered" | "description", columns: number): Decoration {
  const key = `${kind}:${columns}`;
  const cached = listMarkerDecorationCache.get(key);
  if (cached) return cached;

  const decoration = Decoration.mark({
    class: listMarkerClasses[kind],
    attributes: { style: `--om-list-box:${columns}ch;` },
  });
  listMarkerDecorationCache.set(key, decoration);
  return decoration;
}

const INDENT_PER_LEVEL = 2;
// Same tag grammar as the parse index (org/parser.ts).
const HEADLINE_TAGS_PATTERN = /\s+(:[A-Za-z][A-Za-z0-9_@#%+-]*(?::[A-Za-z][A-Za-z0-9_@#%+-]*)*:)\s*$/;
const HEADLINE_COOKIE_PATTERN = /\[(?:\d*\/\d*|\d*%)\]/g;

function lineEndAt(docText: string, pos: number): number {
  const end = docText.indexOf("\n", pos);
  return end === -1 ? docText.length : end;
}

/** Per-keyword class (`om-kw-doing`) so themes can tell open states apart. */
function keywordClass(keyword: string): string {
  return `om-kw-${keyword.toLowerCase().replace(/[^a-z0-9-]/g, "")}`;
}
const BLOCK_TYPES = new Set([
  "src-block",
  "example-block",
  "export-block",
  "comment-block",
]);

const emphasisClass: Record<string, string> = {
  bold: "om-bold",
  italic: "om-italic",
  underline: "om-underline",
  "strike-through": "om-strike",
  code: "om-code",
  verbatim: "om-code",
};

// ── AST walk ───────────────────────────────────────────────────────────────

function walk(
  node: any,
  docText: string,
  entries: Entry[],
  selection: readonly number[],
  doneStates: Set<string>,
  selectionRanges: readonly { from: number; to: number }[],
  sectionLevel = 0
) {
  const pos = node.position?.start?.offset;
  const end = node.position?.end?.offset;

  // Sections carry the indentation context; everything else is uniform.
  if (node.type === "section") {
    let level = sectionLevel;
    for (const child of node.children ?? []) {
      if (child.type === "section") {
        walk(child, docText, entries, selection, doneStates, selectionRanges, level);
        continue;
      }
      if (child.type === "headline") {
        level = child.level;
        decorateHeadline(child, docText, entries, doneStates);
        walk(child, docText, entries, selection, doneStates, selectionRanges, level);
        continue;
      }
      // Regular content sits under the section's heading: indent it.
      if (level > 0 && !BLOCK_TYPES.has(child.type)) {
        indentElement(child, docText, level * INDENT_PER_LEVEL, entries);
      }
      walk(child, docText, entries, selection, doneStates, selectionRanges, level);
    }
    return;
  }

  switch (node.type) {
    case "planning": {
      entries.push({ from: pos, to: pos, deco: line("om-planning") });
      // Label each planning keyword so SCHEDULED/DEADLINE/CLOSED can be
      // styled as quiet metadata rather than as a boxed line of text.
      const planningText = docText.slice(pos, end);
      const keywordPattern = /\b(SCHEDULED|DEADLINE|CLOSED):/g;
      let keywordMatch: RegExpExecArray | null;
      while ((keywordMatch = keywordPattern.exec(planningText)) !== null) {
        entries.push({
          from: pos + keywordMatch.index,
          to: pos + keywordMatch.index + keywordMatch[0].length,
          deco: mark(`om-planning-keyword om-planning-${keywordMatch[1]!.toLowerCase()}`),
        });
      }
      break;
    }
    case "keyword": {
      const title = String(node.key ?? "").toLowerCase() === "title"
        ? /^(\s*#\+title:)([ \t]*)(.*?)[ \t]*$/i.exec(docText.slice(pos, lineEndAt(docText, pos)))
        : null;
      const titleKey = title?.[1] ?? "";
      const titleValue = title?.[3] ?? "";
      if (titleValue) {
        // `#+title:` is the document's H1: the key recedes, the value takes
        // the H1 typography.
        const valueFrom = pos + titleKey.length + (title?.[2] ?? "").length;
        entries.push({ from: pos, to: pos, deco: line("om-keyword om-title") });
        entries.push({ from: pos, to: pos + titleKey.length, deco: mark("om-title-key") });
        entries.push({ from: valueFrom, to: valueFrom + titleValue.length, deco: mark("om-title-text") });
      } else {
        entries.push({ from: pos, to: pos, deco: line("om-keyword") });
      }
      break;
    }
    case "comment":
    case "fixed-width": {
      entries.push({ from: pos, to: pos, deco: line("om-comment") });
      break;
    }
    case "example-block":
    case "export-block":
    case "comment-block": {
      for (let p = pos; p < end; ) {
        entries.push({ from: p, to: p, deco: line("om-comment") });
        const next = docText.indexOf("\n", p) + 1;
        if (!next) break;
        p = next;
      }
      break;
    }
    case "src-block":
      break;
    case "timestamp": {
      entries.push({ from: pos, to: end, deco: mark("om-timestamp") });
      return; // leaf
    }
    case "link": {
      entries.push({
        from: pos,
        to: end,
        deco: Decoration.mark({
          class: "om-link",
          attributes: {
            "data-om-link": "true",
            "data-om-href": String(node.rawLink ?? node.path ?? ""),
          },
        }),
      });
      if (
        node.format === "bracket" &&
        typeof node.contentsBegin === "number" &&
        typeof node.contentsEnd === "number" &&
        docText.slice(node.contentsBegin, node.contentsEnd).trim() &&
        !selectionTouchesRange(selectionRanges, pos, end)
      ) {
        const concealed = mark("nv3-link-hidden-syntax");
        entries.push({ from: pos, to: node.contentsBegin, deco: concealed });
        entries.push({ from: node.contentsEnd, to: end, deco: concealed });
      }
      break;
    }
    case "bold":
    case "italic":
    case "underline":
    case "strike-through":
    case "code":
    case "verbatim": {
      // Hide the delimiters unless the cursor sits on their line.
      const delimDeco = onAnyLine(docText, pos, selection) ? mark("om-dim") : hide();
      entries.push({ from: pos, to: pos + 1, deco: delimDeco });
      entries.push({ from: end - 1, to: end, deco: delimDeco });
      if (end - pos > 2) {
        entries.push({
          from: pos + 1,
          to: end - 1,
          deco: mark(emphasisClass[node.type]!),
        });
      }
      return; // children already covered
    }
  }

  for (const child of node.children ?? [])
    walk(child, docText, entries, selection, doneStates, selectionRanges, sectionLevel);
  if (node.type === "planning") {
    for (const key of ["closed", "deadline", "scheduled"]) {
      const stamp = node[key];
      if (!stamp) continue;
      walk(stamp, docText, entries, selection, doneStates, selectionRanges, sectionLevel);
      const stampFrom = stamp.position?.start?.offset;
      const stampTo = stamp.position?.end?.offset;
      if (typeof stampFrom === "number" && typeof stampTo === "number" && stampTo > stampFrom) {
        entries.push({ from: stampFrom, to: stampTo, deco: mark(`om-timestamp-${key}`) });
      }
    }
  }
}

function decorateHeadline(
  headline: any,
  docText: string,
  entries: Entry[],
  doneStates: Set<string>
) {
  const pos = headline.position.start.offset;
  const todoKeyword: string | undefined = headline.todoKeyword || undefined;
  const done = todoKeyword != null && doneStates.has(todoKeyword);
  // The line carries the TODO state so closed headlines can be dimmed as a
  // whole, not just their keyword.
  const stateClass = todoKeyword ? (done ? " om-heading-done" : " om-heading-todo") : "";
  const level = Math.min(headline.level, 6);
  const lineEnd = lineEndAt(docText, pos);
  entries.push({
    from: pos,
    to: pos,
    deco: line(`om-heading om-h${level}${stateClass}`),
  });
  // Heading typography rides on a mark, as Markdown's heading spans do: the
  // line keeps the body size so section indentation, measured in `ch` on the
  // line box, lines up with the content beneath it.
  if (lineEnd > pos) {
    entries.push({ from: pos, to: lineEnd, deco: mark(`om-heading-text om-hl${level}`) });
  }
  const headlineText = docText.slice(pos, lineEnd);
  const tags = HEADLINE_TAGS_PATTERN.exec(headlineText);
  if (tags?.[1]) {
    const tagsFrom = pos + tags.index + tags[0].indexOf(":");
    entries.push({ from: tagsFrom, to: tagsFrom + tags[1].length, deco: mark("om-tags") });
  }
  for (const cookie of headlineText.matchAll(HEADLINE_COOKIE_PATTERN)) {
    const cookieFrom = pos + (cookie.index ?? 0);
    entries.push({ from: cookieFrom, to: cookieFrom + cookie[0].length, deco: mark("om-cookie") });
  }
  // Star prefix (stars + following space): pulled left into the gutter
  // via CSS negative margin, faint until hovered, click folds the subtree.
  const prefixEnd = Math.min(
    pos + headline.level + 1,
    headline.position.end.offset
  );
  if (prefixEnd > pos) {
    entries.push({
      from: pos,
      to: prefixEnd,
      deco: Decoration.mark({
        class: `om-stars om-stars-l${Math.min(headline.level, 6)}`,
        attributes: { "data-om-stars": "true" },
      }),
    });
  }
  // Headings themselves indent one level less than their content.
  if (headline.level > 1) {
    entries.push({
      from: pos,
      to: pos,
      deco: sectionIndentDeco((headline.level - 1) * INDENT_PER_LEVEL),
    });
  }
  if (headline.todoKeyword) {
    const m = /^\s+([^\s]+)/.exec(docText.slice(pos + headline.level));
    if (m) {
      const kFrom = pos + headline.level + m[0].indexOf(m[1]!);
      const kTo = pos + headline.level + m[0].length;
      entries.push({
        from: kFrom,
        to: kTo,
        deco: Decoration.mark({
          class: `${done ? "om-done" : "om-todo"} ${keywordClass(m[1] ?? "")}`,
          attributes: {
            "data-om-todo": "true",
            "data-om-from": String(kFrom),
            "data-om-to": String(kTo),
          },
        }),
      });
    }
  }
}

/** Apply section indentation to the line box of every line the element spans. */
function indentElement(
  element: any,
  docText: string,
  width: number,
  entries: Entry[]
) {
  const deco = sectionIndentDeco(width);
  // Element positions include the trailing newline; `p < end` keeps the
  // spacer off the line after the element.
  for (
    let p = element.position.start.offset;
    p < element.position.end.offset;

  ) {
    entries.push({ from: p, to: p, deco });
    const next = docText.indexOf("\n", p) + 1;
    if (!next) break;
    p = next;
  }
}

/** True if any selection head sits on the line containing `pos`. */
function onAnyLine(docText: string, pos: number, heads: readonly number[]) {
  const start = docText.lastIndexOf("\n", pos - 1) + 1;
  let end = docText.indexOf("\n", pos);
  if (end === -1) end = docText.length;
  return heads.some((head) => head >= start && head <= end);
}

export function buildOrgModeDecorations(
  doc: Text,
  heads: readonly number[],
  selectionRanges: readonly { from: number; to: number }[] = heads.map((head) => ({ from: head, to: head })),
): DecorationSet {
  const { source: docText, tree } = getOrgSyntax(doc);
  const parsed = parseOrgText(doc);
  const entries: Entry[] = [];
  walk(tree, docText, entries, heads, doneStatesFor(docText), selectionRanges);

  for (const drawer of parsed.propertiesDrawers) {
    entries.push({ from: doc.line(drawer.fromLine).from, to: doc.line(drawer.fromLine).from, deco: line("om-properties-boundary") });
    if (drawer.toLine !== drawer.fromLine) {
      entries.push({ from: doc.line(drawer.toLine).from, to: doc.line(drawer.toLine).from, deco: line("om-properties-boundary") });
    }
    for (const property of drawer.entries) {
      entries.push({ from: doc.line(property.line).from, to: doc.line(property.line).from, deco: line("om-property-line") });
      entries.push({ from: property.from, to: property.from + property.key.length + 2, deco: mark("om-property-key") });
      if (property.valueTo > property.valueFrom) {
        entries.push({ from: property.valueFrom, to: property.valueTo, deco: mark("om-property-value") });
      }
    }
  }

  for (const item of parsed.listItems) {
    const itemLine = doc.line(item.line);
    // `contentFrom` includes the raw marker, its following whitespace, and a
    // checklist token when present. Padding by exactly that source width makes
    // every soft-wrapped row begin at the body column. Pulling back only the
    // existing marker keeps the source in normal inline flow, matching the
    // geometry-safe Markdown list strategy (no replace widgets, no text-indent).
    const prefixColumns = Math.max(1, item.contentFrom - itemLine.from);
    entries.push({
      from: itemLine.from,
      to: itemLine.from,
      deco: listLineDeco(prefixColumns),
    });
    const boxEnd = item.checklistFrom ?? item.contentFrom;
    entries.push({
      from: itemLine.from,
      to: boxEnd,
      deco: listMarkerDeco(item.kind, Math.max(1, boxEnd - itemLine.from)),
    });
    if (item.checklistFrom != null && item.checklistTo != null && item.contentFrom > item.checklistFrom) {
      entries.push({
        from: item.checklistFrom,
        to: item.contentFrom,
        deco: Decoration.mark({
          class: `om-checkbox${item.checklist === "checked" ? " om-checked" : ""}`,
          attributes: {
            style: `--om-list-box:${item.contentFrom - item.checklistFrom}ch;`,
            "data-om-checkbox": "true",
            "data-om-from": String(item.checklistFrom),
            "data-om-to": String(item.checklistTo),
          },
        }),
      });
    }

    if (item.kind !== "description" || item.descriptionTermFrom == null || item.descriptionTermTo == null) continue;
    entries.push({ from: itemLine.from, to: itemLine.from, deco: line("om-description-list") });
    entries.push({ from: item.descriptionTermFrom, to: item.descriptionTermTo, deco: mark("om-description-term") });
  }

  for (const block of parsed.sourceBlocks) {
    for (let lineNumber = block.fromLine; lineNumber <= block.toLine; lineNumber += 1) {
      const sourceLine = doc.line(lineNumber);
      const className = lineNumber === block.fromLine || (block.closed && lineNumber === block.toLine)
        ? "om-src-delimiter"
        : "om-src-body";
      entries.push({ from: sourceLine.from, to: sourceLine.from, deco: line(className) });
    }
  }

  return RangeSet.of(
    entries.map((e) => e.deco.range(e.from, e.to)),
    true
  );
}

function decorationsForState(state: EditorState): DecorationSet {
  getOrgSyntaxForState(state);
  return buildOrgModeDecorations(
    state.doc,
    state.selection.ranges.map((range) => range.head),
    state.selection.ranges,
  );
}

// Cursor moves reuse syntax; edits publish a current incremental tree before
// rendering. There is no delayed snapshot or subsequent formatting reflow.
const orgDecorations = StateField.define<DecorationSet>({
  create: decorationsForState,
  update(value, tr) {
    if (!tr.docChanged && !tr.selection) return value;
    return decorationsForState(tr.state);
  },
  provide: (field) => EditorView.decorations.from(field),
});

// ── Folding (CodeMirror's fold mechanism) ──────────────────────────────────

// A heading folds its whole subtree: everything up to the next heading
// of the same or higher level. The range stops short of the newline
// before that heading, so the next heading keeps its own line.
const orgFoldService = foldService.of((state, lineStart) => {
  const l = state.doc.lineAt(lineStart);
  const m = /^(\*+)\s/.exec(l.text);
  if (!m) return null;
  const level = m[1]!.length;
  let pos = l.to + 1;
  while (pos <= state.doc.length) {
    const next = state.doc.lineAt(pos);
    const h = /^(\*+)\s/.exec(next.text);
    if (h && h[1]!.length <= level)
      return { from: l.to, to: Math.max(l.to, next.from - 1) };
    pos = next.to + 1;
  }
  return state.doc.length > l.to ? { from: l.to, to: state.doc.length } : null;
});

function toggleFold(view: EditorView, lineFrom: number) {
  const range = foldable(
    view.state,
    lineFrom,
    view.state.doc.lineAt(lineFrom).to
  );
  if (!range) return;
  let folded = false;
  foldedRanges(view.state).between(range.from, range.from, (f, t) => {
    if (f === range.from && t === range.to) folded = true;
  });
  view.dispatch({ effects: folded ? unfoldEffect.of(range) : foldEffect.of(range) });
}

// ── Clicks: fold, checkboxes, TODO popover, links ──────────────────────────

let closeTodoPopover: (() => void) | null = null;

function showTodoPopover(
  view: EditorView,
  from: number,
  to: number,
  current: string
) {
  closeTodoPopover?.();
  const coords = view.coordsAtPos(from);
  const el = document.createElement("div");
  el.className = "om-todo-popover";
  for (const state of TODO_STATES) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = state;
    if (state === current) btn.className = "om-todo-current";
    btn.addEventListener("mousedown", (e) => {
      e.preventDefault();
      view.dispatch({ changes: { from, to, insert: state } });
      closeTodoPopover?.();
    });
    el.appendChild(btn);
  }
  document.body.appendChild(el);
  el.style.left = `${coords?.left ?? 0}px`;
  el.style.top = `${(coords?.bottom ?? 0) + 6}px`;
  const close = (e: MouseEvent) => {
    if (!el.contains(e.target as Node)) closeTodoPopover?.();
  };
  closeTodoPopover = () => {
    el.remove();
    document.removeEventListener("mousedown", close, true);
    closeTodoPopover = null;
  };
  setTimeout(() => document.addEventListener("mousedown", close, true));
}

function createClickHandler(options: OrgModeOptions) {
  return EditorView.domEventHandlers({
    // Prevent focus stealing so clicks don't move the cursor.
    mousedown(event, view) {
      const el = event.target as HTMLElement;
      if (
        el.closest(".om-stars") ||
        el.closest("[data-om-checkbox]") ||
        el.closest("[data-om-todo]") ||
        el.closest("[data-om-link]")
      ) {
        event.preventDefault();
        return true;
      }
    },
    click(event, view) {
      const el = event.target as HTMLElement;

      // Star prefix → fold / unfold the subtree.
      const stars = el.closest(".om-stars");
      if (stars) {
        event.preventDefault();
        try {
          const pos = view.posAtDOM(stars, 0);
          toggleFold(view, view.state.doc.lineAt(pos).from);
        } catch {
          /* posAtDOM can throw if the element is detached */
        }
        return true;
      }

      // Checkbox → toggle [ ] / [X].
      const checkbox = el.closest("[data-om-checkbox]") as HTMLElement | null;
      if (checkbox) {
        event.preventDefault();
        const from = Number(checkbox.dataset.omFrom);
        const to = Number(checkbox.dataset.omTo);
        const marker = view.state.doc.sliceString(from, to);
        if (!/^\[[ xX-]\]$/.test(marker)) return true;
        view.dispatch({
          changes: {
            from: from + 1,
            to: from + 2,
            insert: marker[1] === " " ? "X" : " ",
          },
        });
        return true;
      }

      // TODO keyword → popover with all states.
      const todo = el.closest("[data-om-todo]") as HTMLElement | null;
      if (todo) {
        event.preventDefault();
        const from = Number(todo.dataset.omFrom);
        const to = Number(todo.dataset.omTo);
        const current = view.state.doc.sliceString(from, to);
        if (TODO_STATES.includes(current)) {
          if (options.onTodoMenuOpen) {
            options.onTodoMenuOpen({
              from,
              to,
              current,
              states: TODO_STATES,
              event,
              view,
            });
          } else {
            showTodoPopover(view, from, to, current);
          }
        }
        return true;
      }

      // Link → open.
      const link = el.closest("[data-om-link]") as HTMLElement | null;
      if (link) {
        event.preventDefault();
        const href = link.dataset.omHref ?? "";
        if (!href) return true;
        if (options.onLinkOpen) {
          options.onLinkOpen({ href, event, view });
        } else if (/^https?:/.test(href)) {
          window.open(href, "_blank", "noopener,noreferrer");
        }
        return true;
      }
      return false;
    },
  });
}

export function createOrgModeExtension(options: OrgModeOptions = {}): Extension[] {
  return [
    orgSyntaxExtension,
    orgDecorations,
    orgFoldService,
    codeFolding(),
    createClickHandler(options),
    EditorView.lineWrapping,
    EditorView.theme({
      "&": { height: "100%" },
      // Faces, sizes and line height come from the shared document tokens.
      // Match the reference editor while leaving max width under the host's
      // document inspector control.
      ".cm-content": {
        paddingTop: "12px",
        paddingLeft: "4em",
        paddingRight: "0",
        maxWidth: "100%",
      },
    }),
  ];
}
