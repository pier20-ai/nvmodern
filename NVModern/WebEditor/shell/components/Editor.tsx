import React, { useEffect, useRef, useState } from "react";
import { z } from "zod";
import { Prec } from "@codemirror/state";
import { EditorView, keymap, placeholder } from "@codemirror/view";
import {
  collectMarkdownTocHeadings,
  createNv3EditorState,
  defaultNv3FrontmatterSchema,
  detectNv3FileType,
  nv3HeadingReferenceMatches,
  Nv3TableOfContents,
  parseNv3WikilinkTarget,
  resolveActiveTocHeadingId,
  scanMarkdownText,
  type Nv3AutocompleteProvider,
  type Nv3CodeBlockIndex,
  type Nv3FrontmatterResult,
  type Nv3LatexIndex,
  type Nv3LinkIndex,
  type Nv3OrgParseResult,
  type Nv3TagIndex,
  type Nv3TocHeading,
} from "../../src/lib/index.ts";

interface Props {
  filePath: string;
  content: string;
  onOpenFile?: (path: string) => void | Promise<void>;
}

type SaveState = "saved" | "dirty" | "saving" | "error";

const AUTOSAVE_ENABLED = true;
const AUTOSAVE_DELAY_MS = 900;

const MARKDOWN_SCHEMA = defaultNv3FrontmatterSchema.extend({
  title: z.string(),
});

interface ShellFileEntry {
  name: string;
  path: string;
  isDir: boolean;
}

const WIKILINK_INDEX_TTL_MS = 20_000;
const WIKILINK_DEFAULT_EXTENSIONS = [".md", ".markdown", ".org", ".txt", ".json"];
let wikilinkFileIndexCache: { files: string[]; loadedAt: number } | null = null;

function basename(path: string): string {
  const segments = path.split("/");
  return segments[segments.length - 1] ?? path;
}

function dirname(path: string): string {
  const segments = path.split("/");
  segments.pop();
  return segments.join("/");
}

function stripExtension(path: string): string {
  const lastDot = path.lastIndexOf(".");
  if (lastDot <= 0) return path;
  return path.slice(0, lastDot);
}

function cleanWikilinkTarget(rawTarget: string): string {
  return parseNv3WikilinkTarget(rawTarget).note;
}

function resolveMarkdownHeadingSectionRange(
  content: string,
  query: string,
): { from: number; to: number } | null {
  const headings = scanMarkdownText(content).headingOccurrences;
  const startIndex = headings.findIndex((heading) =>
    nv3HeadingReferenceMatches(query, heading.text),
  );
  if (startIndex < 0) return null;

  const start = headings[startIndex]!;
  const next = headings
    .slice(startIndex + 1)
    .find((heading) => heading.level <= start.level);

  return {
    from: start.from,
    to: next?.from ?? content.length,
  };
}

