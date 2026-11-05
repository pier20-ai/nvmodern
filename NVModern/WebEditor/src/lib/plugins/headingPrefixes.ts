import {
  foldEffect,
  foldState,
  foldable,
  foldedRanges,
  unfoldEffect,
  syntaxTree,
} from "@codemirror/language";
import { RangeSetBuilder, type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { collectMarkdownHeadingSections } from "./headings.ts";
import { resolveEventElement, selectionTouchesRange } from "./viewUtils.ts";

/**
 * CM-safe heading prefix rendering + click-to-toggle folding.
 *
 * Historical context:
 * - The original heading concealment path lived in `marksHiding.ts` and used
 *   `display:none` on `HeaderMark` tokens. That looked good, but it broke a core
 *   CodeMirror invariant: visual line geometry no longer matched the document text at
 *   the start of heading lines, which caused cursor motion bugs.
 * - A later experiment kept the hashes in layout but shifted the entire heading line
 *   left with line-level margin tricks. That avoided one class of bug but still proved
 *   too invasive for CM's coordinate mapping and editing behavior.
 * - This file is the replacement approach after those failures. It follows the same
 *   general rule documented in `listPrefixes.ts`: style the already-present text, keep
 *   the source in normal flow, and do not move or remove the whole structural line.
 *
 * Current strategy:
 * - Keep the raw `#... ` prefix in the document and in inline flow.
 * - Decorate only the prefix span itself (`HeaderMark` plus the following space).
 * - Move only the prefix span into the reading gutter. The heading line itself
 *   stays in place, so heading text aligns with body text without line-level
 *   margin/padding tricks.
 * - Never use `display:none` on heading structure.
 * - Keep the prefix low-contrast until hover/focus or the active heading line.
 * - Reuse the same prefix span as the fold toggle target instead of adding a separate
 *   widget or gutter view.
 * - Reflect fold state in the prefix decoration so collapsed headings can be styled.
 *
 * Why this is safer:
 * - The browser still lays out the heading source text normally.
 * - The only layout adjustment is on the prefix span itself, with font-relative
 *   width derived from heading level rather than measured pixel constants.
 * - Cursor correctness is prioritized over more aggressive concealment.
 * - Folding interaction is attached to already-present text, which keeps the DOM and
 *   document model closely aligned.
 *
 * Important invariants / regression guardrails:
 * - If `ArrowUp` / `ArrowDown`, Home/End, or mouse placement around headings becomes
 *   unstable, back the change out.
 * - Do not reintroduce `display:none` for heading structure.
 * - Do not shift the whole heading line.
 * - Prefer active-line raw markdown rendering over clever concealment when editing.
 * - Keep the click target lightweight; do not replace heading prefixes with widgets.
 */
const headingPrefixDecorationCache = new Map<string, Decoration>();
const headingLineDecorationCache = new Map<number, Decoration>();

function headingLineDecoration(level: number): Decoration {
  const cached = headingLineDecorationCache.get(level);
  if (cached) return cached;

  const decoration = Decoration.line({
    class: `nv3-heading-line nv3-heading-line-level-${level}`,
  });
  headingLineDecorationCache.set(level, decoration);
  return decoration;
}

function headingPrefixDecoration(
  level: number,
  options: { active: boolean; collapsed: boolean },
): Decoration {
  const key = `${level}:${options.active ? "active" : "inactive"}:${options.collapsed ? "collapsed" : "expanded"}`;
  const cached = headingPrefixDecorationCache.get(key);
  if (cached) return cached;

  const decoration = Decoration.mark({
    attributes: {
      class: [
        "nv3-heading-prefix",
        `nv3-heading-prefix-level-${level}`,
        options.active ? "nv3-heading-prefix-active" : "",
        options.collapsed ? "nv3-heading-prefix-collapsed" : "",
      ]
        .filter(Boolean)
        .join(" "),
      "data-nv3-heading-prefix": "true",
      "data-nv3-heading-level": String(level),
      "data-nv3-heading-collapsed": options.collapsed ? "true" : "false",
    },
  });

  headingPrefixDecorationCache.set(key, decoration);
  return decoration;
}

function isFoldedExact(
  state: import("@codemirror/state").EditorState,
  from: number,
  to: number,
): boolean {
  let found = false;
  foldedRanges(state).between(from, from, (rangeFrom, rangeTo) => {
    if (rangeFrom === from && rangeTo === to) {
      found = true;
    }
  });
  return found;
}

function buildHeadingPrefixDecorations(
  view: import("@codemirror/view").EditorView,
): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const tree = syntaxTree(view.state);
  const selectionRanges = view.state.selection.ranges;
  const sectionsByLineFrom = new Map(
    collectMarkdownHeadingSections(view.state).map((section) => [
      section.from,
      { from: section.bodyFrom, to: section.bodyTo },
    ]),
  );

  for (const visible of view.visibleRanges) {
    tree.iterate({
      from: visible.from,
      to: visible.to,
      enter(node) {
        if (node.name !== "HeaderMark") {
          return;
        }

        const parent = node.node.parent;
        if (!parent) return;

        const headingLevel = Math.max(1, Math.min(6, node.to - node.from));
        const nextChar = view.state.doc.sliceString(node.to, node.to + 1);
        const prefixTo = nextChar === " " ? node.to + 1 : node.to;

        if (prefixTo <= node.from) {
          return;
        }

        const line = view.state.doc.lineAt(node.from);
        const active = selectionTouchesRange(selectionRanges, parent.from, parent.to);
        const foldRange = sectionsByLineFrom.get(line.from) ?? null;
        const collapsed = !!foldRange && isFoldedExact(view.state, foldRange.from, foldRange.to);

        builder.add(line.from, line.from, headingLineDecoration(headingLevel));
        builder.add(
          node.from,
          prefixTo,
          headingPrefixDecoration(headingLevel, { active, collapsed }),
        );
      },
    });
  }

  return builder.finish();
}

