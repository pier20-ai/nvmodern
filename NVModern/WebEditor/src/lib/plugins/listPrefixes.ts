import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { RangeSetBuilder, type Extension } from "@codemirror/state";
import {
  Decoration,
  EditorView,
  type DecorationSet,
  ViewPlugin,
  type ViewUpdate,
} from "@codemirror/view";
import { resolveEventElement, selectionTouchesRange } from "./viewUtils.ts";

/**
 * CM-safe list prefix rendering.
 *
 * Historical context:
 * - The older list UI (`listMarkers.ts` + `taskCheckboxes.ts`) was visually ambitious. It
 *   hid prefix text, used negative `text-indent`, styled continuation lines separately, and
 *   replaced task markers with a checkbox widget.
 * - That looked close to Notion, but it broke a core editor invariant: CodeMirror's visual
 *   layout and the document's text geometry drifted apart. Once that happened, vertical
 *   cursor movement on wrapped list items (`ArrowUp` / `ArrowDown`) became erratic.
 * - This file is the replacement approach after that failure. It intentionally favors cursor
 *   correctness and scroll smoothness over more aggressive concealment tricks.
 *
 * Current strategy (the safe primitives that actually worked):
 * - Keep source text in normal inline flow.
 * - Use only `Decoration.mark(...)` on existing text plus a small `Decoration.line(...)`
 *   on the list item's start line.
 * - Never use `Decoration.replace(...)` for task checkboxes here.
 * - Never use negative `text-indent`.
 * - Never use `display:none` on structural list text.
 * - For task lists, prefer intuitive editing over perfectly stable concealment.
 * - Keep inactive task lines concealed, but reveal the full raw task prefix on the active
 *   line so caret motion and Enter feel like normal Markdown editing.
 * - Mark concealed task-prefix subranges as atomic so hidden prefix pieces remain
 *   non-interactive when the checkbox UI is shown.
 *
 * What is rendered today:
 * - Bullet lists:
 *   - Raw bullet markers are styled into a 24px visual marker box.
 *   - Soft-wrap hanging indent is implemented with line padding + marker-only negative
 *     margin. This proved stable for wrapped bullets across multiple nesting levels.
 * - Task lists:
 *   - The raw `[ ]` / `[x]` token stays in the document and in inline flow.
 *   - The checkbox is drawn with CSS on top of that token instead of replacing it with a
 *     widget.
 *   - When the task prefix is concealed, the dash and surrounding spaces are visually
 *     collapsed so the line reads like `[checkbox] text`.
 *   - Inactive task lines conceal the markdown prefix and draw a checkbox with CSS on top
 *     of the raw token.
 *   - The active task line falls back to raw markdown prefix rendering (`- [ ] text`) so
 *     caret placement, horizontal motion, and newly created task lines stay understandable.
 *   - Hidden prefix pieces on concealed task lines are exposed to CodeMirror as atomic
 *     ranges so ArrowLeft / ArrowRight try to skip invisible caret positions.
 *   - Task hanging indent is implemented by padding the line and pulling back the checkbox
 *     token span itself, not the hidden dash.
 * - Ordered lists:
 *   - Raw ordered markers are styled into a marker box.
 *   - Hanging indent uses the same safe pattern as bullets, but with a per-line marker-box
 *     width derived from the actual marker text (`1.`, `10.`, `120.`, etc.).
 *   - The same width is fed into both the line padding and the marker pull-back so wrapped
 *     lines align with the text body.
 *
 * Why this is safer than the original implementation:
 * - The browser still lays out the source text normally.
 * - The only geometry tricks are:
 *   - line padding on the start line
 *   - negative margin on the visible marker/token span only
 * - That combination turned out to be tolerated by CodeMirror, whereas hidden-prefix
 *   surgery + negative `text-indent` was not.
 *
 * Important invariants / regression guardrails:
 * - If a change makes `ArrowUp` / `ArrowDown` on wrapped list items unstable, back it out.
 * - Do not reintroduce `Decoration.replace(...)` for checklist tokens in this path.
 * - Do not reintroduce negative `text-indent`.
 * - Do not reintroduce `display:none` on list prefix structure.
 * - Prefer styling the already-present text over replacing or removing it.
 * - Keep inactive task rendering and active task editing as separate concerns; raw prefix
 *   editing on the current line is acceptable if it makes cursor behavior more predictable.
 * - Keep the plugin viewport-scoped and lightweight; do not rebuild complex whole-document
 *   list state unless there is a compelling reason.
 * - When experimenting, change one list kind at a time (bullet, then task, then ordered)
 *   and validate cursor movement after each step.
 *
 * If you modify this later, preserve the main invariant:
 *   cursor movement and scrolling correctness beat visual cleverness.
 */
