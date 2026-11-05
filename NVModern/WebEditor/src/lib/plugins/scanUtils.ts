export interface TextRange {
  from: number;
  to: number;
}

export function isEscaped(input: string, index: number): boolean {
  let backslashCount = 0;
  for (let cursor = index - 1; cursor >= 0; cursor--) {
    if (input[cursor] !== "\\") break;
    backslashCount += 1;
  }
  return backslashCount % 2 === 1;
}

/**
 * Finds inline-code spans (`...`) within a single line.
 *
 * We intentionally keep this scanner lightweight and line-local for performance.
 */
export function findInlineCodeRanges(lineText: string): TextRange[] {
  const ranges: TextRange[] = [];

  for (let index = 0; index < lineText.length; index++) {
    if (lineText[index] !== "`") continue;

    let tickCount = 1;
    while (lineText[index + tickCount] === "`") tickCount += 1;

    const openStart = index;
    const openEnd = index + tickCount;

    let closeStart = -1;
    let closeEnd = -1;

    for (let cursor = openEnd; cursor < lineText.length; cursor++) {
      if (lineText[cursor] !== "`") continue;

      let closeTicks = 1;
      while (lineText[cursor + closeTicks] === "`") closeTicks += 1;

      if (closeTicks !== tickCount) {
        cursor += closeTicks - 1;
        continue;
      }

      closeStart = cursor;
      closeEnd = cursor + closeTicks;
      break;
    }

    if (closeStart === -1 || closeEnd === -1) {
      index = openEnd - 1;
      continue;
    }

    ranges.push({ from: openStart, to: closeEnd });
    index = closeEnd - 1;
  }

  return ranges;
}

export function rangeContainsIndex(ranges: readonly TextRange[], index: number): boolean {
  for (const range of ranges) {
    if (index >= range.from && index < range.to) {
      return true;
    }
  }
  return false;
}

export function hasRangeOverlap(
  ranges: readonly TextRange[],
  from: number,
  to: number,
): boolean {
  for (const range of ranges) {
    if (from < range.to && to > range.from) {
      return true;
    }
  }
  return false;
}

// ── Character classification ──────────────────────────────────────────────

export function isDigit(char: string | undefined): boolean {
  if (!char) return false;
  return char >= "0" && char <= "9";
}

export function isWordLike(char: string | undefined): boolean {
  if (!char) return false;
  return /[A-Za-z0-9_]/.test(char);
}

export function isWhitespace(char: string | undefined): boolean {
  if (!char) return true;
  return /\s/.test(char);
}

// ── Regex helpers ─────────────────────────────────────────────────────────

/** Advances a global regex past a zero-width match to prevent infinite loops. */
export function resetIfStalled(pattern: RegExp, match: RegExpExecArray): void {
  if (pattern.lastIndex === match.index) {
    pattern.lastIndex += 1;
  }
}

// ── Hashing ───────────────────────────────────────────────────────────────

/** Deterministic hue (0–359) from a string. Used for tag/mention chip colors. */
export function hashHue(input: string): number {
  let hash = 0;
  for (let index = 0; index < input.length; index++) {
    hash = input.charCodeAt(index) + ((hash << 5) - hash);
    hash |= 0;
  }
  return Math.abs(hash) % 360;
}

// ── Frontmatter ───────────────────────────────────────────────────────────

export interface FrontmatterBounds {
  fromLine: number;
  toLine: number;
  closed: boolean;
}

export function detectFrontmatterBounds(
  doc: import("@codemirror/state").Text,
): FrontmatterBounds | null {
  if (doc.lines < 1) return null;

  const firstLine = doc.line(1).text.trim();
  if (firstLine !== "---") return null;

  for (let lineNo = 2; lineNo <= doc.lines; lineNo++) {
    if (doc.line(lineNo).text.trim() === "---") {
      return {
        fromLine: 1,
        toLine: lineNo,
        closed: true,
      };
    }
  }

  return {
    fromLine: 1,
    toLine: doc.lines,
    closed: false,
  };
}
