interface DevKernelProcess {
  stdin: {
    write(chunk: string): number;
    end(): void;
  };
  stdout: ReadableStream<Uint8Array>;
  stderr: ReadableStream<Uint8Array>;
  exited: Promise<number>;
  kill(): void;
}

interface PendingKernelRequest {
  request: Record<string, unknown>;
  resolve(value: unknown): void;
  reject(error: Error): void;
  timeout: ReturnType<typeof setTimeout>;
}

export interface DevKernelStatus {
  state: "stopped" | "running" | "unresponsive";
  executable: string;
  script: string;
  error?: string;
}

export interface DevKernelTranscriptEntry {
  direction: "send" | "receive" | "stderr" | "system";
  message: unknown;
}

export class ArborDevKernel {
  private process: DevKernelProcess | null = null;
  private pending = new Map<string, PendingKernelRequest>();
  private stdoutBuffer = "";
  private stderrBuffer = "";
  private stderrTail = "";
  private lastError: string | undefined;
  private sequence = 0;
  private acceptedDocuments = new Map<string, Record<string, unknown>>();

  constructor(
    private readonly executable: string,
    private readonly scriptPath: string,
    private readonly cwd: string,
    private readonly log: (entry: DevKernelTranscriptEntry) => void = () => undefined,
  ) {}

  status(): DevKernelStatus {
    const state = !this.process
      ? "stopped"
      : this.lastError ? "unresponsive" : "running";
    return {
      state,
      executable: this.executable,
      script: this.scriptPath,
      error: this.lastError,
    };
  }

  async evaluate(input: {
    path: string;
    source: string;
    revision: number;
    previousDerivedUIDs?: string[];
  }): Promise<unknown> {
    const id = `dev-${Date.now()}-${++this.sequence}`;
    const request = {
      protocol: "arbor-kernel/1",
      id,
      op: "evaluate",
      document: {
        path: input.path,
        revision: input.revision,
        source: input.source,
      },
      previousDerivedUIDs: input.previousDerivedUIDs ?? [],
    };

    return await this.request(request);
  }

  async request(request: Record<string, unknown>): Promise<unknown> {
    const process = this.ensureProcess();
    const id = request.id;
    if (typeof id !== "string" || !id) throw new Error("Kernel requests require a string id.");
    this.log({ direction: "send", message: request });

    return await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        if (!this.pending.delete(id)) return;
        const error = new Error("The development Racket kernel exceeded its 3 second timeout.");
        this.lastError = error.message;
        this.log({ direction: "system", message: `Request ${id} timed out after 3 seconds.` });
        reject(error);
      }, 3_000);
      this.pending.set(id, { request, resolve, reject, timeout });

      try {
        process.stdin.write(`${JSON.stringify(request)}\n`);
      } catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        const writeError = error instanceof Error ? error : new Error(String(error));
        this.lastError = writeError.message;
        reject(writeError);
      }
    });
  }

  shutdown(): void {
    const process = this.process;
    this.process = null;
    if (!process) return;
    try {
      process.stdin.end();
      process.kill();
    } catch {
      // The process may already have exited.
    }
    this.failPending(new Error("The development Racket kernel stopped."));
  }

  private ensureProcess(): DevKernelProcess {
    if (this.process) return this.process;

    this.stdoutBuffer = "";
    this.stderrBuffer = "";
    this.stderrTail = "";
    this.lastError = undefined;
    const process = Bun.spawn(
      [this.executable, this.scriptPath],
      {
        cwd: this.cwd,
        env: processEnv(),
        stdin: "pipe",
        stdout: "pipe",
        stderr: "pipe",
      },
    ) as unknown as DevKernelProcess;
    this.process = process;
    for (const [documentID, document] of [...this.acceptedDocuments].sort(([left], [right]) => (
      left.localeCompare(right)
    ))) {
      const replayRequest = {
        protocol: "arbor-kernel/1",
        id: `replay-${++this.sequence}-${documentID}`,
        op: "document/replace",
        document,
      };
      this.log({ direction: "send", message: replayRequest });
      process.stdin.write(`${JSON.stringify(replayRequest)}\n`);
    }
    void this.consumeStdout(process);
    void this.consumeStderr(process);
    void process.exited.then((exitCode) => {
      if (this.process === process) this.process = null;
      const detail = this.stderrTail.trim();
      const message = detail
        ? `The development Racket kernel exited with status ${exitCode}: ${detail}`
        : `The development Racket kernel exited with status ${exitCode}.`;
      this.lastError = message;
      this.failPending(new Error(message));
    });
    return process;
  }

  private async consumeStdout(process: DevKernelProcess): Promise<void> {
    const reader = process.stdout.getReader();
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      this.stdoutBuffer += decoder.decode(value, { stream: true });
      let newline = this.stdoutBuffer.indexOf("\n");
      while (newline >= 0) {
        const line = this.stdoutBuffer.slice(0, newline).trim();
        this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
        if (line) this.resolveLine(line);
        newline = this.stdoutBuffer.indexOf("\n");
      }
    }
  }

  private async consumeStderr(process: DevKernelProcess): Promise<void> {
    const reader = process.stderr.getReader();
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = decoder.decode(value, { stream: true });
      this.stderrTail = `${this.stderrTail}${chunk}`.slice(-4_096);
      this.stderrBuffer += chunk;
      let newline = this.stderrBuffer.indexOf("\n");
      while (newline >= 0) {
        const line = this.stderrBuffer.slice(0, newline).trim();
        this.stderrBuffer = this.stderrBuffer.slice(newline + 1);
        if (line) this.log({ direction: "stderr", message: line });
        newline = this.stderrBuffer.indexOf("\n");
      }
    }
  }

  private resolveLine(line: string): void {
    let response: { id?: unknown };
    try {
      response = JSON.parse(line) as { id?: unknown };
    } catch (error) {
      this.lastError = `The development Racket kernel returned invalid JSON: ${String(error)}`;
      return;
    }
    if (typeof response.id !== "string") return;
    this.lastError = undefined;
    this.log({ direction: "receive", message: response });
    const pending = this.pending.get(response.id);
    if (!pending) return;
    this.pending.delete(response.id);
    clearTimeout(pending.timeout);
    if (
      pending.request.op === "document/replace"
      && (response as { ok?: unknown }).ok === true
    ) {
      const document = pending.request.document;
      if (document && typeof document === "object") {
        const documentID = (document as { id?: unknown }).id;
        if (typeof documentID === "string") {
          this.acceptedDocuments.set(documentID, document as Record<string, unknown>);
        }
      }
    }
    pending.resolve(response);
  }

  private failPending(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    this.pending.clear();
  }
}

function processEnv(): Record<string, string> {
  return Object.fromEntries(
    Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined),
  );
}
