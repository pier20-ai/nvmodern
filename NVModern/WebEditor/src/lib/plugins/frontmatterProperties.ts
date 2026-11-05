import { StateField, type EditorState, type Extension, type Text } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { parseMarkdownFrontmatter } from "./frontmatter.ts";
import type { Nv3FrontmatterRange } from "./frontmatterService.ts";
import type { Nv3InlineLinkOpenInput, Nv3LinkOccurrence, Nv3WikilinkOpenInput } from "./links.ts";
import { parseNv3WikilinkTarget } from "./wikilinks.ts";

// While reading, YAML frontmatter shows as a quiet property list instead of
// source: muted keys, values in document type, lists on one line, wikilinks
// and URLs as links. Clicking it (or moving the caret into it) shows the YAML
// for editing. Frontmatter that doesn't parse cleanly always shows as source.

export type Nv3FrontmatterSegment =
  | { kind: "text"; text: string }
  | { kind: "wikilink"; target: string; label: string }
  | { kind: "url"; href: string; label: string };

export interface Nv3FrontmatterRow {
  key: string;
  label: string;
  /** Each item of a list value, or the single value. */
  items: Nv3FrontmatterSegment[][];
  /** Render items as pills (tags) rather than a comma-separated run. */
  pills: boolean;
}

export interface Nv3FrontmatterPropertiesOptions {
  onWikilinkOpen?: (input: Nv3WikilinkOpenInput) => void;
  onInlineLinkOpen?: (input: Nv3InlineLinkOpenInput) => void;
}

const PILL_KEYS = new Set(["tags", "tag", "keywords", "aliases"]);
const WIKILINK = /\[\[([^\]\n]+)\]\]/g;
const URL = /^(https?:\/\/\S+)$/;

function wikilinkLabel(target: string): string {
  const parsed = parseNv3WikilinkTarget(target);
  if (parsed.alias) return parsed.alias;
  const note = parsed.note.split("/").pop() ?? parsed.note;
  if (parsed.referenceKind === "none" || !parsed.referenceQuery) return note || target;
  return note ? `${note} › ${parsed.referenceQuery}` : parsed.referenceQuery;
}

function urlLabel(href: string): string {
  return href.replace(/^https?:\/\/(www\.)?/, "").replace(/\/$/, "");
}

/** Split a scalar value into plain text, wikilinks, and a bare URL. */
export function nv3FrontmatterSegments(value: string): Nv3FrontmatterSegment[] {
  const trimmed = value.trim();
  const url = URL.exec(trimmed);
  if (url) return [{ kind: "url", href: url[1]!, label: urlLabel(url[1]!) }];

  const segments: Nv3FrontmatterSegment[] = [];
  let last = 0;
  for (const match of trimmed.matchAll(WIKILINK)) {
    const index = match.index ?? 0;
    if (index > last) segments.push({ kind: "text", text: trimmed.slice(last, index) });
    const target = match[1]!.trim();
    segments.push({ kind: "wikilink", target, label: wikilinkLabel(target) });
    last = index + match[0].length;
  }
  if (last < trimmed.length) segments.push({ kind: "text", text: trimmed.slice(last) });
  return segments.length > 0 ? segments : [{ kind: "text", text: "" }];
}

function scalarText(value: unknown): string {
  if (value instanceof Date) return value.toISOString().slice(0, 10);
  if (value === null || value === undefined) return "";
  if (typeof value === "object") {
    return Object.entries(value as Record<string, unknown>)
      .map(([key, inner]) => `${key}: ${Array.isArray(inner) ? inner.map(scalarText).join(", ") : scalarText(inner)}`)
      .join("; ");
  }
  return String(value);
}

/** The rows of the property list, in source order. */
export function nv3FrontmatterRows(data: Record<string, unknown>): Nv3FrontmatterRow[] {
  return Object.entries(data).map(([key, value]) => {
    const values = Array.isArray(value) ? value : [value];
    return {
      key,
      label: key.replace(/_/g, " "),
      items: values.map((item) => nv3FrontmatterSegments(scalarText(item))),
      pills: Array.isArray(value) && PILL_KEYS.has(key.toLowerCase()),
    };
  });
}

// ── Widget ────────────────────────────────────────────────────────────

class FrontmatterPropertiesWidget extends WidgetType {
  constructor(
    readonly rows: Nv3FrontmatterRow[],
    readonly range: Nv3FrontmatterRange,
    readonly signature: string,
    readonly options: Nv3FrontmatterPropertiesOptions,
  ) {
    super();
  }

  override eq(other: FrontmatterPropertiesWidget): boolean {
    return other.signature === this.signature && other.range.from === this.range.from;
  }

  override get estimatedHeight(): number {
    return this.rows.length * 20 + 18;
  }

