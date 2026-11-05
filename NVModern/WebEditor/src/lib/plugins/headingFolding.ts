import { codeFolding, foldService, type FoldConfig } from "@codemirror/language";
import type { EditorState, Extension } from "@codemirror/state";
import { collectMarkdownHeadingSections } from "./headings.ts";

/**
 * Markdown heading-section folding.
 *
 * Historical context:
 * - The editor already had `foldKeymap` wired up, but no actual folding service for
 *   Markdown headings, so the key bindings had nothing useful to fold here.
 * - Earlier heading concealment experiments focused on hiding or shifting `#` prefixes.
 *   Those experiments showed that custom visual collapsing can easily fight CodeMirror's
 *   cursor and coordinate model when it removes structural text or changes whole-line
 *   geometry.
 * - For section collapse, the safer approach is to reuse CM's built-in folding state and
 *   placeholder machinery rather than inventing a custom hidden-body widget path.
 *
 * Current strategy:
 * - Compute heading sections with `collectMarkdownHeadingSections(...)`.
 * - Register a `foldService` that makes each heading line foldable.
 * - Fold only the body of the heading section, not the heading line itself.
 * - A section extends from the end of the heading line to just before the next heading
 *   of the same or higher level.
 * - Skip empty / whitespace-only sections so headings with no real body don't expose a
 *   meaningless fold target.
 * - Let CodeMirror own fold state, placeholder rendering, and keyboard commands.
 *
 * Why this is safer:
 * - CM's built-in fold state already handles selection interactions and placeholder
 *   replacement consistently.
 * - The heading prefix plugin can simply toggle CM fold effects instead of trying to hide
 *   section bodies itself.
 * - The folding logic stays purely range-based and document-driven.
 *
 * Important invariants / regression guardrails:
 * - The fold range must start after the heading line, never on the heading text itself.
 * - Do not treat fenced-code pseudo-headings or frontmatter lines as headings; rely on
 *   the shared heading-section collector for this.
 * - If fold/unfold starts causing stale state or cursor glitches, prefer fixing the range
 *   computation or host view lifecycle before adding custom placeholder hacks here.
 */
function resolveMarkdownHeadingFoldRange(
  state: EditorState,
  lineStart: number,
  lineEnd: number,
): { from: number; to: number } | null {
  const line = state.doc.lineAt(lineStart);
  if (line.from !== lineStart || line.to !== lineEnd) {
    return null;
  }

  const sections = collectMarkdownHeadingSections(state);
  const section = sections.find((candidate) => candidate.from === line.from);
  if (!section) return null;
  if (section.bodyTo <= section.bodyFrom) return null;

  const foldBodyText = state.doc.sliceString(section.bodyFrom, section.bodyTo);
  if (!foldBodyText.trim()) return null;

  return {
    from: section.bodyFrom,
    to: section.bodyTo,
  };
}

const defaultHeadingFoldConfig: FoldConfig = {
  placeholderText: "…",
};

export function createMarkdownHeadingFoldingExtension(
  config: FoldConfig = defaultHeadingFoldConfig,
): Extension {
  return [
    codeFolding(config),
    foldService.of(resolveMarkdownHeadingFoldRange),
  ];
}