const LIST_CONTAINER_NAMES = new Set(["BulletList", "OrderedList"]);
const TASK_AFTER_MARK_PATTERN = /^([\t ]*)\[([ xX])\]([\t ]*)(?=\S|$)/;
const VISIBLE_LIST_MARK_PATTERN = /^([\t ]*)([-+*]|\d+[.)])(?=[\t ]|$)/;
const lineDecorationCache = new Map<string, Decoration>();
const markerDecorationCache = new Map<string, Decoration>();
const taskGapDecoration = Decoration.mark({ class: "nv3-list-probe-task-gap" });
const taskAtomicRangeDecoration = Decoration.mark({});

type ListKind = "bullet" | "ordered";

interface ListMarkInfo {
  from: number;
  to: number;
  kind: ListKind;
  markerText: string;
}

function computeListDepth(node: import("@lezer/common").SyntaxNode): number {
  let depth = -1;
  let cursor: import("@lezer/common").SyntaxNode | null = node;

  while (cursor) {
    if (LIST_CONTAINER_NAMES.has(cursor.type.name)) {
      depth += 1;
    }
    cursor = cursor.parent;
  }

  return Math.max(0, depth);
}

function computeListKind(node: import("@lezer/common").SyntaxNode): ListKind {
  let cursor: import("@lezer/common").SyntaxNode | null = node;

  while (cursor) {
    if (cursor.type.name === "OrderedList") return "ordered";
    if (cursor.type.name === "BulletList") return "bullet";
    cursor = cursor.parent;
  }

  return "bullet";
}

function leadingIndentWidth(text: string): number {
  let width = 0;

  for (const char of text) {
    if (char === " ") {
      width += 1;
      continue;
    }

    if (char === "\t") {
      width += 4;
      continue;
    }

    break;
  }

  return width;
}

function fallbackListDepthFromText(text: string): number {
  return Math.max(0, Math.floor(leadingIndentWidth(text) / 4));
}

function detectListMarkFromLine(line: { from: number; text: string }): ListMarkInfo | null {
  const match = line.text.match(VISIBLE_LIST_MARK_PATTERN);
  if (!match) return null;

  const indentation = match[1] ?? "";
  const markerText = match[2] ?? "";
  const kind: ListKind = /^\d/.test(markerText) ? "ordered" : "bullet";
  const from = line.from + indentation.length;
  const to = from + markerText.length;

  return {
    from,
    to,
    kind,
    markerText,
  };
}

function orderedMarkerBoxForText(markerText: string): string {
  if (markerText.length <= 2) return "24px";
  return `calc(${markerText.length}ch + 8px)`;
}

