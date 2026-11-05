import { RangeSetBuilder, type EditorState, type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet } from "@codemirror/view";
import { resolveDocumentScanIndex } from "./documentIndex.ts";
import { trackedDecorationPlugin } from "./scanPlugin.ts";

export interface Nv3CodeBlock {
  fromLine: number;
  toLine: number;
  language: string | null;
  closed: boolean;
}

export interface Nv3CodeBlockIndex {
  count: number;
  blocks: Nv3CodeBlock[];
}

export interface MarkdownCodeFenceOptions {
  onChange?: (index: Nv3CodeBlockIndex) => void;
}

function codeBlockSignature(index: Nv3CodeBlockIndex): string {
  return index.blocks
    .map((block) => `${block.fromLine}-${block.toLine}:${block.language ?? ""}:${block.closed ? 1 : 0}`)
    .join("|");
}

function decorateFenceLanguage(
  line: import("@codemirror/state").Line,
  lineText: string,
  language: string,
  builder: RangeSetBuilder<Decoration>,
): void {
  const fencePos = lineText.indexOf("```");
  if (fencePos < 0) return;
  const languagePos = lineText.indexOf(language, fencePos + 3);
  if (languagePos < 0) return;
  const from = line.from + languagePos;
  builder.add(from, from + language.length, Decoration.mark({ class: "nv3-code-fence-language" }));
}

function buildCodeFenceData(state: EditorState): {
  data: Nv3CodeBlockIndex;
  decorations: DecorationSet;
} {
  const builder = new RangeSetBuilder<Decoration>();
  const scanIndex = resolveDocumentScanIndex(state);

  const blocks: Nv3CodeBlock[] = scanIndex.codeBlocks.map((block) => ({
    fromLine: block.fromLine,
    toLine: block.toLine,
    language: block.language,
    closed: block.closed,
  }));

  for (const block of blocks) {
    if (block.fromLine < 1 || block.fromLine > state.doc.lines) continue;

    const startLine = state.doc.line(block.fromLine);
    builder.add(startLine.from, startLine.from, Decoration.line({ class: "nv3-code-fence-line nv3-code-fence-start" }));
    if (block.language) decorateFenceLanguage(startLine, startLine.text, block.language, builder);

    if (block.closed) {
      for (let lineNo = block.fromLine + 1; lineNo < block.toLine; lineNo++) {
        if (lineNo < 1 || lineNo > state.doc.lines) continue;
        const line = state.doc.line(lineNo);
        builder.add(line.from, line.from, Decoration.line({ class: "nv3-code-fence-line nv3-code-fence-body" }));
      }
      if (block.toLine >= 1 && block.toLine <= state.doc.lines) {
        const endLine = state.doc.line(block.toLine);
        builder.add(endLine.from, endLine.from, Decoration.line({ class: "nv3-code-fence-line nv3-code-fence-end" }));
      }
      continue;
    }

    for (let lineNo = block.fromLine + 1; lineNo <= block.toLine; lineNo++) {
      if (lineNo < 1 || lineNo > state.doc.lines) continue;
      const line = state.doc.line(lineNo);
      builder.add(line.from, line.from, Decoration.line({ class: "nv3-code-fence-line nv3-code-fence-body" }));
    }
  }

  return { data: { count: blocks.length, blocks }, decorations: builder.finish() };
}

export function createMarkdownCodeFenceExtension(options: MarkdownCodeFenceOptions = {}): Extension {
  return trackedDecorationPlugin({
    create: buildCodeFenceData,
    onChange: options.onChange,
    signature: codeBlockSignature,
  });
}
