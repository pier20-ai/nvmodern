import { EditorState, RangeSetBuilder, StateField, type Extension } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  WidgetType,
} from "@codemirror/view";
import { resolveDocumentScanIndex } from "./documentIndex.ts";
import { scanMarkdownText } from "./markdownScanner.ts";

export interface Nv3TransclusionResolveInput {
  target: string;
  filePath?: string;
  depth: number;
  signal: AbortSignal;
  requestKind: "transclusion.resolve";
}

export interface Nv3TransclusionResolved {
  content: string;
  kind?: string;
  filePath?: string;
}

export interface Nv3TransclusionSaveInput {
  target: string;
  filePath?: string;
  depth: number;
  content: string;
  signal: AbortSignal;
  requestKind: "transclusion.save";
}

export interface Nv3TransclusionNestedStateInput {
  target: string;
  filePath?: string;
  depth: number;
  content: string;
  onDocChange: (doc: string) => void;
}

export interface MarkdownTransclusionOptions {
  filePath?: string;
  depth?: number;
  maxDepth?: number;
  saveDebounceMs?: number;
  resolveTransclusion?: (
    input: Nv3TransclusionResolveInput,
  ) => Promise<Nv3TransclusionResolved | null>;
  saveTransclusion?: (input: Nv3TransclusionSaveInput) => Promise<void>;
  createNestedState?: (input: Nv3TransclusionNestedStateInput) => EditorState;
}

interface TransclusionOccurrence {
  target: string;
  from: number;
  to: number;
  line: number;
}

export interface Nv3StandaloneTransclusionOccurrence {
  target: string;
  from: number;
  to: number;
  line: number;
}

const DEFAULT_SAVE_DEBOUNCE_MS = 450;
const TRANSCLUSION_ESTIMATED_HEIGHT_PX = 220;

function standaloneTransclusionsFromState(
  state: import("@codemirror/state").EditorState,
): TransclusionOccurrence[] {
  return resolveDocumentScanIndex(state).transclusions.map((o) => ({
    target: o.target,
    from: o.from,
    to: o.to,
    line: o.line,
  }));
}

export function detectStandaloneTransclusions(
  docText: string,
): Nv3StandaloneTransclusionOccurrence[] {
  return scanMarkdownText(docText).standaloneTransclusions.map((occurrence) => ({
    target: occurrence.target,
    from: occurrence.from,
    to: occurrence.to,
    line: occurrence.line,
  }));
}

class MarkdownTransclusionWidget extends WidgetType {
  private static cleanupMap = new WeakMap<HTMLElement, () => void>();

  constructor(
    readonly occurrence: TransclusionOccurrence,
    readonly options: MarkdownTransclusionOptions,
    readonly depth: number,
  ) {
    super();
  }

  override eq(other: MarkdownTransclusionWidget): boolean {
    return (
      other.occurrence.from === this.occurrence.from &&
      other.occurrence.to === this.occurrence.to &&
      other.occurrence.target === this.occurrence.target &&
      other.depth === this.depth
    );
  }

  override get estimatedHeight(): number {
    return TRANSCLUSION_ESTIMATED_HEIGHT_PX;
  }

  private static setBodyState(
    root: HTMLElement,
    body: HTMLElement,
    status: HTMLElement,
    state:
      | "loading"
      | "ready"
      | "missing"
      | "error"
      | "depth-limit"
      | "saving"
      | "dirty"
      | "saved",
    label: string,
  ): void {
    body.dataset.nv3TransclusionState = state;
    root.dataset.nv3TransclusionState = state;
    status.dataset.nv3TransclusionState = state;
    status.setAttribute("title", label);
    status.setAttribute("aria-label", label);
    status.textContent = "";
  }