function resolveWikilinkFilePath(
  rawTarget: string,
  currentFilePath: string,
  allFiles: readonly string[],
): string | null {
  const target = cleanWikilinkTarget(rawTarget);
  if (!target) return null;

  const currentDir = dirname(currentFilePath);
  const candidateSet = new Set<string>();

  const pushCandidate = (value: string) => {
    const normalized = value.replace(/^\.\//, "").replace(/\/+/g, "/");
    if (normalized) candidateSet.add(normalized);
  };

  pushCandidate(target);
  if (currentDir) {
    pushCandidate(`${currentDir}/${target}`);
  }

  const targetHasExt = /\.[A-Za-z0-9]+$/.test(target);
  if (!targetHasExt) {
    for (const ext of WIKILINK_DEFAULT_EXTENSIONS) {
      pushCandidate(`${target}${ext}`);
      if (currentDir) {
        pushCandidate(`${currentDir}/${target}${ext}`);
      }
    }
  }

  for (const candidate of candidateSet) {
    if (allFiles.includes(candidate)) {
      return candidate;
    }
  }

  const exactBasenameMatches = allFiles.filter((path) => basename(path) === target);
  if (exactBasenameMatches.length === 1) {
    return exactBasenameMatches[0] ?? null;
  }

  const basenameWithoutExtMatches = allFiles.filter(
    (path) => stripExtension(basename(path)) === target,
  );
  if (basenameWithoutExtMatches.length === 1) {
    return basenameWithoutExtMatches[0] ?? null;
  }

  return null;
}

function relativeToCurrentFile(path: string, currentFilePath?: string): string {
  if (!currentFilePath) return path;

  const parts = currentFilePath.split("/");
  parts.pop();
  const currentDir = parts.join("/");

  if (!currentDir) return path;
  if (!path.startsWith(`${currentDir}/`)) return path;

  return path.slice(currentDir.length + 1);
}

async function fetchShellDirectory(
  dir: string,
  signal: AbortSignal,
): Promise<ShellFileEntry[]> {
  const res = await fetch(`/api/files?dir=${encodeURIComponent(dir)}`, { signal });
  if (!res.ok) {
    throw new Error(await res.text());
  }

  return (await res.json()) as ShellFileEntry[];
}

async function buildShellFileIndex(signal: AbortSignal): Promise<string[]> {
  const queue: string[] = ["."];
  const visited = new Set<string>();
  const files: string[] = [];

  while (queue.length) {
    if (signal.aborted) {
      throw new DOMException("Aborted", "AbortError");
    }

    const dir = queue.shift();
    if (!dir) continue;
    if (visited.has(dir)) continue;

    visited.add(dir);

    const entries = await fetchShellDirectory(dir, signal);
    for (const entry of entries) {
      if (entry.isDir) {
        queue.push(entry.path);
      } else {
        files.push(entry.path);
      }
    }
  }

  files.sort((a, b) => a.localeCompare(b));
  return files;
}

async function getShellWikilinkFileIndex(signal: AbortSignal): Promise<string[]> {
  const now = Date.now();

  if (wikilinkFileIndexCache && now - wikilinkFileIndexCache.loadedAt < WIKILINK_INDEX_TTL_MS) {
    return wikilinkFileIndexCache.files;
  }

  const files = await buildShellFileIndex(signal);
  wikilinkFileIndexCache = {
    files,
    loadedAt: now,
  };
  return files;
}

async function fetchShellFile(
  path: string,
  signal: AbortSignal,
  readReason = "manual",
): Promise<string> {
  const res = await fetch(`/api/file?path=${encodeURIComponent(path)}`, {
    signal,
    headers: {
      "X-Read-Reason": readReason,
    },
  });
  if (!res.ok) {
    throw new Error(await res.text());
  }
  return await res.text();
}

async function saveShellFile(
  path: string,
  content: string,
  signal: AbortSignal,
  saveReason = "transclusion",
): Promise<void> {
  const res = await fetch(`/api/file?path=${encodeURIComponent(path)}`, {
    method: "PUT",
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "X-Save-Reason": saveReason,
    },
    body: content,
    signal,
  });

  if (!res.ok) {
    throw new Error(await res.text());
  }
}

const shellWikilinkProvider: Nv3AutocompleteProvider = {
  source: "shell.wikilink.files",
  trigger: "[[",
  async query(input) {
    const allFiles = await getShellWikilinkFileIndex(input.signal);

    const query = input.text.trim().toLowerCase();
    const candidates = allFiles
      .filter((path) => path !== input.filePath)
      .map((path) => ({
        path,
        visible: relativeToCurrentFile(path, input.filePath),
      }))
      .filter(({ path, visible }) => {
        if (!query) return true;

        const pathLower = path.toLowerCase();
        const visibleLower = visible.toLowerCase();
        const nameLower = basename(path).toLowerCase();

        return (
          pathLower.includes(query) ||
          visibleLower.includes(query) ||
          nameLower.includes(query)
        );
      })
      .sort((left, right) => {
        const leftStarts = left.visible.toLowerCase().startsWith(query);
        const rightStarts = right.visible.toLowerCase().startsWith(query);
        if (leftStarts !== rightStarts) return leftStarts ? -1 : 1;

        const leftBaseStarts = basename(left.visible).toLowerCase().startsWith(query);
        const rightBaseStarts = basename(right.visible).toLowerCase().startsWith(query);
        if (leftBaseStarts !== rightBaseStarts) return leftBaseStarts ? -1 : 1;

        if (left.visible.length !== right.visible.length) {
          return left.visible.length - right.visible.length;
        }

        return left.visible.localeCompare(right.visible);
      })
      .slice(0, 50);

    return candidates.map((candidate) => ({
      label: candidate.visible,
      insertText: candidate.path,
      detail: candidate.path,
      type: "text",
    }));
  },
};

