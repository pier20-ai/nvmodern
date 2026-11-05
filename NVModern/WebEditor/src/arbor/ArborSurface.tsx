import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type DragEvent as ReactDragEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  type MouseEvent as ReactMouseEvent,
} from "react";
import {
  ArborOutlineStore,
  ArborVisibleIndex,
  arborBlockId,
  arborPageId,
  parseArborBlockText,
  parseArborSource,
  setArborMarkdownTaskChecked,
  isManagedComputation,
  type ArborBlockId,
  type ArborCaretTarget,
  type ArborDocumentSnapshot,
  type ArborEditResult,
  type ArborVisibleRow,
} from "../lib/arbor/index.ts";
import {
  isValidISODate,
  todayISODateLocal,
} from "../lib/plugins/dateUtils.ts";
import {
  applyNv3TextSubstitutions,
  type Nv3TextSubstitutionChange,
  type Nv3TextSubstitutionRule,
} from "../lib/plugins/substitutions.ts";
import {
  Popover,
  PopoverContent,
} from "../components/ui/popover.tsx";
import {
  insertOrReplaceArborTimestamp,
  updateInsertedArborTimestamp,
} from "./dateShortcuts.ts";
import {
  ArborMarkdownView,
  type ArborMarkdownNavigation,
} from "./ArborMarkdownView.tsx";
import {
  caretIsOnVisualLineBoundary,
  caretOffset,
  focusEditor,
  focusEditorSelection,
  insertTextAtSelection,
  plainText,
  scrollCaretIntoView,
  selectionOffsets,
} from "./dom.ts";
import {
  startArborDocumentSync,
  type ArborDocumentSync,
} from "./documentSync.ts";
import type { ArborHost, ArborInlineFormat } from "./host.ts";
import {
  canDropBlocks,
  completionPosition,
  completionTrigger,
  dropTargetAtPointer,
  keyboardDropTarget,
  localCompletionProvider,
  moveBlocksToTarget,
  outdentBlocks,
  pastedBlockTexts,
  pointerRangeSelection,
  rangeSelection,
  selectedOutlineText,
  selectedRowsOutlineText,
  selectionRoots,
  shouldExtendBlockSelection,
  shouldMergeBlockOnBackspace,
  toggleDelimitedSelection,
  workspacePageCompletionItems,
  type ArborCompletionItem,
  type ArborCompletionTrigger,
  type ArborDropTarget,
} from "./interactions.ts";
import {
  ARBOR_COMPLETION_BINDINGS,
  ARBOR_EDITOR_BINDINGS,
  ARBOR_LEADER_BINDINGS,
  ARBOR_SELECTION_BINDINGS,
  dispatchKey,
} from "./keymap.ts";

const PAGE_ID = arborPageId("arbor-playground");
const MARKDOWN_PAGE_ID = arborPageId("markdown");
const DATE_LEADER_TIMEOUT_MS = 1_500;

const INITIAL_OUTLINE: ArborDocumentSnapshot = {
  version: 1,
  pages: [{
    id: PAGE_ID,
    title: "Arbor Playground",
    children: [
      arborBlockId("playground-welcome"),
      arborBlockId("playground-editing"),
      arborBlockId("playground-ideas"),
    ],
  }, {
    id: MARKDOWN_PAGE_ID,
    title: "Markdown",
    children: [arborBlockId("playground-markdown-about")],
  }],
  blocks: [
    {
      id: arborBlockId("playground-welcome"),
      pageId: PAGE_ID,
      parentId: null,
      children: [arborBlockId("playground-welcome-links"), arborBlockId("playground-welcome-markdown")],
      text: "A fast, local **Roam-style outliner**",
    },
    {
      id: arborBlockId("playground-welcome-links"),
      pageId: PAGE_ID,
      parentId: arborBlockId("playground-welcome"),
      children: [],
      text: "Click any block to edit its raw [[Markdown]]",
    },
    {
      id: arborBlockId("playground-welcome-markdown"),
      pageId: PAGE_ID,
      parentId: arborBlockId("playground-welcome"),
      children: [],
      text: "Blur to render **bold**, ^^highlights^^, `code`, #tags, and [links](https://commonmark.org/)",
    },
    {
      id: arborBlockId("playground-editing"),
      pageId: PAGE_ID,
      parentId: null,
      children: [
        arborBlockId("playground-editing-enter"),
        arborBlockId("playground-editing-tab"),
        arborBlockId("playground-editing-move"),
      ],
      text: "Editing",
    },
    {
      id: arborBlockId("playground-editing-enter"),
      pageId: PAGE_ID,
      parentId: arborBlockId("playground-editing"),
      children: [],
      text: "Enter splits a block · Shift+Enter adds a line",
    },
    {
      id: arborBlockId("playground-editing-tab"),
      pageId: PAGE_ID,
      parentId: arborBlockId("playground-editing"),
      children: [],
      text: "Tab indents · Shift+Tab outdents · Backspace merges",
    },
    {
      id: arborBlockId("playground-editing-move"),
      pageId: PAGE_ID,
      parentId: arborBlockId("playground-editing"),
      children: [],
      text: "Option+↑/↓ moves a block · ⌘Z undoes",
    },
    {
      id: arborBlockId("playground-ideas"),
      pageId: PAGE_ID,
      parentId: null,
      children: [arborBlockId("playground-ideas-child")],
      text: "Things to try",
    },
    {
      id: arborBlockId("playground-ideas-child"),
      pageId: PAGE_ID,
      parentId: arborBlockId("playground-ideas"),
      children: [],
      text: "Write here. This outline exists only in memory and resets on refresh.",
    },
    {
      id: arborBlockId("playground-markdown-about"),
      pageId: MARKDOWN_PAGE_ID,
      parentId: null,
      children: [],
      text: "This is the [[Markdown]] page. Return to [[Arbor Playground]].",
    },
  ],
};

function sourceOffsetAtPoint(event: ReactMouseEvent<HTMLElement>, fallback: number): number {
  const documentWithCaret = document as Document & {
    caretPositionFromPoint?(x: number, y: number): { offsetNode: Node; offset: number } | null;
    caretRangeFromPoint?(x: number, y: number): Range | null;
  };
  const position = documentWithCaret.caretPositionFromPoint?.(event.clientX, event.clientY);
  const legacyRange = position ? null : documentWithCaret.caretRangeFromPoint?.(event.clientX, event.clientY);
  const node = position?.offsetNode ?? legacyRange?.startContainer;
  const offset = position?.offset ?? legacyRange?.startOffset;
  if (!node || offset === undefined) return fallback;

  const element = node instanceof Element ? node : node.parentElement;
  const token = element?.closest<HTMLElement>("[data-source-start]");
  if (!token || !event.currentTarget.contains(token)) return fallback;

  try {
    const prefix = document.createRange();
    prefix.selectNodeContents(token);
    prefix.setEnd(node, offset);
    const start = Number(token.dataset.sourceStart ?? 0);
    const end = Number(token.dataset.sourceEnd ?? fallback);
    return Math.min(start + prefix.toString().length, end);
  } catch {
    return fallback;
  }
}

