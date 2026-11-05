/**
 * Inline image preview for Markdown `![alt](url)` syntax.
 *
 * 1. **Preview**  — block widget below each `![…](…)` showing the image.
 * 2. **Conceal**  — hides raw syntax when cursor is elsewhere, showing only
 *    a small caption derived from the alt text.
 * 3. **Paste**    — intercepts clipboard image data, delegates to the host
 *    via `onImagePaste` callback, inserts the returned path.
 *
 * This file is **framework-agnostic** — it must not import from the bridge,
 * the nvModern adapter, or any app-specific code.
 */

import { type EditorState, type Extension, StateField } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  ViewPlugin,
  WidgetType,
  type ViewUpdate,
} from "@codemirror/view";
import { resolveDocumentScanIndex } from "./documentIndex.ts";
import { selectionTouchesRange } from "./viewUtils.ts";

// ── Constants ───────────────────────────────────────────────────────────────

/** URLs we can hand straight to `<img src>` without a resolver. */
const DIRECT_URL_RE = /^(?:https?:\/\/|data:image\/)/i;

/** Maximum clipboard file size (bytes) we accept for paste. */
const MAX_PASTE_FILE_BYTES = 10 * 1024 * 1024; // 10 MB

// ── Options ─────────────────────────────────────────────────────────────────

export interface MarkdownImagePreviewOptions {
  /**
   * Resolve a relative / local image path to a URL the browser can load.
   * Called only for paths that are NOT already http/https/data: URLs.
   * `filePath` is the current note path, allowing callers to resolve
   * note-relative assets before returning a displayable URL.
   * Return `null` to skip preview for that path.
   */
  resolveImageUrl?: (src: string, filePath?: string) => string | null;

  /** Current note path, passed through to `resolveImageUrl`. */
  filePath?: string;

  /**
   * Handle an image paste from the clipboard.
   * Receives raw base64 data (no `data:` prefix) and the MIME type.
   * Should save the image and return the relative path to insert
   * (e.g. `.attachments/20260322-193742-a4f2.png`), or `null` to cancel.
   */
  onImagePaste?: (data: string, mimeType: string) => Promise<string | null>;

  /** Enable clipboard image paste. Default: `true`. */
  enablePaste?: boolean;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Strip an optional Markdown title from an image URL.
 * `![alt](url "title")` → url portion only.
 * Data-URIs are returned as-is.
 */
function stripMarkdownTitle(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.startsWith("data:")) return trimmed;
  const m = trimmed.match(/^(\S+)\s+(?:"[^"]*"|'[^']*')$/);
  return m ? m[1]! : trimmed;
}

/** Resolve an image target to a displayable src, or null. */
function resolvePreviewSrc(
  target: string,
  resolver?: (src: string, filePath?: string) => string | null,
  filePath?: string,
): string | null {
  const url = stripMarkdownTitle(target);
  if (DIRECT_URL_RE.test(url)) return url;
  if (resolver) return resolver(url, filePath);
  return null;
}

/** Extract the alt text from `![alt](…)` given the token range. */
function extractImageAlt(state: EditorState, from: number, to: number): string {
  const text = state.sliceDoc(from, to);
  const m = text.match(/^!\[([^\]]*)\]/);
  return m?.[1] ?? "";
}

// ── Preview widget ──────────────────────────────────────────────────────────

class ImagePreviewWidget extends WidgetType {
  constructor(
    readonly src: string,
    readonly alt: string,
  ) {
    super();
  }

  override eq(other: ImagePreviewWidget): boolean {
    return other.src === this.src && other.alt === this.alt;
  }

  override toDOM(): HTMLElement {
    const wrapper = document.createElement("div");
    wrapper.className = "nv3-image-preview";
    wrapper.setAttribute("contenteditable", "false");

    const img = document.createElement("img");
    img.className = "nv3-image-preview-img";
    img.src = this.src;
    img.alt = this.alt;
    img.draggable = false;
    img.loading = "lazy";

    img.addEventListener("load", () => {
      wrapper.classList.add("nv3-image-preview-loaded");
    });

    img.addEventListener("error", () => {
      wrapper.classList.add("nv3-image-preview-error");
      img.style.display = "none";
      const msg = document.createElement("span");
      msg.className = "nv3-image-preview-error-msg";
      msg.textContent = "\u26A0 Image failed to load";
      wrapper.appendChild(msg);
    });

    wrapper.appendChild(img);
    return wrapper;
  }

