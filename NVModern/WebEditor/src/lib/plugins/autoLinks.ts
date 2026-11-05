/**
 * Auto-detect bare URLs and render them as clickable links.
 *
 * Works for both Markdown and Org files. Scans visible lines for
 * `https://...` and `http://...` patterns bounded by whitespace or
 * punctuation, and adds link decorations.
 *
 * Skips URLs that are already inside link syntax (`[[...]]`, `[...](...)`),
 * inline code, or code fences.
 */
import { type Extension } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  ViewPlugin,
  type ViewUpdate,
} from "@codemirror/view";
import { resolveEventElement } from "./viewUtils.ts";

// Match http:// or https:// URLs up to whitespace or common trailing punctuation
const URL_PATTERN = /https?:\/\/[^\s<>\[\]"'`)(}{]+[^\s<>\[\]"'`)(}{.,;:!?]/g;

// Characters that shouldn't appear just before a URL match (part of link syntax)
const LINK_CONTEXT_BEFORE = new Set(["(", "[", '"', "'", "`"]);

function buildAutoLinkDecorations(
  state: import("@codemirror/state").EditorState,
): DecorationSet {
  const ranges: Array<import("@codemirror/state").Range<Decoration>> = [];
  const doc = state.doc;

  for (let lineNo = 1; lineNo <= doc.lines; lineNo++) {
    const line = doc.line(lineNo);
    const text = line.text;

    URL_PATTERN.lastIndex = 0;
    let match: RegExpExecArray | null;

    while ((match = URL_PATTERN.exec(text)) !== null) {
      const url = match[0] ?? "";
      const startOffset = match.index;
      const endOffset = startOffset + url.length;

      // Skip if inside link syntax
      const prevChar = text[startOffset - 1];
      if (prevChar && LINK_CONTEXT_BEFORE.has(prevChar)) continue;

      // Skip if preceded by `](` (markdown link URL position)
      if (startOffset >= 2 && text[startOffset - 2] === "]" && text[startOffset - 1] === "(") continue;

      // Skip if inside inline code backticks
      const before = text.slice(0, startOffset);
      const backtickCount = (before.match(/`/g) ?? []).length;
      if (backtickCount % 2 === 1) continue;

      const from = line.from + startOffset;
      const to = line.from + endOffset;

      ranges.push(
        Decoration.mark({
          tagName: "a",
          class: "nv3-auto-link",
          attributes: {
            href: url,
            "data-nv3-auto-link": "true",
            "data-nv3-auto-link-href": url,
          },
        }).range(from, to),
      );
    }
  }

  return Decoration.set(ranges, true);
}

export function createAutoLinksExtension(): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;

      constructor(view: import("@codemirror/view").EditorView) {
        this.decorations = buildAutoLinkDecorations(view.state);
      }

      update(update: ViewUpdate) {
        if (!update.docChanged) return;
        this.decorations = buildAutoLinkDecorations(update.state);
      }
    },
    {
      decorations: (v) => v.decorations,
      eventHandlers: {
        mousedown(event, view) {
          const el = resolveEventElement(event.target);
          if (!el || !view.dom.contains(el)) return;
          if (el.closest("[data-nv3-auto-link='true']")) {
            event.preventDefault();
            return true;
          }
        },
        click(event, view) {
          const el = resolveEventElement(event.target);
          if (!el || !view.dom.contains(el)) return;
          const link = el.closest("[data-nv3-auto-link='true']");
          if (!(link instanceof HTMLElement)) return;
          const href = link.dataset.nv3AutoLinkHref;
          if (!href) return;
          event.preventDefault();
          window.open(href, "_blank", "noopener,noreferrer");
          return true;
        },
      },
    },
  );
}