interface ArborSurfaceProps {
  context?: {
    path?: string;
    title?: string;
    body?: string;
    isEditable?: boolean;
    substitutionRules?: readonly Nv3TextSubstitutionRule[];
  };
  host?: ArborHost;
  developmentHarness?: boolean;
  onPerformanceSample?: unknown;
}

interface CompletionState {
  blockId: ArborBlockId;
  trigger: ArborCompletionTrigger;
  items: readonly ArborCompletionItem[];
  selectedIndex: number;
  top: number;
  left: number;
}

interface MouseSelectionState {
  anchorId: ArborBlockId;
  focusTarget: ArborCaretTarget | null;
  dragged: boolean;
}

function changedRange(before: string, after: string): { from: number; to: number } {
  let from = 0;
  while (from < before.length && from < after.length && before[from] === after[from]) from += 1;
  let suffix = 0;
  while (suffix < before.length - from
    && suffix < after.length - from
    && before[before.length - suffix - 1] === after[after.length - suffix - 1]) suffix += 1;
  return { from, to: after.length - suffix };
}

function offsetAfterSubstitutions(
  offset: number,
  changes: readonly Nv3TextSubstitutionChange[],
): number {
  let delta = 0;
  for (const change of changes) {
    if (offset < change.from) break;
    if (offset <= change.to) return change.from + delta + change.insert.length;
    delta += change.insert.length - (change.to - change.from);
  }
  return offset + delta;
}

function createSession(context?: ArborSurfaceProps["context"]) {
  if (context?.body !== undefined) {
    const parsed = parseArborSource(context.body, { title: context.title ?? "Untitled" });
    const store = ArborOutlineStore.fromSnapshot(parsed.snapshot);
    if (store.getPage(parsed.pageId)?.childCount === 0) store.insertBlock({ pageId: parsed.pageId });
    store.clearHistory();
    return { store, visible: new ArborVisibleIndex(store), rootPageId: parsed.pageId };
  }
  const store = ArborOutlineStore.fromSnapshot(INITIAL_OUTLINE);
  return { store, visible: new ArborVisibleIndex(store), rootPageId: PAGE_ID };
}