const SHELL_DEMO_USERS = [
  { handle: "alex", name: "Alex Mercer", team: "Product" },
  { handle: "ananya", name: "Ananya Rao", team: "Design" },
  { handle: "ben", name: "Ben Carter", team: "Infra" },
  { handle: "chloe", name: "Chloe Kim", team: "Docs" },
  { handle: "daniel", name: "Daniel Singh", team: "Backend" },
  { handle: "divya", name: "Divya Nair", team: "Research" },
  { handle: "elena", name: "Elena Park", team: "Frontend" },
  { handle: "farhan", name: "Farhan Ali", team: "Ops" },
  { handle: "gabe", name: "Gabe Laurent", team: "AI" },
  { handle: "hana", name: "Hana Yoon", team: "Mobile" },
  { handle: "ira", name: "Ira Kapoor", team: "QA" },
  { handle: "jules", name: "Jules Martin", team: "Platform" },
  { handle: "kai", name: "Kai Wong", team: "Infra" },
  { handle: "leo", name: "Leo Fernandez", team: "Product" },
  { handle: "maya", name: "Maya Iyer", team: "Design" },
  { handle: "noah", name: "Noah Reed", team: "Backend" },
  { handle: "olivia", name: "Olivia Tan", team: "Research" },
  { handle: "priya", name: "Priya Menon", team: "Frontend" },
  { handle: "ravi", name: "Ravi Patel", team: "AI" },
  { handle: "sara", name: "Sara Johnson", team: "Ops" },
  { handle: "tanvi", name: "Tanvi Shah", team: "QA" },
  { handle: "vikram", name: "Vikram Das", team: "Platform" },
  { handle: "yuki", name: "Yuki Arai", team: "Mobile" },
  { handle: "zoe", name: "Zoe Williams", team: "Docs" },
] as const;

const shellMentionProvider: Nv3AutocompleteProvider = {
  source: "shell.mention.users",
  trigger: "@",
  query(input) {
    const query = input.text.trim().toLowerCase();

    const filtered = SHELL_DEMO_USERS.filter((user) => {
      if (!query) return true;
      return (
        user.handle.includes(query) ||
        user.name.toLowerCase().includes(query) ||
        user.team.toLowerCase().includes(query)
      );
    })
      .sort((left, right) => {
        const leftStarts = left.handle.startsWith(query);
        const rightStarts = right.handle.startsWith(query);
        if (leftStarts !== rightStarts) return leftStarts ? -1 : 1;
        return left.handle.localeCompare(right.handle);
      })
      .slice(0, 20);

    return filtered.map((user) => ({
      label: user.handle,
      insertText: user.handle,
      detail: `${user.name} · ${user.team}`,
      type: "variable",
    }));
  },
};

