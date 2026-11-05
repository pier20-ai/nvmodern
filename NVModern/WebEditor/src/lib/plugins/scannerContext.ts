import type { Text } from "@codemirror/state";
import {
  detectFrontmatterBounds,
  findInlineCodeRanges,
  type FrontmatterBounds,
  type TextRange,
} from "./scanUtils.ts";

const FENCE_PATTERN = /^\s*```/;

export interface Nv3ScannerLineContext {
  lineNo: number;
  from: number;
  to: number;
  text: string;
  inFrontmatter: boolean;
  inFence: boolean;
  isFenceDelimiter: boolean;
  inlineCodeRanges: TextRange[];
}

export interface Nv3MarkdownScannerContext {
  doc: Text;
  frontmatter: FrontmatterBounds | null;
  lines: Nv3ScannerLineContext[];
}

export function isMarkdownLineScannable(line: Nv3ScannerLineContext): boolean {
  return !line.inFrontmatter && !line.inFence && !line.isFenceDelimiter;
}

export function createMarkdownScannerContext(doc: Text): Nv3MarkdownScannerContext {
  const frontmatter = detectFrontmatterBounds(doc);
  const lines: Nv3ScannerLineContext[] = [];

  const isFrontmatterLine = (lineNo: number): boolean => {
    return Boolean(frontmatter && lineNo >= frontmatter.fromLine && lineNo <= frontmatter.toLine);
  };

  let inFence = false;

  for (let lineNo = 1; lineNo <= doc.lines; lineNo++) {
    const line = doc.line(lineNo);
    const inFrontmatter = isFrontmatterLine(lineNo);
    const isFenceDelimiter = !inFrontmatter && FENCE_PATTERN.test(line.text);

    lines.push({
      lineNo,
      from: line.from,
      to: line.to,
      text: line.text,
      inFrontmatter,
      inFence,
      isFenceDelimiter,
      inlineCodeRanges:
        inFrontmatter || inFence || isFenceDelimiter ? [] : findInlineCodeRanges(line.text),
    });

    if (isFenceDelimiter) {
      inFence = !inFence;
    }
  }

  return {
    doc,
    frontmatter,
    lines,
  };
}
