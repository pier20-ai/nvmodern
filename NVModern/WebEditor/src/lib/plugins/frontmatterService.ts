import { isMap, isScalar, parseDocument } from "yaml";
import type { ZodTypeAny } from "zod";

export type Nv3FrontmatterSchema = ZodTypeAny;

export interface Nv3FrontmatterDiagnostic {
  severity: "error" | "warning";
  message: string;
  line?: number;
  column?: number;
  key?: string;
  code?: string;
}

export interface Nv3FrontmatterRange {
  from: number;
  to: number;
  fromLine: number;
  toLine: number;
  closed: boolean;
}

export interface Nv3FrontmatterExtractResult {
  present: boolean;
  raw: string | null;
  range?: Nv3FrontmatterRange;
  parsed?: unknown;
  parseDiagnostics: Nv3FrontmatterDiagnostic[];
  keyLocations: Record<string, { line: number; column: number }>;
}

type ParsedYamlDocument = ReturnType<typeof parseDocument>;

function lineStartOffsets(input: string): number[] {
  const offsets = [0];

  for (let index = 0; index < input.length; index++) {
    if (input[index] === "\n") {
      offsets.push(index + 1);
    }
  }

  return offsets;
}

function lineStart(offsets: readonly number[], lineNo: number, docLength: number): number {
  if (lineNo < 1) return 0;
  return offsets[lineNo - 1] ?? docLength;
}

function offsetToLineCol(input: string, offset: number): { line: number; col: number } {
  const boundedOffset = Math.max(0, Math.min(offset, input.length));

  let line = 1;
  let lineStartOffset = 0;

  for (let index = 0; index < boundedOffset; index++) {
    if (input[index] !== "\n") continue;
    line += 1;
    lineStartOffset = index + 1;
  }

  return {
    line,
    col: boundedOffset - lineStartOffset + 1,
  };
}

function firstLine(input: string): string {
  const newlineIndex = input.indexOf("\n");
  if (newlineIndex < 0) return input;

  const line = input.slice(0, newlineIndex);
  if (line.endsWith("\r")) {
    return line.slice(0, -1);
  }
  return line;
}

function findClosingFrontmatterLine(lines: readonly string[]): number {
  for (let index = 1; index < lines.length; index++) {
    if ((lines[index] ?? "").trim() === "---") {
      return index + 1;
    }
  }
  return -1;
}

function cleanYamlErrorMessage(message: string): string {
  const headline = message.split("\n")[0]?.trim() ?? "YAML parse error";
  return headline.replace(/\s+at line \d+, column \d+:\s*$/u, "");
}

function yamlDiagnostics(
  doc: ParsedYamlDocument,
  contentStartLine: number,
): Nv3FrontmatterDiagnostic[] {
  const diagnostics: Nv3FrontmatterDiagnostic[] = [];

  for (const error of doc.errors) {
    const location = error.linePos?.[0];
    diagnostics.push({
      severity: "error",
      message: cleanYamlErrorMessage(error.message),
      line: location ? contentStartLine + location.line - 1 : undefined,
      column: location?.col,
      code: error.code,
    });
  }

  for (const warning of doc.warnings) {
    const location = warning.linePos?.[0];
    diagnostics.push({
      severity: "warning",
      message: cleanYamlErrorMessage(warning.message),
      line: location ? contentStartLine + location.line - 1 : undefined,
      column: location?.col,
      code: warning.code,
    });
  }

  return diagnostics;
}

function keyLocationsFromDocument(
  doc: ParsedYamlDocument,
  rawFrontmatter: string,
  contentStartLine: number,
): Record<string, { line: number; column: number }> {
  const locations: Record<string, { line: number; column: number }> = {};
  const contents = doc.contents;

  if (!isMap(contents)) {
    return locations;
  }

  for (const entry of contents.items) {
    const keyNode = entry.key;
    if (!keyNode) continue;

    const rawRange = (keyNode as { range?: [number, number, number] }).range;
    const keyOffset = rawRange?.[0];
    if (typeof keyOffset !== "number") continue;

    const keyLineCol = offsetToLineCol(rawFrontmatter, keyOffset);

    let keyName: string | null = null;
    if (isScalar(keyNode) && typeof keyNode.value === "string") {
      keyName = keyNode.value;
    } else {
      const serialized = (keyNode as { toJSON?: () => unknown }).toJSON?.();
      keyName = serialized === undefined ? null : String(serialized);
    }

    if (!keyName || Object.prototype.hasOwnProperty.call(locations, keyName)) {
      continue;
    }

    locations[keyName] = {
      line: contentStartLine + keyLineCol.line - 1,
      column: keyLineCol.col,
    };
  }

  return locations;
}

function parsedValueFromDocument(doc: ParsedYamlDocument): unknown {
  const value = doc.toJS();
  if (value === null) {
    return {};
  }
  return value;
}

export function extractFrontmatter(docText: string): Nv3FrontmatterExtractResult {
  const lines = docText.split(/\r?\n/);
  const initialLine = firstLine(docText).replace(/^\uFEFF/, "").trim();

  if (initialLine !== "---") {
    return {
      present: false,
      raw: null,
      parseDiagnostics: [],
      keyLocations: {},
    };
  }

  const offsets = lineStartOffsets(docText);
  const closingLineNo = findClosingFrontmatterLine(lines);

  if (closingLineNo < 0) {
    return {
      present: true,
      raw: docText.slice(lineStart(offsets, 2, docText.length)),
      parseDiagnostics: [
        {
          severity: "error",
          message: "Frontmatter starts with '---' but does not have a closing '---'.",
          line: 1,
          column: 1,
        },
      ],
      keyLocations: {},
      range: {
        from: 0,
        to: docText.length,
        fromLine: 1,
        toLine: lines.length,
        closed: false,
      },
    };
  }

  const rawStart = lineStart(offsets, 2, docText.length);
  const rawEnd = lineStart(offsets, closingLineNo, docText.length);
  const rangeEnd = lineStart(offsets, closingLineNo + 1, docText.length);
  const raw = docText.slice(rawStart, rawEnd);

  const yamlDocument = parseDocument(raw, {
    prettyErrors: true,
  });

  const parseDiagnostics = yamlDiagnostics(yamlDocument, 2);
  const hasParseErrors = parseDiagnostics.some((diagnostic) => diagnostic.severity === "error");

  return {
    present: true,
    raw,
    parsed: hasParseErrors ? undefined : parsedValueFromDocument(yamlDocument),
    parseDiagnostics,
    keyLocations: hasParseErrors ? {} : keyLocationsFromDocument(yamlDocument, raw, 2),
    range: {
      from: 0,
      to: rangeEnd,
      fromLine: 1,
      toLine: closingLineNo,
      closed: true,
    },
  };
}

export function validateFrontmatter(
  parsed: unknown,
  schema: Nv3FrontmatterSchema,
  keyLocations: Record<string, { line: number; column: number }> = {},
): Nv3FrontmatterDiagnostic[] {
  const validationResult = schema.safeParse(parsed);
  if (validationResult.success) {
    return [];
  }

  return validationResult.error.issues.map((issue) => {
    const firstPath = issue.path[0];
    const key = typeof firstPath === "string" ? firstPath : undefined;
    const location = key ? keyLocations[key] : undefined;
    const pathLabel = issue.path.length > 0 ? issue.path.map(String).join(".") : null;

    return {
      severity: "error" as const,
      key,
      line: location?.line,
      column: location?.column,
      message: pathLabel ? `${pathLabel}: ${issue.message}` : issue.message,
      code: issue.code,
    };
  });
}
