export interface ArborKernelDiagnostic {
  severity: string;
  code: string;
  message: string;
  line?: number;
  column?: number;
}

export interface ArborKernelPatch {
  op: string;
  uid: string;
  revision: number;
  display?: string;
  value?: unknown;
}

export interface ArborKernelResponse {
  ok?: boolean;
  outcome?: string;
  revision?: number;
  acceptedRevision?: number;
  worldRevision?: number;
  documentID?: string;
  factCount?: number;
  diagnostics?: ArborKernelDiagnostic[];
  patches?: ArborKernelPatch[];
  document?: {
    id?: string;
    path: string;
    revision?: number;
    source?: string;
  };
}

export interface ArborEvaluateRequest {
  path: string;
  source: string;
  revision: number;
  previousDerivedUIDs: string[];
}

export interface ArborDocumentWrite {
  id: string;
  path: string;
  source: string;
  revision: number;
  requestId: string;
}

export interface ArborDocumentReplaceRequest {
  requestId: string;
  document: {
    id: string;
    path: string;
    source: string;
    revision: number;
  };
}

export interface ArborQueryRequest {
  requestId: string;
  documentId: string;
  revision: number;
  queryId: string;
  arguments?: Record<string, unknown>;
}

export interface ArborQueryResponse extends ArborKernelResponse {
  queryID?: string;
  columns?: string[];
  rows?: unknown[][];
}

export interface ArborViewCell {
  kind: "block" | "scalar";
  value: unknown;
  display: string;
  blockID?: string;
  documentID?: string | null;
  path?: string | null;
  markdown?: string | null;
}

export interface ArborViewRow {
  id: string;
  cells: ArborViewCell[];
}

export interface ArborViewResult {
  id: string;
  producerID: string;
  kind: "expression" | "query";
  presentation: "scalar" | "outline" | "table";
  status: "ok" | "error" | "needs-arguments";
  display?: string;
  value?: unknown;
  inputs?: string[];
  columns?: string[];
  rows?: ArborViewRow[];
  diagnostics?: ArborKernelDiagnostic[];
}

export interface ArborViewRequest {
  requestId: string;
  documentId: string;
  revision: number;
  queryId?: string;
  arguments?: Record<string, unknown>;
}

export interface ArborViewResponse extends ArborKernelResponse {
  views?: ArborViewResult[];
}

export interface ArborProducerResult {
  key: string;
  markdown: string;
  origin?: {
    blockID: string;
    documentID: string;
    path: string;
  };
  updatePolicy?: "source-text" | "detach";
}

export interface ArborProducerRequest {
  requestId: string;
  documentId: string;
  revision: number;
  producerId: string;
  mode: "refresh" | "append";
  arguments?: Record<string, unknown>;
}

export interface ArborProducerResponse extends ArborKernelResponse {
  producerID?: string;
  kind?: "expression" | "query" | "effect" | "mutation";
  status?: "effect-request" | "mutation-request";
  mode?: "refresh" | "append";
  generation?: number;
  inputHash?: string;
  results?: ArborProducerResult[];
  effect?: ArborEffectRequest;
  mutation?: ArborMutationRequest;
}

export interface ArborEffectCapability {
  id: string;
  kind: string;
  resource: string;
  summary: string;
}

export type ArborValue = null | boolean | number | string | ArborValue[] | {
  [key: string]: ArborValue;
};

export interface ArborEffectRequest {
  executionID: string;
  handler: string;
  arguments: ArborValue[];
  capability: ArborEffectCapability | null;
  limits: {
    timeoutMs: number;
    maxOutputBytes: number;
  };
}

export interface ArborMutationRequest {
  executionID: string;
  summary: string[];
  operationCount: number;
  destructive: boolean;
  capability: ArborEffectCapability;
  expectedSource: string;
  document: {
    id: string;
    path: string;
    revision: number;
    source: string;
  };
}

export interface ArborIntentRequest {
  requestId: string;
  documentId: string;
  revision: number;
  resultId: string;
  intent: { op: "set-text"; text: string };
}

export interface ArborIntentResponse extends ArborKernelResponse {
  origin?: { blockID: string; documentID: string; path: string };
  text?: string;
}

export interface ArborLinkTarget {
  target: string;
  href: string;
  filePath?: string;
}

export interface ArborInlineLinkTarget {
  href: string;
  filePath?: string;
}

export interface ArborWikilinkSuggestion {
  label: string;
  insertText: string;
  detail?: string;
}

export interface ArborDatePickerRequest {
  isoDate: string;
  kind: "inactive" | "active";
  raw: string;
  filePath?: string;
}

export type ArborInlineFormat = "bold" | "italic";

export interface ArborContextMenuRequest {
  x: number;
  y: number;
  selectionText: string;
  blockId: ArborBlockId;
  canMoveUp: boolean;
  canMoveDown: boolean;
}

export type ArborContextMenuAction =
  | "copyText"
  | "copyId"
  | "moveUp"
  | "moveDown"
  | "delete";

export interface ArborHost {
  readonly kernelEnabled: boolean;
  trace?(event: string, detail: Record<string, unknown>): void;
  saveDocument(document: ArborDocumentWrite): void | Promise<void>;
  evaluate(request: ArborEvaluateRequest): Promise<ArborKernelResponse>;
  replaceDocument(request: ArborDocumentReplaceRequest): Promise<ArborKernelResponse>;
  runQuery(request: ArborQueryRequest): Promise<ArborQueryResponse>;
  getView(request: ArborViewRequest): Promise<ArborViewResponse>;
  runProducer(request: ArborProducerRequest): Promise<ArborProducerResponse>;
  applyIntent(request: ArborIntentRequest): Promise<ArborIntentResponse>;
  autocompleteWikilinks?(
    query: string,
    filePath?: string,
  ): Promise<readonly ArborWikilinkSuggestion[]>;
  pickDate?(request: ArborDatePickerRequest): Promise<string | null>;
  subscribeInlineFormatting?(
    handler: (format: ArborInlineFormat) => boolean,
  ): () => void;
  showContextMenu?(request: ArborContextMenuRequest): void;
  subscribeContextMenuActions?(
    handler: (action: ArborContextMenuAction) => boolean,
  ): () => void;
  openLink(link: ArborLinkTarget): void;
  openInlineLink(link: ArborInlineLinkTarget): void;
}
