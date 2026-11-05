export type ArborBlockId = string & { readonly __arborBlockId: unique symbol };
export type ArborPageId = string & { readonly __arborPageId: unique symbol };

export type ArborComputationState = "live" | "snapshot" | "detached";

export interface ArborComputationMetadata {
  readonly version: 1 | 2;
  readonly state: ArborComputationState;
  readonly producerId: ArborBlockId;
  readonly resultKey: string;
  readonly generation: number;
  readonly inputHash: string;
  readonly worldRevision?: number;
  readonly originBlockId?: ArborBlockId;
  readonly updatePolicy?: "source-text" | "detach";
}

export interface ArborBlockSnapshot {
  id: ArborBlockId;
  pageId: ArborPageId;
  parentId: ArborBlockId | null;
  children: ArborBlockId[];
  text: string;
  computation?: ArborComputationMetadata;
  collapsed?: boolean;
}

export interface ArborPageSnapshot {
  id: ArborPageId;
  title: string;
  children: ArborBlockId[];
}

export interface ArborDocumentSnapshot {
  version: 1;
  pages: ArborPageSnapshot[];
  blocks: ArborBlockSnapshot[];
}

export interface ArborBlockNode {
  readonly id: ArborBlockId;
  pageId: ArborPageId;
  text: string;
  parentId: ArborBlockId | null;
  firstChildId: ArborBlockId | null;
  lastChildId: ArborBlockId | null;
  previousSiblingId: ArborBlockId | null;
  nextSiblingId: ArborBlockId | null;
  childCount: number;
  collapsed: boolean;
  computation?: ArborComputationMetadata;
}

export interface ArborPageNode {
  readonly id: ArborPageId;
  title: string;
  firstChildId: ArborBlockId | null;
  lastChildId: ArborBlockId | null;
  childCount: number;
}

export interface ArborCaretTarget {
  blockId: ArborBlockId;
  offset: number;
}

export interface ArborEditResult {
  changed: boolean;
  focus: ArborCaretTarget | null;
}

export interface ArborInsertInput {
  pageId: ArborPageId;
  parentId?: ArborBlockId | null;
  afterId?: ArborBlockId | null;
  id?: ArborBlockId;
  text?: string;
  computation?: ArborComputationMetadata;
  collapsed?: boolean;
}

export interface ArborMoveDestination {
  pageId?: ArborPageId;
  parentId: ArborBlockId | null;
  afterId: ArborBlockId | null;
}

export interface ArborTextEditOptions {
  /** Consecutive edits with the same key coalesce into one undo entry. */
  historyGroup?: string;
  /** Kernel materialization may update a live result without detaching it. */
  preserveComputation?: boolean;
}

export interface ArborMoveOptions {
  /** Kernel materialization may reorder a live result without detaching it. */
  preserveComputation?: boolean;
}

export interface ArborHistoryState {
  readonly canUndo: boolean;
  readonly canRedo: boolean;
  readonly undoDepth: number;
  readonly redoDepth: number;
}

export interface ArborVisibleRow {
  readonly id: ArborBlockId;
  readonly pageId: ArborPageId;
  readonly parentId: ArborBlockId | null;
  readonly depth: number;
  readonly hasChildren: boolean;
  readonly collapsed: boolean;
}

export interface ArborVisibleSlice {
  readonly rows: readonly ArborVisibleRow[];
  readonly offset: number;
  readonly total: number;
}

export interface ArborVirtualWindow {
  readonly rows: readonly ArborVisibleRow[];
  readonly startIndex: number;
  readonly endIndex: number;
  readonly paddingTop: number;
  readonly paddingBottom: number;
  readonly totalHeight: number;
}

export interface ArborIdFactory {
  blockId(): ArborBlockId;
  pageId(): ArborPageId;
}

export interface ArborSourceDiagnostic {
  readonly severity: "error" | "warning";
  readonly code:
    | "arbor.missing-language"
    | "arbor.unsupported-language"
    | "arbor.invalid-indentation"
    | "arbor.indentation-jump"
    | "arbor.duplicate-id"
    | "arbor.invalid-anchor"
    | "arbor.unexpected-line";
  readonly message: string;
  readonly line: number;
  readonly column: number;
}

export interface ArborSourceParseOptions {
  title?: string;
  pageId?: ArborPageId;
  idFactory?: ArborIdFactory;
}

export interface ArborSourceParseResult {
  readonly snapshot: ArborDocumentSnapshot;
  readonly pageId: ArborPageId;
  readonly diagnostics: readonly ArborSourceDiagnostic[];
  readonly synthesizedIds: readonly ArborBlockId[];
}
