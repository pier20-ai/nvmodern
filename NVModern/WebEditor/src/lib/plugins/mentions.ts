import { RangeSetBuilder, type Extension } from "@codemirror/state";
import { Decoration, type DecorationSet } from "@codemirror/view";
import { hashHue } from "./scanUtils.ts";
import { resolveDocumentScanIndex } from "./documentIndex.ts";
import { decorationPlugin } from "./scanPlugin.ts";

const mentionDecorationCache = new Map<string, Decoration>();

function mentionDecoration(mention: string): Decoration {
  const canonical = mention.toLowerCase();
  const cached = mentionDecorationCache.get(canonical);
  if (cached) return cached;

  const hue = hashHue(canonical);
  const decoration = Decoration.mark({
    class: "nv3-mention",
    attributes: {
      style: `--nv3-tag-hue:${hue};color:hsl(${hue}, var(--tag-heading-s), var(--tag-heading-l));`,
    },
  });

  mentionDecorationCache.set(canonical, decoration);
  return decoration;
}

function buildMentionDecorations(
  state: import("@codemirror/state").EditorState,
): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  for (const occurrence of resolveDocumentScanIndex(state).mentions) {
    builder.add(occurrence.from, occurrence.to, mentionDecoration(occurrence.mention));
  }
  return builder.finish();
}

export function createMarkdownMentionExtension(): Extension {
  return decorationPlugin({ create: buildMentionDecorations });
}