  override toDOM(view: EditorView): HTMLElement {
    const root = document.createElement("div");
    root.className = "nv3-frontmatter-props";
    root.setAttribute("role", "group");
    root.setAttribute("aria-label", "Properties");
    root.title = "Click to edit properties";

    for (const row of this.rows) {
      const key = document.createElement("div");
      key.className = "nv3-frontmatter-props-key";
      key.textContent = row.label;
      const value = document.createElement("div");
      value.className = `nv3-frontmatter-props-value${row.pills ? " nv3-frontmatter-props-pills" : ""}`;
      row.items.forEach((item, index) => {
        const holder = row.pills ? document.createElement("span") : value;
        if (row.pills) {
          holder.className = "nv3-frontmatter-props-pill";
          value.append(holder);
        } else if (index > 0) {
          value.append(document.createTextNode(", "));
        }
        for (const segment of item) holder.append(this.segmentDOM(segment, view));
      });
      root.append(key, value);
    }

    root.addEventListener("mousedown", (event) => {
      // Links handle their own clicks; anything else switches to editing.
      if ((event.target as Element | null)?.closest("a")) {
        event.preventDefault();
        return;
      }
      event.preventDefault();
      const firstProperty = view.state.doc.line(Math.min(this.range.fromLine + 1, view.state.doc.lines));
      view.dispatch({ selection: { anchor: firstProperty.to } });
      view.focus();
    });
    return root;
  }

  private segmentDOM(segment: Nv3FrontmatterSegment, view: EditorView): Node {
    if (segment.kind === "text") return document.createTextNode(segment.text);
    const anchor = document.createElement("a");
    anchor.className = segment.kind === "wikilink" ? "nv3-frontmatter-props-wikilink" : "nv3-frontmatter-props-url";
    anchor.textContent = segment.label;
    anchor.href = segment.kind === "url" ? segment.href : "#";
    if (segment.kind === "wikilink") anchor.title = segment.target;
    anchor.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (segment.kind === "wikilink") this.openWikilink(segment.target, event, view);
      else this.openUrl(segment.href, segment.label, event, view);
    });
    return anchor;
  }

  private sourceRange(view: EditorView, text: string): { from: number; to: number } {
    const source = view.state.doc.sliceString(this.range.from, this.range.to);
    const index = source.indexOf(text);
    if (index < 0) return { from: this.range.from, to: this.range.from };
    return { from: this.range.from + index, to: this.range.from + index + text.length };
  }

  private openWikilink(target: string, event: MouseEvent, view: EditorView) {
    if (!this.options.onWikilinkOpen) return;
    const { from, to } = this.sourceRange(view, `[[${target}]]`);
    const occurrence: Nv3LinkOccurrence = {
      kind: "wikilink",
      target,
      from,
      to,
      line: view.state.doc.lineAt(from).number,
    };
    this.options.onWikilinkOpen({
      target,
      href: target,
      occurrence,
      event,
      view,
      shiftKey: event.shiftKey,
      metaKey: event.metaKey,
      altKey: event.altKey,
      ctrlKey: event.ctrlKey,
    });
  }

  private openUrl(href: string, label: string, event: MouseEvent, view: EditorView) {
    if (!this.options.onInlineLinkOpen) {
      window.open(href, "_blank", "noopener,noreferrer");
      return;
    }
    const { from, to } = this.sourceRange(view, href);
    this.options.onInlineLinkOpen({ href, label, from, to, event, view });
  }

  override ignoreEvent(): boolean {
    return true;
  }
}

// ── State ─────────────────────────────────────────────────────────────

interface PropertiesState {
  rows: Nv3FrontmatterRow[] | null;
  range: Nv3FrontmatterRange | null;
  signature: string;
}

const FRONTMATTER_SCAN_LIMIT = 64 * 1024;

function readProperties(doc: Text): PropertiesState {
  const head = doc.sliceString(0, Math.min(doc.length, FRONTMATTER_SCAN_LIMIT));
  const result = parseMarkdownFrontmatter(head);
  const clean =
    result.present &&
    result.range?.closed === true &&
    result.data !== null &&
    Object.keys(result.data).length > 0 &&
    result.diagnostics.every((diagnostic) => diagnostic.severity !== "error");
  if (!clean || !result.range || !result.data) return { rows: null, range: null, signature: "" };
  const rows = nv3FrontmatterRows(result.data);
  return { rows, range: result.range, signature: JSON.stringify(rows) };
}

/** Whether the caret is in the frontmatter, so it should show as source. */
function editingFrontmatter(state: EditorState, range: Nv3FrontmatterRange): boolean {
  // The very start of the document counts as outside, so a freshly opened
  // note reads as properties even with the caret at position zero.
  return state.selection.ranges.some((selection) => selection.to > range.from && selection.from <= range.to);
}

export function createMarkdownFrontmatterPropertiesExtension(options: Nv3FrontmatterPropertiesOptions = {}): Extension {
  const propertiesField = StateField.define<PropertiesState>({
    create: (state) => readProperties(state.doc),
    update: (value, transaction) => (transaction.docChanged ? readProperties(transaction.newDoc) : value),
  });

  const decorations = EditorView.decorations.compute([propertiesField, "selection"], (state): DecorationSet => {
    const properties = state.field(propertiesField);
    if (!properties.rows || !properties.range || editingFrontmatter(state, properties.range)) return Decoration.none;
    const end = state.doc.line(Math.min(properties.range.toLine, state.doc.lines)).to;
    return Decoration.set([
      Decoration.replace({
        block: true,
        widget: new FrontmatterPropertiesWidget(properties.rows, properties.range, properties.signature, options),
      }).range(properties.range.from, end),
    ]);
  });

  return [propertiesField, decorations];
}