function listLineDecoration(
  depth: number,
  kind: ListKind,
  options: { hangProbe: boolean; taskHangProbe: boolean; orderedHangProbe: boolean; markerBox?: string },
): Decoration {
  const key = `${depth}:${kind}:${options.hangProbe ? "hang" : "plain"}:${options.taskHangProbe ? "task-hang" : "task-plain"}:${options.orderedHangProbe ? `ordered-${options.markerBox ?? "default"}` : "ordered-plain"}`;
  const cached = lineDecorationCache.get(key);
  if (cached) return cached;

  const decoration = Decoration.line({
    attributes: {
      class: [
        "nv3-list-prefix-line",
        `nv3-list-prefix-line-${kind}`,
        options.hangProbe ? "nv3-list-hang-probe-line" : "",
        options.taskHangProbe ? "nv3-list-hang-probe-task-line" : "",
        options.orderedHangProbe ? "nv3-list-hang-probe-ordered-line" : "",
      ]
        .filter(Boolean)
        .join(" "),
      style: [
        `--nv3-list-depth:${depth};`,
        options.orderedHangProbe && options.markerBox
          ? `--nv3-list-hang-marker-box:${options.markerBox};`
          : "",
      ]
        .filter(Boolean)
        .join(""),
    },
  });

  lineDecorationCache.set(key, decoration);
  return decoration;
}

function listMarkerDecoration(
  kind: ListKind,
  isTask: boolean,
  options: { hangProbe: boolean; orderedHangProbe: boolean; markerBox?: string; revealTask?: boolean, bustCache?: boolean },
): Decoration {
  const key = `${kind}:${isTask ? "task" : "plain"}:${options.hangProbe ? "hang" : "plain"}:${options.orderedHangProbe ? `ordered-${options.markerBox ?? "default"}` : "ordered-plain"}`;
  const cached = markerDecorationCache.get(key);
  if (cached && !options.bustCache) return cached;

  const decoration = Decoration.mark({
    attributes: {
      class: [
        "nv3-list-probe-mark",
        `nv3-list-probe-mark-${kind}`,
        isTask ? "nv3-list-probe-mark-task" : "",
        options.hangProbe ? "nv3-list-hang-probe-mark" : "",
        options.orderedHangProbe ? "nv3-list-hang-probe-ordered-mark" : "",
        options.revealTask ? "nv3-list-probe-mark-task-reveal" : "",
      ]
        .filter(Boolean)
        .join(" "),
      style:
        options.orderedHangProbe && options.markerBox
          ? `--nv3-list-hang-marker-box:${options.markerBox};`
          : "",
    },
  });

  markerDecorationCache.set(key, decoration);
  return decoration;
}

function taskTokenDecoration(
  checked: boolean,
  from: number,
  to: number,
  hangProbe: boolean,
): Decoration {
  return Decoration.mark({
    attributes: {
      class: [
        "nv3-list-probe-task-token",
        checked ? "nv3-list-probe-task-token-checked" : "nv3-list-probe-task-token-unchecked",
        hangProbe ? "nv3-list-hang-probe-task-token" : "",
      ]
        .filter(Boolean)
        .join(" "),
      "data-nv3-task-state": checked ? "checked" : "unchecked",
      "data-nv3-task-checkbox": "true",
      "data-nv3-task-from": String(from),
      "data-nv3-task-to": String(to),
    },
  });
}

