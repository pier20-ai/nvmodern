export interface EpubNavigationItem {
  id?: string;
  href?: string;
  label?: string;
  subitems?: EpubNavigationItem[];
}

export interface EpubOutlineItem {
  id: string;
  title: string;
  level: number;
  href: string;
  cfi?: string;
}

export const MAX_EPUB_ARCHIVE_BYTES = 256 * 1024 * 1024;

export function validateEpubArchiveSize(byteLength: number): void {
  if (!Number.isFinite(byteLength) || byteLength < 0 || byteLength > MAX_EPUB_ARCHIVE_BYTES) {
    throw new Error("EPUB exceeds the 256 MB archive limit.");
  }
}

const PUBLISHER_THEME_IDS = new Set(["", "system", "default", "publisher"]);

const BLOCKED_ELEMENT_NAMES = new Set([
  "applet",
  "embed",
  "form",
  "frame",
  "frameset",
  "iframe",
  "object",
  "script",
]);

const BLOCKED_URL_PROTOCOLS = new Set(["javascript:", "vbscript:"]);

export const EPUB_CONTENT_SECURITY_POLICY = [
  "default-src 'none'",
  "script-src 'none'",
  "connect-src 'none'",
  "object-src 'none'",
  "frame-src 'none'",
  "form-action 'none'",
  // EPUB.js replaces the publication's base element with a generated blob URL.
  // Keeping only blob: preserves relative chapter links without allowing a book
  // to redirect resolution to a remote origin.
  "base-uri blob:",
  "style-src 'unsafe-inline' blob: data:",
  "img-src blob: data:",
  "font-src blob: data:",
  "media-src blob: data:",
].join("; ");

export function flattenEpubToc(items: EpubNavigationItem[]): EpubOutlineItem[] {
  const result: EpubOutlineItem[] = [];
  const usedIDs = new Set<string>();

  const visit = (entries: EpubNavigationItem[], level: number) => {
    for (const entry of entries) {
      const href = entry.href?.trim() ?? "";
      const title = entry.label?.trim() || href || "Untitled section";
      if (href) {
        const seed = entry.id?.trim() || `epub-outline-${result.length}`;
        let id = seed;
        let suffix = 2;
        while (usedIDs.has(id)) {
          id = `${seed}-${suffix++}`;
        }
        usedIDs.add(id);
        result.push({ id, title, level, href });
      }
      if (Array.isArray(entry.subitems) && entry.subitems.length > 0) {
        visit(entry.subitems, level + 1);
      }
    }
  };

  visit(items, 1);
  return result;
}

function hrefWithoutFragment(href: string): string {
  return href.split("#", 1)[0] ?? href;
}

export function activeEpubOutlineID(
  outline: EpubOutlineItem[],
  currentHref: string,
): string | undefined {
  const exact = outline.find((item) => item.href === currentHref);
  if (exact) return exact.id;

  const currentPath = hrefWithoutFragment(currentHref);
  return outline.find((item) => hrefWithoutFragment(item.href) === currentPath)?.id;
}

export function isPublisherDefaultEpubTheme(themeID: string | null | undefined): boolean {
  return PUBLISHER_THEME_IDS.has((themeID ?? "").trim().toLowerCase());
}

export function createEpubThemeOverrideCSS(
  themeID: string | null | undefined,
  inspectorCSS: string | null | undefined,
): string | null {
  if (isPublisherDefaultEpubTheme(themeID)) return null;

  const source = inspectorCSS?.trim();
  if (!source) return null;

  return `${source}\n\n${EPUB_THEME_ADAPTER_CSS}`;
}

export function isBlockedEpubElementName(name: string): boolean {
  return BLOCKED_ELEMENT_NAMES.has(name.trim().toLowerCase());
}

export function isBlockedEpubAttribute(name: string, value: string): boolean {
  const normalizedName = name.trim().toLowerCase();
  if (normalizedName.startsWith("on")) return true;
  if (normalizedName === "srcdoc" || normalizedName === "formaction") return true;

  if (["href", "src", "xlink:href", "action"].includes(normalizedName)) {
    const compactValue = value.replace(/[\u0000-\u0020]+/g, "").toLowerCase();
    return [...BLOCKED_URL_PROTOCOLS].some((protocol) => compactValue.startsWith(protocol));
  }

  return false;
}

export function isExternalEpubHref(href: string): boolean {
  const trimmed = href.trim();
  if (!trimmed || trimmed.startsWith("#")) return false;
  return /^(?:https?:|mailto:|tel:)/i.test(trimmed);
}

const EPUB_THEME_ADAPTER_CSS = `
:root {
  color-scheme: light dark;
  background: var(--nv3-color-bg, Canvas) !important;
}
html, body {
  background: var(--nv3-color-bg, Canvas) !important;
  color: var(--nv3-color-text, CanvasText) !important;
  font-family: var(--nv3-font-sans, system-ui, sans-serif) !important;
}
html {
  font-size: var(--nv3-document-scale, 100%) !important;
}
body {
  font-size: 1rem !important;
  box-sizing: border-box;
  max-width: var(--nv3-editor-max-width, none) !important;
  margin-inline: auto !important;
}
h1, h2, h3, h4, h5, h6 {
  color: var(--nv3-md-heading-color, var(--nv3-color-text, CanvasText)) !important;
  font-family: var(--nv3-font-display, var(--nv3-font-sans, system-ui, sans-serif)) !important;
}
a { color: var(--nv3-color-accent, LinkText) !important; }
blockquote {
  color: var(--nv3-color-text-muted, var(--nv3-color-text, CanvasText)) !important;
  border-inline-start-color: var(--nv3-color-border, currentColor) !important;
}
pre, code, kbd, samp {
  color: var(--nv3-md-inline-code-color, var(--nv3-color-text, CanvasText)) !important;
  background: var(--nv3-color-surface, transparent) !important;
  font-family: var(--nv3-font-mono, ui-monospace, monospace) !important;
}
::selection { background: var(--nv3-selection-bg, Highlight) !important; }
`;
