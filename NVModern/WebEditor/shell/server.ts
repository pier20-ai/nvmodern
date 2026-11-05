import index from "./index.html";
import stackIndex from "./stack.html";
import { constants } from "node:fs";
import { access, appendFile, mkdir, readdir, realpath, rm, stat, symlink } from "node:fs/promises";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { basename, dirname, extname, join, relative, resolve, sep } from "node:path";
import {
  ArborDevKernel,
  type DevKernelTranscriptEntry,
} from "./arborKernel.ts";

/**
 * Test shell server.
 *
 * Endpoints:
 *   GET /                → editor shell UI
 *   GET /stack           → side stack preview (read-only note cards)
 *   GET /api/files?dir=  → list files in a directory
 *   GET /api/file?path=  → read file content
 *   PUT /api/file?path=  → write file content
 */

const ALLOWED_EXTENSIONS = new Set([
  ".md",
  ".markdown",
  ".org",
  ".json",
  ".jsonl",
  ".txt",
  ".outline",
]);

const HIDDEN_DIRS = new Set(["node_modules", ".git", ".idea", ".vscode"]);

const ROOT = resolve(process.env.EDITOR_ROOT ?? process.cwd());
const REPO_ROOT = resolve(import.meta.dir, "../../..");
const KERNEL_SCRIPT = resolve(REPO_ROOT, "ArborKernel/arbor-kernel.rkt");
const BUILTIN_THEMES_DIR = resolve(REPO_ROOT, "NVModern/BuiltinThemes");
const THEME_ID_PATTERN = /^[a-z0-9][a-z0-9-]*$/;
const LOG_DIRECTORY = process.env.NVMODERN_LOG_DIR ?? "/tmp/nvmodern";
const LOG_TIMESTAMP = new Date().toISOString().replace(/[:.]/g, "-");
const KERNEL_LOG_PATH = resolve(LOG_DIRECTORY, `arbor-kernel-dev-${LOG_TIMESTAMP}.jsonl`);
const LATEST_KERNEL_LOG_PATH = resolve(LOG_DIRECTORY, "latest-arbor-kernel-dev.jsonl");

await mkdir(dirname(KERNEL_LOG_PATH), { recursive: true });
await appendFile(KERNEL_LOG_PATH, "");

interface TranscriptEntry extends DevKernelTranscriptEntry {
  sequence: number;
  timestamp: string;
}

const transcript: TranscriptEntry[] = [];
let transcriptSequence = 0;
let logWrite = Promise.resolve();

function recordKernelMessage(entry: DevKernelTranscriptEntry): void {
  transcriptSequence += 1;
  const recorded = { ...entry, sequence: transcriptSequence, timestamp: new Date().toISOString() };
  transcript.push(recorded);
  if (transcript.length > 500) transcript.splice(0, transcript.length - 500);
  logWrite = logWrite
    .then(() => appendFile(KERNEL_LOG_PATH, `${JSON.stringify(recorded)}\n`))
    .catch((error) => console.error("Could not write the Arbor kernel log:", error));
}

function kernelStatus() {
  return {
    ...(kernel?.status() ?? {
      state: "stopped" as const,
      executable: "",
      script: KERNEL_SCRIPT,
      error: "Racket executable not found.",
    }),
    logFile: KERNEL_LOG_PATH,
  };
}

