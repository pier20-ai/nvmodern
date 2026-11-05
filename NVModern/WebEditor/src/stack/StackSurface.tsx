/**
 * Side stack surface: a vertically scrolling column of read-only note cards
 * beside a tab's content. Each expanded card renders its note with the editor
 * library (same plugins and theme as the main editor) in a non-editable
 * CodeMirror view. The surface is host-agnostic: it renders `StackState` and
 * reports user intent through `StackHost.emit`; `stack.tsx` wires that to the
 * native bridge and the dev shell to a local mock.
 */
import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Annotation, EditorState, type Extension } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import {
  createNv3EditorState,
  parseNv3WikilinkTarget,
  type CreateNv3EditorStateOptions,
  type Nv3TransclusionResolveInput,
  type Nv3TransclusionResolved,
} from "../lib/index.ts";
import {
  resolveInlineWorkspaceHref,
  resolvePreviewImageUrl,
  resolveWikilinkHref,
  resolveWorkspaceRelativePath,
} from "../editorHost.ts";
import {
  focusFromWikilinkTarget,
  focusLabel,
  reconcileOverrides,
  stackCardDisplay,
  stackLinkIntent,
  type StackCard,
  type StackClickModifiers,
  type StackState,
} from "./model.ts";

export interface StackHost {
  emit(event: string, payload?: Record<string, unknown>): void;
  resolveTransclusion?: (input: Nv3TransclusionResolveInput) => Promise<Nv3TransclusionResolved | null>;
}

/** A one-shot request (reveal, flash, focus); `nonce` makes repeats distinct. */
export interface StackRequest {
  id: string | null;
  nonce: number;
}

export interface StackSurfaceProps {
  state: StackState;
  host: StackHost;
  reveal?: StackRequest | null;
  flash?: StackRequest | null;
  focus?: StackRequest | null;
}

/** Marks the only transactions allowed to change a card's text: host updates. */
const hostSync = Annotation.define<boolean>();

const READ_ONLY_EXTENSIONS: Extension[] = [
  EditorState.readOnly.of(true),
  EditorView.editable.of(false),
  // Widgets (tables, checkboxes, TODO keywords) dispatch edits directly;
  // only host updates may change a card.
  EditorState.changeFilter.of((transaction) => transaction.annotation(hostSync) === true),
  EditorView.contentAttributes.of({ spellcheck: "false", autocorrect: "off", autocapitalize: "off" }),
];

function modifiersOf(event: MouseEvent): StackClickModifiers {
  return {
    shiftKey: event.shiftKey,
    metaKey: event.metaKey,
    altKey: event.altKey,
    ctrlKey: event.ctrlKey,
  };
}

export function StackSurface({ state, host, reveal, flash, focus }: StackSurfaceProps) {
  const [collapsedOverrides, setCollapsedOverrides] = useState<Map<string, boolean>>(() => new Map());
  const [wholeNoteOverrides, setWholeNoteOverrides] = useState<Map<string, boolean>>(() => new Map());
  const cardElements = useRef(new Map<string, HTMLElement>());

  useEffect(() => {
    setCollapsedOverrides((current) => reconcileOverrides(current, state.cards, (card) => card.collapsed));
    setWholeNoteOverrides((current) => reconcileOverrides(current, state.cards, (card) => card.showWholeNote));
  }, [state.cards]);

  useLayoutEffect(() => {
    if (!reveal?.id) return;
    cardElements.current.get(reveal.id)?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }, [reveal?.id, reveal?.nonce]);

  useEffect(() => {
    if (!focus) return;
    const id = focus.id ?? state.cards[0]?.id;
    const element = id ? cardElements.current.get(id) : null;
    const title = element?.querySelector<HTMLElement>(".nv-stack-card-title");
    title?.focus({ preventScroll: true });
    element?.scrollIntoView({ block: "nearest" });
  }, [focus?.id, focus?.nonce]);

  if (state.cards.length === 0) {
    return (
      <div className="nv-stack nv-stack-is-empty">
        <p className="nv-stack-empty">Shift-click a link to keep its note here.</p>
      </div>
    );
  }

  return (
    <div className="nv-stack">
      {state.cards.map((card) => {
        const collapsed = collapsedOverrides.get(card.id) ?? card.collapsed;
        const showWholeNote = wholeNoteOverrides.get(card.id) ?? card.showWholeNote ?? false;
        return (
          <StackCardView
            key={card.id}
            card={card}
            collapsed={collapsed}
            showWholeNote={showWholeNote}
            flashNonce={flash?.id === card.id ? flash.nonce : 0}
            host={host}
            registerElement={(element) => {
              if (element) cardElements.current.set(card.id, element);
              else cardElements.current.delete(card.id);
            }}
            onToggleCollapsed={() => {
              const next = !collapsed;
              setCollapsedOverrides((current) => new Map(current).set(card.id, next));
              host.emit("stackCollapse", { id: card.id, collapsed: next });
            }}
            onToggleWholeNote={() => {
              const next = !showWholeNote;
              setWholeNoteOverrides((current) => new Map(current).set(card.id, next));
              host.emit("stackShowWholeNote", { id: card.id, showWholeNote: next });
            }}
          />
        );
      })}
    </div>
  );
}

