/**
 * Work around stale WebKit paint for CodeMirror's synthetic selection layer.
 *
 * nvModern uses CodeMirror's `drawSelection()` extension, which hides the
 * browser-native selection and paints selected text with absolutely positioned
 * `.cm-selectionBackground` rectangles inside `.cm-selectionLayer`. On
 * WKWebView, collapsing a non-empty selection can remove those DOM rectangles
 * correctly while leaving their old pixels visible in the layer backing store,
 * especially in wrapped-line whitespace and editor negative space. Inspector
 * confirms that the selection state and DOM are already clean when the ghost is
 * visible, so this is a repaint invalidation issue rather than stale editor
 * state.
 *
 * The smallest reliable nudge is to briefly remove the selection layer from
 * layout after a non-empty selection becomes empty. Toggling a class on the
 * layer forces WebKit to rebuild/repaint that layer, clearing the stale pixels
 * without changing CodeMirror selection semantics. We keep the workaround
 * narrowly scoped to that transition so normal selection dragging, scrolling,
 * and cursor blinking stay on CodeMirror's normal path.
 */
import { type Extension } from "@codemirror/state";
import { EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";

const repaintClass = "nv3-selection-layer-repaint";

function hasNonEmptySelection(view: EditorView): boolean {
  return view.state.selection.ranges.some((range) => !range.empty);
}

function repaintSelectionLayer(view: EditorView): void {
  const layer = view.dom.querySelector<HTMLElement>(".cm-selectionLayer");
  const win = view.dom.ownerDocument.defaultView;
  if (!layer || !win) return;

  layer.classList.add(repaintClass);
  win.requestAnimationFrame(() => {
    win.requestAnimationFrame(() => {
      if (layer.isConnected) layer.classList.remove(repaintClass);
    });
  });
}

export function createNv3SelectionLayerRepaintExtension(): Extension {
  return ViewPlugin.fromClass(
    class {
      private hadNonEmptySelection: boolean;

      constructor(view: EditorView) {
        this.hadNonEmptySelection = hasNonEmptySelection(view);
      }

      update(update: ViewUpdate) {
        if (!update.selectionSet) return;

        const hasNonEmpty = hasNonEmptySelection(update.view);
        if (this.hadNonEmptySelection && !hasNonEmpty) {
          repaintSelectionLayer(update.view);
        }
        this.hadNonEmptySelection = hasNonEmpty;
      }
    },
  );
}
