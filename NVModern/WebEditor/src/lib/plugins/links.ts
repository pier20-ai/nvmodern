import { Facet, type EditorState, type Extension } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  ViewPlugin,
  WidgetType,
  type ViewUpdate,
} from "@codemirror/view";
import { resolveDocumentScanIndex } from "./documentIndex.ts";
import { nv3InteractionModeChanged, resolveNv3InteractionMode } from "./interactionState.ts";
import { wikilinkDisplaySegments } from "./wikilinks.ts";
import { resolveEventElement, selectionTouchesRange } from "./viewUtils.ts";

export type Nv3LinkKind = "wikilink" | "transclusion" | "preview";

export interface Nv3LinkOccurrence {
  kind: Nv3LinkKind;
  target: string;
  from: number;
  to: number;
  line: number;
}

export interface Nv3LinkIndex {
  count: number;
  wikilinkCount: number;
  transclusionCount: number;
  previewCount: number;
  occurrences: Nv3LinkOccurrence[];
}

export interface Nv3WikilinkOpenInput {
  target: string;
  href: string;
  occurrence: Nv3LinkOccurrence;
  event: MouseEvent;
  view: import("@codemirror/view").EditorView;
  /** Modifier keys held during the click, so hosts can route e.g. Shift-click elsewhere. */
  shiftKey: boolean;
  metaKey: boolean;
  altKey: boolean;
  ctrlKey: boolean;
}

export interface Nv3WikilinkHrefInput {
  target: string;
  occurrence: Nv3LinkOccurrence;
  filePath?: string;
}

export interface Nv3InlineLinkOpenInput {
  href: string;
  label: string;
  from: number;
  to: number;
  event: MouseEvent;
  view: import("@codemirror/view").EditorView;
}

export interface Nv3InlineLinkHrefInput {
  href: string;
  label: string;
  from: number;
  to: number;
  filePath?: string;
}

export interface MarkdownLinkOptions {
  filePath?: string;
  onChange?: (index: Nv3LinkIndex) => void;
  resolveWikilinkHref?: (input: Nv3WikilinkHrefInput) => string;
  resolveInlineLinkHref?: (input: Nv3InlineLinkHrefInput) => string;
  onWikilinkOpen?: (input: Nv3WikilinkOpenInput) => void;
  onInlineLinkOpen?: (input: Nv3InlineLinkOpenInput) => void;
}

// Rendered widgets share the same host link resolution as source decorations.
const markdownLinkOptionsFacet = Facet.define<MarkdownLinkOptions, MarkdownLinkOptions>({
  combine: (values) => values[values.length - 1] ?? {},
});

export function wikilinkAnchorAttributes(
  state: EditorState,
  occurrence: Nv3LinkOccurrence,
  options: MarkdownLinkOptions = state.facet(markdownLinkOptionsFacet),
): Record<string, string> {
  const href = options.resolveWikilinkHref?.({
    target: occurrence.target,
    occurrence,
    filePath: options.filePath,
  }) ?? occurrence.target;
  return {
    href,
    "data-nv3-wikilink": "true",
    "data-nv3-target": occurrence.target,
    "data-nv3-from": String(occurrence.from),
    "data-nv3-to": String(occurrence.to),
  };
}

class InlineLinkOpenWidget extends WidgetType {
  constructor(
    readonly href: string,
    readonly label: string,
    readonly from: number,
    readonly to: number,
  ) {
    super();
  }

  override eq(other: InlineLinkOpenWidget): boolean {
    return (
      other.href === this.href &&
      other.label === this.label &&
      other.from === this.from &&
      other.to === this.to
    );
  }

  override toDOM(): HTMLElement {
    const node = document.createElement("span");
    node.className = "nv3-inline-link-open-arrow";
    node.textContent = "↗";
    node.setAttribute("data-nv3-inline-link-open", "true");
    node.setAttribute("data-nv3-inline-link-href", this.href);
    node.setAttribute("data-nv3-inline-link-label", this.label);
    node.setAttribute("data-nv3-inline-link-from", String(this.from));
    node.setAttribute("data-nv3-inline-link-to", String(this.to));
    node.setAttribute("title", `Open ${this.href}`);
    return node;
  }

  override ignoreEvent(): boolean {
    return false;
  }
}

function linkSignature(index: Nv3LinkIndex): string {
  const positions = index.occurrences
    .map((occurrence) => `${occurrence.kind}:${occurrence.from}:${occurrence.to}`)
    .join("|");
  return `${index.wikilinkCount}:${index.transclusionCount}:${index.previewCount}:${positions}`;
}

