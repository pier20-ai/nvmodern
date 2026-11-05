/**
 * nvModern host helpers shared by the WKWebView surfaces that render notes
 * with the editor library: the main editor (`App.tsx`) and the side stack
 * (`stack/`). Workspace paths, the `nvmodern-file://` preview scheme and the
 * host appearance are adapter concerns, so they live outside `src/lib/`.
 */
import {
  parseNv3WikilinkTarget,
  type Nv3TransclusionResolveInput,
  type Nv3TransclusionResolved,
} from "./lib/index.ts";
import { bridge } from "./bridge.ts";

export type HostColorScheme = "light" | "dark";

export function cleanTarget(rawTarget: string): string {
  return parseNv3WikilinkTarget(rawTarget).note;
}

/** The `href` stamped on rendered wikilinks: the note part of the target. */
export function resolveWikilinkHref(rawTarget: string): string {
  return cleanTarget(rawTarget) || rawTarget;
}

export function hasExternalHrefScheme(rawHref: string): boolean {
  return /^(?:[A-Za-z][A-Za-z0-9+.-]*:|\/\/)/.test(rawHref);
}

export function normalizeWorkspacePath(path: string): string | null {
  const parts: string[] = [];

  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") {
      if (parts.length === 0) return null;
      parts.pop();
      continue;
    }
    parts.push(part);
  }

  return parts.join("/");
}

export function directoryOfWorkspacePath(path?: string): string {
  if (!path) return "";
  const normalized = path.replaceAll("\\", "/").replace(/^\/+/, "");
  const slash = normalized.lastIndexOf("/");
  return slash >= 0 ? normalized.slice(0, slash) : "";
}

export function splitHrefSuffix(rawHref: string): { path: string; suffix: string } {
  const hashIndex = rawHref.indexOf("#");
  const queryIndex = rawHref.indexOf("?");
  const splitIndex =
    hashIndex < 0 ? queryIndex : queryIndex < 0 ? hashIndex : Math.min(hashIndex, queryIndex);

  if (splitIndex < 0) {
    return { path: rawHref, suffix: "" };
  }

  return {
    path: rawHref.slice(0, splitIndex),
    suffix: rawHref.slice(splitIndex),
  };
}

export function resolveWorkspaceRelativePath(rawHref: string, filePath?: string): string | null {
  const trimmed = rawHref.trim();
  if (!trimmed || hasExternalHrefScheme(trimmed) || trimmed.startsWith("data:")) {
    return null;
  }

  const { path } = splitHrefSuffix(trimmed);
  if (!path) return null;

  const normalizedPath = path.replaceAll("\\", "/");
  if (normalizedPath.startsWith("/")) {
    return normalizeWorkspacePath(normalizedPath.replace(/^\/+/, ""));
  }

  const baseDir = directoryOfWorkspacePath(filePath);
  const combined = baseDir ? `${baseDir}/${normalizedPath}` : normalizedPath;
  return normalizeWorkspacePath(combined);
}

export function resolveInlineWorkspaceHref(rawHref: string, filePath?: string): string {
  const trimmed = rawHref.trim();
  if (!trimmed || hasExternalHrefScheme(trimmed) || trimmed.startsWith("data:")) {
    return trimmed;
  }

  const { suffix } = splitHrefSuffix(trimmed);
  const resolvedPath = resolveWorkspaceRelativePath(trimmed, filePath);
  if (!resolvedPath) return trimmed;

  return suffix ? `${resolvedPath}${suffix}` : resolvedPath;
}

/**
 * Maps a Markdown image source to the native `nvmodern-file://` preview
 * scheme. External and data URLs return null so the image plugin keeps them.
 */
export function resolvePreviewImageUrl(src: string, sourcePath?: string): string | null {
  const trimmed = src.trim();
  if (!trimmed || hasExternalHrefScheme(trimmed) || trimmed.startsWith("data:")) return null;

  const { path } = splitHrefSuffix(trimmed);
  if (!path) return null;

  const params = new URLSearchParams({ path });
  if (sourcePath) params.set("sourcePath", sourcePath);
  return `nvmodern-file://preview?${params.toString()}`;
}

/** Applies the native window's light/dark appearance (`setHostAppearance`). */
export function applyHostColorScheme(value: unknown) {
  const colorScheme: HostColorScheme = value === "dark" ? "dark" : "light";
  const root = document.documentElement;
  root.setAttribute("data-theme", colorScheme);
  root.style.colorScheme = colorScheme;
  if (document.body) {
    document.body.style.colorScheme = colorScheme;
  }
}

/** Resolves `![[transclusions]]` through the native `transclusion.resolve` request. */
export function resolveTransclusionOverBridge({
  target,
  filePath,
  depth,
  requestKind,
  signal,
}: Nv3TransclusionResolveInput): Promise<Nv3TransclusionResolved | null> {
  return bridge
    .request("transclusion.resolve", { target, filePath, depth, requestKind }, signal)
    .then((result) => {
      if (!result || typeof result !== "object") return null;
      const payload = result as { content?: unknown; kind?: unknown; filePath?: unknown };
      if (typeof payload.content !== "string") return null;
      return {
        content: payload.content,
        kind: typeof payload.kind === "string" ? payload.kind : undefined,
        filePath: typeof payload.filePath === "string" ? payload.filePath : undefined,
      };
    });
}
