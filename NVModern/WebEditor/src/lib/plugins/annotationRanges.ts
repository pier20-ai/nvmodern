import type { Text } from "@codemirror/state";

const BLOCK_MARKER = /^\s*(?:(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?|>\s?|#{1,6}\s+)/;

/**
 * Start a mark after a block marker (list bullet or number, task box, quote,
 * heading hashes) when it would otherwise begin on one. Those markers are
 * drawn by their own decorations, and a badge in front of them breaks the
 * list or heading layout.
 */
export function nv3AnnotationStart(doc: Text, from: number, to: number): number {
  const line = doc.lineAt(from);
  const marker = BLOCK_MARKER.exec(line.text);
  if (!marker) return from;
  const markerEnd = line.from + marker[0].length;
  return from < markerEnd && markerEnd < to ? markerEnd : from;
}
