import {
  applyArborMaterialization,
  type ArborBlockId,
  parseArborSource,
  serializeArborPage,
  type ArborOutlineStore,
  type ArborPageId,
} from "../lib/arbor/index.ts";
import type {
  ArborDocumentReplaceRequest,
  ArborHost,
  ArborIntentResponse,
  ArborKernelResponse,
  ArborProducerResponse,
  ArborQueryResponse,
} from "./host.ts";

interface ArborDocumentSyncOptions {
  store: ArborOutlineStore;
  pageId: ArborPageId;
  document: { id: string; path: string };
  host: ArborHost;
  debounceMs?: number;
  initialRevision?: number;
  makeRequestId?: () => string;
}

export interface ArborDocumentSync {
  readonly ready: Promise<void>;
  revision(): number;
  flush(): Promise<void>;
  applyIntent(resultId: ArborBlockId, text: string): Promise<boolean>;
  runProducer(
    producerId: ArborBlockId,
    mode?: "refresh" | "append",
    arguments_?: Record<string, unknown>,
  ): Promise<ArborProducerResponse>;
  runQuery(queryId: string, arguments_?: Record<string, unknown>): Promise<ArborQueryResponse>;
  stop(): void;
}

let requestSequence = 0;
const initialRevisions = new Map<string, number>();

function defaultRequestId(): string {
  requestSequence += 1;
  return `arbor-${Date.now()}-${requestSequence}`;
}

function nextInitialRevision(documentId: string): number {
  const revision = Math.max(Date.now(), (initialRevisions.get(documentId) ?? 0) + 1);
  initialRevisions.set(documentId, revision);
  return revision;
}

function logRequest(
  direction: "send" | "receive" | "error",
  op: string,
  requestId: string,
  revision: number,
  detail: Record<string, unknown> = {},
): void {
  console.info("[Arbor][renderer]", { direction, op, requestId, revision, ...detail });
}