interface StackCardViewProps {
  card: StackCard;
  collapsed: boolean;
  showWholeNote: boolean;
  flashNonce: number;
  host: StackHost;
  registerElement: (element: HTMLElement | null) => void;
  onToggleCollapsed: () => void;
  onToggleWholeNote: () => void;
}

function StackCardView({
  card,
  collapsed,
  showWholeNote,
  flashNonce,
  host,
  registerElement,
  onToggleCollapsed,
  onToggleWholeNote,
}: StackCardViewProps) {
  const elementRef = useRef<HTMLElement | null>(null);
  const display = useMemo(() => stackCardDisplay(card, showWholeNote), [card, showWholeNote]);
  const label = focusLabel(card.focus);
  const [sectionReveal, setSectionReveal] = useState<{ from: number; nonce: number } | null>(null);

  const toggleWholeNote = () => {
    // Expanding to the whole note keeps the section in view.
    if (display.showingSection && display.section) {
      const from = display.section.from;
      setSectionReveal((current) => ({ from, nonce: (current?.nonce ?? 0) + 1 }));
    }
    onToggleWholeNote();
  };

  useEffect(() => {
    const element = elementRef.current;
    if (!flashNonce || !element) return;
    element.scrollIntoView({ block: "nearest", behavior: "smooth" });
    element.classList.remove("is-flashing");
    void element.offsetWidth; // restart the animation
    element.classList.add("is-flashing");
    const timer = window.setTimeout(() => element.classList.remove("is-flashing"), 1_000);
    return () => window.clearTimeout(timer);
  }, [flashNonce]);

  const openInMain = (event: React.MouseEvent) => {
    host.emit("stackOpenInMain", {
      id: card.id,
      path: card.path,
      focus: card.focus,
      ...modifiersOf(event.nativeEvent),
    });
  };

  return (
    <section
      className={`nv-stack-card${collapsed ? " is-collapsed" : ""}`}
      data-stack-card-id={card.id}
      aria-label={card.title}
      ref={(element) => {
        elementRef.current = element;
        registerElement(element);
      }}
    >
      <header className="nv-stack-card-header">
        <button
          type="button"
          className="nv-stack-card-icon nv-stack-card-toggle"
          aria-expanded={!collapsed}
          title={collapsed ? "Expand" : "Collapse"}
          onClick={onToggleCollapsed}
        >
          <ChevronIcon />
        </button>
        <button type="button" className="nv-stack-card-title" title={`Open ${card.path}`} onClick={openInMain}>
          <span className="nv-stack-card-title-text">{card.title}</span>
          {label ? <span className="nv-stack-card-focus">{label}</span> : null}
        </button>
        <span className="nv-stack-card-actions">
          <button type="button" className="nv-stack-card-icon" title="Open in main view" onClick={openInMain}>
            <OpenIcon />
          </button>
          <button
            type="button"
            className="nv-stack-card-icon"
            title="Close"
            onClick={() => host.emit("stackClose", { id: card.id })}
          >
            <CloseIcon />
          </button>
        </span>
      </header>
      {collapsed ? null : (
        <div className="nv-stack-card-body">
          <StackCardEditor card={card} doc={display.doc} host={host} reveal={sectionReveal} />
          {card.focus ? (
            display.sectionMissing ? (
              <p className="nv-stack-card-note">“{label}” isn’t in this note now — showing all of it.</p>
            ) : (
              <button type="button" className="nv-stack-card-scope" onClick={toggleWholeNote}>
                {display.showingSection ? "Show whole note" : `Show only “${label}”`}
              </button>
            )
          ) : null}
        </div>
      )}
    </section>
  );
}