function inlineOpenElement(target: EventTarget | null): HTMLElement | null {
  const element = resolveEventElement(target);
  if (!element) return null;

  const inlineOpen = element.closest(
    ".nv3-inline-link-open-arrow[data-nv3-inline-link-open='true']",
  );
  if (!(inlineOpen instanceof HTMLElement)) return null;
  return inlineOpen;
}

function wikilinkAnchorElement(target: EventTarget | null): HTMLAnchorElement | null {
  const element = resolveEventElement(target);
  if (!element) return null;

  const anchor = element.closest("a.nv3-link-wikilink[data-nv3-wikilink='true']");
  if (!(anchor instanceof HTMLAnchorElement)) return null;
  return anchor;
}

/** Ctrl is left out: on macOS Ctrl-click is a secondary click (context menu). */
function hasClickModifier(event: MouseEvent): boolean {
  return event.shiftKey || event.metaKey || event.altKey;
}

function inlineLinkAnchorElement(target: EventTarget | null): HTMLAnchorElement | null {
  const element = resolveEventElement(target);
  if (!element) return null;

  const anchor = element.closest("a.nv3-link-inline[data-nv3-inline-link='true']");
  if (!(anchor instanceof HTMLAnchorElement)) return null;
  return anchor;
}

export function buildLinkData(
  state: EditorState,
  options: MarkdownLinkOptions,
): {
  index: Nv3LinkIndex;
  decorations: DecorationSet;
} {
  const scanIndex = resolveDocumentScanIndex(state);
  const shouldDegradeVisuals = resolveNv3InteractionMode(state) !== "idle";
  const decorationRanges: Array<import("@codemirror/state").Range<Decoration>> = [];

  const occurrences: Nv3LinkOccurrence[] = scanIndex.links.map((occurrence) => ({
    kind: occurrence.kind,
    target: occurrence.target,
    from: occurrence.from,
    to: occurrence.to,
    line: occurrence.line,
  }));

  let wikilinkCount = 0;
  let transclusionCount = 0;
  let previewCount = 0;

  for (const occurrence of occurrences) {
    if (occurrence.kind === "transclusion") {
      decorationRanges.push(
        Decoration.mark({ class: "nv3-link nv3-link-transclusion" }).range(
          occurrence.from,
          occurrence.to,
        ),
      );
      transclusionCount += 1;
      continue;
    }

    if (occurrence.kind === "preview") {
      decorationRanges.push(
        Decoration.mark({ class: "nv3-link nv3-link-preview" }).range(
          occurrence.from,
          occurrence.to,
        ),
      );
      previewCount += 1;
      continue;
    }

    wikilinkCount += 1;

    decorationRanges.push(
      Decoration.mark({
        tagName: "a",
        class: "nv3-link nv3-link-wikilink",
        attributes: wikilinkAnchorAttributes(state, occurrence, options),
      }).range(occurrence.from, occurrence.to),
    );

    if (occurrence.to - occurrence.from < 4) {
      continue;
    }

    const bodyFrom = occurrence.from + 2;
    const bodyTo = occurrence.to - 2;
    const segments = wikilinkDisplaySegments(state.doc.sliceString(bodyFrom, bodyTo));

    // Keep title-only links stable while typing elsewhere, just like inline links.
    if (
      segments.aliasFrom !== null &&
      segments.aliasTo !== null &&
      !selectionTouchesRange(state.selection.ranges, occurrence.from, occurrence.to)
    ) {
      decorationRanges.push(
        Decoration.mark({ class: "nv3-link-hidden-syntax" }).range(
          occurrence.from,
          bodyFrom + segments.aliasFrom,
        ),
        Decoration.mark({ class: "nv3-link-wikilink-text" }).range(
          bodyFrom + segments.aliasFrom,
          bodyFrom + segments.aliasTo,
        ),
        Decoration.mark({ class: "nv3-link-hidden-syntax" }).range(
          bodyFrom + segments.aliasTo,
          occurrence.to,
        ),
      );
      continue;
    }

    if (shouldDegradeVisuals) continue;

    decorationRanges.push(
      Decoration.mark({
        tagName: "span",
        class: "nv3-link-wikilink-bracket",
      }).range(occurrence.from, bodyFrom),
    );

    if (segments.noteTo > segments.noteFrom) {
      decorationRanges.push(
        Decoration.mark({
          tagName: "span",
          class: "nv3-link-wikilink-text nv3-link-wikilink-note",
        }).range(bodyFrom + segments.noteFrom, bodyFrom + segments.noteTo),
      );
    }

    if (
      segments.referenceMarkerFrom !== null &&
      segments.referenceMarkerTo !== null &&
      segments.referenceMarkerTo > segments.referenceMarkerFrom
    ) {
      decorationRanges.push(
        Decoration.mark({
          tagName: "span",
          class: "nv3-link-wikilink-subpath-marker",
        }).range(bodyFrom + segments.referenceMarkerFrom, bodyFrom + segments.referenceMarkerTo),
      );
    }

    if (
      segments.referenceTextFrom !== null &&
      segments.referenceTextTo !== null &&
      segments.referenceTextTo > segments.referenceTextFrom
    ) {
      decorationRanges.push(
        Decoration.mark({
          tagName: "span",
          class: "nv3-link-wikilink-subpath-text",
        }).range(bodyFrom + segments.referenceTextFrom, bodyFrom + segments.referenceTextTo),
      );
    }

    const styledUntil =
      segments.referenceTextTo ??
      segments.referenceMarkerTo ??
      segments.noteTo;
    if (bodyTo > bodyFrom + styledUntil) {
      decorationRanges.push(
        Decoration.mark({
          tagName: "span",
          class: "nv3-link-wikilink-text",
        }).range(bodyFrom + styledUntil, bodyTo),
      );
    }

    decorationRanges.push(
      Decoration.mark({
        tagName: "span",
        class: "nv3-link-wikilink-bracket",
      }).range(bodyTo, occurrence.to),
    );
  }

  for (const inlineLink of scanIndex.inlineLinks) {
    const href =
      options.resolveInlineLinkHref?.({
        href: inlineLink.href,
        label: inlineLink.label,
        from: inlineLink.from,
        to: inlineLink.to,
        filePath: options.filePath,
      }) ?? inlineLink.href;

    const inlineAttributes = {
      href,
      target: "_blank",
      rel: "noopener noreferrer",
      "data-nv3-inline-link": "true",
      "data-nv3-inline-link-href": inlineLink.href,
      "data-nv3-inline-link-label": inlineLink.label,
      "data-nv3-inline-link-from": String(inlineLink.from),
      "data-nv3-inline-link-to": String(inlineLink.to),
    };

    // Keep concealed inline-link layout stable while typing elsewhere. Expanding
    // long `[label](url)` spans above the caret can make WebKit's editor scroller
    // jump as wrapped line heights change.
    if (selectionTouchesRange(state.selection.ranges, inlineLink.from, inlineLink.to)) {
      continue;
    }

    decorationRanges.push(
      Decoration.mark({
        tagName: "a",
        class: "nv3-link nv3-link-inline",
        attributes: inlineAttributes,
      }).range(inlineLink.labelFrom, inlineLink.labelTo),
    );

    decorationRanges.push(
      Decoration.mark({ class: "nv3-link-hidden-syntax" }).range(inlineLink.from, inlineLink.from + 1),
    );
    decorationRanges.push(
      Decoration.mark({ class: "nv3-link-hidden-syntax" }).range(
        inlineLink.labelTo,
        inlineLink.labelTo + 2,
      ),
    );
    decorationRanges.push(
      Decoration.mark({ class: "nv3-link-hidden-syntax" }).range(
        inlineLink.urlFrom,
        inlineLink.urlTo,
      ),
    );
    decorationRanges.push(
      Decoration.mark({ class: "nv3-link-hidden-syntax" }).range(inlineLink.to - 1, inlineLink.to),
    );

    decorationRanges.push(
      Decoration.widget({
        side: 1,
        widget: new InlineLinkOpenWidget(
          inlineLink.href,
          inlineLink.label,
          inlineLink.from,
          inlineLink.to,
        ),
      }).range(inlineLink.to),
    );
  }

  const index: Nv3LinkIndex = {
    count: occurrences.length,
    wikilinkCount,
    transclusionCount,
    previewCount,
    occurrences,
  };

  return {
    index,
    decorations: Decoration.set(decorationRanges, true),
  };
}