export function startArborDocumentSync(options: ArborDocumentSyncOptions): ArborDocumentSync {
  const debounceMs = options.debounceMs ?? 180;
  const makeRequestId = options.makeRequestId ?? defaultRequestId;
  let sourceRevision = options.initialRevision ?? nextInitialRevision(options.document.id);
  let dirty = false;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let saveChain = Promise.resolve();
  let kernelChain = Promise.resolve();
  let producerChain = Promise.resolve();
  let stopped = false;
  let acceptedRevision: number | null = null;
  let knownKernelRevision: number | null = null;
  let installingAuthoritativeSource = false;

  const traceRequest = (
    direction: "send" | "receive" | "error",
    op: string,
    requestId: string,
    revision: number,
    detail: Record<string, unknown> = {},
  ): void => {
    logRequest(direction, op, requestId, revision, detail);
    options.host.trace?.("documentSync", { direction, op, requestId, revision, ...detail });
  };

  const replace = (source: string, revision: number, requestId: string): Promise<void> => {
    const request: ArborDocumentReplaceRequest = {
      requestId,
      document: { ...options.document, source, revision },
    };
    const startedAt = performance.now();
    traceRequest("send", "document/replace", requestId, revision);
    return options.host.replaceDocument(request).then((response) => {
      traceRequest("receive", "document/replace", requestId, revision, {
        durationMs: Math.round((performance.now() - startedAt) * 10) / 10,
        outcome: response.outcome ?? (response.ok === false ? "rejected" : "accepted"),
        factCount: response.factCount,
      });
      if (response.ok === false) {
        if (response.acceptedRevision !== undefined) {
          knownKernelRevision = response.acceptedRevision;
          acceptedRevision = null;
        }
        return;
      }
      acceptedRevision = response.revision ?? revision;
      knownKernelRevision = acceptedRevision;
    }).catch((error) => {
      traceRequest("error", "document/replace", requestId, revision, {
        message: String(error),
      });
    });
  };

  const queueRevision = (source: string, revision: number, persist: boolean): Promise<void> => {
    const requestId = makeRequestId();
    if (!persist) {
      kernelChain = kernelChain.then(() => replace(source, revision, requestId));
      return kernelChain;
    }

    const operation = saveChain.then(async () => {
      const startedAt = performance.now();
      traceRequest("send", "document/save", requestId, revision);
      try {
        await options.host.saveDocument({
          ...options.document,
          source,
          revision,
          requestId,
        });
        traceRequest("receive", "document/save", requestId, revision, {
          durationMs: Math.round((performance.now() - startedAt) * 10) / 10,
          outcome: "accepted",
        });
        kernelChain = kernelChain.then(() => replace(source, revision, requestId));
        await kernelChain;
      } catch (error) {
        traceRequest("error", "document/save", requestId, revision, {
          message: String(error),
        });
      }
    });
    saveChain = operation.catch(() => undefined);
    return operation;
  };

  const flush = (): Promise<void> => {
    if (timer) clearTimeout(timer);
    timer = null;
    if (!dirty) return Promise.all([saveChain, kernelChain]).then(() => undefined);
    dirty = false;
    return queueRevision(
      serializeArborPage(options.store, options.pageId),
      sourceRevision,
      true,
    );
  };

  const synchronizedRevision = async (): Promise<number> => {
    await flush();
    if (acceptedRevision === sourceRevision) return sourceRevision;
    if (knownKernelRevision === null) {
      throw new Error("The current outline revision has not been accepted by the kernel.");
    }

    for (let attempt = 0; attempt < 2; attempt += 1) {
      options.host.trace?.("revisionResync", {
        attempt: attempt + 1,
        sourceRevision,
        acceptedRevision,
        knownKernelRevision,
      });
      sourceRevision = Math.max(sourceRevision, knownKernelRevision) + 1;
      initialRevisions.set(options.document.id, sourceRevision);
      await queueRevision(
        serializeArborPage(options.store, options.pageId),
        sourceRevision,
        false,
      );
      if (acceptedRevision === sourceRevision) return sourceRevision;
    }
    throw new Error("The outline changed while synchronizing with the kernel.");
  };

  const learnRevisionMismatch = (response: ArborKernelResponse): boolean => {
    if (response.ok !== false || response.acceptedRevision === undefined) return false;
    knownKernelRevision = response.acceptedRevision;
    acceptedRevision = null;
    options.host.trace?.("revisionMismatch", {
      requestRevision: response.revision,
      acceptedRevision: response.acceptedRevision,
      diagnostics: response.diagnostics,
    });
    return true;
  };

  const runRevisioned = async <Response extends ArborKernelResponse>(
    request: (revision: number, requestId: string) => Promise<Response>,
  ): Promise<{ response: Response; revision: number; requestId: string }> => {
    let response!: Response;
    let revision = sourceRevision;
    let requestId = "";
    for (let attempt = 0; attempt < 2; attempt += 1) {
      revision = await synchronizedRevision();
      requestId = makeRequestId();
      response = await request(revision, requestId);
      if (!learnRevisionMismatch(response)) break;
    }
    return { response, revision, requestId };
  };

  const unsubscribe = options.store.subscribe((change) => {
    if (
      installingAuthoritativeSource
      || change.kind === "view"
      || !change.pageIds.has(options.pageId)
    ) return;
    sourceRevision += 1;
    dirty = true;
    options.host.trace?.("sourceChanged", {
      changeKind: change.kind,
      pageId: options.pageId,
      sourceRevision,
    });
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => void flush(), debounceMs);
  });

  const ready = queueRevision(
    serializeArborPage(options.store, options.pageId),
    sourceRevision,
    false,
  );

  return {
    ready,
    revision: () => sourceRevision,
    flush,
    async runProducer(producerId, mode = "refresh", arguments_ = {}) {
      let response!: ArborProducerResponse;
      let requestId = "";
      let revision = sourceRevision;
      const operation = producerChain.then(async () => {
        const run = await runRevisioned(async (currentRevision, currentRequestId) => {
          const startedAt = performance.now();
          traceRequest("send", "producer/run", currentRequestId, currentRevision, {
            producerId, mode,
          });
          const currentResponse = await options.host.runProducer({
            requestId: currentRequestId,
            documentId: options.document.id,
            revision: currentRevision,
            producerId,
            mode,
            arguments: arguments_,
          });
          traceRequest("receive", "producer/run", currentRequestId, currentRevision, {
            durationMs: Math.round((performance.now() - startedAt) * 10) / 10,
            outcome: currentResponse.ok === false ? "rejected" : "accepted",
            producerId,
            mode,
            resultCount: currentResponse.results?.length,
          });
          return currentResponse;
        });
        ({ response, revision, requestId } = run);
        if (response.ok === false || stopped) return;
        if (revision !== sourceRevision || revision !== acceptedRevision) {
          throw new Error("The producer changed while its result was running; run it again.");
        }
        if (response.kind === "mutation") {
          const document = response.document;
          const expectedRevision = response.outcome === "idempotent" ? revision : revision + 1;
          if (
            !document
            || document.id !== options.document.id
            || document.path !== options.document.path
            || document.revision === undefined
            || document.source === undefined
            || document.revision !== expectedRevision
          ) {
            throw new Error("The kernel returned an invalid outline transaction.");
          }
          const parsed = parseArborSource(document.source, {
            pageId: options.pageId,
            title: options.store.getPage(options.pageId)?.title,
          });
          const diagnostic = parsed.diagnostics.find((item) => item.severity === "error");
          if (diagnostic) throw new Error(diagnostic.message);
          installingAuthoritativeSource = true;
          try {
            options.store.replaceSnapshot(parsed.snapshot);
          } finally {
            installingAuthoritativeSource = false;
          }
          sourceRevision = document.revision;
          acceptedRevision = document.revision;
          dirty = false;
          options.host.trace?.("mutationInstalled", {
            documentId: document.id,
            path: document.path,
            revision: document.revision,
            source: document.source,
          });
          return;
        }
        if (
          response.producerID !== producerId
          || response.mode !== mode
          || response.generation === undefined
          || response.inputHash === undefined
          || response.results === undefined
        ) {
          throw new Error("The kernel returned an invalid producer materialization.");
        }
        applyArborMaterialization(options.store, {
          producerId,
          mode,
          generation: response.generation,
          inputHash: response.inputHash,
          worldRevision: response.worldRevision,
          results: response.results,
        });
        await flush();
      });
      producerChain = operation.catch((error) => {
        traceRequest("error", "producer/run", requestId, revision, {
          message: String(error), producerId, mode,
        });
      });
      await operation;
      return response;
    },
    async runQuery(queryId, arguments_ = {}) {
      const run = await runRevisioned(async (revision, requestId) => {
        const startedAt = performance.now();
        traceRequest("send", "query/run", requestId, revision, { queryId });
        try {
          const response = await options.host.runQuery({
            requestId,
            documentId: options.document.id,
            revision,
            queryId,
            arguments: arguments_,
          });
          traceRequest("receive", "query/run", requestId, revision, {
            durationMs: Math.round((performance.now() - startedAt) * 10) / 10,
            outcome: response.ok === false ? "rejected" : "accepted",
            rowCount: response.rows?.length,
            queryId,
          });
          return response;
        } catch (error) {
          traceRequest("error", "query/run", requestId, revision, {
            message: String(error), queryId,
          });
          throw error;
        }
      });
      return run.response as ArborQueryResponse;
    },
    async applyIntent(resultId, text) {
      const detach = async () => {
        const computation = options.store.getBlock(resultId)?.computation;
        if (computation) {
          options.store.setBlockComputation(resultId, { ...computation, state: "detached" });
          await flush();
        }
      };
      let response: ArborIntentResponse;
      try {
        const run = await runRevisioned((revision, requestId) => (
          options.host.applyIntent({
            requestId,
            documentId: options.document.id,
            revision,
            resultId,
            intent: { op: "set-text", text },
          })
        ));
        response = run.response;
      } catch {
        await detach();
        return false;
      }
      if (response.ok === false || !response.origin || response.text === undefined) {
        await detach();
        return false;
      }
      if (response.origin.documentID === options.document.id) {
        const originId = response.origin.blockID as ArborBlockId;
        if (options.store.hasBlock(originId)) {
          options.store.setBlockText(originId, response.text);
          await flush();
        }
      }
      return true;
    },
    stop() {
      stopped = true;
      unsubscribe();
      if (timer) {
        clearTimeout(timer);
        timer = null;
        void flush();
      }
    },
  };
}
