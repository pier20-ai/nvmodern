import { arborBlockId, arborPageId } from "./ids.ts";
import {
  parseArborAnchor,
  serializeArborAnchor,
  type ArborAnchor,
} from "./materialization.ts";
import type { ArborOutlineStore } from "./store.ts";
import type {
  ArborBlockId,
  ArborBlockSnapshot,
  ArborPageId,
  ArborSourceDiagnostic,
  ArborSourceParseOptions,
  ArborSourceParseResult,
} from "./types.ts";

const ARBOR_LANGUAGE = "arbor/0";
const LANGUAGE_PATTERN = /^#lang\s+(\S+)\s*$/;
const BLOCK_PATTERN = /^([ \t]*)-\s?(.*)$/;
const CONTINUATION_PATTERN = /^([ \t]*)\|(?:\s(.*))?$/;
const ID_SUFFIX_PATTERN = /^(?:(.*?)\s+)?\^(\S+)\s*$/;

export interface ArborSerializeOptions {
  lang?: string;
}

export interface ArborBlockText {
  readonly text: string;
  readonly anchor?: ArborAnchor;
}

export function parseArborBlockText(value: string): ArborBlockText {
  const match = value.match(ID_SUFFIX_PATTERN);
  const anchor = match ? parseArborAnchor(match[2]!) : null;
  return anchor
    ? { text: match?.[1] ?? "", anchor }
    : { text: value };
}

function fnv1a(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(36).padStart(7, "0");
}

function indentationWidth(value: string): number {
  let width = 0;
  for (const character of value) width += character === "\t" ? 2 : 1;
  return width;
}

function deterministicPageId(title: string): ArborPageId {
  return arborPageId(`p_${fnv1a(title)}`);
}

function deterministicBlockId(
  pageId: ArborPageId,
  line: number,
  depth: number,
  text: string,
  used: ReadonlySet<ArborBlockId>,
): ArborBlockId {
  let salt = 0;
  while (true) {
    const suffix = salt === 0 ? "" : `:${salt}`;
    const id = arborBlockId(`b_${fnv1a(`${pageId}:${line}:${depth}:${text}${suffix}`)}`);
    if (!used.has(id)) return id;
    salt += 1;
  }
}

export function isArborSource(source: string): boolean {
  const firstLine = source.replace(/^\uFEFF/, "").split(/\r?\n/, 1)[0]?.trim() ?? "";
  return firstLine === `#lang ${ARBOR_LANGUAGE}`;
}

