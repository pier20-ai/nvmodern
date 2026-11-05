/**
 * Task checkbox detection utility.
 *
 * The interactive checkbox rendering lives in `listPrefixes.ts` (CSS-based
 * approach). This file only provides the `detectMarkdownTaskCheckboxes`
 * scanning function used by external consumers.
 */
import { scanMarkdownText } from "./markdownScanner.ts";

export interface Nv3TaskCheckboxOccurrence {
  from: number;
  to: number;
  line: number;
  checked: boolean;
}

export function detectMarkdownTaskCheckboxes(docText: string): Nv3TaskCheckboxOccurrence[] {
  return scanMarkdownText(docText).taskCheckboxOccurrences.map((o) => ({
    from: o.from,
    to: o.to,
    line: o.line,
    checked: o.checked,
  }));
}
