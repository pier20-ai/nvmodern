import { mount, type Mounted } from "pele";
import { StateField, type EditorState, type Extension } from "@codemirror/state";
import { Decoration, EditorView, WidgetType, type DecorationSet } from "@codemirror/view";
import { resolveDocumentScanIndex } from "./documentIndex.ts";

export interface MermaidBlock {
  from: number;
  source: string;
}

export function mermaidBlocks(state: EditorState): MermaidBlock[] {
  return resolveDocumentScanIndex(state).codeBlocks
    .filter((block) => block.closed && block.language?.toLowerCase() === "mermaid")
    .map((block) => ({
      from: state.doc.line(block.toLine).to,
      source: state.sliceDoc(state.doc.line(block.fromLine).to + 1, state.doc.line(block.toLine).from),
    }));
}

class PreviewController {
  readonly root = document.createElement("div");
  private readonly diagram = document.createElement("div");
  private readonly status = document.createElement("div");
  private readonly media = window.matchMedia("(prefers-color-scheme: dark)");
  private readonly observer: MutationObserver;
  private readonly resize: ResizeObserver;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private mounted: Mounted | undefined;
  private source = "";
  private hasPreview = false;
  private destroyed = false;

  constructor(private readonly view: EditorView, source: string) {
    this.root.className = "nv3-mermaid-preview";
    this.root.contentEditable = "false";
    this.diagram.className = "nv3-mermaid-diagram";
    this.diagram.setAttribute("role", "img");
    this.diagram.setAttribute("aria-label", "Mermaid diagram");
    this.status.className = "nv3-mermaid-status";
    this.status.setAttribute("role", "status");
    this.root.append(this.diagram, this.status);
    this.observer = new MutationObserver(this.refresh);
    this.observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    this.media.addEventListener("change", this.refresh);
    this.resize = new ResizeObserver(() => this.view.requestMeasure());
    this.resize.observe(this.root);
    this.update(source);
  }

  private refresh = () => this.mounted?.refresh();

  update(source: string): void {
    if (source === this.source && (this.timer !== undefined || this.mounted)) return;
    this.source = source;
    this.schedule();
  }

  private schedule(): void {
    clearTimeout(this.timer);
    this.status.textContent = this.hasPreview ? "Preview outdated — updating…" : "Rendering diagram…";
    this.timer = setTimeout(() => {
      this.timer = undefined;
      if (this.destroyed) return;
      if (this.mounted) {
        this.mounted.update(this.source);
      } else {
        this.mounted = mount(this.diagram, this.source, {
          limit: 50_000,
          maxEdges: 500,
          zoom: false,
          onRender: () => {
            this.hasPreview = true;
            this.status.textContent = "";
            this.view.requestMeasure();
          },
          // Pele retains the last good drawing and displays the escaped error itself.
          onError: () => {
            this.status.textContent = this.hasPreview ? "Preview outdated." : "";
            this.view.requestMeasure();
          },
        });
      }
      this.view.requestMeasure();
    }, 300);
  }

  destroy(): void {
    this.destroyed = true;
    this.mounted?.destroy();
    clearTimeout(this.timer);
    this.observer.disconnect();
    this.resize.disconnect();
    this.media.removeEventListener("change", this.refresh);
  }
}

const controllers = new WeakMap<HTMLElement, PreviewController>();

class MermaidPreviewWidget extends WidgetType {
  constructor(readonly source: string) { super(); }
  override eq(other: MermaidPreviewWidget): boolean { return this.source === other.source; }
  override get estimatedHeight(): number { return 200; }
  override toDOM(view: EditorView): HTMLElement {
    const controller = new PreviewController(view, this.source);
    controllers.set(controller.root, controller);
    return controller.root;
  }
  override updateDOM(dom: HTMLElement): boolean {
    const controller = controllers.get(dom);
    if (!controller) return false;
    controller.update(this.source);
    return true;
  }
  override destroy(dom: HTMLElement): void { controllers.get(dom)?.destroy(); }
  override ignoreEvent(): boolean { return true; }
}

function decorations(state: EditorState): DecorationSet {
  return Decoration.set(mermaidBlocks(state).map((block) =>
    Decoration.widget({ block: true, side: 1, widget: new MermaidPreviewWidget(block.source) }).range(block.from),
  ));
}

export function createMarkdownMermaidExtension(): Extension {
  return StateField.define<DecorationSet>({
    create: decorations,
    update(value, transaction) {
      return transaction.docChanged ? decorations(transaction.state) : value;
    },
    provide: (field) => EditorView.decorations.from(field),
  });
}
