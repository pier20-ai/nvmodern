import React from "react";
import { createRoot } from "react-dom/client";
import type { Root } from "react-dom/client";
import { Excalidraw, serializeAsJSON } from "@excalidraw/excalidraw";
import type { ExcalidrawInitialDataState } from "@excalidraw/excalidraw/types";

const host = document.getElementById("root");
if (!host) throw new Error("Canvas root is missing");

function post(event: string, payload: Record<string, unknown> = {}) {
  window.webkit?.messageHandlers?.nvmodernCanvas?.postMessage({ event, payload });
}

let latestScene: string | null = null;
let lastSentScene: string | null = null;
let mounted = false;
let canvasRoot: Root | null = null;
let canvasData: ExcalidrawInitialDataState | null = null;
let canvasReadOnly = false;
let desiredAppearance: "light" | "dark" | null = null;

function flush() {
  if (latestScene && latestScene !== lastSentScene) {
    lastSentScene = latestScene;
    post("change", { scene: latestScene });
  }
}

type CanvasChangeHandler = NonNullable<React.ComponentProps<typeof Excalidraw>["onChange"]>;

const onCanvasChange: CanvasChangeHandler = (elements, appState, files) => {
  const serialized = serializeAsJSON(elements, appState, files, "local");
  if (latestScene === null) {
    // Initial hydration is not an edit; opening a file must preserve its bytes.
    latestScene = serialized;
    lastSentScene = serialized;
    return;
  }
  if (serialized === latestScene) return;
  latestScene = serialized;
  flush();
};

function renderCanvas() {
  if (!canvasRoot || !canvasData || !desiredAppearance) return;
  canvasRoot.render(
    <Excalidraw
      initialData={canvasData}
      theme={desiredAppearance}
      viewModeEnabled={canvasReadOnly}
      onChange={onCanvasChange}
    />,
  );
}

function load(scene: string, appearance: "light" | "dark", isReadOnly: boolean) {
  if (mounted) return;
  const initialData = JSON.parse(scene) as ExcalidrawInitialDataState & { type?: string };
  if (initialData.type !== "excalidraw" || !Array.isArray(initialData.elements)) {
    throw new Error("This file is not an Excalidraw scene");
  }
  mounted = true;
  canvasData = initialData;
  canvasReadOnly = isReadOnly;
  desiredAppearance ??= appearance;
  canvasRoot = createRoot(host);
  renderCanvas();
}

function setAppearance(appearance: "light" | "dark") {
  if (desiredAppearance === appearance) return;
  desiredAppearance = appearance;
  renderCanvas();
}

window.nvmodernCanvasLoad = load;
window.nvmodernCanvasSetAppearance = setAppearance;
window.nvmodernCanvasFlush = flush;
window.addEventListener("pagehide", flush);
// Excalidraw handles these shortcuts on the document. Prevent WebKit's own
// unhandled-key action from ringing the system bell after the tool switches.
window.addEventListener("keydown", (event) => {
  if (event.metaKey || event.ctrlKey || event.altKey || event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement || (event.target instanceof HTMLElement && event.target.isContentEditable)) return;
  if (["r", "a", "l", "e", "d", "o", "p", "f", "t", "v", "h", "q", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].includes(event.key.toLowerCase())) event.preventDefault();
}, true);
window.addEventListener("error", (event) => post("error", { message: event.message }));
window.addEventListener("unhandledrejection", (event) => post("error", { message: String(event.reason) }));
post("ready");

declare global {
  interface Window {
    webkit?: { messageHandlers?: { nvmodernCanvas?: { postMessage: (message: unknown) => void } } };
    nvmodernCanvasLoad?: typeof load;
    nvmodernCanvasSetAppearance?: typeof setAppearance;
    nvmodernCanvasFlush?: typeof flush;
    EXCALIDRAW_ASSET_PATH?: string;
  }
}