export function ArborSurface({
  context,
  host,
  developmentHarness = false,
}: ArborSurfaceProps = {}) {
  const [session] = useState(() => createSession(context));
  const [revision, setRevision] = useState(0);
  const [activeBlockId, setActiveBlockId] = useState<ArborBlockId | null>(null);
  const [pageId, setPageId] = useState(session.rootPageId);
  const [zoomBlockId, setZoomBlockId] = useState<ArborBlockId | null>(null);
  const [selectedBlockIds, setSelectedBlockIds] = useState<Set<ArborBlockId>>(new Set());
  const [selectionAnchorId, setSelectionAnchorId] = useState<ArborBlockId | null>(null);
  const [selectionExtentId, setSelectionExtentId] = useState<ArborBlockId | null>(null);
  const [completion, setCompletion] = useState<CompletionState | null>(null);
  const [dropTarget, setDropTarget] = useState<ArborDropTarget | null>(null);
  const [dateLeaderOpen, setDateLeaderOpen] = useState(false);
  const editorRefs = useRef(new Map<ArborBlockId, HTMLElement>());
  const initializedEditors = useRef(new WeakSet<HTMLElement>());
  const outlineRef = useRef<HTMLDivElement | null>(null);
  const pendingFocus = useRef<ArborCaretTarget | null>(null);
  const suspendedFocus = useRef<ArborCaretTarget | null>(null);
  const mouseSelection = useRef<MouseSelectionState | null>(null);
  const documentSync = useRef<ArborDocumentSync | null>(null);
  const contextMenuBlockId = useRef<ArborBlockId | null>(null);
  const typingSession = useRef(0);
  const editedSourceResults = useRef(new Set<ArborBlockId>());
  const isComposing = useRef(false);
  const scrollerRef = useRef<HTMLDivElement | null>(null);
  const draggedBlockIds = useRef<ArborBlockId[]>([]);
  const copyExplicitRows = useRef(false);
  const completionRequest = useRef(0);
  const dateLeaderActive = useRef(false);
  const dateLeaderTimer = useRef<number | null>(null);
  const dateEditSequence = useRef(0);
  const datePickerRequest = useRef(0);
  const completionAnchor = completion ? {
    getBoundingClientRect: () => new DOMRect(completion.left, completion.top, 0, 0),
  } : null;

  const clearDateLeader = useCallback(() => {
    dateLeaderActive.current = false;
    if (dateLeaderTimer.current !== null) {
      window.clearTimeout(dateLeaderTimer.current);
      dateLeaderTimer.current = null;
    }
    setDateLeaderOpen(false);
  }, []);

  const armDateLeader = useCallback(() => {
    clearDateLeader();
    dateLeaderActive.current = true;
    setDateLeaderOpen(true);
    dateLeaderTimer.current = window.setTimeout(clearDateLeader, DATE_LEADER_TIMEOUT_MS);
  }, [clearDateLeader]);

  useEffect(() => () => {
    if (dateLeaderTimer.current !== null) window.clearTimeout(dateLeaderTimer.current);
    datePickerRequest.current += 1;
  }, []);

  useEffect(() => session.store.subscribe((change) => {
    if (change.kind !== "content") setRevision((value) => value + 1);
  }), [session]);

  useEffect(() => host?.subscribeContextMenuActions?.((action) => {
    const blockId = contextMenuBlockId.current;
    if (!blockId) return false;
    const block = session.store.getBlock(blockId);
    if (!block) return false;

    switch (action) {
      case "copyText":
        void navigator.clipboard.writeText(block.text).catch(() => undefined);
        return true;
      case "copyId":
        void navigator.clipboard.writeText(blockId).catch(() => undefined);
        return true;
      case "moveUp":
        if (block.previousSiblingId === null) return false;
        session.store.moveBlockUp(blockId);
        break;
      case "moveDown":
        if (block.nextSiblingId === null) return false;
        session.store.moveBlockDown(blockId);
        break;
      case "delete":
        setActiveBlockId(null);
        if (zoomBlockId === blockId) setZoomBlockId(null);
        session.store.deleteBlock(blockId);
        if (session.store.getPage(pageId)?.childCount === 0) {
          session.store.insertBlock({ pageId });
        }
        break;
    }
    setActiveBlockId(null);
    setRevision((value) => value + 1);
    return true;
  }), [host, pageId, session, zoomBlockId]);

  useEffect(() => {
    if (activeBlockId && !session.store.hasBlock(activeBlockId)) {
      setActiveBlockId(null);
      setCompletion(null);
    }
    if (zoomBlockId && !session.store.hasBlock(zoomBlockId)) setZoomBlockId(null);
    if (selectionAnchorId && !session.store.hasBlock(selectionAnchorId)) setSelectionAnchorId(null);
    if (selectionExtentId && !session.store.hasBlock(selectionExtentId)) setSelectionExtentId(null);
    setSelectedBlockIds((current) => {
      const existing = new Set([...current].filter((id) => session.store.hasBlock(id)));
      return existing.size === current.size ? current : existing;
    });
  }, [activeBlockId, revision, selectionAnchorId, selectionExtentId, session, zoomBlockId]);

  useEffect(() => {
    Object.defineProperty(window, "arborOutline", {
      configurable: true,
      get: () => session.store.toSnapshot(),
    });
    return () => {
      delete (window as Window & { arborOutline?: ArborDocumentSnapshot }).arborOutline;
    };
  }, [session]);

  useEffect(() => {
    if (!host) return;
    const path = context?.path ?? "arbor-playground.outline";
    const sync = startArborDocumentSync({
      store: session.store,
      pageId: session.rootPageId,
      document: { id: path, path },
      host,
    });
    documentSync.current = sync;

    if (developmentHarness) {
      (window as Window & {
        arborKernelQuery?: (
          queryId: string,
          arguments_?: Record<string, unknown>,
        ) => Promise<unknown>;
      }).arborKernelQuery = (queryId, arguments_) => sync.runQuery(queryId, arguments_);
    }

    return () => {
      sync.stop();
      if (documentSync.current === sync) documentSync.current = null;
      if (developmentHarness) {
        delete (window as Window & { arborKernelQuery?: unknown }).arborKernelQuery;
      }
    };
  }, [context?.path, developmentHarness, host, session]);

  useLayoutEffect(() => {
    const target = pendingFocus.current;
    if (!target) return;
    const editor = editorRefs.current.get(target.blockId);
    if (!editor) return;
    const block = session.store.getBlock(target.blockId);
    if (block && plainText(editor) !== block.text) editor.textContent = block.text;
    pendingFocus.current = null;
    focusEditor(editor, target.offset);
    const scroller = scrollerRef.current;
    if (scroller) scrollCaretIntoView(editor, scroller);
  }, [activeBlockId, revision, session]);

  useLayoutEffect(() => {
    if (activeBlockId === null && selectedBlockIds.size > 0) {
      outlineRef.current?.focus({ preventScroll: true });
    }
  }, [activeBlockId, selectedBlockIds]);

  const requestFocus = useCallback((target: ArborCaretTarget | null) => {
    if (!target) return;
    pendingFocus.current = target;
    typingSession.current += 1;
    setActiveBlockId(target.blockId);
    setCompletion(null);
    setRevision((value) => value + 1);
  }, []);

  useEffect(() => {
    const restoreFocus = () => {
      if (document.visibilityState === "hidden") return;
      const target = suspendedFocus.current;
      if (!target) return;
      suspendedFocus.current = null;
      requestAnimationFrame(() => {
        const editor = editorRefs.current.get(target.blockId);
        if (editor) {
          focusEditor(editor, target.offset);
          const scroller = scrollerRef.current;
          if (scroller) scrollCaretIntoView(editor, scroller);
        }
      });
    };
    window.addEventListener("focus", restoreFocus);
    document.addEventListener("visibilitychange", restoreFocus);
    return () => {
      window.removeEventListener("focus", restoreFocus);
      document.removeEventListener("visibilitychange", restoreFocus);
    };
  }, []);

  useEffect(() => {
    const finishMouseSelection = () => {
      const state = mouseSelection.current;
      mouseSelection.current = null;
      if (!state) return;
      if (state.dragged) {
        window.getSelection()?.removeAllRanges();
        outlineRef.current?.focus({ preventScroll: true });
        return;
      }
      if (state.focusTarget) {
        setSelectedBlockIds(new Set());
        setSelectionExtentId(null);
        requestFocus(state.focusTarget);
      }
    };
    window.addEventListener("mouseup", finishMouseSelection);
    return () => window.removeEventListener("mouseup", finishMouseSelection);
  }, [requestFocus]);

  const applyEdit = (result: ArborEditResult) => {
    if (result.changed) setRevision((value) => value + 1);
    requestFocus(result.focus);
  };

  const navigate = (navigation: ArborMarkdownNavigation) => {
    setActiveBlockId(null);

    if (navigation.kind === "external") {
      if (host) {
        host.openInlineLink({ href: navigation.href, filePath: context?.path });
      } else {
        window.open(navigation.href, "_blank", "noopener,noreferrer");
      }
      return;
    }

    if (navigation.kind === "block") {
      const block = session.store.getBlock(arborBlockId(navigation.target));
      if (block) {
        setPageId(block.pageId);
        setZoomBlockId(block.id);
        return;
      }
      host?.openLink({
        target: `#^${navigation.target}`,
        href: `((${navigation.target}))`,
        filePath: context?.path,
      });
      return;
    }

    const page = session.store.toSnapshot().pages.find(
      (candidate) => candidate.title.toLocaleLowerCase() === navigation.target.toLocaleLowerCase(),
    );
    if (page) {
      setPageId(page.id);
      setZoomBlockId(null);
      return;
    }
    host?.openLink({
      target: navigation.target,
      href: `[[${navigation.target}]]`,
      filePath: context?.path,
    });
  };

  const allRows = session.visible.rows(pageId, zoomBlockId);
  const visibleRows: readonly ArborVisibleRow[] = allRows;
  const orderedSelectedIds = visibleRows
    .filter((row) => selectedBlockIds.has(row.id))
    .map((row) => row.id);
  const selectedRoots = selectionRoots(session.store, orderedSelectedIds);

  const selectBlock = (
    blockId: ArborBlockId,
    options: { additive?: boolean; range?: boolean } = {},
  ) => {
    copyExplicitRows.current = Boolean(options.additive && !options.range);
    if (options.range && selectionAnchorId) {
      setSelectedBlockIds(rangeSelection(visibleRows, selectionAnchorId, blockId));
    } else if (options.additive) {
      setSelectedBlockIds((current) => {
        const next = new Set(current);
        if (next.has(blockId)) next.delete(blockId);
        else next.add(blockId);
        return next;
      });
      setSelectionAnchorId(blockId);
    } else {
      setSelectedBlockIds(new Set([blockId]));
      setSelectionAnchorId(blockId);
    }
    setSelectionExtentId(blockId);
    setActiveBlockId(null);
    setCompletion(null);
  };

  const ensurePageHasBlock = () => {
    if (session.store.getPage(pageId)?.childCount === 0) session.store.insertBlock({ pageId });
  };

  const deleteRoots = (label: string, roots = selectedRoots) => {
    if (roots.length === 0) return;
    const deletesZoom = zoomBlockId !== null && roots.includes(zoomBlockId);
    session.store.transaction(label, () => {
      for (const id of roots) {
        if (session.store.hasBlock(id)) session.store.deleteBlock(id);
      }
      ensurePageHasBlock();
    });
    setActiveBlockId(null);
    setSelectedBlockIds(new Set());
    copyExplicitRows.current = false;
    if (deletesZoom) setZoomBlockId(null);
    setRevision((value) => value + 1);
  };

  const runBulkEdit = (
    label: string,
    edit: (blockId: ArborBlockId) => ArborEditResult,
    ids = selectedRoots,
  ) => {
    if (ids.length === 0) return;
    session.store.transaction(label, () => {
      for (const id of ids) {
        if (session.store.hasBlock(id)) edit(id);
      }
    });
    setSelectedBlockIds(new Set(ids.filter((id) => session.store.hasBlock(id))));
    setRevision((value) => value + 1);
  };

  const copySelected = async (cut: boolean) => {
    if (selectedRoots.length === 0) return;
    const text = copyExplicitRows.current
      ? selectedRowsOutlineText(session.store, orderedSelectedIds)
      : selectedOutlineText(session.store, selectedRoots);
    await navigator.clipboard.writeText(text);
    if (!cut) return;
    deleteRoots("Cut blocks");
  };

  const updateCompletion = (editor: HTMLElement, blockId: ArborBlockId) => {
    if (isComposing.current) return;
    const request = completionRequest.current + 1;
    completionRequest.current = request;
    const trigger = completionTrigger(plainText(editor), caretOffset(editor));
    if (!trigger) {
      setCompletion(null);
      return;
    }
    const selection = window.getSelection();
    const caretRect = selection?.rangeCount ? selection.getRangeAt(0).getBoundingClientRect() : null;
    const position = completionPosition(
      caretRect?.left ?? editor.getBoundingClientRect().left,
      caretRect?.bottom ?? editor.getBoundingClientRect().bottom,
      window.innerWidth,
      window.innerHeight,
    );
    const show = (items: readonly ArborCompletionItem[]) => {
      if (completionRequest.current !== request || document.activeElement !== editor) return;
      const current = completionTrigger(plainText(editor), caretOffset(editor));
      if (!current || current.kind !== trigger.kind || current.start !== trigger.start
        || current.end !== trigger.end || current.query !== trigger.query) return;
      setCompletion(items.length === 0 ? null : {
        blockId,
        trigger,
        items,
        selectedIndex: 0,
        ...position,
      });
    };

    if (trigger.kind === "page" && host?.autocompleteWikilinks) {
      setCompletion(null);
      void host.autocompleteWikilinks(trigger.query, context?.path)
        .then((items) => show(workspacePageCompletionItems(items)))
        .catch(() => show([]));
      return;
    }

    show(localCompletionProvider.candidates(trigger, session.store.toSnapshot()));
  };

  const acceptCompletion = (editor: HTMLElement, state: CompletionState) => {
    const item = state.items[state.selectedIndex];
    const block = session.store.getBlock(state.blockId);
    if (!item || !block) return;
    const text = block.text.slice(0, state.trigger.start)
      + item.insertText
      + block.text.slice(state.trigger.end);
    const offset = state.trigger.start + item.insertText.length;
    session.store.setBlockText(state.blockId, text, {
      historyGroup: `typing:${state.blockId}:${typingSession.current}`,
    });
    editor.textContent = text;
    focusEditor(editor, offset);
    completionRequest.current += 1;
    setCompletion(null);
  };

  const moveSelection = (direction: "up" | "down") => {
    const roots = selectedRoots;
    const target = keyboardDropTarget(session.store, roots, direction);
    if (!target) return;
    const result = moveBlocksToTarget(session.store, roots, target);
    if (result.changed) setRevision((value) => value + 1);
  };

  const handleSelectionKeyDown = (event: ReactKeyboardEvent<HTMLElement>) => {
    // Bindings live in keymap.ts; this only supplies what each command does.
    return dispatchKey(ARBOR_SELECTION_BINDINGS, event, (command) => {
      if (command === "undo" || command === "redo") {
        event.preventDefault();
        applyEdit(command === "redo" ? session.store.redo() : session.store.undo());
        return true;
      }
      if (selectedRoots.length === 0) return false;
      switch (command) {
        case "copy":
        case "cut":
          event.preventDefault();
          void copySelected(command === "cut").catch(() => undefined);
          return true;
        case "delete":
          event.preventDefault();
          deleteRoots("Delete blocks");
          return true;
        case "outdent":
          event.preventDefault();
          outdentBlocks(session.store, selectedRoots);
          setRevision((value) => value + 1);
          return true;
        case "indent":
          event.preventDefault();
          runBulkEdit("Indent blocks", (id) => session.store.indentBlock(id));
          return true;
        case "moveUp":
        case "moveDown":
          event.preventDefault();
          moveSelection(command === "moveUp" ? "up" : "down");
          return true;
        case "clear":
          event.preventDefault();
          setSelectedBlockIds(new Set());
          setSelectionAnchorId(null);
          setSelectionExtentId(null);
          copyExplicitRows.current = false;
          return true;
        case "extendUp":
        case "extendDown": {
          const extentId = selectionExtentId ?? orderedSelectedIds.at(-1);
          const extentIndex = visibleRows.findIndex((row) => row.id === extentId);
          const target = visibleRows[extentIndex + (command === "extendUp" ? -1 : 1)];
          const anchor = selectionAnchorId ?? extentId;
          if (!target || !anchor) return false;
          event.preventDefault();
          copyExplicitRows.current = false;
          setSelectionExtentId(target.id);
          setSelectedBlockIds(rangeSelection(visibleRows, anchor, target.id));
          return true;
        }
      }
    });
  };

  const handleDragOver = (event: ReactDragEvent<HTMLElement>, blockId: ArborBlockId) => {
    if (draggedBlockIds.current.length === 0) return;
    event.preventDefault();
    const rect = event.currentTarget.getBoundingClientRect();
    const target = dropTargetAtPointer(blockId, event.clientY, rect.top, rect.height);
    const valid = canDropBlocks(session.store, draggedBlockIds.current, target);
    event.dataTransfer.dropEffect = valid ? "move" : "none";
    setDropTarget(valid ? target : null);

    const scroller = scrollerRef.current;
    if (!scroller) return;
    const scrollerRect = scroller.getBoundingClientRect();
    const edge = 40;
    if (event.clientY < scrollerRect.top + edge) scroller.scrollTop -= 16;
    else if (event.clientY > scrollerRect.bottom - edge) scroller.scrollTop += 16;
  };

  const pasteBlocks = (
    editor: HTMLElement,
    blockId: ArborBlockId,
    clipboardText: string,
  ) => {
    const block = session.store.getBlock(blockId);
    const selection = selectionOffsets(editor);
    if (!block || !selection) return;

    const substitutedClipboard = applyNv3TextSubstitutions(
      clipboardText,
      0,
      clipboardText.length,
      context?.substitutionRules,
    ).text;
    const sourceLines = pastedBlockTexts(
      block.text,
      selection.start,
      selection.end,
      substitutedClipboard,
    );
    const after = block.text.slice(selection.end);
    const claimedIds = new Set<ArborBlockId>();
    const pasted = sourceLines.map((value) => {
      const parsed = parseArborBlockText(value);
      const requestedId = parsed.anchor?.id;
      const available = requestedId
        && !claimedIds.has(requestedId)
        && (requestedId === blockId || !session.store.hasBlock(requestedId));
      if (!available) return { text: value };
      claimedIds.add(requestedId);
      return { text: parsed.text, anchor: parsed.anchor };
    });

    let currentId = blockId;
    let lastId = blockId;
    const preservesSourceComputation = sourceLines.length === 1
      && !pasted[0]?.anchor
      && block.computation?.state === "live"
      && block.computation.updatePolicy === "source-text";
    session.store.transaction(sourceLines.length > 1 ? "Paste blocks" : "Paste block", () => {
      const first = pasted[0]!;
      if (first.anchor && first.anchor.id !== currentId) {
        session.store.renameBlock(currentId, first.anchor.id);
        currentId = first.anchor.id;
      }
      session.store.setBlockText(currentId, first.text, {
        preserveComputation: preservesSourceComputation,
      });
      if (first.anchor) {
        session.store.setBlockComputation(currentId, first.anchor.computation);
      }

      let afterId = currentId;
      for (const item of pasted.slice(1)) {
        const result = session.store.insertBlock({
          pageId: block.pageId,
          parentId: block.parentId,
          afterId,
          ...(item.anchor ? { id: item.anchor.id, computation: item.anchor.computation } : {}),
          text: item.text,
        });
        afterId = result.focus!.blockId;
      }
      lastId = afterId;
    });
    if (preservesSourceComputation) editedSourceResults.current.add(currentId);

    if (currentId !== blockId) {
      setSelectedBlockIds((current) => new Set(
        [...current].map((id) => id === blockId ? currentId : id),
      ));
      setSelectionAnchorId((current) => current === blockId ? currentId : current);
      setSelectionExtentId((current) => current === blockId ? currentId : current);
    }
    copyExplicitRows.current = false;
    setCompletion(null);
    setRevision((value) => value + 1);
    requestFocus({ blockId: lastId, offset: pasted.at(-1)!.text.length - after.length });
  };

  const insertDate = (
    editor: HTMLElement,
    blockId: ArborBlockId,
    openPicker: boolean,
  ) => {
    const block = session.store.getBlock(blockId);
    if (!block) return;
    const caret = caretOffset(editor);
    const selection = selectionOffsets(editor) ?? { start: caret, end: caret };
    const isoDate = todayISODateLocal();
    const edit = insertOrReplaceArborTimestamp(
      block.text,
      selection.start,
      selection.end,
      isoDate,
    );
    const historyGroup = `date:${blockId}:${dateEditSequence.current += 1}`;
    const sourceBacked = block.computation?.state === "live"
      && block.computation.updatePolicy === "source-text";
    const wasManaged = isManagedComputation(block.computation);
    session.store.setBlockText(blockId, edit.text, {
      historyGroup,
      preserveComputation: sourceBacked,
    });
    if (sourceBacked) editedSourceResults.current.add(blockId);
    if (wasManaged) setRevision((value) => value + 1);
    editor.textContent = edit.text;
    focusEditor(editor, edit.to);
    setCompletion(null);

    if (!openPicker || !host?.pickDate) return;
    const request = datePickerRequest.current + 1;
    datePickerRequest.current = request;
    let focusOffset = edit.to;
    void host.pickDate({
      isoDate,
      kind: edit.kind,
      raw: edit.raw,
      filePath: context?.path,
    }).then((pickedISODate) => {
      if (datePickerRequest.current !== request
        || !pickedISODate
        || !isValidISODate(pickedISODate)) return;
      const current = session.store.getBlock(blockId);
      if (!current) return;
      const updated = updateInsertedArborTimestamp(current.text, edit, pickedISODate);
      if (!updated) return;
      focusOffset = updated.to;
      const preservesSourceComputation = current.computation?.state === "live"
        && current.computation.updatePolicy === "source-text";
      session.store.setBlockText(blockId, updated.text, {
        historyGroup,
        preserveComputation: preservesSourceComputation,
      });
      if (preservesSourceComputation) editedSourceResults.current.add(blockId);
      const currentEditor = editorRefs.current.get(blockId);
      if (currentEditor) {
        currentEditor.textContent = updated.text;
      }
      setRevision((value) => value + 1);
    }).catch((error) => {
      host.trace?.("date-picker-error", {
        blockId,
        message: error instanceof Error ? error.message : String(error),
      });
    }).finally(() => {
      if (datePickerRequest.current !== request) return;
      const currentEditor = editorRefs.current.get(blockId);
      if (currentEditor) focusEditor(currentEditor, focusOffset);
    });
  };

  const applyInlineFormatting = useCallback((
    editor: HTMLElement,
    blockId: ArborBlockId,
    format: ArborInlineFormat,
  ): boolean => {
    const block = session.store.getBlock(blockId);
    const selection = selectionOffsets(editor);
    if (!block || !selection) return false;
    const delimiters = format === "bold"
      ? { open: "**", close: "**" }
      : { open: "*", close: "*" };
    const edit = toggleDelimitedSelection(
      block.text,
      selection.start,
      selection.end,
      delimiters.open,
      delimiters.close,
    );
    if (!edit) return false;

    typingSession.current += 1;
    const sourceBacked = block.computation?.state === "live"
      && block.computation.updatePolicy === "source-text";
    const wasManaged = isManagedComputation(block.computation);
    session.store.setBlockText(blockId, edit.text, {
      historyGroup: `format:${blockId}:${typingSession.current}`,
      preserveComputation: sourceBacked,
    });
    if (sourceBacked) editedSourceResults.current.add(blockId);
    if (wasManaged) setRevision((value) => value + 1);
    editor.textContent = edit.text;
    focusEditorSelection(editor, edit.start, edit.end);
    setCompletion(null);
    return true;
  }, [session]);

  const applyActiveInlineFormatting = useCallback((format: ArborInlineFormat): boolean => {
    if (!activeBlockId) return false;
    const editor = editorRefs.current.get(activeBlockId);
    return editor ? applyInlineFormatting(editor, activeBlockId, format) : false;
  }, [activeBlockId, applyInlineFormatting]);

  useEffect(() => (
    host?.subscribeInlineFormatting?.(applyActiveInlineFormatting)
  ), [applyActiveInlineFormatting, host]);

  const handleKeyDown = (event: ReactKeyboardEvent<HTMLElement>, blockId: ArborBlockId) => {
    const editor = event.currentTarget;
    const block = session.store.getBlock(blockId);
    if (!block) return;
    if (isComposing.current || event.nativeEvent.isComposing) return;
    const offset = caretOffset(editor);

    // Second key after the date leader (⌘;). Any other key just cancels the leader and is handled normally.
    if (dateLeaderActive.current
      && !["Meta", "Alt", "Control", "Shift"].includes(event.key)) {
      clearDateLeader();
      const handled = dispatchKey(ARBOR_LEADER_BINDINGS, event, (command) => {
        event.preventDefault();
        if (command === "insertToday") insertDate(editor, blockId, false);
        if (command === "insertTodayWithCalendar") insertDate(editor, blockId, true);
        return true;
      });
      if (handled) return;
    }

    if (event.key === "Escape") completionRequest.current += 1;

    const openCompletion = completion?.blockId === blockId ? completion : null;
    if (openCompletion && dispatchKey(ARBOR_COMPLETION_BINDINGS, event, (command) => {
      event.preventDefault();
      if (command === "accept") {
        acceptCompletion(editor, openCompletion);
      } else if (command === "dismiss") {
        setCompletion(null);
      } else {
        const step = command === "next" ? 1 : -1;
        setCompletion((current) => current && ({
          ...current,
          selectedIndex: (current.selectedIndex + step + current.items.length) % current.items.length,
        }));
      }
      return true;
    })) return;

    // Bindings live in keymap.ts; returning false declines so later bindings and browser defaults still run.
    dispatchKey(ARBOR_EDITOR_BINDINGS, event, (command) => {
      switch (command) {
        case "dateLeader":
          event.preventDefault();
          setCompletion(null);
          armDateLeader();
          return true;
        case "bold":
        case "italic":
          event.preventDefault();
          applyInlineFormatting(editor, blockId, command);
          return true;
        case "undo":
        case "redo":
          event.preventDefault();
          applyEdit(command === "redo" ? session.store.redo() : session.store.undo());
          return true;
        case "runRefresh":
        case "runAppend": {
          const sync = documentSync.current;
          if (!sync) return false;
          event.preventDefault();
          void sync.runProducer(blockId, command === "runAppend" ? "append" : "refresh").then((response) => {
            if (response.ok !== false && documentSync.current === sync) {
              setRevision((value) => value + 1);
            }
          }).catch(() => undefined);
          return true;
        }
        case "blur":
          event.preventDefault();
          editor.blur();
          return true;
        case "newline":
          event.preventDefault();
          insertTextAtSelection(editor, "\n");
          return true;
        case "split":
          event.preventDefault();
          applyEdit(session.store.splitBlock(blockId, offset));
          return true;
        case "indent":
        case "outdent":
          event.preventDefault();
          applyEdit(command === "outdent"
            ? session.store.outdentBlock(blockId)
            : session.store.indentBlock(blockId));
          return true;
        case "mergePrevious":
          if (!shouldMergeBlockOnBackspace(offset, window.getSelection()?.isCollapsed ?? true)) return false;
          event.preventDefault();
          applyEdit(session.store.mergeWithPrevious(blockId));
          return true;
        case "moveUp":
        case "moveDown":
          event.preventDefault();
          applyEdit(command === "moveUp"
            ? session.store.moveBlockUp(blockId)
            : session.store.moveBlockDown(blockId));
          return true;
        case "extendUp":
        case "extendDown": {
          const selection = window.getSelection();
          const direction = command === "extendUp" ? "up" : "down";
          if (!shouldExtendBlockSelection(
            direction,
            offset,
            block.text.length,
            selection?.isCollapsed ?? true,
            selectedBlockIds.size > 0,
          )) return false;
          event.preventDefault();
          const currentIndex = visibleRows.findIndex((row) => row.id === blockId);
          const target = visibleRows[currentIndex + (command === "extendUp" ? -1 : 1)];
          if (target) {
            const anchor = selectionAnchorId ?? blockId;
            copyExplicitRows.current = false;
            setSelectionAnchorId(anchor);
            setSelectionExtentId(target.id);
            setSelectedBlockIds(rangeSelection(visibleRows, anchor, target.id));
            setActiveBlockId(null);
          }
          return true;
        }
        case "stepLeft":
        case "stepRight": {
          if (!window.getSelection()?.isCollapsed) return false;
          const left = command === "stepLeft";
          const atBoundary = left ? offset === 0 : offset === block.text.length;
          if (atBoundary) {
            const currentIndex = visibleRows.findIndex((row) => row.id === blockId);
            const target = visibleRows[currentIndex + (left ? -1 : 1)];
            const targetBlock = target && session.store.getBlock(target.id);
            if (targetBlock) {
              event.preventDefault();
              requestFocus({
                blockId: targetBlock.id,
                offset: left ? targetBlock.text.length : 0,
              });
            }
          }
          return true;
        }
        case "stepUp":
        case "stepDown": {
          if (!window.getSelection()?.isCollapsed) return false;
          requestAnimationFrame(() => {
            const scroller = scrollerRef.current;
            if (editor.isConnected && scroller) scrollCaretIntoView(editor, scroller);
          });
          const up = command === "stepUp";
          if (!caretIsOnVisualLineBoundary(editor, up ? "up" : "down")) return true;
          const currentIndex = visibleRows.findIndex((row) => row.id === blockId);
          const target = visibleRows[currentIndex + (up ? -1 : 1)];
          const targetBlock = target && session.store.getBlock(target.id);
          if (targetBlock) {
            event.preventDefault();
            requestFocus({
              blockId: targetBlock.id,
              offset: Math.min(offset, targetBlock.text.length),
            });
          }
          return true;
        }
      }
    });
  };

  return (
    <div
      className="arbor-shell"
      onKeyDown={(event) => {
        if (event.target instanceof HTMLElement && event.target.isContentEditable) return;
        handleSelectionKeyDown(event);
      }}
    >
      <div className="arbor-scroller" ref={scrollerRef}>
        <main className="arbor-page">
          {zoomBlockId || pageId !== session.rootPageId ? (
            <nav className="arbor-breadcrumbs" aria-label="Outline location">
              <button
                type="button"
                onClick={() => {
                  setPageId(session.rootPageId);
                  setZoomBlockId(null);
                }}
              >
                ← Back to outline
              </button>
            </nav>
          ) : null}
          <div
            className="arbor-outline"
            ref={outlineRef}
            role="tree"
            aria-label="Outline"
            tabIndex={0}
            onDragLeave={(event) => {
              if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
                setDropTarget(null);
              }
            }}
          >
            {visibleRows.map((row) => {
              const block = session.store.getBlock(row.id);
              if (!block) return null;
              const active = activeBlockId === row.id;
              const style = { "--arbor-depth": row.depth } as CSSProperties;
              // Heading rows have a taller first line, so the bullet needs to
              // sit lower to stay centred on it. The level lives on the inner
              // heading span, which CSS cannot reach from the gutter, so
              // surface it on the row. Derived from the leading marker, the
              // same rule the Markdown parser applies.
              const headingLevel = /^(#{1,3})\s/.exec(block.text ?? "")?.[1]?.length;

              return (
                  <div
                    key={row.id}
                    className="arbor-row"
                    role="treeitem"
                    aria-level={row.depth + 1}
                    aria-selected={selectedBlockIds.has(row.id)}
                    aria-expanded={row.hasChildren ? !row.collapsed : undefined}
                    data-active={active ? "true" : "false"}
                    data-computation={block.computation?.state}
                    data-collapsed={row.collapsed ? "true" : "false"}
                    data-heading-level={headingLevel}
                    data-selected={selectedBlockIds.has(row.id) ? "true" : "false"}
                    data-drop-placement={dropTarget?.blockId === row.id ? dropTarget.placement : undefined}
                    style={style}
                    onContextMenu={(event) => {
                      if (!host?.showContextMenu) return;
                      event.preventDefault();
                      event.stopPropagation();
                      contextMenuBlockId.current = row.id;
                      host.showContextMenu({
                        x: event.clientX,
                        y: event.clientY,
                        selectionText: window.getSelection()?.toString() ?? "",
                        blockId: row.id,
                        canMoveUp: block.previousSiblingId !== null,
                        canMoveDown: block.nextSiblingId !== null,
                      });
                    }}
                    onDragOver={(event) => handleDragOver(event, row.id)}
                    onMouseMove={(event) => {
                      const state = mouseSelection.current;
                      if (!state || event.buttons !== 1) return;
                      const selection = pointerRangeSelection(
                        visibleRows,
                        state.anchorId,
                        row.id,
                        state.dragged,
                      );
                      if (!selection.dragged) return;
                      state.dragged = true;
                      copyExplicitRows.current = false;
                      window.getSelection()?.removeAllRanges();
                      setActiveBlockId(null);
                      setCompletion(null);
                      setSelectionAnchorId(state.anchorId);
                      setSelectionExtentId(selection.extentId);
                      setSelectedBlockIds(new Set(selection.selectedIds));
                    }}
                    onDrop={(event) => {
                      event.preventDefault();
                      if (dropTarget) {
                        const result = moveBlocksToTarget(
                          session.store,
                          draggedBlockIds.current,
                          dropTarget,
                        );
                        if (result.changed) setRevision((value) => value + 1);
                      }
                      setDropTarget(null);
                      draggedBlockIds.current = [];
                    }}
                  >
                    <div className="arbor-row-gutter">
                      <button
                        type="button"
                        className="arbor-bullet-button"
                        draggable
                        aria-label={row.hasChildren
                          ? row.collapsed ? "Expand block" : "Collapse block"
                          : "Zoom into block"}
                        title={row.hasChildren
                          ? "Click to collapse · Double-click to zoom · Right-click for actions"
                          : "Double-click to zoom · Right-click for actions"}
                        onClick={(event) => {
                          if (event.shiftKey || event.metaKey || event.ctrlKey) {
                            selectBlock(row.id, {
                              range: event.shiftKey,
                              additive: event.metaKey || event.ctrlKey,
                            });
                          } else if (row.hasChildren) {
                            session.store.toggleCollapsed(row.id);
                          } else {
                            selectBlock(row.id);
                          }
                        }}
                        onDoubleClick={() => {
                          setActiveBlockId(null);
                          setZoomBlockId(row.id);
                        }}
                        onDragStart={(event) => {
                          const roots = selectedBlockIds.has(row.id) && selectedRoots.length > 0
                            ? selectedRoots
                            : [row.id];
                          draggedBlockIds.current = roots;
                          copyExplicitRows.current = false;
                          setSelectedBlockIds(new Set(roots));
                          setSelectionAnchorId(row.id);
                          setSelectionExtentId(row.id);
                          event.dataTransfer.effectAllowed = "move";
                          event.dataTransfer.setData("text/plain", String(row.id));
                        }}
                        onDragEnd={() => {
                          draggedBlockIds.current = [];
                          setDropTarget(null);
                        }}
                      />
                    </div>

                    <div className="arbor-block">
                      {active ? (
                        <div
                          key={`editor:${row.id}`}
                          ref={(element) => {
                            if (element) {
                              editorRefs.current.set(row.id, element);
                              if (!initializedEditors.current.has(element)) {
                                initializedEditors.current.add(element);
                                element.textContent = block.text;
                              }
                            } else {
                              editorRefs.current.delete(row.id);
                            }
                          }}
                          className="arbor-block-editor"
                          contentEditable="plaintext-only"
                          suppressContentEditableWarning
                          role="textbox"
                          aria-multiline="true"
                          aria-label="Outline block"
                          aria-autocomplete="list"
                          aria-controls={completion?.blockId === row.id
                            ? "arbor-outline-completions"
                            : undefined}
                          data-placeholder="Write something…"
                          spellCheck
                          onMouseDown={(event) => {
                            if (event.shiftKey || event.metaKey || event.ctrlKey) {
                              event.preventDefault();
                              selectBlock(row.id, {
                                range: event.shiftKey,
                                additive: event.metaKey || event.ctrlKey,
                              });
                              return;
                            }
                            mouseSelection.current = {
                              anchorId: row.id,
                              focusTarget: null,
                              dragged: false,
                            };
                          }}
                          onInput={(event) => {
                            const current = session.store.getBlock(row.id);
                            const rawText = plainText(event.currentTarget);
                            const range = changedRange(current?.text ?? "", rawText);
                            const substitution = applyNv3TextSubstitutions(
                              rawText,
                              range.from,
                              range.to,
                              context?.substitutionRules,
                            );
                            const text = substitution.text;
                            if (substitution.changes.length > 0) {
                              const caret = caretOffset(event.currentTarget);
                              event.currentTarget.textContent = text;
                              focusEditor(
                                event.currentTarget,
                                offsetAfterSubstitutions(caret, substitution.changes),
                              );
                            }
                            const computation = current?.computation;
                            const wasManaged = isManagedComputation(computation);
                            const sourceBacked = computation?.state === "live"
                              && computation.updatePolicy === "source-text";
                            session.store.setBlockText(row.id, text, {
                              historyGroup: `typing:${row.id}:${typingSession.current}`,
                              preserveComputation: sourceBacked,
                            });
                            if (sourceBacked) editedSourceResults.current.add(row.id);
                            if (wasManaged) setRevision((value) => value + 1);
                            updateCompletion(event.currentTarget, row.id);
                          }}
                          onKeyDown={(event) => handleKeyDown(event, row.id)}
                          onCompositionStart={() => {
                            isComposing.current = true;
                            completionRequest.current += 1;
                            setCompletion(null);
                          }}
                          onCompositionEnd={(event) => {
                            isComposing.current = false;
                            updateCompletion(event.currentTarget, row.id);
                          }}
                          onPaste={(event) => {
                            event.preventDefault();
                            pasteBlocks(
                              event.currentTarget,
                              row.id,
                              event.clipboardData.getData("text/plain"),
                            );
                          }}
                          onBlur={(event) => {
                            clearDateLeader();
                            const offset = caretOffset(event.currentTarget);
                            const computation = session.store.getBlock(row.id)?.computation;
                            const sourceBacked = computation?.state === "live"
                              && computation.updatePolicy === "source-text";
                            const text = plainText(event.currentTarget);
                            session.store.setBlockText(row.id, text, {
                              historyGroup: `typing:${row.id}:${typingSession.current}`,
                              preserveComputation: sourceBacked,
                            });
                            if (sourceBacked && editedSourceResults.current.delete(row.id)) {
                              void documentSync.current?.applyIntent(row.id, text).then(() => {
                                setRevision((value) => value + 1);
                              }).catch(() => undefined);
                            }
                            setCompletion(null);
                            requestAnimationFrame(() => {
                              if (!document.hasFocus()) {
                                suspendedFocus.current = { blockId: row.id, offset };
                                return;
                              }
                              setActiveBlockId((current) => current === row.id ? null : current);
                              setRevision((value) => value + 1);
                            });
                          }}
                        />
                      ) : (
                        <div
                          key={`rendered:${row.id}`}
                          className="arbor-block-rendered"
                          role="button"
                          tabIndex={0}
                          onMouseDown={(event) => {
                            if (event.shiftKey || event.metaKey || event.ctrlKey) {
                              event.preventDefault();
                              selectBlock(row.id, {
                                range: event.shiftKey,
                                additive: event.metaKey || event.ctrlKey,
                              });
                              return;
                            }
                            const target = {
                              blockId: row.id,
                              offset: sourceOffsetAtPoint(event, block.text.length),
                            };
                            mouseSelection.current = {
                              anchorId: row.id,
                              focusTarget: target,
                              dragged: false,
                            };
                            copyExplicitRows.current = false;
                            setSelectedBlockIds(new Set());
                            setSelectionAnchorId(null);
                            setSelectionExtentId(null);
                          }}
                          onKeyDown={(event) => {
                            if (event.key !== "Enter" && event.key !== " ") return;
                            event.preventDefault();
                            requestFocus({ blockId: row.id, offset: block.text.length });
                          }}
                        >
                          <ArborMarkdownView
                            source={block.text}
                            onNavigate={navigate}
                            onTaskToggle={(checked) => {
                              const text = setArborMarkdownTaskChecked(block.text, checked);
                              if (text === block.text) return;
                              session.store.setBlockText(row.id, text);
                              setRevision((value) => value + 1);
                            }}
                          />
                        </div>
                      )}
                    </div>
                  </div>
              );
            })}
          </div>
        </main>
        {completion ? (
          <Popover open modal={false}>
            <PopoverContent
              anchor={completionAnchor}
              className="arbor-completion"
              role="listbox"
              id="arbor-outline-completions"
              aria-label="Outline completions"
              initialFocus={false}
              finalFocus={false}
            >
              <div className="arbor-completion-list">
                {completion.items.map((item, index) => (
                  <div
                    role="option"
                    aria-selected={index === completion.selectedIndex}
                    className="arbor-completion-item"
                    key={`${item.detail}:${item.id}`}
                    onMouseMove={() => {
                      if (index !== completion.selectedIndex) {
                        setCompletion({ ...completion, selectedIndex: index });
                      }
                    }}
                    onMouseDown={(event) => {
                      event.preventDefault();
                      const editor = editorRefs.current.get(completion.blockId);
                      if (editor) acceptCompletion(editor, { ...completion, selectedIndex: index });
                    }}
                  >
                    <span>{item.label}</span>
                    <small>{item.detail}</small>
                  </div>
                ))}
              </div>
            </PopoverContent>
          </Popover>
        ) : null}
        <div
          className="nv3-leader-overlay"
          data-nv3-open={dateLeaderOpen ? "true" : "false"}
          aria-hidden={!dateLeaderOpen}
        >
          <div className="nv3-leader-overlay-title">⌘; shortcuts</div>
          <div className="nv3-leader-overlay-list">
            <div className="nv3-leader-overlay-item"><kbd>.</kbd><span>Insert today</span></div>
            <div className="nv3-leader-overlay-item"><kbd>D</kbd><span>Insert today + calendar</span></div>
          </div>
        </div>
      </div>
    </div>
  );
}