function buildDecorations(view: import("@codemirror/view").EditorView): {
  decorations: DecorationSet;
  atomicRanges: DecorationSet;
} {
  const state = view.state;
  const ranges: Array<import("@codemirror/state").Range<Decoration>> = [];
  const atomicRangeBuilder = new RangeSetBuilder<Decoration>();
  const selectionRanges = state.selection.ranges.map((range) => ({ from: range.from, to: range.to }));
  const maxVisibleTo = view.visibleRanges.reduce((max, visible) => Math.max(max, visible.to), 0);

  ensureSyntaxTree(state, maxVisibleTo, 50);
  const tree = syntaxTree(state);
  const seenStartLines = new Map<number, { depth: number; kind: ListKind }>();
  const listMarksByLine = new Map<number, ListMarkInfo>();
  const visibleLineNumbers = new Set<number>();

  for (const visible of view.visibleRanges) {
    const fromLine = state.doc.lineAt(visible.from).number;
    const toLine = state.doc.lineAt(Math.max(visible.from, visible.to - 1)).number;
    for (let lineNo = fromLine; lineNo <= toLine; lineNo += 1) {
      visibleLineNumbers.add(lineNo);
    }

    tree.iterate({
      from: visible.from,
      to: visible.to,
      enter(node) {
        if (node.name === "ListItem") {
          const startLine = state.doc.lineAt(node.from).number;
          const next = {
            depth: computeListDepth(node.node),
            kind: computeListKind(node.node),
          };
          const existing = seenStartLines.get(startLine);

          if (!existing || next.depth >= existing.depth) {
            seenStartLines.set(startLine, next);
          }

          return;
        }

        if (node.name !== "ListMark") return;

        const kind = computeListKind(node.node);
        const lineNo = state.doc.lineAt(node.from).number;
        const existing = listMarksByLine.get(lineNo);
        const next = {
          from: node.from,
          to: node.to,
          kind,
          markerText: state.doc.sliceString(node.from, node.to),
        };
        if (!existing || next.from >= existing.from) {
          listMarksByLine.set(lineNo, next);
        }
      },
    });
  }

  for (const lineNo of visibleLineNumbers) {
    const line = state.doc.line(lineNo);
    const fallbackMark = detectListMarkFromLine(line);
    if (!fallbackMark) continue;

    if (!seenStartLines.has(lineNo)) {
      seenStartLines.set(lineNo, {
        depth: fallbackListDepthFromText(line.text),
        kind: fallbackMark.kind,
      });
    }

    if (!listMarksByLine.has(lineNo)) {
      listMarksByLine.set(lineNo, fallbackMark);
    }
  }

  for (const [lineNo, info] of seenStartLines) {
    const line = state.doc.line(lineNo);
    const bulletHangProbe = info.kind === "bullet";

    const mark = listMarksByLine.get(lineNo);
    if (!mark) {
      ranges.push(
        listLineDecoration(info.depth, info.kind, {
          hangProbe: bulletHangProbe,
          taskHangProbe: false,
          orderedHangProbe: false,
        }).range(line.from),
      );
      continue;
    }

    const afterMarkText = line.text.slice(mark.to - line.from);
    const taskMatch = afterMarkText.match(TASK_AFTER_MARK_PATTERN);

    if (!taskMatch) {
      const orderedHangProbe = mark.kind === "ordered";
      const orderedMarkerBox = orderedHangProbe ? orderedMarkerBoxForText(mark.markerText) : undefined;

      ranges.push(
        listLineDecoration(info.depth, info.kind, {
          hangProbe: bulletHangProbe,
          taskHangProbe: false,
          orderedHangProbe,
          markerBox: orderedMarkerBox,
        }).range(line.from),
      );
      ranges.push(
        listMarkerDecoration(mark.kind, false, {
          hangProbe: bulletHangProbe,
          orderedHangProbe,
          markerBox: orderedMarkerBox,
          bustCache: true,
        }).range(mark.from, mark.to),
      );
      continue;
    }

    const leadingWhitespaceLength = taskMatch[1]?.length ?? 0;
    const trailingWhitespaceLength = taskMatch[3]?.length ?? 0;
    const taskFrom = mark.to + leadingWhitespaceLength;
    const taskTo = taskFrom + 3;
    const prefixTo = taskTo + trailingWhitespaceLength;
    const checked = (taskMatch[2] ?? " ") !== " ";
    const revealRawTaskLine = selectionTouchesRange(selectionRanges, line.from, line.to);

    if (revealRawTaskLine) {
      const orderedHangProbe = mark.kind === "ordered";
      const orderedMarkerBox = orderedHangProbe ? orderedMarkerBoxForText(mark.markerText) : undefined;

      ranges.push(
        listLineDecoration(info.depth, info.kind, {
          hangProbe: bulletHangProbe,
          taskHangProbe: false,
          orderedHangProbe,
          markerBox: orderedMarkerBox,
        }).range(line.from),
      );
      ranges.push(
        listMarkerDecoration(mark.kind, false, {
          hangProbe: bulletHangProbe,
          orderedHangProbe,
          markerBox: orderedMarkerBox,
          revealTask: true,
          bustCache: true,
        }).range(mark.from, mark.to),
      );
      continue;
    }

    const taskHangProbe = mark.kind === "bullet";

    ranges.push(
      listLineDecoration(info.depth, info.kind, {
        hangProbe: bulletHangProbe && !taskHangProbe,
        taskHangProbe,
        orderedHangProbe: false,
      }).range(line.from),
    );
    ranges.push(
      listMarkerDecoration(mark.kind, true, {
        hangProbe: false,
        orderedHangProbe: false,
      }).range(mark.from, mark.to),
    );

    if (taskFrom > mark.from) {
      atomicRangeBuilder.add(mark.from, taskFrom, taskAtomicRangeDecoration);
    }

    if (leadingWhitespaceLength > 0) {
      ranges.push(taskGapDecoration.range(mark.to, taskFrom));
    }

    ranges.push(taskTokenDecoration(checked, taskFrom, taskTo, taskHangProbe).range(taskFrom, taskTo));

    if (prefixTo > taskTo) {
      atomicRangeBuilder.add(taskTo, prefixTo, taskAtomicRangeDecoration);
    }

    if (trailingWhitespaceLength > 0) {
      ranges.push(taskGapDecoration.range(taskTo, prefixTo));
    }
  }

  ranges.sort((left, right) => left.from - right.from || left.to - right.to);
  return {
    decorations: Decoration.set(ranges, true),
    atomicRanges: atomicRangeBuilder.finish(),
  };
}

