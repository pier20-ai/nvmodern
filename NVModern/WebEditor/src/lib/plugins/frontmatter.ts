import { RangeSetBuilder, type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet } from "@codemirror/view";
import { z } from "zod";
import {
  extractFrontmatter,
  validateFrontmatter,
  type Nv3FrontmatterDiagnostic,
  type Nv3FrontmatterRange,
  type Nv3FrontmatterSchema,
} from "./frontmatterService.ts";
import { trackedDecorationPlugin } from "./scanPlugin.ts";
import { asPlainObject } from "./viewUtils.ts";

export {
  extractFrontmatter,
  validateFrontmatter,
  type Nv3FrontmatterDiagnostic,
  type Nv3FrontmatterRange,
  type Nv3FrontmatterSchema,
};

export interface Nv3FrontmatterResult {
  present: boolean;
  valid: boolean;
  data: Record<string, unknown> | null;
  diagnostics: Nv3FrontmatterDiagnostic[];
  raw: string | null;
  range?: Nv3FrontmatterRange;
}

export interface MarkdownFrontmatterOptions {
  schema?: Nv3FrontmatterSchema;
  onChange?: (result: Nv3FrontmatterResult) => void;
}

export const defaultNv3FrontmatterSchema = z
  .object({
    title: z.string().optional(),
    tags: z.array(z.string()).optional(),
    date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Expected date in YYYY-MM-DD format").optional(),
    draft: z.boolean().optional(),
    summary: z.string().optional(),
    header_states: z.record(z.string(), z.string()).optional(),
  })
  .passthrough();

export function parseMarkdownFrontmatter(
  docText: string,
  schema?: Nv3FrontmatterSchema,
): Nv3FrontmatterResult {
  const extraction = extractFrontmatter(docText);

  if (!extraction.present) {
    return { present: false, valid: true, data: null, diagnostics: [], raw: null };
  }

  const diagnostics: Nv3FrontmatterDiagnostic[] = [...extraction.parseDiagnostics];
  if (schema && extraction.parsed !== undefined) {
    diagnostics.push(...validateFrontmatter(extraction.parsed, schema, extraction.keyLocations));
  }

  return {
    present: true,
    valid: diagnostics.every((d) => d.severity !== "error"),
    data: asPlainObject(extraction.parsed),
    diagnostics,
    raw: extraction.raw,
    range: extraction.range,
  };
}

function frontmatterDecorations(
  doc: import("@codemirror/state").Text,
  result: Nv3FrontmatterResult,
): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();

  if (!result.present || !result.range) return builder.finish();

  const errorLines = new Set<number>();
  for (const diagnostic of result.diagnostics) {
    if (diagnostic.severity !== "error" || typeof diagnostic.line !== "number") continue;
    errorLines.add(diagnostic.line);
  }

  for (let lineNo = result.range.fromLine; lineNo <= result.range.toLine; lineNo++) {
    if (lineNo < 1 || lineNo > doc.lines) continue;
    const line = doc.line(lineNo);
    const classes = ["nv3-frontmatter-line"];
    if (lineNo === result.range.fromLine) classes.push("nv3-frontmatter-start");
    if (lineNo === result.range.toLine && result.range.closed) classes.push("nv3-frontmatter-end");
    if (errorLines.has(lineNo)) classes.push("nv3-frontmatter-line-error");
    builder.add(line.from, line.from, Decoration.line({ class: classes.join(" ") }));
  }

  return builder.finish();
}

function frontmatterSignature(result: Nv3FrontmatterResult): string {
  return JSON.stringify(result);
}

export function createMarkdownFrontmatterExtension(options: MarkdownFrontmatterOptions = {}): Extension {
  const { schema, onChange } = options;

  return trackedDecorationPlugin({
    create: (state) => {
      const result = parseMarkdownFrontmatter(state.doc.toString(), schema);
      return { data: result, decorations: frontmatterDecorations(state.doc, result) };
    },
    onChange,
    signature: frontmatterSignature,
  });
}