  override toDOM(): HTMLElement {
    const root = document.createElement("div");
    root.className = "nv3-transclusion-block";
    root.setAttribute("data-nv3-target", this.occurrence.target);

    const header = document.createElement("div");
    header.className = "nv3-transclusion-header";
    header.setAttribute("role", "button");
    header.setAttribute("aria-expanded", "true");
    header.setAttribute("title", "Hide transclusion preview");

    const target = document.createElement("code");
    target.className = "nv3-transclusion-target";
    target.textContent = this.occurrence.target;

    const status = document.createElement("span");
    status.className = "nv3-transclusion-status";

    header.append(status, target);

    const body = document.createElement("div");
    body.className = "nv3-transclusion-body";

    root.append(header, body);

    let isCollapsed = false;
    const setCollapsed = (collapsed: boolean) => {
      isCollapsed = collapsed;
      root.dataset.nv3TransclusionCollapsed = collapsed ? "true" : "false";
      body.hidden = collapsed;
      header.setAttribute("aria-expanded", collapsed ? "false" : "true");
      header.setAttribute(
        "title",
        collapsed ? "Show transclusion preview" : "Hide transclusion preview",
      );
    };

    header.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      setCollapsed(!isCollapsed);
    });

    if (!this.options.resolveTransclusion) {
      body.textContent = "No transclusion resolver configured.";
      MarkdownTransclusionWidget.setBodyState(
        root,
        body,
        status,
        "error",
        "Resolver missing",
      );
      return root;
    }

    if (this.depth >= (this.options.maxDepth ?? 1)) {
      body.textContent = "Nested transclusion depth limit reached.";
      MarkdownTransclusionWidget.setBodyState(
        root,
        body,
        status,
        "depth-limit",
        "Depth limit reached",
      );
      return root;
    }

    MarkdownTransclusionWidget.setBodyState(root, body, status, "loading", "Loading");

    const loadController = new AbortController();
    let saveController: AbortController | null = null;
    let saveTimer: ReturnType<typeof setTimeout> | null = null;
    let nestedView: EditorView | null = null;
    let resolvedFilePath: string | undefined;
    let lastSavedContent: string | null = null;

    const dispose = () => {
      loadController.abort();
      saveController?.abort();
      if (saveTimer) {
        clearTimeout(saveTimer);
        saveTimer = null;
      }
      if (nestedView) {
        nestedView.destroy();
        nestedView = null;
      }
    };

    MarkdownTransclusionWidget.cleanupMap.set(root, dispose);

    const scheduleSave = (docText: string) => {
      if (!this.options.saveTransclusion) return;
      if (lastSavedContent !== null && docText === lastSavedContent) return;

      MarkdownTransclusionWidget.setBodyState(root, body, status, "dirty", "Unsaved");

      if (saveTimer) {
        clearTimeout(saveTimer);
        saveTimer = null;
      }

      saveTimer = setTimeout(async () => {
        saveTimer = null;
        saveController?.abort();
        saveController = new AbortController();

        MarkdownTransclusionWidget.setBodyState(root, body, status, "saving", "Saving");

        try {
          await this.options.saveTransclusion?.({
            target: this.occurrence.target,
            filePath: resolvedFilePath ?? this.options.filePath,
            depth: this.depth,
            content: docText,
            signal: saveController.signal,
            requestKind: "transclusion.save",
          });

          if (saveController.signal.aborted) return;
          lastSavedContent = docText;
          MarkdownTransclusionWidget.setBodyState(root, body, status, "saved", "Saved");
        } catch (error) {
          if (saveController.signal.aborted) return;
          MarkdownTransclusionWidget.setBodyState(
            root,
            body,
            status,
            "error",
            "Save failed",
          );
          console.warn("[nv3 transclusion] save failed", error);
        }
      }, this.options.saveDebounceMs ?? DEFAULT_SAVE_DEBOUNCE_MS);
    };

    const mountNestedEditor = (content: string, nestedFilePath?: string) => {
      body.textContent = "";

      const nestedState = this.options.createNestedState
        ? this.options.createNestedState({
            target: this.occurrence.target,
            filePath: nestedFilePath ?? this.options.filePath,
            depth: this.depth + 1,
            content,
            onDocChange: scheduleSave,
          })
        : EditorState.create({
            doc: content,
            extensions: [
              EditorView.lineWrapping,
              EditorView.updateListener.of((update) => {
                if (!update.docChanged) return;
                scheduleSave(update.state.doc.toString());
              }),
            ],
          });

      nestedView = new EditorView({
        state: nestedState,
        parent: body,
      });

      MarkdownTransclusionWidget.setBodyState(root, body, status, "ready", "Ready");
    };

    void (async () => {
      try {
        const resolved = await this.options.resolveTransclusion?.({
          target: this.occurrence.target,
          filePath: this.options.filePath,
          depth: this.depth,
          signal: loadController.signal,
          requestKind: "transclusion.resolve",
        });

        if (loadController.signal.aborted) return;

        if (!resolved) {
          body.textContent = `Could not resolve transclusion target: ${this.occurrence.target}`;
          MarkdownTransclusionWidget.setBodyState(
            root,
            body,
            status,
            "missing",
            "Target missing",
          );
          return;
        }

        resolvedFilePath = resolved.filePath;
        lastSavedContent = resolved.content;
        mountNestedEditor(resolved.content, resolved.filePath);
      } catch (error) {
        if (loadController.signal.aborted) return;
        body.textContent = `Failed to load transclusion target: ${this.occurrence.target}`;
        MarkdownTransclusionWidget.setBodyState(root, body, status, "error", "Load failed");
        console.warn("[nv3 transclusion] resolve failed", error);
      }
    })();

    return root;
  }

  override destroy(dom: HTMLElement): void {
    MarkdownTransclusionWidget.cleanupMap.get(dom)?.();
    MarkdownTransclusionWidget.cleanupMap.delete(dom);
  }

  override ignoreEvent(): boolean {
    return true;
  }
}

function buildTransclusionDecorations(
  state: import("@codemirror/state").EditorState,
  options: MarkdownTransclusionOptions,
  depth: number,
): { decorations: DecorationSet; occurrences: TransclusionOccurrence[] } {
  const builder = new RangeSetBuilder<Decoration>();
  const occurrences = standaloneTransclusionsFromState(state);

  for (const occurrence of occurrences) {
    builder.add(
      occurrence.from,
      occurrence.to,
      Decoration.replace({
        block: true,
        widget: new MarkdownTransclusionWidget(occurrence, options, depth),
      }),
    );
  }

  return {
    decorations: builder.finish(),
    occurrences,
  };
}

export function createMarkdownTransclusionExtension(
  options: MarkdownTransclusionOptions,
): Extension {
  if (!options.resolveTransclusion) {
    return [];
  }

  const depth = options.depth ?? 0;

  const transclusionDecorationsField = StateField.define<DecorationSet>({
    create(state) {
      return buildTransclusionDecorations(state, options, depth).decorations;
    },

    update(decorations, transaction) {
      if (!transaction.docChanged) return decorations;
      return buildTransclusionDecorations(transaction.state, options, depth).decorations;
    },

    provide(field) {
      return EditorView.decorations.from(field);
    },
  });

  return transclusionDecorationsField;
}
