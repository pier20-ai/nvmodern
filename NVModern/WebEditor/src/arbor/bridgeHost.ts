import { bridge } from "../bridge.ts";
import type {
  ArborHost,
  ArborKernelResponse,
  ArborIntentResponse,
  ArborProducerResponse,
  ArborQueryResponse,
  ArborViewResponse,
  ArborWikilinkSuggestion,
} from "./host.ts";

function wikilinkSuggestions(response: unknown): ArborWikilinkSuggestion[] {
  if (!response || typeof response !== "object") return [];
  const items = (response as { items?: unknown }).items;
  if (!Array.isArray(items)) return [];
  return items.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const value = item as Record<string, unknown>;
    if (typeof value.label !== "string") return [];
    return [{
      label: value.label,
      insertText: typeof value.insertText === "string" ? value.insertText : value.label,
      ...(typeof value.detail === "string" ? { detail: value.detail } : {}),
    }];
  });
}

export const nvmodernArborHost: ArborHost = {
  kernelEnabled: true,

  trace(event, detail) {
    bridge.emit("arborTrace", { event, ...detail });
  },

  saveDocument(document) {
    bridge.emit("docChange", { path: document.path, body: document.source });
  },

  async evaluate(request) {
    return await bridge.request("arbor.evaluate", request) as ArborKernelResponse;
  },

  async replaceDocument(request) {
    return await bridge.request("arbor.documentReplace", request) as ArborKernelResponse;
  },

  async runQuery(request) {
    return await bridge.request("arbor.queryRun", request) as ArborQueryResponse;
  },

  async getView(request) {
    return await bridge.request("arbor.viewGet", request) as ArborViewResponse;
  },

  async runProducer(request) {
    return await bridge.request("arbor.producerRun", request) as ArborProducerResponse;
  },

  async applyIntent(request) {
    return await bridge.request("arbor.intentApply", request) as ArborIntentResponse;
  },

  async autocompleteWikilinks(query, filePath) {
    const response = await bridge.request("autocomplete.wikilink", { query, filePath });
    return wikilinkSuggestions(response);
  },

  async pickDate(request) {
    const response = await bridge.request("date.pick", request);
    if (!response || typeof response !== "object") return null;
    const isoDate = (response as { isoDate?: unknown }).isoDate;
    return typeof isoDate === "string" ? isoDate : null;
  },

  subscribeInlineFormatting(handler) {
    return bridge.onCommand((command) => {
      const handled = command === "toggleMarkdownBold"
        ? handler("bold")
        : command === "toggleMarkdownItalic"
          ? handler("italic")
          : false;
      if (handled) bridge.emit("contentInteraction");
    });
  },

  showContextMenu(request) {
    bridge.emit("contextMenuRequested", {
      x: request.x,
      y: request.y,
      selectionText: request.selectionText,
      arbor: {
        blockId: request.blockId,
        canMoveUp: request.canMoveUp,
        canMoveDown: request.canMoveDown,
      },
    });
  },

  subscribeContextMenuActions(handler) {
    return bridge.onCommand((command) => {
      const prefix = "arborContextMenu.";
      if (!command.startsWith(prefix)) return;
      const action = command.slice(prefix.length);
      if (
        action === "copyText"
        || action === "copyId"
        || action === "moveUp"
        || action === "moveDown"
        || action === "delete"
      ) {
        if (handler(action)) bridge.emit("contentInteraction");
      }
    });
  },

  openLink(link) {
    bridge.emit("wikilinkOpen", link);
  },

  openInlineLink(link) {
    bridge.emit("inlineLinkOpen", link);
  },
};