function resolveHeadingPrefixElement(target: EventTarget | null): HTMLElement | null {
  const element = resolveEventElement(target);
  if (!element) return null;

  const prefix = element.closest(".nv3-heading-prefix[data-nv3-heading-prefix='true']");
  return prefix instanceof HTMLElement ? prefix : null;
}

function toggleHeadingFold(
  view: import("@codemirror/view").EditorView,
  prefixElement: HTMLElement,
): boolean {
  if (!view.dom.contains(prefixElement)) return false;

  let pos: number;
  try {
    pos = view.posAtDOM(prefixElement, 0);
  } catch {
    return false;
  }

  const line = view.state.doc.lineAt(pos);
  const range = foldable(view.state, line.from, line.to);
  if (!range) return false;

  const effect = isFoldedExact(view.state, range.from, range.to)
    ? unfoldEffect.of(range)
    : foldEffect.of(range);

  view.dispatch({ effects: effect });
  return true;
}

export function createMarkdownHeadingPrefixesExtension(): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;

      constructor(view: import("@codemirror/view").EditorView) {
        this.decorations = buildHeadingPrefixDecorations(view);
      }

      update(update: ViewUpdate) {
        if (
          !update.docChanged &&
          !update.viewportChanged &&
          !update.selectionSet &&
          update.startState.field(foldState, false) === update.state.field(foldState, false)
        ) {
          return;
        }

        this.decorations = buildHeadingPrefixDecorations(update.view);
      }
    },
    {
      decorations: (pluginValue) => pluginValue.decorations,
      eventHandlers: {
        mousedown(event, view) {
          if (event.button !== 0) return;

          const prefix = resolveHeadingPrefixElement(event.target);
          if (!prefix || !view.dom.contains(prefix)) return;

          event.preventDefault();
          return true;
        },

        click(event, view) {
          if (event.button !== 0) return;

          const prefix = resolveHeadingPrefixElement(event.target);
          if (!prefix || !view.dom.contains(prefix)) return;

          event.preventDefault();
          return toggleHeadingFold(view, prefix);
        },
      },
    },
  );
}