interface StackCardEditorProps {
  card: StackCard;
  doc: string;
  host: StackHost;
  /** Scrolls this offset into view; set when the whole note replaces a section. */
  reveal: { from: number; nonce: number } | null;
}

function StackCardEditor({ card, doc, host, reveal }: StackCardEditorProps) {
  const mountRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const cardRef = useRef(card);
  const hostRef = useRef(host);
  cardRef.current = card;
  hostRef.current = host;

  useEffect(() => {
    const mount = mountRef.current;
    if (!mount) return;

    const filePath = card.path;
    const fileType = card.fileType;
    const richText = fileType === "markdown" || fileType === "org";

    const emitLink = (event: string, payload: Record<string, unknown>, mouse: MouseEvent) => {
      const current = cardRef.current;
      const modifiers = modifiersOf(mouse);
      hostRef.current.emit(event, {
        id: current.id,
        fromPath: current.path,
        ...payload,
        intent: stackLinkIntent(modifiers),
        ...modifiers,
      });
    };

    const options: CreateNv3EditorStateOptions = {
      filePath,
      fileType,
      onWikilinkOpen: ({ target, href, event }) => {
        emitLink(
          "stackLinkOpen",
          { target, href, note: parseNv3WikilinkTarget(target).note, focus: focusFromWikilinkTarget(target) },
          event,
        );
      },
      onInlineLinkOpen: ({ href, label, event }) => {
        emitLink(
          "stackInlineLinkOpen",
          { href, label, resolvedPath: resolveWorkspaceRelativePath(href, cardRef.current.path) },
          event,
        );
      },
      // Read-only: no TODO state popover.
      onOrgTodoMenuOpen: () => {},
      resolveWikilinkHref: ({ target }) => resolveWikilinkHref(target),
      resolveInlineLinkHref: ({ href }) => resolveInlineWorkspaceHref(href, filePath),
      resolveImageUrl: (src: string, sourcePath?: string) => resolvePreviewImageUrl(src, sourcePath ?? filePath),
      resolveTransclusion: hostRef.current.resolveTransclusion,
      latexPreviewMode: richText ? "katex" : "none",
      maxTransclusionDepth: 1,
      extraExtensions: READ_ONLY_EXTENSIONS,
    };
    options.createNestedTransclusionState = (input) =>
      createNv3EditorState({
        ...options,
        doc: input.content,
        filePath: input.filePath ?? filePath,
        fileType: undefined,
        _transclusionDepth: input.depth,
      });

    const view = new EditorView({
      state: createNv3EditorState({ ...options, doc }),
      parent: mount,
    });
    viewRef.current = view;

    // Table cells enter edit mode on click; in a card they stay inert.
    const blockTableEditing = (event: Event) => {
      const target = event.target instanceof Element ? event.target : null;
      if (!target?.closest(".nv3-table-ui-cell-content")) return;
      event.preventDefault();
      event.stopPropagation();
    };
    mount.addEventListener("mousedown", blockTableEditing, true);
    mount.addEventListener("click", blockTableEditing, true);

    return () => {
      mount.removeEventListener("mousedown", blockTableEditing, true);
      mount.removeEventListener("click", blockTableEditing, true);
      view.destroy();
      viewRef.current = null;
    };
    // The view is rebuilt only when the note's identity or language changes;
    // text updates go through the effect below.
  }, [card.path, card.fileType]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    const current = view.state.doc.toString();
    if (current === doc) return;
    view.dispatch({
      changes: { from: 0, to: current.length, insert: doc },
      selection: { anchor: 0 },
      annotations: hostSync.of(true),
    });
  }, [doc]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view || !reveal || reveal.from <= 0 || reveal.from > view.state.doc.length) return;
    view.dispatch({ effects: EditorView.scrollIntoView(reveal.from, { y: "start", yMargin: 48 }) });
  }, [reveal?.nonce]);

  return <div className="nv-stack-card-editor" ref={mountRef} />;
}

function ChevronIcon() {
  return (
    <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
      <path d="M4.5 6.25 8 9.75l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function OpenIcon() {
  return (
    <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
      <path
        d="M6.5 3.5h-2a1 1 0 0 0-1 1v7a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1v-2M9 3.5h3.5V7M12.25 3.75 7.5 8.5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
      <path d="m4.5 4.5 7 7m0-7-7 7" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  );
}