function toggleTaskCheckbox(
  view: import("@codemirror/view").EditorView,
  from: number,
  to: number,
): boolean {
  const marker = view.state.doc.sliceString(from, to);
  if (!/^\[[ xX]\]$/.test(marker)) return false;

  const nextState = marker[1] === " " ? "X" : " ";

  view.dispatch({
    changes: {
      from: from + 1,
      to: from + 2,
      insert: nextState,
    },
  });

  return true;
}

export function createMarkdownListPrefixesExtension(): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      atomicRanges: DecorationSet;

      constructor(view: import("@codemirror/view").EditorView) {
        const built = buildDecorations(view);
        this.decorations = built.decorations;
        this.atomicRanges = built.atomicRanges;
      }

      update(update: ViewUpdate) {
        if (!update.docChanged && !update.viewportChanged && !update.selectionSet) {
          return;
        }

        const built = buildDecorations(update.view);
        this.decorations = built.decorations;
        this.atomicRanges = built.atomicRanges;
      }
    },
    {
      decorations: (pluginValue) => pluginValue.decorations,
      provide: (plugin) =>
        EditorView.atomicRanges.of((view) => view.plugin(plugin)?.atomicRanges ?? Decoration.none),
      eventHandlers: {
        mousedown(event, view) {
          if (event.button !== 0) return;

          const target = resolveEventElement(event.target);
          if (!target) return;

          const checkbox = target.closest(
            ".nv3-list-probe-task-token[data-nv3-task-checkbox='true'][data-nv3-task-from][data-nv3-task-to]",
          );
          if (!(checkbox instanceof HTMLElement) || !view.dom.contains(checkbox)) return;

          event.preventDefault();
          return true;
        },

        click(event, view) {
          if (event.button !== 0) return;

          const target = resolveEventElement(event.target);
          if (!target) return;

          const checkbox = target.closest(
            ".nv3-list-probe-task-token[data-nv3-task-checkbox='true'][data-nv3-task-from][data-nv3-task-to]",
          );
          if (!(checkbox instanceof HTMLElement) || !view.dom.contains(checkbox)) return;

          const from = Number(checkbox.dataset.nv3TaskFrom ?? Number.NaN);
          const to = Number(checkbox.dataset.nv3TaskTo ?? Number.NaN);
          if (!Number.isFinite(from) || !Number.isFinite(to)) return;

          event.preventDefault();
          return toggleTaskCheckbox(view, from, to);
        },
      },
    },
  );
}
