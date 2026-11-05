import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Button } from "../src/components/ui/button.tsx";
import {
  Dialog,
  DialogBackdrop,
  DialogContent,
  DialogDescription,
  DialogPortal,
  DialogTitle,
} from "../src/components/ui/dialog.tsx";
import { Input } from "../src/components/ui/input.tsx";
import { ArborSurface } from "../src/arbor/ArborSurface.tsx";
import type {
  ArborHost,
  ArborEffectCapability,
  ArborIntentResponse,
  ArborKernelResponse,
  ArborProducerResponse,
  ArborQueryResponse,
  ArborViewResponse,
} from "../src/arbor/host.ts";

interface OpenArborFile {
  path: string;
  content: string;
}

interface TranscriptEntry {
  sequence: number;
  timestamp: string;
  direction: "send" | "receive" | "stderr" | "system";
  message: unknown;
}

interface KernelLogResponse {
  entries: TranscriptEntry[];
  status: {
    state: "stopped" | "running" | "unresponsive";
    error?: string;
    logFile?: string;
  };
}

function singleQueryId(entries: readonly TranscriptEntry[]): string | undefined {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index]!;
    if (entry.direction !== "receive" || !entry.message || typeof entry.message !== "object") {
      continue;
    }
    const queryIds = (entry.message as { queryIDs?: unknown }).queryIDs;
    if (Array.isArray(queryIds) && queryIds.length === 1 && typeof queryIds[0] === "string") {
      return queryIds[0];
    }
  }
  return undefined;
}

async function postKernel(request: Record<string, unknown>): Promise<Record<string, unknown>> {
  const response = await fetch("/api/arbor/kernel", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
  const result = await response.json() as Record<string, unknown>;
  if (!response.ok) throw new Error(String(result.error ?? `Kernel request failed: ${response.status}`));
  return result;
}

function KernelTranscript() {
  const [entries, setEntries] = useState<TranscriptEntry[]>([]);
  const [status, setStatus] = useState<KernelLogResponse["status"]>({ state: "stopped" });
  const [queryId, setQueryId] = useState("");
  const [argumentsText, setArgumentsText] = useState("{}");
  const [queryStatus, setQueryStatus] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    let after = 0;
    let logFile: string | undefined;
    const poll = async () => {
      try {
        const response = await fetch(`/api/arbor/kernel/logs?after=${after}`);
        const update = await response.json() as KernelLogResponse;
        if (!active) return;
        setStatus(update.status);
        const discoveredQueryId = singleQueryId(update.entries);
        if (discoveredQueryId) setQueryId(discoveredQueryId);
        if (update.status.logFile !== logFile) {
          logFile = update.status.logFile;
          after = update.entries.at(-1)?.sequence ?? 0;
          setEntries(update.entries.slice(-500));
          return;
        }
        if (update.entries.length > 0) {
          after = update.entries.at(-1)!.sequence;
          setEntries((current) => {
            const entriesBySequence = new Map(current.map((entry) => [entry.sequence, entry]));
            for (const entry of update.entries) entriesBySequence.set(entry.sequence, entry);
            return [...entriesBySequence.values()].slice(-500);
          });
        }
      } catch (error) {
        if (active) setStatus({ state: "stopped", error: String(error) });
      }
    };
    void poll();
    const interval = window.setInterval(() => void poll(), 400);
    return () => {
      active = false;
      window.clearInterval(interval);
    };
  }, []);

  const runQuery = async (event: React.FormEvent) => {
    event.preventDefault();
    const runner = (window as Window & {
      arborKernelQuery?: (queryId: string, arguments_?: Record<string, unknown>) => Promise<unknown>;
    }).arborKernelQuery;
    if (!runner) {
      setQueryStatus("Renderer sync is not ready.");
      return;
    }
    let arguments_: Record<string, unknown>;
    try {
      const parsed = JSON.parse(argumentsText) as unknown;
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        setQueryStatus("Arguments must be a JSON object, for example {\"tag\":\"project\"}.");
        return;
      }
      arguments_ = parsed as Record<string, unknown>;
    } catch {
      setQueryStatus("Arguments must be valid JSON, for example {\"tag\":\"project\"}.");
      return;
    }
    try {
      const response = await runner(queryId.trim(), arguments_) as {
        ok?: boolean;
        rows?: unknown[];
        diagnostics?: Array<{ message?: unknown }>;
      };
      const diagnostic = response.diagnostics?.find((item) => typeof item.message === "string");
      setQueryStatus(response.ok === false
        ? String(diagnostic?.message ?? "The kernel rejected the query.")
        : `${response.rows?.length ?? 0} row${response.rows?.length === 1 ? "" : "s"}`);
    } catch (error) {
      setQueryStatus(String(error));
    }
  };

  return (
    <section className="arbor-kernel-transcript" aria-label="Arbor kernel transcript">
      <header>
        <div className="arbor-kernel-meta">
          <strong>Kernel transcript</strong>
          <span data-state={status.state} title={status.error}>
            {status.state}{status.error ? ` · ${status.error}` : ""}
          </span>
          {status.logFile ? <code title={status.logFile}>{status.logFile}</code> : null}
        </div>
        <form className="arbor-kernel-query" onSubmit={runQuery}>
          <span className="arbor-kernel-query-help" id="arbor-kernel-query-help">
            Declaration stays in the outline →
          </span>
          <Input
            aria-label="Query block UID"
            aria-describedby="arbor-kernel-query-help"
            placeholder="Block UID, e.g. q-tag"
            title="Enter the ^uid of the outline block that contains the query declaration."
            value={queryId}
            onChange={(event) => setQueryId(event.target.value)}
          />
          <Input
            aria-label="Query arguments as JSON"
            placeholder='Arguments JSON, e.g. {"tag":"project"}'
            value={argumentsText}
            onChange={(event) => setArgumentsText(event.target.value)}
          />
          <Button type="submit" disabled={!queryId.trim()}>Run query</Button>
          {queryStatus ? <span title={queryStatus}>{queryStatus}</span> : null}
        </form>
      </header>
      <div className="arbor-kernel-messages" role="log" aria-live="polite">
        {entries.length === 0 ? (
          <div className="arbor-kernel-empty">The first document/replace message will appear here.</div>
        ) : entries.map((entry) => (
          <div className="arbor-kernel-message" data-direction={entry.direction} key={entry.sequence}>
            <span>{entry.direction}</span>
            <pre>{typeof entry.message === "string"
              ? entry.message
              : JSON.stringify(entry.message, null, 2)}</pre>
          </div>
        ))}
      </div>
    </section>
  );
}