async function locateRacket(): Promise<string | null> {
  const candidates = [
    process.env.ARBOR_RACKET,
    "/opt/homebrew/bin/racket",
    "/usr/local/bin/racket",
  ].filter((candidate): candidate is string => Boolean(candidate));
  try {
    const applications = await readdir("/Applications");
    for (const name of applications.filter((name) => name.startsWith("Racket v")).sort().reverse()) {
      candidates.push(`/Applications/${name}/bin/racket`);
    }
  } catch {
    // Racket may be installed outside /Applications.
  }
  for (const candidate of candidates) {
    try {
      await access(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Try the next supported install location.
    }
  }
  return null;
}

const racket = await locateRacket();
const kernel = racket
  ? new ArborDevKernel(racket, KERNEL_SCRIPT, REPO_ROOT, recordKernelMessage)
  : null;
if (!kernel) recordKernelMessage({ direction: "system", message: "Racket executable not found." });

interface PlannedEffect {
  executionID: string;
  handler: string;
  arguments: unknown[];
  capability?: { id?: string } | null;
  limits: { timeoutMs: number; maxOutputBytes: number };
}

interface PlannedMutation {
  executionID: string;
  summary: string[];
  operationCount: number;
  destructive: boolean;
  capability: { id: string; kind: string; resource: string; summary: string };
  expectedSource: string;
  document: { id: string; path: string; revision: number; source: string };
}

const pendingEffects = new Map<string, PlannedEffect>();
const completedEffects = new Map<string, Record<string, unknown>>();
const pendingMutations = new Map<string, PlannedMutation>();
const completedMutations = new Map<string, Record<string, unknown>>();

function recordMutationBroker(
  mutation: PlannedMutation,
  startedAt: number,
  outcome: "ok" | "denied" | "conflict" | "error",
): void {
  recordKernelMessage({
    direction: "system",
    message: {
      event: "mutation/broker",
      executionID: mutation.executionID,
      operationCount: mutation.operationCount,
      destructive: mutation.destructive,
      durationMs: Math.round((performance.now() - startedAt) * 10) / 10,
      outcome,
    },
  });
}

function resolveInsideRoot(pathLike: string): string {
  const resolved = resolve(ROOT, pathLike);
  if (resolved !== ROOT && !resolved.startsWith(`${ROOT}${sep}`)) {
    throw new Error("Path escapes editor root");
  }
  return resolved;
}

async function resolveExistingInsideRoot(pathLike: string): Promise<string> {
  const root = await realpath(ROOT);
  const resolved = await realpath(resolveInsideRoot(pathLike));
  if (resolved !== root && !resolved.startsWith(`${root}${sep}`)) {
    throw new Error("Path resolves outside editor root");
  }
  return resolved;
}

async function resolveWritableInsideRoot(pathLike: string): Promise<string> {
  const root = await realpath(ROOT);
  const target = resolveInsideRoot(pathLike);
  const parent = await realpath(dirname(target));
  if (parent !== root && !parent.startsWith(`${root}${sep}`)) {
    throw new Error("Path resolves outside editor root");
  }
  return join(parent, basename(target));
}

function relPath(absPath: string): string {
  const rel = relative(ROOT, absPath);
  return rel.split(sep).join("/");
}

async function listFiles(dir: string): Promise<{ name: string; path: string; isDir: boolean }[]> {
  const resolvedDir = resolveInsideRoot(dir);
  const entries = await readdir(resolvedDir, { withFileTypes: true });

  const results: { name: string; path: string; isDir: boolean }[] = [];

  for (const entry of entries) {
    if (entry.name.startsWith(".")) continue;

    const entryAbsPath = join(resolvedDir, entry.name);
    const entryRelPath = relPath(entryAbsPath);

    if (entry.isDirectory()) {
      if (HIDDEN_DIRS.has(entry.name)) continue;
      results.push({
        name: entry.name,
        path: entryRelPath,
        isDir: true,
      });
      continue;
    }

    if (ALLOWED_EXTENSIONS.has(extname(entry.name).toLowerCase())) {
      results.push({
        name: entry.name,
        path: entryRelPath,
        isDir: false,
      });
    }
  }

  return results.sort((a, b) => {
    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
}

async function outlineFiles(dir = "."): Promise<string[]> {
  const entries = await listFiles(dir);
  const nested = await Promise.all(entries.map(async (entry) => {
    if (entry.isDir) return await outlineFiles(entry.path);
    return extname(entry.name).toLowerCase() === ".outline" ? [entry.path] : [];
  }));
  return nested.flat().sort();
}

let workspaceIndex: Promise<void> | null = null;

function ensureWorkspaceIndexed(): Promise<void> {
  if (!kernel) return Promise.resolve();
  workspaceIndex ??= (async () => {
    for (const path of await outlineFiles()) {
      const source = await Bun.file(resolveInsideRoot(path)).text();
      await kernel.request({
        protocol: "arbor-kernel/1",
        id: `workspace-index:${path}`,
        op: "document/replace",
        document: { id: path, path, revision: 0, source },
      });
    }
  })();
  return workspaceIndex;
}

const MAX_EFFECT_OUTPUT_BYTES = 1024 * 1024;
const MAX_EFFECT_TIMEOUT_MS = 60_000;

function stringArgument(effect: PlannedEffect, index: number): string {
  const value = effect.arguments[index];
  if (typeof value !== "string") throw new Error(`${effect.handler} argument ${index + 1} must be text.`);
  return value;
}

function effectLimits(effect: PlannedEffect): { timeoutMs: number; maxOutputBytes: number } {
  return {
    timeoutMs: Math.max(1, Math.min(effect.limits.timeoutMs, MAX_EFFECT_TIMEOUT_MS)),
    maxOutputBytes: Math.max(1, Math.min(effect.limits.maxOutputBytes, MAX_EFFECT_OUTPUT_BYTES)),
  };
}

function wildcardPattern(value: string): RegExp {
  const escaped = value.replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*/g, ".*")
    .replace(/\?/g, ".");
  return new RegExp(`^${escaped}$`, "i");
}

async function runCommand(
  command: string,
  arguments_: string[],
  options: { input?: string; timeoutMs: number; maxOutputBytes: number; env?: NodeJS.ProcessEnv },
): Promise<string> {
  return await new Promise<string>((resolvePromise, reject) => {
    const child = spawn(command, arguments_, {
      cwd: ROOT,
      env: options.env ?? process.env,
      stdio: [options.input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
    });
    const chunks: Buffer[] = [];
    let byteCount = 0;
    let settled = false;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const finish = (error?: Error) => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      if (error) reject(error);
      else resolvePromise(Buffer.concat(chunks).toString("utf8").replace(/\s+$/, ""));
    };
    const append = (chunk: Buffer) => {
      byteCount += chunk.length;
      if (byteCount > options.maxOutputBytes) {
        child.kill();
        finish(new Error(`Effect output exceeds ${options.maxOutputBytes} bytes.`));
      } else {
        chunks.push(chunk);
      }
    };
    child.stdout!.on("data", append);
    child.stderr!.on("data", append);
    child.on("error", (error) => finish(error));
    child.on("close", (code) => finish(code === 0
      ? undefined
      : new Error(`Process exited with status ${code ?? "unknown"}.`)));
    if (options.input !== undefined) child.stdin?.end(options.input);
    timeout = setTimeout(() => {
      child.kill();
      finish(new Error(`Effect exceeded the ${options.timeoutMs} ms timeout.`));
    }, options.timeoutMs);
  });
}

async function executeEffect(effect: PlannedEffect): Promise<unknown> {
  const limits = effectLimits(effect);
  switch (effect.handler) {
    case "clock/now":
      return new Date().toISOString();
    case "clock/today":
      return new Date().toISOString().slice(0, 10);
    case "fs/read": {
      const path = await resolveExistingInsideRoot(stringArgument(effect, 0));
      const file = Bun.file(path);
      if (file.size > limits.maxOutputBytes) throw new Error("Effect output exceeds its byte limit.");
      return await file.text();
    }
    case "fs/list": {
      const path = await resolveExistingInsideRoot(
        effect.arguments.length === 0 ? "." : stringArgument(effect, 0),
      );
      return (await readdir(path, { withFileTypes: true }))
        .filter((entry) => !entry.name.startsWith("."))
        .map((entry) => ({
          name: entry.name,
          kind: entry.isDirectory() ? "directory" : entry.isFile() ? "file" : "other",
        }))
        .sort((a, b) => a.name.localeCompare(b.name));
    }
    case "fs/stat": {
      const path = await resolveExistingInsideRoot(stringArgument(effect, 0));
      const info = await stat(path);
      return {
        path: stringArgument(effect, 0),
        kind: info.isDirectory() ? "directory" : info.isFile() ? "file" : "other",
        bytes: info.size,
        modified: info.mtime.toISOString(),
      };
    }
    case "fs/glob": {
      const path = await resolveExistingInsideRoot(stringArgument(effect, 0));
      const pattern = wildcardPattern(stringArgument(effect, 1));
      return (await readdir(path, { withFileTypes: true }))
        .filter((entry) => pattern.test(entry.name))
        .map((entry) => ({ name: entry.name, kind: entry.isDirectory() ? "directory" : "file" }))
        .sort((a, b) => a.name.localeCompare(b.name));
    }
    case "fs/write":
    case "fs/append": {
      const relativePath = stringArgument(effect, 0);
      const content = stringArgument(effect, 1);
      const path = await resolveWritableInsideRoot(relativePath);
      if (effect.handler === "fs/write") await Bun.write(path, content);
      else await appendFile(path, content);
      return { path: relativePath, bytes: Buffer.byteLength(content) };
    }
    case "fs/mkdir": {
      const relativePath = stringArgument(effect, 0);
      await mkdir(await resolveWritableInsideRoot(relativePath));
      return { path: relativePath, created: true };
    }
    case "process/run":
      return await runCommand(
        stringArgument(effect, 0),
        effect.arguments.slice(1).map((_, index) => stringArgument(effect, index + 1)),
        limits,
      );
    case "http/request": {
      const method = stringArgument(effect, 0);
      const url = stringArgument(effect, 1);
      const body = effect.arguments.length >= 3 ? stringArgument(effect, 2) : undefined;
      const headers = effect.arguments[3];
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), limits.timeoutMs);
      try {
        const response = await fetch(url, {
          method,
          ...(body !== undefined && method !== "GET" ? { body } : {}),
          ...(headers && typeof headers === "object" && !Array.isArray(headers)
            ? { headers: headers as Record<string, string> }
            : {}),
          signal: controller.signal,
        });
        const bytes = new Uint8Array(await response.arrayBuffer());
        if (bytes.byteLength > limits.maxOutputBytes) throw new Error("Effect output exceeds its byte limit.");
        return {
          status: response.status,
          headers: Object.fromEntries(response.headers.entries()),
          body: new TextDecoder("utf-8", { fatal: true }).decode(bytes),
        };
      } finally {
        clearTimeout(timeout);
      }
    }
    case "clipboard/read":
      return await runCommand("/usr/bin/pbpaste", [], limits);
    case "clipboard/write": {
      const text = stringArgument(effect, 0);
      await runCommand("/usr/bin/pbcopy", [], { ...limits, input: text });
      return { bytes: Buffer.byteLength(text) };
    }
    case "notification/show": {
      const title = stringArgument(effect, 0);
      const body = effect.arguments.length === 2 ? stringArgument(effect, 1) : "";
      const quoted = (value: string) => value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
      await runCommand("/usr/bin/osascript", [
        "-e",
        `display notification "${quoted(body)}" with title "${quoted(title)}"`,
      ], limits);
      return { shown: true };
    }
    case "action/run":
      throw new Error("action/run is available in the native nvModern host.");
    case "model/complete": {
      const command = process.env.NVMODERN_ARBOR_MODEL_COMMAND;
      if (!command) throw new Error("Set NVMODERN_ARBOR_MODEL_COMMAND to enable model/complete.");
      const prompt = stringArgument(effect, 0);
      const model = effect.arguments.length === 2 ? stringArgument(effect, 1) : "";
      return await runCommand(command, [], {
        ...limits,
        input: prompt,
        env: { ...process.env, ...(model ? { NVMODERN_ARBOR_MODEL: model } : {}) },
      });
    }
    default:
      throw new Error(`Unsupported effect handler: ${effect.handler}`);
  }
}