  override ignoreEvent(): boolean {
    return true;
  }

  override get estimatedHeight(): number {
    return 200;
  }
}

// ── Block decoration (StateField) ───────────────────────────────────────────

function buildBlockDecorations(
  state: EditorState,
  resolver?: (src: string, filePath?: string) => string | null,
  filePath?: string,
): DecorationSet {
  const scanIndex = resolveDocumentScanIndex(state);
  const ranges: Array<import("@codemirror/state").Range<Decoration>> = [];

  for (const link of scanIndex.links) {
    if (link.kind !== "preview") continue;

    const src = resolvePreviewSrc(link.target, resolver, filePath);
    if (!src) continue;

    const alt = extractImageAlt(state, link.from, link.to);
    const lineEnd = state.doc.lineAt(link.from).to;

    ranges.push(
      Decoration.widget({
        widget: new ImagePreviewWidget(src, alt),
        block: true,
        side: 1,
      }).range(lineEnd),
    );
  }

  return Decoration.set(ranges, true);
}

// ── Syntax hiding (ViewPlugin — selection-sensitive) ────────────────────────

const hiddenSyntaxDeco = Decoration.mark({ class: "nv3-image-syntax-hidden" });
const captionDeco = Decoration.mark({ class: "nv3-image-caption" });

function buildSyntaxHidingDecorations(
  state: EditorState,
  resolver?: (src: string, filePath?: string) => string | null,
  filePath?: string,
): DecorationSet {
  const scanIndex = resolveDocumentScanIndex(state);
  const ranges: Array<import("@codemirror/state").Range<Decoration>> = [];
  const sel = state.selection.ranges;

  for (const link of scanIndex.links) {
    if (link.kind !== "preview") continue;

    // Only hide syntax for images we can actually preview.
    const src = resolvePreviewSrc(link.target, resolver, filePath);
    if (!src) continue;

    // When cursor touches the image line, reveal raw syntax.
    if (selectionTouchesRange(sel, link.from, link.to)) continue;

    const text = state.sliceDoc(link.from, link.to);

    // Parse offsets within the token: ![alt](url)
    const bracketOpen = 0; // !
    const altStart = 2; // after ![
    const altEnd = text.indexOf("]", altStart);
    if (altEnd < 0) continue;
    const urlStart = altEnd + 1; // ](
    const urlEnd = text.length; // )

    // Hide `![`
    ranges.push(hiddenSyntaxDeco.range(link.from + bracketOpen, link.from + altStart));

    // Style alt text as caption (if non-empty)
    if (altEnd > altStart) {
      ranges.push(captionDeco.range(link.from + altStart, link.from + altEnd));
    }

    // Hide `](url)`
    ranges.push(hiddenSyntaxDeco.range(link.from + altEnd, link.from + urlEnd));
  }

  return Decoration.set(ranges, true);
}

// ── Paste handler ───────────────────────────────────────────────────────────

/** Read a File as a data-URL string. */
function readFileAsDataURL(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as string);
    reader.onerror = () => reject(new Error("Failed to read image file"));
    reader.readAsDataURL(file);
  });
}

/** Extract base64 body and MIME type from a data URL. */
function parseDataURL(dataUrl: string): { base64: string; mimeType: string } | null {
  const m = dataUrl.match(/^data:(image\/[^;]+);base64,(.+)$/s);
  if (!m) return null;
  return { mimeType: m[1]!, base64: m[2]! };
}

