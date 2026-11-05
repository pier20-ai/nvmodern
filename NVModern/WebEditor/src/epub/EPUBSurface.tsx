import React, { useEffect, useRef, useState } from "react";
import type {
  Book,
  Contents,
  Location,
  Rendition,
} from "epubjs";
import type { EditorContext } from "../App.tsx";
import { bridge } from "../bridge.ts";
import {
  activeEpubOutlineID,
  createEpubThemeOverrideCSS,
  flattenEpubToc,
  isPublisherDefaultEpubTheme,
  validateEpubArchiveSize,
  type EpubOutlineItem,
} from "./epubHelpers.ts";
import { installEpubLinkGuard, sanitizeEpubDocument } from "./epubSecurity.ts";

type EpubFactory = typeof import("epubjs").default;

declare global {
  interface Window {
    nvmodernEpubRuntime?: {
      createBook: EpubFactory;
    };
  }
}

let epubRuntimePromise: Promise<EpubFactory> | null = null;

function loadEpubRuntime(): Promise<EpubFactory> {
  if (window.nvmodernEpubRuntime) {
    return Promise.resolve(window.nvmodernEpubRuntime.createBook);
  }
  if (epubRuntimePromise) return epubRuntimePromise;

  epubRuntimePromise = new Promise<EpubFactory>((resolve, reject) => {
    const script = document.createElement("script");
    script.src = new URL("./epub.js", window.location.href).href;
    script.onload = () => {
      const factory = window.nvmodernEpubRuntime?.createBook;
      if (factory) {
        resolve(factory);
      } else {
        reject(new Error("EPUB runtime loaded without registering its reader."));
      }
    };
    script.onerror = () => reject(new Error("Failed to load EPUB runtime."));
    document.head.append(script);
  }).catch((error) => {
    epubRuntimePromise = null;
    throw error;
  });

  return epubRuntimePromise;
}

interface EpubLocationPayload {
  href: string;
  cfi?: string;
  progression?: number;
}

interface EpubAppearance {
  themeID?: string;
  css?: string;
}

const EPUB_THEME_STYLE_ID = "nvmodern-epub-theme-override";

function applyThemeToContents(contents: Contents, appearance: EpubAppearance) {
  const document = contents.document;
  const root = document.documentElement;
  const existing = document.getElementById(EPUB_THEME_STYLE_ID);
  const css = createEpubThemeOverrideCSS(appearance.themeID, appearance.css);

  if (!css) {
    existing?.remove();
    root.removeAttribute("data-doc-theme");
    const originalTheme = root.getAttribute("data-nvmodern-original-theme");
    if (originalTheme == null || originalTheme === "__absent__") {
      root.removeAttribute("data-theme");
    } else {
      root.setAttribute("data-theme", originalTheme);
    }
    root.removeAttribute("data-nvmodern-original-theme");
    return;
  }

  if (!root.hasAttribute("data-nvmodern-original-theme")) {
    root.setAttribute("data-nvmodern-original-theme", root.getAttribute("data-theme") ?? "__absent__");
  }
  root.setAttribute("data-doc-theme", appearance.themeID ?? "system");
  root.setAttribute("data-theme", document.documentElement.ownerDocument.defaultView?.parent?.document.documentElement.dataset.theme === "dark" ? "dark" : "light");

  const style = existing?.localName === "style"
    ? existing as HTMLStyleElement
    : document.createElement("style");
  style.id = EPUB_THEME_STYLE_ID;
  style.textContent = css;
  if (!style.isConnected) {
    (document.head ?? document.documentElement).append(style);
  }
}

function locationPayload(location: Location): EpubLocationPayload {
  const start = location.start;
  return {
    href: start.href,
    ...(start.cfi ? { cfi: start.cfi } : {}),
    ...(Number.isFinite(start.percentage) ? { progression: start.percentage } : {}),
  };
}

function initialEpubTarget(context: EditorContext): string | undefined {
  if (context.scrollState?.kind !== "epub") return undefined;
  return context.scrollState.cfi || context.scrollState.href;
}

