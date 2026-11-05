/**
 * Shared DOM/view utilities for CM6 plugins.
 *
 * These helpers are used across many decoration plugins. Keeping them in one
 * place eliminates duplication and ensures consistent behavior.
 */

/**
 * Tests whether any selection range touches the half-open interval [from, to].
 * Used by decoration plugins to reveal raw markup on the active line.
 */
export function selectionTouchesRange(
  ranges: readonly { from: number; to: number }[],
  from: number,
  to: number,
): boolean {
  for (const range of ranges) {
    if (range.from === range.to) {
      if (range.from >= from && range.from <= to) return true;
      continue;
    }
    if (range.from <= to && range.to >= from) return true;
  }
  return false;
}

/**
 * Resolves an event target to the nearest Element.
 * Handles text nodes and other non-Element targets.
 */
export function resolveEventElement(target: EventTarget | null): Element | null {
  if (!target) return null;
  if (target instanceof Element) return target;
  if (target instanceof Node) return target.parentElement;
  return null;
}

/** Focus the editor content without scrolling. */
export function focusEditorWithoutScroll(view: import("@codemirror/view").EditorView): void {
  try {
    (view.contentDOM as HTMLElement).focus({ preventScroll: true });
  } catch {
    view.focus();
  }
}

/** Safely cast `unknown` to a plain object, returning null for arrays and primitives. */
export function asPlainObject(value: unknown): Record<string, unknown> | null {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return null;
}