export function createMarkdownLinkExtension(options: MarkdownLinkOptions = {}): Extension {
  const { onChange, onWikilinkOpen, onInlineLinkOpen } = options;

  return [markdownLinkOptionsFacet.of(options), ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      index: Nv3LinkIndex;
      private signature: string;

      constructor(view: import("@codemirror/view").EditorView) {
        const data = buildLinkData(view.state, options);
        this.decorations = data.decorations;
        this.index = data.index;
        this.signature = linkSignature(data.index);
        onChange?.(data.index);
      }

      update(update: ViewUpdate) {
        const interactionChanged = nv3InteractionModeChanged(update);
        const shouldRebuildForSelection =
          update.selectionSet && resolveNv3InteractionMode(update.state) === "idle";
        if (!update.docChanged && !interactionChanged && !shouldRebuildForSelection) return;

        const data = buildLinkData(update.state, options);
        this.decorations = data.decorations;
        this.index = data.index;

        if (!update.docChanged) return;

        const nextSignature = linkSignature(data.index);
        if (nextSignature !== this.signature) {
          this.signature = nextSignature;
          onChange?.(data.index);
        }
      }
    },
    {
      decorations: (pluginValue) => pluginValue.decorations,
      eventHandlers: {
        mousedown(event, view) {
          const inlineOpen = inlineOpenElement(event.target);
          if (inlineOpen && view.dom.contains(inlineOpen)) {
            event.preventDefault();
            return true;
          }

          // A modified click on a wikilink is a link gesture (e.g. Shift-click
          // to open beside the document), not a selection gesture: keep
          // CodeMirror from extending the selection or adding a cursor. The
          // click handler below still receives the click.
          if (!onWikilinkOpen || event.button !== 0 || !hasClickModifier(event)) return;
          const anchor = wikilinkAnchorElement(event.target);
          if (!anchor || !view.dom.contains(anchor)) return;

          event.preventDefault();
          return true;
        },

        click(event, view) {
          const inlineOpen = inlineOpenElement(event.target);
          if (inlineOpen && view.dom.contains(inlineOpen)) {
            const href = inlineOpen.dataset.nv3InlineLinkHref ?? "";
            const label = inlineOpen.dataset.nv3InlineLinkLabel ?? "";
            const from = Number(inlineOpen.dataset.nv3InlineLinkFrom ?? NaN);
            const to = Number(inlineOpen.dataset.nv3InlineLinkTo ?? NaN);
            if (!href || !Number.isFinite(from) || !Number.isFinite(to)) return;

            event.preventDefault();

            if (onInlineLinkOpen) {
              onInlineLinkOpen({
                href,
                label,
                from,
                to,
                event,
                view,
              });
            } else {
              window.open(href, "_blank", "noopener,noreferrer");
            }

            return true;
          }

          const inlineAnchor = inlineLinkAnchorElement(event.target);
          if (inlineAnchor && view.dom.contains(inlineAnchor)) {
            const href = inlineAnchor.dataset.nv3InlineLinkHref ?? inlineAnchor.getAttribute("href") ?? "";
            const label = inlineAnchor.dataset.nv3InlineLinkLabel ?? inlineAnchor.textContent ?? href;
            const from = Number(inlineAnchor.dataset.nv3InlineLinkFrom ?? NaN);
            const to = Number(inlineAnchor.dataset.nv3InlineLinkTo ?? NaN);
            if (!href || !Number.isFinite(from) || !Number.isFinite(to)) return;

            event.preventDefault();

            if (onInlineLinkOpen) {
              onInlineLinkOpen({
                href,
                label,
                from,
                to,
                event,
                view,
              });
            } else {
              window.open(inlineAnchor.href || href, "_blank", "noopener,noreferrer");
            }

            return true;
          }

          if (!onWikilinkOpen) return;

          const anchor = wikilinkAnchorElement(event.target);
          if (!anchor || !view.dom.contains(anchor)) return;

          const from = Number(anchor.dataset.nv3From ?? NaN);
          const to = Number(anchor.dataset.nv3To ?? NaN);
          const linkTarget = anchor.dataset.nv3Target ?? "";
          const href = anchor.getAttribute("href") ?? linkTarget;
          if (!Number.isFinite(from) || !Number.isFinite(to) || !linkTarget) return;

          const occurrence: Nv3LinkOccurrence = {
            kind: "wikilink",
            target: linkTarget,
            from,
            to,
            line: view.state.doc.lineAt(from).number,
          };

          event.preventDefault();
          onWikilinkOpen({
            target: linkTarget,
            href,
            occurrence,
            event,
            view,
            shiftKey: event.shiftKey,
            metaKey: event.metaKey,
            altKey: event.altKey,
            ctrlKey: event.ctrlKey,
          });

          return true;
        },
      },
    },
  )];
}