export function EPUBSurface({ context }: { context: EditorContext }) {
  const mountRef = useRef<HTMLDivElement | null>(null);
  const bookRef = useRef<Book | null>(null);
  const renditionRef = useRef<Rendition | null>(null);
  const outlineRef = useRef<EpubOutlineItem[]>([]);
  const locationRef = useRef<EpubLocationPayload | null>(null);
  const contentsRef = useRef(new Set<Contents>());
  const fixedLayoutRef = useRef(false);
  const appearanceRef = useRef<EpubAppearance>({
    themeID: context.documentInspectorTheme,
    css: context.documentInspectorCSS,
  });
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const emitNavigationState = (layout?: string) => {
    const location = locationRef.current;
    bridge.emit("epubNavigationState", {
      path: context.path,
      outline: outlineRef.current,
      ...(location
        ? {
            activeOutlineId: activeEpubOutlineID(outlineRef.current, location.href),
            location,
          }
        : {}),
      ...(layout ? { layout } : {}),
    });
  };

  useEffect(() => {
    appearanceRef.current = {
      themeID: context.documentInspectorTheme,
      css: context.documentInspectorCSS,
    };
    for (const contents of contentsRef.current) {
      applyThemeToContents(
        contents,
        fixedLayoutRef.current ? { themeID: "system" } : appearanceRef.current,
      );
    }
  }, [context.documentInspectorCSS, context.documentInspectorTheme]);

  useEffect(() => {
    const observer = new MutationObserver(() => {
      if (fixedLayoutRef.current || isPublisherDefaultEpubTheme(appearanceRef.current.themeID)) return;
      for (const contents of contentsRef.current) {
        applyThemeToContents(contents, appearanceRef.current);
      }
    });
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const mount = mountRef.current;
    const previewURL = context.previewURL ?? (context.path
      ? `nvmodern-file://preview?${new URLSearchParams({ path: context.path }).toString()}`
      : undefined);
    if (!mount || !previewURL) {
      setIsLoading(false);
      setError("EPUB path unavailable.");
      return;
    }

    let disposed = false;
    const abortController = new AbortController();
    const linkGuardCleanups = new Map<Contents, () => void>();

    const load = async () => {
      setIsLoading(true);
      setError(null);

      try {
        // Keep epubjs in its own classic script. WebKit parses the complete
        // shared editor bundle before React can mount, so even deferred module
        // initialization lets legacy EPUB code blank every text document.
        const ePub = await loadEpubRuntime();
        if (disposed) return;
        if (typeof context.fileSize === "number") {
          validateEpubArchiveSize(context.fileSize);
        }
        const response = await fetch(previewURL, { signal: abortController.signal });
        if (!response.ok) throw new Error(`Failed to load EPUB (${response.status})`);
        const data = await response.arrayBuffer();
        validateEpubArchiveSize(data.byteLength);
        if (disposed) return;

        const book = ePub(data);
        bookRef.current = book;
        const [metadata, navigation] = await Promise.all([
          book.loaded.metadata,
          book.loaded.navigation,
        ]);
        if (disposed) {
          book.destroy();
          return;
        }

        const fixedLayout = metadata.layout === "pre-paginated";
        fixedLayoutRef.current = fixedLayout;
        const layout = fixedLayout ? "pre-paginated" : "reflowable";
        outlineRef.current = flattenEpubToc(navigation.toc ?? []);

        // Sanitize the inert spine DOM before EPUB.js serializes it into an
        // iframe. The content hook below repeats this after load as a second
        // line of defense; the iframe itself never receives allow-scripts.
        book.spine.hooks.content.register((document: Document) => {
          sanitizeEpubDocument(document);
        });

        const rendition = book.renderTo(mount, fixedLayout
          ? {
              width: "100%",
              height: "100%",
              manager: "default",
              flow: "paginated",
              spread: "none",
              allowScriptedContent: false,
              allowPopups: false,
            }
          : {
              width: "100%",
              height: "100%",
              manager: "continuous",
              flow: "scrolled-doc",
              spread: "none",
              allowScriptedContent: false,
              allowPopups: false,
            });
        renditionRef.current = rendition;

        rendition.hooks.content.register((contents: Contents) => {
          sanitizeEpubDocument(contents.document);
          contentsRef.current.add(contents);
          applyThemeToContents(
            contents,
            fixedLayout ? { themeID: "system" } : appearanceRef.current,
          );
          const removeLinkGuard = installEpubLinkGuard(contents, (href, label) => {
            bridge.emit("inlineLinkOpen", {
              href,
              label,
              filePath: context.path,
            });
          });
          linkGuardCleanups.set(contents, removeLinkGuard);
        });

        rendition.hooks.unloaded.register((contents: Contents) => {
          linkGuardCleanups.get(contents)?.();
          linkGuardCleanups.delete(contents);
          contentsRef.current.delete(contents);
        });

        rendition.on("relocated", (location: Location) => {
          if (disposed) return;
          locationRef.current = locationPayload(location);
          emitNavigationState(layout);
        });

        await rendition.display(initialEpubTarget(context));
        if (!disposed) setIsLoading(false);
      } catch (loadError) {
        if (disposed || abortController.signal.aborted) return;
        const message = loadError instanceof Error ? loadError.message : String(loadError);
        setError(message);
        setIsLoading(false);
        bridge.emit("previewLoadError", {
          kind: "epub",
          path: context.path,
          message,
        });
      }
    };

    void load();

    return () => {
      disposed = true;
      abortController.abort();
      for (const cleanup of linkGuardCleanups.values()) cleanup();
      linkGuardCleanups.clear();
      contentsRef.current.clear();
      renditionRef.current = null;
      bookRef.current?.destroy();
      bookRef.current = null;
      outlineRef.current = [];
      locationRef.current = null;
      fixedLayoutRef.current = false;
      mount.replaceChildren();
    };
  }, [context.path, context.previewURL]);

  useEffect(() => bridge.onCommand((command, payload) => {
    if (command !== "epubNavigate") return;
    const request = (payload ?? {}) as { path?: unknown; href?: unknown; cfi?: unknown };
    if (typeof request.path === "string" && request.path !== context.path) return;
    const target = typeof request.cfi === "string"
      ? request.cfi
      : typeof request.href === "string"
        ? request.href
        : undefined;
    if (!target) return;

    void renditionRef.current?.display(target).catch((navigationError: unknown) => {
      bridge.emit("previewLoadError", {
        kind: "epub-navigation",
        path: context.path,
        message: navigationError instanceof Error ? navigationError.message : String(navigationError),
      });
    });
  }), [context.path]);

  return (
    <div className="nvmodern-epub-surface">
      <div ref={mountRef} className="nvmodern-epub-rendition" />
      {isLoading ? <div className="nvmodern-epub-status">Loading EPUB…</div> : null}
      {error ? <div className="nvmodern-epub-status nvmodern-epub-error">{error}</div> : null}
    </div>
  );
}