const server = Bun.serve({
  port: Number(process.env.PORT ?? 3000),

  routes: {
    "/": index,
    "/stack": stackIndex,

    "/api/files": async (req) => {
      const url = new URL(req.url);
      const dir = url.searchParams.get("dir") ?? ".";

      try {
        const files = await listFiles(dir);
        return Response.json(files);
      } catch (e) {
        return Response.json({ error: String(e) }, { status: 400 });
      }
    },

    // Built-in themes, read straight from NVModern/BuiltinThemes so the shell
    // previews exactly what the app bundles.
    "/api/themes": async () => {
      const names = (await readdir(BUILTIN_THEMES_DIR)).filter((name) => name.endsWith(".css")).sort();
      const themes = await Promise.all(names.map(async (name) => {
        const css = await Bun.file(join(BUILTIN_THEMES_DIR, name)).text();
        const label = /--nv3-theme-name:\s*([^;]+);/.exec(css)?.[1]?.trim();
        const id = name.slice(0, -".css".length);
        return { id, label: label ?? id };
      }));
      return Response.json(themes);
    },

    "/api/theme": async (req) => {
      const id = new URL(req.url).searchParams.get("id") ?? "";
      if (!THEME_ID_PATTERN.test(id)) {
        return Response.json({ error: "invalid theme id" }, { status: 400 });
      }
      const file = Bun.file(join(BUILTIN_THEMES_DIR, `${id}.css`));
      if (!(await file.exists())) {
        return Response.json({ error: "theme not found" }, { status: 404 });
      }
      return new Response(await file.text(), {
        headers: { "Content-Type": "text/css; charset=utf-8", "Cache-Control": "no-store" },
      });
    },

    "/api/file": {
      GET: async (req) => {
        const url = new URL(req.url);
        const filePath = url.searchParams.get("path");
        if (!filePath) {
          return Response.json({ error: "path required" }, { status: 400 });
        }

        try {
          const resolvedPath = resolveInsideRoot(filePath);
          const content = await Bun.file(resolvedPath).text();
          return new Response(content, {
            headers: { "Content-Type": "text/plain; charset=utf-8" },
          });
        } catch (e) {
          return Response.json({ error: String(e) }, { status: 404 });
        }
      },

      PUT: async (req) => {
        const url = new URL(req.url);
        const filePath = url.searchParams.get("path");
        if (!filePath) {
          return Response.json({ error: "path required" }, { status: 400 });
        }

        try {
          const resolvedPath = resolveInsideRoot(filePath);
          const content = await req.text();
          await Bun.write(resolvedPath, content);
          return Response.json({ ok: true });
        } catch (e) {
          return Response.json({ error: String(e) }, { status: 500 });
        }
      },
    },

    "/api/arbor/kernel": {
      GET: () => Response.json(kernelStatus()),
      POST: async (req) => {
        if (!kernel) {
          return Response.json({ error: "Racket executable not found." }, { status: 503 });
        }
        try {
          await ensureWorkspaceIndexed();
          const request = await req.json() as Record<string, unknown>;
          const allowedOps = new Set([
            "evaluate",
            "document/replace",
            "query/run",
            "view/get",
            "producer/run",
            "effect/cancel",
          ]);
          if (
            request.protocol !== "arbor-kernel/1"
            || typeof request.id !== "string"
            || typeof request.op !== "string"
            || !allowedOps.has(request.op)
          ) {
            return Response.json({ error: "Invalid Arbor kernel request." }, { status: 400 });
          }
          const response = await kernel.request(request) as Record<string, unknown>;
          if (response.status === "effect-request") {
            const effect = response.effect as PlannedEffect | undefined;
            if (effect?.executionID && typeof effect.handler === "string"
                && Array.isArray(effect.arguments) && effect.limits
                && typeof effect.limits.timeoutMs === "number"
                && typeof effect.limits.maxOutputBytes === "number") {
              pendingEffects.set(effect.executionID, effect);
            }
          }
          if (response.status === "mutation-request") {
            const mutation = response.mutation as PlannedMutation | undefined;
            if (
              mutation?.executionID
              && Array.isArray(mutation.summary)
              && typeof mutation.operationCount === "number"
              && mutation.document?.revision > 0
            ) {
              pendingMutations.set(mutation.executionID, mutation);
            }
          }
          return Response.json(response);
        } catch (error) {
          return Response.json({ error: String(error) }, { status: 502 });
        }
      },
    },

    "/api/arbor/intent": {
      POST: async (req) => {
        if (!kernel) {
          return Response.json({ error: "Racket executable not found." }, { status: 503 });
        }
        try {
          await ensureWorkspaceIndexed();
          const request = await req.json() as Record<string, unknown>;
          if (request.protocol !== "arbor-kernel/1" || request.op !== "intent/apply") {
            return Response.json({ error: "Invalid Arbor intent request." }, { status: 400 });
          }
          const intent = await kernel.request(request) as Record<string, unknown>;
          if (intent.ok === false) return Response.json(intent);
          if (intent.outcome === "idempotent") return Response.json(intent);
          const document = intent.document as {
            id: string; path: string; revision: number; source: string;
          };
          const resolvedPath = await resolveExistingInsideRoot(document.path);
          const diskSource = await Bun.file(resolvedPath).text();
          if (diskSource !== intent.expectedSource) {
            return Response.json({
              ...intent,
              ok: false,
              diagnostics: [{
                severity: "error",
                code: "ARBOR3405",
                message: "The source document changed on disk; reload before applying this edit.",
              }],
            });
          }
          await Bun.write(resolvedPath, document.source);
          const replaced = await kernel.request({
            protocol: "arbor-kernel/1",
            id: `${String(request.id)}:replace`,
            op: "document/replace",
            document,
          }) as Record<string, unknown>;
          if (replaced.ok === false) throw new Error("Kernel rejected the source-backed replacement.");
          const { expectedSource: _expectedSource, document: _document, ...response } = intent;
          return Response.json(response);
        } catch (error) {
          return Response.json({ error: String(error) }, { status: 502 });
        }
      },
    },

    "/api/arbor/effect": {
      POST: async (req) => {
        if (!kernel) {
          return Response.json({ error: "Racket executable not found." }, { status: 503 });
        }
        try {
          const body = await req.json() as { allowed?: boolean; executionID?: string };
          if (typeof body.executionID !== "string") {
            return Response.json({ error: "Invalid Arbor effect request." }, { status: 400 });
          }
          const completed = completedEffects.get(body.executionID);
          if (completed) return Response.json(completed);
          const effect = pendingEffects.get(body.executionID);
          if (!effect) {
            return Response.json({ error: "Arbor effect is not pending." }, { status: 409 });
          }
          pendingEffects.delete(body.executionID);
          let outcome: Record<string, unknown>;
          const startedAt = performance.now();
          if (body.allowed === false) {
            outcome = { ok: false, message: "Effect permission was denied." };
          } else {
            try {
              outcome = { ok: true, value: await executeEffect(effect) };
            } catch (error) {
              outcome = { ok: false, message: String(error) };
            }
          }
          const output = outcome.ok ? JSON.stringify(outcome.value) : "";
          recordKernelMessage({
            direction: "system",
            message: {
              event: "effect/broker",
              executionID: body.executionID,
              handler: effect.handler,
              capabilityID: effect.capability?.id ?? null,
              durationMs: Math.round((performance.now() - startedAt) * 10) / 10,
              outputBytes: Buffer.byteLength(output),
              outputHash: output
                ? createHash("sha1").update(output).digest("hex")
                : null,
              outcome: body.allowed === false ? "denied" : outcome.ok ? "ok" : "error",
            },
          });
          const response = await kernel.request({
            protocol: "arbor-kernel/1",
            id: `${body.executionID}:complete`,
            op: "effect/complete",
            executionID: body.executionID,
            outcome,
          }) as Record<string, unknown>;
          completedEffects.set(body.executionID, response);
          if (completedEffects.size > 128) {
            completedEffects.delete(completedEffects.keys().next().value!);
          }
          return Response.json(response);
        } catch (error) {
          return Response.json({ error: String(error) }, { status: 502 });
        }
      },
    },

    "/api/arbor/mutation": {
      POST: async (req) => {
        if (!kernel) {
          return Response.json({ error: "Racket executable not found." }, { status: 503 });
        }
        let mutation: PlannedMutation | undefined;
        const startedAt = performance.now();
        try {
          const body = await req.json() as { allowed?: boolean; executionID?: string };
          if (typeof body.executionID !== "string") {
            return Response.json({ error: "Invalid Arbor mutation request." }, { status: 400 });
          }
          const completed = completedMutations.get(body.executionID);
          if (completed) return Response.json(completed);
          mutation = pendingMutations.get(body.executionID);
          if (!mutation) {
            return Response.json({ error: "Arbor mutation is not pending." }, { status: 409 });
          }
          pendingMutations.delete(body.executionID);
          if (body.allowed === false) {
            const denied = await kernel.request({
              protocol: "arbor-kernel/1",
              id: `${body.executionID}:denied`,
              op: "mutation/complete",
              executionID: body.executionID,
              outcome: { ok: false, message: "Outline transaction was denied." },
            }) as Record<string, unknown>;
            recordMutationBroker(mutation, startedAt, "denied");
            completedMutations.set(body.executionID, denied);
            if (completedMutations.size > 128) {
              completedMutations.delete(completedMutations.keys().next().value!);
            }
            return Response.json(denied);
          }

          const path = await resolveExistingInsideRoot(mutation.document.path);
          const diskSource = await Bun.file(path).text();
          if (diskSource !== mutation.expectedSource) {
            await kernel.request({
              protocol: "arbor-kernel/1",
              id: `${body.executionID}:conflict`,
              op: "mutation/complete",
              executionID: body.executionID,
              outcome: { ok: false, message: "The source changed on disk." },
            });
            recordMutationBroker(mutation, startedAt, "conflict");
            return Response.json({
              error: "The source document changed on disk; reload before applying this transaction.",
            }, { status: 409 });
          }

          await Bun.write(path, mutation.document.source);
          const replaced = await kernel.request({
            protocol: "arbor-kernel/1",
            id: `${body.executionID}:replace`,
            op: "document/replace",
            document: mutation.document,
          }) as Record<string, unknown>;
          if (replaced.ok === false) {
            if (await Bun.file(path).text() === mutation.document.source) {
              await Bun.write(path, mutation.expectedSource);
            }
            throw new Error("Kernel rejected the outline transaction replacement.");
          }
          const response = await kernel.request({
            protocol: "arbor-kernel/1",
            id: `${body.executionID}:complete`,
            op: "mutation/complete",
            executionID: body.executionID,
            outcome: { ok: true },
          }) as Record<string, unknown>;
          recordMutationBroker(mutation, startedAt, "ok");
          completedMutations.set(body.executionID, response);
          if (completedMutations.size > 128) {
            completedMutations.delete(completedMutations.keys().next().value!);
          }
          return Response.json(response);
        } catch (error) {
          if (mutation) recordMutationBroker(mutation, startedAt, "error");
          return Response.json({ error: String(error) }, { status: 502 });
        }
      },
    },

    "/api/arbor/kernel/logs": (req) => {
      const after = Number(new URL(req.url).searchParams.get("after") ?? 0);
      return Response.json({
        entries: transcript.filter((entry) => entry.sequence > after),
        status: kernelStatus(),
      });
    },
  },

  development: {
    hmr: true,
    console: true,
  },
});

await rm(LATEST_KERNEL_LOG_PATH, { force: true });
await symlink(KERNEL_LOG_PATH, LATEST_KERNEL_LOG_PATH);

console.log(`🔧 Editor shell → http://localhost:${server.port}`);
console.log(`📁 Serving files from: ${ROOT}`);
console.log(`🧾 Arbor kernel log: ${KERNEL_LOG_PATH}`);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, async () => {
    kernel?.shutdown();
    await logWrite.catch(() => undefined);
    server.stop();
    process.exit(0);
  });
}
