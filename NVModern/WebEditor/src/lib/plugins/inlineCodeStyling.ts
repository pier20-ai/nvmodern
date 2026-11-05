import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { RangeSetBuilder, type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet, ViewPlugin, type ViewUpdate } from "@codemirror/view";

const inlineCodeDecoration = Decoration.mark({ class: "nv3-inline-code" });

function buildInlineCodeDecorations(view: import("@codemirror/view").EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const maxVisibleTo = view.visibleRanges.reduce((max, visible) => Math.max(max, visible.to), 0);
  const tree = ensureSyntaxTree(view.state, maxVisibleTo, 50) ?? syntaxTree(view.state);

  for (const visible of view.visibleRanges) {
    tree.iterate({
      from: visible.from,
      to: visible.to,
      enter(node) {
        if (node.name !== "InlineCode") return;

        const syntaxNode = node.node;
        let contentFrom = node.from;
        let contentTo = node.to;

        if (syntaxNode.firstChild?.type.name === "CodeMark") contentFrom = syntaxNode.firstChild.to;
        if (syntaxNode.lastChild?.type.name === "CodeMark") contentTo = syntaxNode.lastChild.from;
        if (contentFrom >= contentTo) return;

        builder.add(contentFrom, contentTo, inlineCodeDecoration);
      },
    });
  }

  return builder.finish();
}

export function createMarkdownInlineCodeStylingExtension(): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;

      constructor(view: import("@codemirror/view").EditorView) {
        this.decorations = buildInlineCodeDecorations(view);
      }

      update(update: ViewUpdate) {
        if (!update.docChanged && !update.viewportChanged) return;
        this.decorations = buildInlineCodeDecorations(update.view);
      }
    },
    { decorations: (v) => v.decorations },
  );
}