export function ArborDevSurface({ file }: { file?: OpenArborFile }) {
  const [permission, setPermission] = useState<{
    capability: ArborEffectCapability;
    title: string;
    details: string[];
    approveLabel: string;
    allowGrant: boolean;
    resolve: (choice: "once" | "node" | "cancel") => void;
  } | null>(null);
  const grantedCapabilities = useRef(new Set<string>());
  const finishPermission = useCallback((choice: "once" | "node" | "cancel") => {
    const current = permission;
    if (!current) return;
    setPermission(null);
    current.resolve(choice);
  }, [permission]);
  const authorize = useCallback(async (
    capability: ArborEffectCapability | null,
    options: {
      title?: string;
      details?: string[];
      approveLabel?: string;
      allowGrant?: boolean;
    } = {},
  ) => {
    if (!capability) return true;
    const allowGrant = options.allowGrant ?? true;
    if (allowGrant && grantedCapabilities.current.has(capability.id)) return true;
    const choice = await new Promise<"once" | "node" | "cancel">((resolve) => {
      setPermission({
        capability,
        title: options.title ?? "Allow this node to perform an effect?",
        details: options.details ?? [],
        approveLabel: options.approveLabel ?? "Allow once",
        allowGrant,
        resolve,
      });
    });
    if (allowGrant && choice === "node") grantedCapabilities.current.add(capability.id);
    return choice !== "cancel";
  }, []);
  const host = useMemo<ArborHost>(() => {
    return {
      kernelEnabled: true,
      async saveDocument(document) {
        if (!file) return;
        const response = await fetch(`/api/file?path=${encodeURIComponent(document.path)}`, {
          method: "PUT",
          headers: { "Content-Type": "text/plain; charset=utf-8" },
          body: document.source,
        });
        if (!response.ok) throw new Error(await response.text());
      },
      async evaluate(request) {
        return await postKernel({
          protocol: "arbor-kernel/1",
          id: `dev-evaluate-${Date.now()}`,
          op: "evaluate",
          document: {
            path: request.path,
            revision: request.revision,
            source: request.source,
          },
          previousDerivedUIDs: request.previousDerivedUIDs,
        }) as ArborKernelResponse;
      },
      async replaceDocument(request) {
        const response = await postKernel({
          protocol: "arbor-kernel/1",
          id: request.requestId,
          op: "document/replace",
          document: request.document,
        }) as ArborKernelResponse;
        return response;
      },
      async runQuery(request) {
        const response = await postKernel({
          protocol: "arbor-kernel/1",
          id: request.requestId,
          op: "query/run",
          documentID: request.documentId,
          revision: request.revision,
          queryID: request.queryId,
          arguments: request.arguments ?? {},
        });
        return response as ArborQueryResponse;
      },
      async getView(request) {
        const response = await postKernel({
          protocol: "arbor-kernel/1",
          id: request.requestId,
          op: "view/get",
          documentID: request.documentId,
          revision: request.revision,
          ...(request.queryId ? { queryID: request.queryId } : {}),
          arguments: request.arguments ?? {},
        });
        return response as ArborViewResponse;
      },
      async runProducer(request) {
        const prepared = await postKernel({
          protocol: "arbor-kernel/1",
          id: request.requestId,
          op: "producer/run",
          documentID: request.documentId,
          revision: request.revision,
          producerID: request.producerId,
          mode: request.mode,
          arguments: request.arguments ?? {},
        }) as ArborProducerResponse;
        if (prepared.status === "effect-request" && prepared.effect) {
          const allowed = await authorize(prepared.effect.capability);
          const response = await fetch("/api/arbor/effect", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ executionID: prepared.effect.executionID, allowed }),
          });
          const completed = await response.json() as ArborProducerResponse & { error?: string };
          if (!response.ok) throw new Error(completed.error ?? `Effect failed: ${response.status}`);
          return completed;
        }
        if (prepared.status !== "mutation-request" || !prepared.mutation) return prepared;
        const allowed = await authorize(prepared.mutation.capability, {
          title: "Apply this outline transaction?",
          details: prepared.mutation.summary,
          approveLabel: "Apply",
          allowGrant: false,
        });
        const response = await fetch("/api/arbor/mutation", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ executionID: prepared.mutation.executionID, allowed }),
        });
        const completed = await response.json() as ArborProducerResponse & { error?: string };
        if (!response.ok) throw new Error(completed.error ?? `Mutation failed: ${response.status}`);
        return completed;
      },
      async applyIntent(request) {
        const response = await fetch("/api/arbor/intent", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            protocol: "arbor-kernel/1",
            id: request.requestId,
            op: "intent/apply",
            documentID: request.documentId,
            revision: request.revision,
            resultID: request.resultId,
            intent: request.intent,
          }),
        });
        const result = await response.json() as ArborIntentResponse & { error?: string };
        if (!response.ok) throw new Error(result.error ?? `Intent failed: ${response.status}`);
        return result;
      },
      openLink(link) {
        console.info("[Arbor][dev] open link", link);
      },
      openInlineLink(link) {
        window.open(link.href, "_blank", "noopener,noreferrer");
      },
    };
  }, [authorize, file]);

  return (
    <div className="arbor-dev-workspace">
      <div className="arbor-dev-notice">
        {file ? "Editing the opened .outline document" : "Arbor playground"}
        {" · renderer saves first, then indexes the same revision"}
      </div>
      {permission ? (
        <Dialog
          open
          onOpenChange={(open) => {
            if (!open) finishPermission("cancel");
          }}
        >
          <DialogPortal>
            <DialogBackdrop />
            <DialogContent className="arbor-effect-permission">
              <DialogTitle>{permission.title}</DialogTitle>
              <DialogDescription>{permission.capability.summary}</DialogDescription>
              {permission.details.length > 0 ? (
                <ul>
                  {permission.details.map((detail, index) => <li key={`${index}:${detail}`}>{detail}</li>)}
                </ul>
              ) : null}
              <code>{permission.capability.resource}</code>
              <div className="arbor-effect-permission-actions">
                <Button onClick={() => finishPermission("cancel")}>Cancel</Button>
                <Button onClick={() => finishPermission("once")}>{permission.approveLabel}</Button>
                {permission.allowGrant ? (
                  <Button onClick={() => finishPermission("node")}>Allow for this node</Button>
                ) : null}
              </div>
            </DialogContent>
          </DialogPortal>
        </Dialog>
      ) : null}
      <div className="arbor-dev-surface">
        <ArborSurface
          context={file ? {
            path: file.path,
            title: file.path.split("/").at(-1)?.replace(/\.outline$/i, ""),
            body: file.content,
            isEditable: true,
          } : undefined}
          host={host}
          developmentHarness
        />
      </div>
      <KernelTranscript />
    </div>
  );
}
