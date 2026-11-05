/**
 * Shared editor interaction/performance state.
 *
 * This gives the library a tiny, framework-agnostic control plane for hot
 * interaction phases like typing or IME composition. Hosts can set the mode
 * without reconfiguring the installed extension graph, and plugins can choose
 * to self-degrade while staying mounted.
 */
import { StateEffect, StateField, type EditorState, type Extension } from "@codemirror/state";
import type { EditorView, ViewUpdate } from "@codemirror/view";

export type Nv3InteractionMode = "idle" | "typing" | "composing";

export const setNv3InteractionModeEffect = StateEffect.define<Nv3InteractionMode>();

export const nv3InteractionModeField = StateField.define<Nv3InteractionMode>({
  create() {
    return "idle";
  },

  update(value, transaction) {
    for (const effect of transaction.effects) {
      if (effect.is(setNv3InteractionModeEffect)) {
        value = effect.value;
      }
    }

    return value;
  },
});

export function createNv3InteractionStateExtension(): Extension {
  return nv3InteractionModeField;
}

export function getNv3InteractionMode(state: EditorState): Nv3InteractionMode | null {
  return state.field(nv3InteractionModeField, false) ?? null;
}

export function resolveNv3InteractionMode(state: EditorState): Nv3InteractionMode {
  return getNv3InteractionMode(state) ?? "idle";
}

export function isNv3InteractionActive(state: EditorState): boolean {
  return resolveNv3InteractionMode(state) !== "idle";
}

export function setNv3InteractionMode(view: EditorView, mode: Nv3InteractionMode): boolean {
  if (resolveNv3InteractionMode(view.state) === mode) {
    return false;
  }

  view.dispatch({
    effects: setNv3InteractionModeEffect.of(mode),
  });
  return true;
}

export function nv3InteractionModeChanged(update: ViewUpdate): boolean {
  return resolveNv3InteractionMode(update.startState) !== resolveNv3InteractionMode(update.state);
}
