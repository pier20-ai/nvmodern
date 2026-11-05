import { RangeSetBuilder, type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet } from "@codemirror/view";
import { hashHue } from "./scanUtils.ts";
import { resolveDocumentScanIndex, type DocumentScanIndex } from "./documentIndex.ts";
import { trackedDecorationPlugin } from "./scanPlugin.ts";

export interface Nv3TagOccurrence {
  tag: string;
  kind: "hash" | "heading";
  from: number;
  to: number;
  line: number;
}

export interface Nv3TagIndex {
  allTags: string[];
  hashTags: string[];
  headingTags: string[];
  occurrences: Nv3TagOccurrence[];
}

export interface MarkdownTagPluginOptions {
  onChange?: (index: Nv3TagIndex) => void;
}

const hashTagDecoration = Decoration.mark({ class: "nv3-tag nv3-tag-hash" });
const headingTagDecorationCache = new Map<string, Decoration>();

function headingTagDecoration(tagContent: string): Decoration {
  const canonicalKey = (tagContent.split("=")[0] ?? tagContent).toLowerCase();
  const cacheKey = canonicalKey || tagContent;

  const cached = headingTagDecorationCache.get(cacheKey);
  if (cached) return cached;

  const hue = hashHue(cacheKey);
  const decoration = Decoration.mark({
    class: "nv3-tag nv3-tag-heading",
    attributes: { style: `--nv3-tag-hue:${hue};` },
  });

  headingTagDecorationCache.set(cacheKey, decoration);
  return decoration;
}

function indexSignature(index: Nv3TagIndex): string {
  const occSig = index.occurrences
    .map((occ) => `${occ.kind}:${occ.tag}:${occ.from}:${occ.to}`)
    .join("|");
  return `${index.allTags.join(",")}::${occSig}`;
}

export function buildTagDataFromScanIndex(scanIndex: DocumentScanIndex): {
  index: Nv3TagIndex;
  decorations: DecorationSet;
} {
  const builder = new RangeSetBuilder<Decoration>();
  const hashTags = new Set<string>();
  const headingTags = new Set<string>();
  const occurrences: Nv3TagOccurrence[] = [];

  for (const occurrence of scanIndex.tags) {
    hashTags.add(occurrence.tag);
    occurrences.push({ tag: occurrence.tag, kind: "hash", from: occurrence.from, to: occurrence.to, line: occurrence.line });
  }

  for (const occurrence of scanIndex.headingTags) {
    headingTags.add(occurrence.tag);
    occurrences.push({ tag: occurrence.tag, kind: "heading", from: occurrence.from, to: occurrence.to, line: occurrence.line });
  }

  occurrences.sort((left, right) => left.from - right.from || left.kind.localeCompare(right.kind));

  for (const occurrence of occurrences) {
    builder.add(
      occurrence.from,
      occurrence.to,
      occurrence.kind === "hash" ? hashTagDecoration : headingTagDecoration(occurrence.tag),
    );
  }

  const sortedHashTags = [...hashTags].sort((a, b) => a.localeCompare(b));
  const sortedHeadingTags = [...headingTags].sort((a, b) => a.localeCompare(b));
  const allTags = [...new Set([...sortedHashTags, ...sortedHeadingTags])].sort((a, b) => a.localeCompare(b));

  return {
    index: { allTags, hashTags: sortedHashTags, headingTags: sortedHeadingTags, occurrences },
    decorations: builder.finish(),
  };
}

export function createMarkdownTagExtension(options: MarkdownTagPluginOptions = {}): Extension {
  return trackedDecorationPlugin({
    create: (state) => {
      const { index, decorations } = buildTagDataFromScanIndex(resolveDocumentScanIndex(state));
      return { data: index, decorations };
    },
    onChange: options.onChange,
    signature: indexSignature,
  });
}