export function Editor({ filePath, content, onOpenFile }: Props) {
  const fileType = detectNv3FileType(filePath);

  const mountRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const saveRef = useRef<(() => Promise<void>) | null>(null);

  const lastSavedDocRef = useRef(content);
  const isSavingRef = useRef(false);
  const resaveRequestedRef = useRef(false);

  const [saveState, setSaveState] = useState<SaveState>("saved");
  const [error, setError] = useState<string | null>(null);

  const [frontmatter, setFrontmatter] = useState<Nv3FrontmatterResult | null>(null);
  const [tagIndex, setTagIndex] = useState<Nv3TagIndex | null>(null);
  const [latexIndex, setLatexIndex] = useState<Nv3LatexIndex | null>(null);
  const [linkIndex, setLinkIndex] = useState<Nv3LinkIndex | null>(null);
  const [codeBlocks, setCodeBlocks] = useState<Nv3CodeBlockIndex | null>(null);
  const [orgParse, setOrgParse] = useState<Nv3OrgParseResult | null>(null);
  const [tocHeadings, setTocHeadings] = useState<Nv3TocHeading[]>([]);
  const [activeTocHeadingId, setActiveTocHeadingId] = useState<string | null>(null);
  const tocHeadingsRef = useRef<Nv3TocHeading[]>([]);

  useEffect(() => {
    if (!mountRef.current) return;

    let destroyed = false;
    let autosaveTimer: ReturnType<typeof setTimeout> | null = null;

    const clearAutosaveTimer = () => {
      if (!autosaveTimer) return;
      clearTimeout(autosaveTimer);
      autosaveTimer = null;
    };

    const save = async (reason: "manual" | "autosave") => {
      const view = viewRef.current;
      if (!view) return;

      const doc = view.state.doc.toString();
      if (doc === lastSavedDocRef.current) {
        if (!destroyed) {
          setSaveState("saved");
        }
        return;
      }

      if (isSavingRef.current) {
        resaveRequestedRef.current = true;
        return;
      }

      isSavingRef.current = true;
      clearAutosaveTimer();

      if (!destroyed) {
        setSaveState("saving");
        setError(null);
      }

      try {
        const res = await fetch(`/api/file?path=${encodeURIComponent(filePath)}`, {
          method: "PUT",
          headers: {
            "Content-Type": "text/plain; charset=utf-8",
            "X-Save-Reason": reason,
          },
          body: doc,
        });

        if (!res.ok) {
          throw new Error(await res.text());
        }

        lastSavedDocRef.current = doc;

        if (!destroyed) {
          const liveDoc = viewRef.current?.state.doc.toString() ?? doc;
          setSaveState(liveDoc === lastSavedDocRef.current ? "saved" : "dirty");
        }
      } catch (e) {
        if (!destroyed) {
          setSaveState("error");
          setError(String(e));
        }
      } finally {
        isSavingRef.current = false;

        if (resaveRequestedRef.current) {
          resaveRequestedRef.current = false;

          if (AUTOSAVE_ENABLED && !destroyed) {
            autosaveTimer = setTimeout(() => {
              void save("autosave");
            }, AUTOSAVE_DELAY_MS);
          }
        }
      }
    };

    saveRef.current = () => save("manual");

    const saveCommand = () => {
      void save("manual");
      return true;
    };

    const handleWikilinkOpen = (target: string) => {
      if (!onOpenFile) return;

      void (async () => {
        try {
          const allFiles = await getShellWikilinkFileIndex(new AbortController().signal);
          const resolvedPath = resolveWikilinkFilePath(target, filePath, allFiles);
          if (!resolvedPath) {
            console.warn(`[nv3 wikilink] Unable to resolve '${target}' from '${filePath}'.`);
            return;
          }

          await onOpenFile(resolvedPath);
        } catch (wikilinkError) {
          console.warn("[nv3 wikilink] navigation failed", wikilinkError);
        }
      })();
    };

    const resolveTransclusion = async ({
      target,
      signal,
      filePath: sourceFilePath,
      requestKind,
    }: {
      target: string;
      signal: AbortSignal;
      filePath?: string;
      requestKind: "transclusion.resolve";
    }) => {
      const allFiles = await getShellWikilinkFileIndex(signal);
      const sourcePath = sourceFilePath ?? filePath;
      const resolvedPath = resolveWikilinkFilePath(target, sourcePath, allFiles);
      if (!resolvedPath) {
        return null;
      }

      const content = await fetchShellFile(resolvedPath, signal, requestKind);
      const parsed = parseNv3WikilinkTarget(target);
      const resolvedContent =
        parsed.referenceKind === "heading"
          ? (() => {
              const range = resolveMarkdownHeadingSectionRange(content, parsed.referenceQuery);
              return range ? content.slice(range.from, range.to) : null;
            })()
          : content;
      if (resolvedContent === null) {
        return null;
      }

      const extension = resolvedPath.slice(Math.max(0, resolvedPath.lastIndexOf(".") + 1));
      return {
        content: resolvedContent,
        kind: extension || undefined,
        filePath: resolvedPath,
      };
    };

    const saveTransclusion = async ({
      target,
      content: transcludedContent,
      signal,
      filePath: sourceFilePath,
      requestKind,
    }: {
      target: string;
      content: string;
      signal: AbortSignal;
      filePath?: string;
      requestKind: "transclusion.save";
    }) => {
      const allFiles = await getShellWikilinkFileIndex(signal);
      const sourcePath = sourceFilePath ?? filePath;
      const resolvedPath = resolveWikilinkFilePath(target, sourcePath, allFiles);
      if (!resolvedPath) {
        throw new Error(`Unable to resolve transclusion target '${target}'.`);
      }

      const parsed = parseNv3WikilinkTarget(target);
      if (parsed.referenceKind === "heading") {
        const currentContent = await fetchShellFile(resolvedPath, signal, requestKind);
        const range = resolveMarkdownHeadingSectionRange(currentContent, parsed.referenceQuery);
        if (!range) {
          throw new Error(`Unable to resolve transclusion heading '${target}'.`);
        }

        const nextContent =
          currentContent.slice(0, range.from) +
          transcludedContent +
          currentContent.slice(range.to);
        await saveShellFile(resolvedPath, nextContent, signal, requestKind);
        return;
      }

      await saveShellFile(resolvedPath, transcludedContent, signal, requestKind);
    };

    const syncToc = (view: EditorView, refreshHeadings: boolean) => {
      if (fileType !== "markdown") {
        tocHeadingsRef.current = [];
        setTocHeadings([]);
        setActiveTocHeadingId(null);
        return;
      }

      const headings = refreshHeadings ? collectMarkdownTocHeadings(view.state) : tocHeadingsRef.current;
      if (refreshHeadings) {
        tocHeadingsRef.current = headings;
        setTocHeadings(headings);
      }

      const nextActiveHeadingId = resolveActiveTocHeadingId(
        headings,
        view.viewport.from,
        view.viewport.to,
      );
      setActiveTocHeadingId(nextActiveHeadingId);
    };

    setFrontmatter(null);
    setTagIndex(null);
    setLatexIndex(null);
    setLinkIndex(null);
    setCodeBlocks(null);
    setOrgParse(null);
    tocHeadingsRef.current = [];
    setTocHeadings([]);
    setActiveTocHeadingId(null);
    setError(null);

    lastSavedDocRef.current = content;
    isSavingRef.current = false;
    resaveRequestedRef.current = false;

    const state = createNv3EditorState({
      doc: content,
      filePath,
      fileType,
      frontmatterSchema: MARKDOWN_SCHEMA,
      latexPreviewMode: fileType === "markdown" || fileType === "org" ? "katex" : "none",
      autocompleteProviders:
        fileType === "markdown" ? [shellWikilinkProvider, shellMentionProvider] : undefined,
      autocompleteActivateOnTypingDelay: 140,
      onAutocompleteError: ({ providerSource, error: autocompleteError }) => {
        console.warn(`[nv3 autocomplete] ${providerSource} failed`, autocompleteError);
      },
      resolveWikilinkHref: ({ target }) => cleanWikilinkTarget(target) || target,
      onWikilinkOpen: ({ target }) => {
        handleWikilinkOpen(target);
      },
      resolveTransclusion:
        fileType === "markdown"
          ? ({ target, signal, filePath: sourceFilePath, requestKind }) =>
              resolveTransclusion({
                target,
                signal,
                filePath: sourceFilePath,
                requestKind,
              })
          : undefined,
      saveTransclusion:
        fileType === "markdown"
          ? ({
              target,
              content: transcludedContent,
              signal,
              filePath: sourceFilePath,
              requestKind,
            }) =>
              saveTransclusion({
                target,
                content: transcludedContent,
                signal,
                filePath: sourceFilePath,
                requestKind,
              })
          : undefined,
      maxTransclusionDepth: 1,
      onFrontmatterChange: (result) => {
        if (destroyed) return;
        setFrontmatter(result);
      },
      onTagsChange: (index) => {
        if (destroyed) return;
        setTagIndex(index);
      },
      onLatexChange: (index) => {
        if (destroyed) return;
        setLatexIndex(index);
      },
      onLinksChange: (index) => {
        if (destroyed) return;
        setLinkIndex(index);
      },
      onCodeBlocksChange: (index) => {
        if (destroyed) return;
        setCodeBlocks(index);
      },
      onOrgParseChange: (result) => {
        if (destroyed) return;
        setOrgParse(result);
      },
      extraExtensions: [
        placeholder(
          fileType === "org"
            ? "Org mode parser enabled — features will layer on top incrementally."
            : "Start writing Markdown…",
        ),
        EditorView.contentAttributes.of({
          spellcheck: "true",
        }),
        Prec.high(
          keymap.of([
            {
              key: "Mod-s",
              run: saveCommand,
              preventDefault: true,
            },
          ]),
        ),
        EditorView.updateListener.of((update) => {
          if (update.docChanged || update.viewportChanged) {
            syncToc(update.view, update.docChanged);
          }

          if (!update.docChanged) return;

          const currentDoc = update.state.doc.toString();
          const isDirty = currentDoc !== lastSavedDocRef.current;

          setSaveState((current) => {
            if (!isDirty) return "saved";
            if (current === "saving") return current;
            return "dirty";
          });
          setError(null);

          if (AUTOSAVE_ENABLED && isDirty) {
            clearAutosaveTimer();
            autosaveTimer = setTimeout(() => {
              void save("autosave");
            }, AUTOSAVE_DELAY_MS);
          }
        }),
      ],
    });

    const view = new EditorView({
      state,
      parent: mountRef.current,
    });

    viewRef.current = view;
    view.focus();
    setSaveState("saved");
    syncToc(view, true);

    return () => {
      destroyed = true;
      clearAutosaveTimer();
      saveRef.current = null;
      view.destroy();
      viewRef.current = null;
    };
  }, [content, filePath, fileType]);

  const saveNow = () => {
    if (!saveRef.current) return;
    void saveRef.current();
  };

  const jumpToHeading = (heading: Nv3TocHeading) => {
    const view = viewRef.current;
    if (!view) return;

    view.dispatch({
      selection: { anchor: heading.from },
      scrollIntoView: true,
    });
    view.focus();
  };

  const frontmatterErrors =
    frontmatter?.diagnostics.filter((diagnostic) => diagnostic.severity === "error") ?? [];
  const frontmatterWarnings =
    frontmatter?.diagnostics.filter((diagnostic) => diagnostic.severity === "warning") ?? [];

  const topTags = tagIndex?.allTags.slice(0, 8) ?? [];
  const codeFenceLanguages = Array.from(
    new Set(
      (codeBlocks?.blocks ?? [])
        .map((block) => block.language)
        .filter((language): language is string => Boolean(language)),
    ),
  );

  return (
    <div className="editor-shell">
      <div className="editor-layout">
        {fileType === "markdown" && tocHeadings.length > 0 && (
          <aside className="editor-toc-rail">
            <Nv3TableOfContents
              headings={tocHeadings}
              activeHeadingId={activeTocHeadingId}
              onSelectHeading={jumpToHeading}
            />
          </aside>
        )}

        <div className="editor-main">
          <div className="editor-toolbar">
        <div className="editor-toolbar-left">
          <span className={`editor-status is-${saveState}`}>
            {saveState === "saved" && "Saved"}
            {saveState === "dirty" && "Unsaved changes"}
            {saveState === "saving" && "Saving…"}
            {saveState === "error" && "Save failed"}
          </span>
          <span className="editor-autosave">
            Autosave {AUTOSAVE_ENABLED ? `on (${AUTOSAVE_DELAY_MS}ms)` : "off"}
          </span>
        </div>

        <button
          className="editor-save-button"
          onClick={saveNow}
          disabled={saveState === "saving"}
        >
          Save (⌘/Ctrl+S)
        </button>
      </div>

      <div className="editor-inspector">
        <div className="editor-inspector-row">
          <span className="editor-chip">Mode: {fileType}</span>

          {fileType === "markdown" && (
            <>
              <span className="editor-chip">Hash tags: {tagIndex?.hashTags.length ?? 0}</span>
              <span className="editor-chip">
                Heading tags: {tagIndex?.headingTags.length ?? 0}
              </span>
              <span className="editor-chip">Math inline: {latexIndex?.inlineCount ?? 0}</span>
              <span className="editor-chip">Math blocks: {latexIndex?.blockCount ?? 0}</span>
              <span className="editor-chip">Code blocks: {codeBlocks?.count ?? 0}</span>
              <span className="editor-chip">Wikilinks: {linkIndex?.wikilinkCount ?? 0}</span>
              <span className="editor-chip">
                Transclusions: {linkIndex?.transclusionCount ?? 0}
              </span>
              <span className="editor-chip">Previews: {linkIndex?.previewCount ?? 0}</span>
              <span
                className={`editor-chip ${
                  frontmatter?.valid === false ? "is-warning" : "is-ok"
                }`}
              >
                Frontmatter:{" "}
                {!frontmatter?.present
                  ? "none"
                  : frontmatter.valid
                    ? "valid"
                    : `${frontmatterErrors.length} error(s)`}
              </span>
            </>
          )}

          {fileType === "org" && (
            <>
              <span className="editor-chip">Headings: {orgParse?.counts.headingCount ?? 0}</span>
              <span className="editor-chip">Lists: {orgParse?.counts.listItemCount ?? 0}</span>
              <span className="editor-chip">Links: {orgParse?.counts.linkCount ?? 0}</span>
              <span className="editor-chip">Timestamps: {orgParse?.counts.timestampCount ?? 0}</span>
              <span className="editor-chip">Src blocks: {orgParse?.counts.sourceBlockCount ?? 0}</span>
              <span className="editor-chip">Tables: {orgParse?.counts.tableCount ?? 0}</span>
              <span className="editor-chip">Footnotes: {orgParse?.counts.footnoteReferenceCount ?? 0}</span>
              <span className="editor-chip">Markup: {orgParse?.counts.markupCount ?? 0}</span>
            </>
          )}
        </div>

        {fileType === "org" && (
          <div className="editor-mode-notice">
            Org parser is active (single-pass structural index). Rendering and interaction plugins
            will be layered on top next.
            {orgParse?.diagnostics.length ? (
              <ul className="editor-diagnostics-list">
                {orgParse.diagnostics.map((diagnostic, index) => (
                  <li key={`${diagnostic.code}-${diagnostic.line}-${index}`}>
                    <span className="diagnostic-severity warning">warning</span>
                    <span>{diagnostic.message}</span>
                    <span className="diagnostic-line">line {diagnostic.line}</span>
                  </li>
                ))}
              </ul>
            ) : null}
          </div>
        )}

        {fileType === "markdown" && (
          <div className="editor-inspector-details">
            {frontmatter?.diagnostics.length ? (
              <ul className="editor-diagnostics-list">
                {frontmatter.diagnostics.map((diagnostic, index) => (
                  <li key={`${diagnostic.message}-${index}`}>
                    <span className={`diagnostic-severity ${diagnostic.severity}`}>
                      {diagnostic.severity}
                    </span>
                    <span>{diagnostic.message}</span>
                    {typeof diagnostic.line === "number" && (
                      <span className="diagnostic-line">line {diagnostic.line}</span>
                    )}
                  </li>
                ))}
              </ul>
            ) : frontmatter?.present ? (
              <p className="editor-inspector-ok">Frontmatter matches the current schema.</p>
            ) : (
              <p className="editor-inspector-muted">
                No frontmatter detected. Add a leading <code>---</code> block to enable schema
                validation.
              </p>
            )}

            <div className="editor-inspector-metadata">
              {topTags.length > 0 && (
                <p>
                  <strong>Top tags:</strong> {topTags.map((tag) => `#${tag}`).join(", ")}
                </p>
              )}

              {codeFenceLanguages.length > 0 && (
                <p>
                  <strong>Code fence languages:</strong> {codeFenceLanguages.join(", ")}
                </p>
              )}

              {(linkIndex?.occurrences.length ?? 0) > 0 && (
                <p>
                  <strong>Detected links:</strong>{" "}
                  {linkIndex!.occurrences
                    .slice(0, 5)
                    .map((occurrence) => `${occurrence.kind}:${occurrence.target}`)
                    .join(" · ")}
                </p>
              )}

              {frontmatterWarnings.length > 0 && (
                <p>
                  <strong>Warnings:</strong> {frontmatterWarnings.length}
                </p>
              )}
            </div>
          </div>
        )}
      </div>

          <div className="editor-mount" ref={mountRef} />

          {error && <div className="editor-error">{error}</div>}
        </div>
      </div>
    </div>
  );
}
