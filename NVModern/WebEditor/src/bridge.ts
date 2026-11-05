type HostMessage =
  | { kind: "command"; command: string; payload?: unknown }
  | { kind: "response"; requestId: string; result?: unknown; error?: string };

type WebMessage =
  | { kind: "ready" }
  | { kind: "event"; event: string; payload?: unknown }
  | { kind: "request"; requestId: string; method: string; params?: unknown };

type CommandListener = (command: string, payload: unknown) => void;

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
}

declare global {
  interface Window {
    nvmodernReceive?: (message: HostMessage) => void;
    webkit?: {
      messageHandlers?: {
        nvmodern?: {
          postMessage: (message: WebMessage) => void;
        };
      };
    };
  }
}

class NvmodernBridge {
  private pendingRequests = new Map<string, PendingRequest>();
  private commandListeners = new Set<CommandListener>();
  private nextRequestID = 1;

  constructor() {
    window.nvmodernReceive = (message: HostMessage) => {
      this.handleIncoming(message);
    };
  }

  sendReady() {
    this.post({ kind: "ready" });
  }

  emit(event: string, payload?: unknown) {
    this.post({ kind: "event", event, payload });
  }

  request(method: string, params?: unknown, signal?: AbortSignal): Promise<unknown> {
    if (signal?.aborted) {
      return Promise.reject(new DOMException("Aborted", "AbortError"));
    }

    const requestId = `req-${Date.now()}-${this.nextRequestID++}`;

    return new Promise((resolve, reject) => {
      const pending: PendingRequest = {
        resolve,
        reject: (error: Error) => reject(error),
      };

      this.pendingRequests.set(requestId, pending);

      if (signal) {
        const onAbort = () => {
          signal.removeEventListener("abort", onAbort);
          if (this.pendingRequests.delete(requestId)) {
            reject(new DOMException("Aborted", "AbortError"));
          }
        };
        signal.addEventListener("abort", onAbort, { once: true });
      }

      const sent = this.post({ kind: "request", requestId, method, params });
      if (!sent) {
        this.pendingRequests.delete(requestId);
        reject(new Error("Host bridge unavailable"));
      }
    });
  }

  onCommand(listener: CommandListener): () => void {
    this.commandListeners.add(listener);
    return () => {
      this.commandListeners.delete(listener);
    };
  }

  private post(message: WebMessage): boolean {
    const handler = window.webkit?.messageHandlers?.nvmodern;
    if (!handler) {
      console.warn("[nvmodern bridge] message handler unavailable", message);
      return false;
    }

    handler.postMessage(message);
    return true;
  }

  private handleIncoming(message: HostMessage) {
    if (!message || typeof message !== "object") {
      return;
    }

    if (message.kind === "command") {
      for (const listener of this.commandListeners) {
        listener(message.command, message.payload);
      }
      return;
    }

    if (message.kind === "response") {
      const pending = this.pendingRequests.get(message.requestId);
      if (!pending) {
        return;
      }

      this.pendingRequests.delete(message.requestId);
      if (message.error) {
        pending.reject(new Error(message.error));
      } else {
        pending.resolve(message.result);
      }
    }
  }
}

export const bridge = new NvmodernBridge();
