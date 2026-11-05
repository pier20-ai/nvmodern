/**
 * Side stack entry point (`stack.html` / `stack.js` / `stack.css`): hosts the
 * read-only card column beside a tab's content in its own WKWebView, over the
 * same structured bridge as the main editor. Protocol: "Stack bridge protocol"
 * in docs/tickets/0031-side-stack.md.
 */
import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { applyNv3UserStylesheet } from "./lib/index.ts";
import { bridge } from "./bridge.ts";
import { applyHostColorScheme, resolveTransclusionOverBridge } from "./editorHost.ts";
import { StackSurface, type StackHost, type StackRequest } from "./stack/StackSurface.tsx";
import { EMPTY_STACK, normalizeStackPayload, type StackState } from "./stack/model.ts";
import "./styles/editor.lib.css";
import "./styles/stack.css";

const bridgeHost: StackHost = {
  emit: (event, payload) => bridge.emit(event, payload ?? {}),
  resolveTransclusion: resolveTransclusionOverBridge,
};

function idFrom(payload: unknown): string | null {
  const id = (payload as { id?: unknown } | null)?.id;
  return typeof id === "string" && id ? id : null;
}

function StackApp() {
  const [state, setState] = useState<StackState>(EMPTY_STACK);
  const [reveal, setReveal] = useState<StackRequest | null>(null);
  const [flash, setFlash] = useState<StackRequest | null>(null);
  const [focus, setFocus] = useState<StackRequest | null>(null);
  const nonce = useRef(0);

  useEffect(() => {
    const unsubscribe = bridge.onCommand((command, payload) => {
      switch (command) {
        case "setHostAppearance":
          applyHostColorScheme((payload as { colorScheme?: unknown } | null)?.colorScheme);
          return;
        case "setTheme": {
          const css = (payload as { userThemeCSS?: unknown } | null)?.userThemeCSS;
          applyNv3UserStylesheet(typeof css === "string" ? css : null);
          return;
        }
        case "setStack": {
          const next = normalizeStackPayload(payload);
          setState(next);
          if (next.revealId) setReveal({ id: next.revealId, nonce: ++nonce.current });
          return;
        }
        case "flashCard": {
          const id = idFrom(payload);
          if (id) setFlash({ id, nonce: ++nonce.current });
          return;
        }
        case "focusStack":
          setFocus({ id: idFrom(payload), nonce: ++nonce.current });
          return;
        default:
          return;
      }
    });

    const notifyInteraction = () => bridge.emit("contentInteraction", {});
    const handleContextMenu = (event: MouseEvent) => {
      event.preventDefault();
      const card = event.target instanceof Element ? event.target.closest<HTMLElement>("[data-stack-card-id]") : null;
      bridge.emit("contextMenuRequested", {
        x: event.clientX,
        y: event.clientY,
        selectionText: window.getSelection?.()?.toString().trim() ?? "",
        cardId: card?.dataset.stackCardId ?? null,
      });
    };

    window.addEventListener("pointerdown", notifyInteraction, true);
    window.addEventListener("focusin", notifyInteraction, true);
    window.addEventListener("contextmenu", handleContextMenu, true);
    bridge.sendReady();

    return () => {
      unsubscribe();
      window.removeEventListener("pointerdown", notifyInteraction, true);
      window.removeEventListener("focusin", notifyInteraction, true);
      window.removeEventListener("contextmenu", handleContextMenu, true);
    };
  }, []);

  return <StackSurface state={state} host={bridgeHost} reveal={reveal} flash={flash} focus={focus} />;
}

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("Missing #root mount element");
createRoot(rootElement).render(<StackApp />);
