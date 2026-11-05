import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { selectionTouchesRange } from "./viewUtils.ts";

const horizontalRuleLineDecoration = Decoration.line({ class: "nv3-horizontal-rule-line" });
const activeHorizontalRuleLineDecoration = Decoration.line({
  class: "nv3-horizontal-rule-line nv3-horizontal-rule-active",
});
const horizontalRuleMarkDecoration = Decoration.mark({ class: "nv3-horizontal-rule-mark" });
const activeHorizontalRuleMarkDecoration = Decoration.mark({
  class: "nv3-horizontal-rule-mark nv3-horizontal-rule-active",
});

function buildHorizontalRuleDecorations(view: import("@codemirror/view").EditorView): DecorationSet {
  const ranges: Array<import("@codemirror/state").Range<Decoration>> = [];
  const maxVisibleTo = view.visibleRanges.reduce((max, visible) => Math.max(max, visible.to), 0);
  const tree = ensureSyntaxTree(view.state, maxVisibleTo, 50) ?? syntaxTree(view.state);
  const selectionRanges = view.state.selection.ranges;

  for (const visible of view.visibleRanges) {
    tree.iterate({
      from: visible.from,
      to: visible.to,
      enter(node) {
        if (node.name !== "HorizontalRule") return;

        const active = selectionTouchesRange(selectionRanges, node.from, node.to);
        const line = view.state.doc.lineAt(node.from);

        ranges.push((active ? activeHorizontalRuleLineDecoration : horizontalRuleLineDecoration).range(line.from));
        ranges.push((active ? activeHorizontalRuleMarkDecoration : horizontalRuleMarkDecoration).range(node.from, node.to));
      },
    });
  }

  return Decoration.set(ranges, true);
}

export function createMarkdownHorizontalRuleExtension(): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;

      constructor(view: import("@codemirror/view").EditorView) {
        this.decorations = buildHorizontalRuleDecorations(view);
      }

      update(update: ViewUpdate) {
        if (!update.docChanged && !update.viewportChanged && !update.selectionSet) return;
        this.decorations = buildHorizontalRuleDecorations(update.view);
      }
    },
    { decorations: (plugin) => plugin.decorations },
  );
}