function imageClipboardFile(event: ClipboardEvent): File | null {
  const data = event.clipboardData;
  if (!data) return null;

  // If plain text is on the clipboard, let CM6's default paste handle it.
  // We intentionally do NOT check for text/html — WebKit/WKWebView
  // auto-wraps pasted images in <img> HTML even for pure image pastes.
  if (data.types.includes("text/plain")) return null;

  if (data.items) {
    for (const item of Array.from(data.items)) {
      if (item.kind === "file" && item.type.startsWith("image/")) {
        const file = item.getAsFile();
        if (file && file.size <= MAX_PASTE_FILE_BYTES) return file;
      }
    }
  }

  if (data.files) {
    for (const file of Array.from(data.files)) {
      if (file.type.startsWith("image/") && file.size <= MAX_PASTE_FILE_BYTES) {
        return file;
      }
    }
  }

  return null;
}

/** Extract a data-URL from HTML `<img src="data:image/…">`. */
function extractDataImageFromHTML(html: string): string | null {
  const m = html.match(/<img[^>]+src\s*=\s*["'](data:image\/[^"']+)["']/i);
  return m?.[1] ?? null;
}

function insertImageMarkdown(view: EditorView, path: string, alt: string): void {
  const { from, to } = view.state.selection.main;
  const insertion = `![${alt}](${path})`;
  view.dispatch({
    changes: { from, to, insert: insertion },
    selection: { anchor: from + insertion.length },
  });
}

function createPasteExtension(
  onImagePaste: (data: string, mimeType: string) => Promise<string | null>,
): Extension {
  return EditorView.domEventHandlers({
    paste(event: ClipboardEvent, view: EditorView) {
      if (view.state.readOnly) return false;

      // ── Path A: image file from clipboard APIs ───────────────────
      const file = imageClipboardFile(event);
      if (file) {
        event.preventDefault();
        readFileAsDataURL(file)
          .then((dataUrl) => {
            const parsed = parseDataURL(dataUrl);
            if (!parsed) throw new Error("Unrecognised data-URL format");
            return onImagePaste(parsed.base64, parsed.mimeType);
          })
          .then((path) => {
            if (path) insertImageMarkdown(view, path, "image");
          })
          .catch((err) => console.error("[nv3-image-paste]", err));
        return true;
      }

      // ── Path B: WebKit HTML-wrapped data-URL fallback ────────────
      const data = event.clipboardData;
      if (
        data &&
        !data.types.includes("text/plain") &&
        data.types.includes("text/html")
      ) {
        const html = data.getData("text/html");
        const dataUrl = extractDataImageFromHTML(html);
        if (dataUrl) {
          const parsed = parseDataURL(dataUrl);
          if (parsed) {
            event.preventDefault();
            onImagePaste(parsed.base64, parsed.mimeType)
              .then((path) => {
                if (path) insertImageMarkdown(view, path, "image");
              })
              .catch((err) => console.error("[nv3-image-paste]", err));
            return true;
          }
        }
      }

      return false;
    },
  });
}

// ── Public extension ────────────────────────────────────────────────────────

export function createMarkdownImagePreviewExtension(
  options: MarkdownImagePreviewOptions = {},
): Extension {
  const { resolveImageUrl, onImagePaste, enablePaste, filePath } = options;
  const extensions: Extension[] = [];

  // Block widgets (must be StateField — CM6 forbids block decos from plugins).
  extensions.push(
    StateField.define<DecorationSet>({
      create(state) {
        return buildBlockDecorations(state, resolveImageUrl, filePath);
      },
      update(value, tr) {
        if (!tr.docChanged) return value;
        return buildBlockDecorations(tr.state, resolveImageUrl, filePath);
      },
      provide(field) {
        return EditorView.decorations.from(field);
      },
    }),
  );

  // Syntax hiding (ViewPlugin for selection-sensitivity; inline decos only).
  extensions.push(
    ViewPlugin.fromClass(
      class {
        decorations: DecorationSet;
        constructor(view: EditorView) {
          this.decorations = buildSyntaxHidingDecorations(view.state, resolveImageUrl, filePath);
        }
        update(update: ViewUpdate) {
          if (update.docChanged || update.selectionSet) {
            this.decorations = buildSyntaxHidingDecorations(
              update.state,
              resolveImageUrl,
              filePath,
            );
          }
        }
      },
      { decorations: (v) => v.decorations },
    ),
  );

  // Paste handler.
  if (enablePaste !== false && onImagePaste) {
    extensions.push(createPasteExtension(onImagePaste));
  }

  return extensions;
}
