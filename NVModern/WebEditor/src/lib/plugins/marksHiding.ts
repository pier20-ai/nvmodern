import { syntaxTree } from "@codemirror/language";
import { RangeSetBuilder, type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { selectionTouchesRange } from "./viewUtils.ts";

const hiddenMarkDecoration = Decoration.mark({ class: "nv3-hidden-mark" });

function buildHiddenMarksDecorations(
  view: import("@codemirror/view").EditorView,
): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const tree = syntaxTree(view.state);
  const ranges = view.state.selection.ranges;

  for (const visible of view.visibleRanges) {
    tree.iterate({
      from: visible.from,
      to: visible.to,
      enter(node) {
        const parent = node.node.parent;
        if (!parent) return;
        if (selectionTouchesRange(ranges, parent.from, parent.to)) return;

        switch (node.name) {
          case "EmphasisMark":
            builder.add(node.from, node.to, hiddenMarkDecoration);
            return;
          case "CodeMark":
            if (parent.type.name === "InlineCode") {
              builder.add(node.from, node.to, hiddenMarkDecoration);
            }
            return;
        }
      },
    });
  }

  return builder.finish();
}

export function createMarkdownMarksHidingExtension(): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;

      constructor(view: import("@codemirror/view").EditorView) {
        this.decorations = buildHiddenMarksDecorations(view);
      }

      update(update: ViewUpdate) {
        if (!update.docChanged && !update.viewportChanged && !update.selectionSet) return;
        this.decorations = buildHiddenMarksDecorations(update.view);
      }
    },
    { decorations: (v) => v.decorations },
  );
}