export function parseArborSource(
  source: string,
  options: ArborSourceParseOptions = {},
): ArborSourceParseResult {
  const normalized = source.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n");
  const lines = normalized.split("\n");
  const title = options.title ?? "Untitled";
  const pageId = options.pageId ?? deterministicPageId(title);
  const diagnostics: ArborSourceDiagnostic[] = [];
  const synthesizedIds: ArborBlockId[] = [];
  const usedIds = new Set<ArborBlockId>();
  const childrenByParent = new Map<ArborBlockId | null, ArborBlockId[]>([[null, []]]);
  const blocks: ArborBlockSnapshot[] = [];
  const blocksById = new Map<ArborBlockId, ArborBlockSnapshot>();
  const stack: ArborBlockId[] = [];

  const languageMatch = lines[0]?.match(LANGUAGE_PATTERN);
  let bodyStart = 1;
  if (!languageMatch) {
    diagnostics.push({
      severity: "error",
      code: "arbor.missing-language",
      message: `Arbor documents must start with #lang ${ARBOR_LANGUAGE}`,
      line: 1,
      column: 1,
    });
    bodyStart = 0;
  } else if (languageMatch[1] !== ARBOR_LANGUAGE) {
    diagnostics.push({
      severity: "error",
      code: "arbor.unsupported-language",
      message: `Unsupported Arbor language: ${languageMatch[1]}`,
      line: 1,
      column: 1,
    });
  }

  for (let lineIndex = bodyStart; lineIndex < lines.length; lineIndex += 1) {
    const rawLine = lines[lineIndex]!;
    if (rawLine.trim() === "") continue;

    const continuation = rawLine.match(CONTINUATION_PATTERN);
    if (continuation) {
      const width = indentationWidth(continuation[1]!);
      const targetDepth = Math.floor(width / 2) - 1;
      const targetId = targetDepth >= 0 ? stack[targetDepth] : undefined;
      const target = targetId ? blocksById.get(targetId) : undefined;
      if (!target || width % 2 !== 0) {
        diagnostics.push({
          severity: "error",
          code: "arbor.unexpected-line",
          message: "A continuation line must be indented beneath a block",
          line: lineIndex + 1,
          column: 1,
        });
      } else {
        target.text += `\n${continuation[2] ?? ""}`;
      }
      continue;
    }

    const match = rawLine.match(BLOCK_PATTERN);
    if (!match) {
      diagnostics.push({
        severity: "error",
        code: "arbor.unexpected-line",
        message: "Expected an outline block beginning with - or a | continuation",
        line: lineIndex + 1,
        column: 1,
      });
      continue;
    }

    const width = indentationWidth(match[1]!);
    if (width % 2 !== 0) {
      diagnostics.push({
        severity: "warning",
        code: "arbor.invalid-indentation",
        message: "Arbor indentation is canonicalized to two spaces per level",
        line: lineIndex + 1,
        column: 1,
      });
    }
    let depth = Math.floor(width / 2);
    if (depth > stack.length) {
      diagnostics.push({
        severity: "error",
        code: "arbor.indentation-jump",
        message: "Outline indentation cannot skip a parent level",
        line: lineIndex + 1,
        column: 1,
      });
      depth = stack.length;
    }

    const sourceText = match[2]!;
    const idMatch = sourceText.match(ID_SUFFIX_PATTERN);
    const parsedText = parseArborBlockText(sourceText);
    const anchor = parsedText.anchor ?? null;
    const text = anchor ? parsedText.text : sourceText;
    let id = anchor?.id;
    if (idMatch && !anchor) {
      diagnostics.push({
        severity: "error",
        code: "arbor.invalid-anchor",
        message: "Invalid Arbor block anchor metadata",
        line: lineIndex + 1,
        column: Math.max(1, rawLine.lastIndexOf(`^${idMatch[2]}`) + 1),
      });
    }
    if (id && usedIds.has(id)) {
      diagnostics.push({
        severity: "error",
        code: "arbor.duplicate-id",
        message: `Duplicate block id: ${id}`,
        line: lineIndex + 1,
        column: Math.max(1, rawLine.lastIndexOf(`^${id}`) + 1),
      });
      id = undefined;
    }
    if (!id) {
      id = options.idFactory?.blockId() ?? deterministicBlockId(pageId, lineIndex + 1, depth, text, usedIds);
      synthesizedIds.push(id);
    }
    usedIds.add(id);

    const parentId = depth > 0 ? stack[depth - 1] ?? null : null;
    const children = childrenByParent.get(parentId) ?? [];
    children.push(id);
    childrenByParent.set(parentId, children);
    childrenByParent.set(id, []);
    const block: ArborBlockSnapshot = {
      id,
      pageId,
      parentId,
      children: childrenByParent.get(id)!,
      text,
      ...(anchor?.computation ? { computation: anchor.computation } : {}),
    };
    blocks.push(block);
    blocksById.set(id, block);
    stack[depth] = id;
    stack.length = depth + 1;
  }

  return {
    snapshot: {
      version: 1,
      pages: [{ id: pageId, title, children: childrenByParent.get(null)! }],
      blocks,
    },
    pageId,
    diagnostics,
    synthesizedIds,
  };
}

export function serializeArborPage(
  store: ArborOutlineStore,
  pageId: ArborPageId,
  options: ArborSerializeOptions = {},
): string {
  const page = store.getPage(pageId);
  if (!page) throw new Error(`Unknown Arbor page: ${pageId}`);
  const lang = options.lang ?? ARBOR_LANGUAGE;
  const lines = [`#lang ${lang}`];
  const stack: Array<{ id: ArborBlockId; depth: number }> = [];
  let rootId = page.lastChildId;
  while (rootId) {
    stack.push({ id: rootId, depth: 0 });
    rootId = store.getBlock(rootId)?.previousSiblingId ?? null;
  }

  while (stack.length > 0) {
    const { id, depth } = stack.pop()!;
    const block = store.getBlock(id);
    if (!block) throw new Error(`Broken Arbor outline link: ${id}`);
    const indentation = "  ".repeat(depth);
    const textLines = block.text.replace(/\r\n?/g, "\n").split("\n");
    const firstLine = textLines[0] ?? "";
    const anchor = serializeArborAnchor(block.id, block.computation);
    lines.push(`${indentation}- ${firstLine}${firstLine ? " " : ""}^${anchor}`);
    for (let index = 1; index < textLines.length; index += 1) {
      lines.push(`${indentation}  |${textLines[index] ? ` ${textLines[index]}` : ""}`);
    }

    let childId = block.lastChildId;
    while (childId) {
      stack.push({ id: childId, depth: depth + 1 });
      childId = store.getBlock(childId)?.previousSiblingId ?? null;
    }
  }

  return `${lines.join("\n")}\n`;
}
