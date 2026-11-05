import { RangeSetBuilder, Text, type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet } from "@codemirror/view";
import { parseMarkdownFrontmatter } from "./frontmatter.ts";
import {
  createMarkdownScannerContext,
  isMarkdownLineScannable,
  type Nv3ScannerLineContext,
} from "./scannerContext.ts";
import { decorationPlugin } from "./scanPlugin.ts";
import { asPlainObject } from "./viewUtils.ts";

const ATX_HEADING_PREFIX_PATTERN = /^\s{0,3}#{1,6}[ \t]+/;
const HEADING_STATE_TOKEN_PATTERN = /^\[([^\]\n]+)\](?=\s|$)/;

export const DEFAULT_MARKDOWN_HEADER_STATES: Record<string, string> = {
  TODO: "#b58900",
  DOING: "#2563eb",
  DONE: "#2f855a",
  CANCELED: "#6b7280",
  POSTPONED: "#8b5cf6",
};

export interface Nv3MarkdownHeadingStateOccurrence {
  state: string;
  color: string;
  from: number;
  to: number;
  line: number;
}

function normalizeHeadingStateName(input: string): string {
  return input.trim().toUpperCase();
}

export function resolveMarkdownHeaderStates(docText: string): Record<string, string> {
  const result = parseMarkdownFrontmatter(docText);
  const configured = asPlainObject(asPlainObject(result.data)?.header_states);
  if (!configured) return { ...DEFAULT_MARKDOWN_HEADER_STATES };

  const merged: Record<string, string> = { ...DEFAULT_MARKDOWN_HEADER_STATES };
  for (const [rawKey, rawValue] of Object.entries(configured)) {
    const key = normalizeHeadingStateName(rawKey);
    const value = typeof rawValue === "string" ? rawValue.trim() : "";
    if (key && value) merged[key] = value;
  }
  return merged;
}

export function scanMarkdownHeadingStates(
  doc: Text | string,
  headerStates: Readonly<Record<string, string>>,
): Nv3MarkdownHeadingStateOccurrence[] {
  const source = typeof doc === "string" ? Text.of(doc.split(/\r?\n/)) : doc;
  const context = createMarkdownScannerContext(source);
  const occurrences: Nv3MarkdownHeadingStateOccurrence[] = [];

  for (const line of context.lines) {
    if (!isMarkdownLineScannable(line)) continue;
    const prefixMatch = line.text.match(ATX_HEADING_PREFIX_PATTERN);
    if (!prefixMatch) continue;

    const prefix = prefixMatch[0] ?? "";
    const contentText = line.text.slice(prefix.length);
    const match = contentText.match(HEADING_STATE_TOKEN_PATTERN);
    if (!match) continue;

    const rawState = match[1] ?? "";
    const normalizedState = normalizeHeadingStateName(rawState);
    const color = headerStates[normalizedState];
    const token = match[0] ?? "";
    if (!normalizedState || !color || !token) continue;

    occurrences.push({
      state: normalizedState,
      color,
      from: line.from + prefix.length,
      to: line.from + prefix.length + token.length,
      line: line.lineNo,
    });
  }

  return occurrences;
}

function buildHeadingStateDecorations(
  state: import("@codemirror/state").EditorState,
): DecorationSet {
  const docText = state.doc.toString();
  const headerStates = resolveMarkdownHeaderStates(docText);
  const occurrences = scanMarkdownHeadingStates(docText, headerStates);
  const builder = new RangeSetBuilder<Decoration>();

  for (const occurrence of occurrences) {
    builder.add(
      occurrence.from,
      occurrence.to,
      Decoration.mark({
        tagName: "span",
        class: "nv3-heading-state",
        attributes: {
          "data-nv3-heading-state": "true",
          "data-nv3-heading-state-name": occurrence.state,
          style: `--nv3-heading-state-color: ${occurrence.color};`,
        },
      }),
    );
  }

  return builder.finish();
}

export function createMarkdownTodoHeadingsExtension(): Extension {
  return decorationPlugin({ create: buildHeadingStateDecorations });
}
