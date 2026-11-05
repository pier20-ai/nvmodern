import type { ArborOutlineStore } from "./store.ts";
import type {
  ArborBlockId,
  ArborBlockNode,
  ArborComputationMetadata,
  ArborEditResult,
} from "./types.ts";

const STABLE_ID = "[A-Za-z0-9][A-Za-z0-9._:-]{0,127}";
const COMPONENT = "[A-Za-z0-9._:-]+";
const POSITIVE_INTEGER = "(?:[1-9][0-9]*|true)";
const WORLD_REVISION = "(?:[0-9]+|true|false|x)";
const C1_ANCHOR_PATTERN = new RegExp(
  `^(${STABLE_ID})(?:~c1~([lsd])~(${STABLE_ID})~(${COMPONENT})~(${POSITIVE_INTEGER})~([a-f0-9]{40})(?:~(${WORLD_REVISION}))?)?$`,
);
const C2_ANCHOR_PATTERN = new RegExp(
  `^(${STABLE_ID})~c2~([lsd])~(${STABLE_ID})~(${COMPONENT})~(${POSITIVE_INTEGER})~([a-f0-9]{40})~(${WORLD_REVISION})~(${STABLE_ID})~([td])$`,
);

const stateCodes = {
  live: "l",
  snapshot: "s",
  detached: "d",
} as const;

const statesByCode = {
  l: "live",
  s: "snapshot",
  d: "detached",
} as const;

function parseInteger(value: string): number {
  if (value === "true") return 1;
  if (value === "false") return 0;
  return Number(value);
}

export interface ArborAnchor {
  readonly id: ArborBlockId;
  readonly computation?: ArborComputationMetadata;
}

export interface ArborMaterializedResult {
  readonly key: string;
  readonly markdown: string;
  readonly origin?: {
    readonly blockID: string;
    readonly documentID: string;
    readonly path: string;
  };
  readonly updatePolicy?: "source-text" | "detach";
}

export interface ArborProducerRun {
  readonly producerId: ArborBlockId;
  readonly mode: "refresh" | "append";
  readonly generation: number;
  readonly inputHash: string;
  readonly worldRevision?: number;
  readonly results: readonly ArborMaterializedResult[];
}

export interface ArborMaterializationPlan {
  readonly freezeIds: readonly ArborBlockId[];
  readonly deleteIds: readonly ArborBlockId[];
  readonly results: ReadonlyArray<{
    readonly blockId?: ArborBlockId;
    readonly result: ArborMaterializedResult;
  }>;
}

export function parseArborAnchor(value: string): ArborAnchor | null {
  const c2 = value.match(C2_ANCHOR_PATTERN);
  const match = c2 ?? value.match(C1_ANCHOR_PATTERN);
  if (!match) return null;
  const id = match[1] as ArborBlockId;
  const stateCode = match[2] as keyof typeof statesByCode | undefined;
  if (!stateCode) return { id };
  return {
    id,
    computation: {
      version: c2 ? 2 : 1,
      state: statesByCode[stateCode],
      producerId: match[3] as ArborBlockId,
      resultKey: match[4]!,
      generation: parseInteger(match[5]!),
      inputHash: match[6]!,
      ...(match[7] === undefined || match[7] === "x"
        ? {}
        : { worldRevision: parseInteger(match[7]) }),
      ...(c2 ? {
        originBlockId: match[8] as ArborBlockId,
        updatePolicy: match[9] === "t" ? "source-text" as const : "detach" as const,
      } : {}),
    },
  };
}

export function serializeArborAnchor(
  id: ArborBlockId,
  computation?: ArborComputationMetadata,
): string {
  if (!computation) return id;
  if (computation.originBlockId && computation.updatePolicy) {
    return [
      id,
      "c2",
      stateCodes[computation.state],
      computation.producerId,
      computation.resultKey,
      computation.generation,
      computation.inputHash,
      computation.worldRevision ?? "x",
      computation.originBlockId,
      computation.updatePolicy === "source-text" ? "t" : "d",
    ].join("~");
  }
  const world = computation.worldRevision === undefined ? "" : `~${computation.worldRevision}`;
  return [
    id,
    "c1",
    stateCodes[computation.state],
    computation.producerId,
    computation.resultKey,
    computation.generation,
    computation.inputHash,
  ].join("~") + world;
}

export function isManagedComputation(
  computation: ArborComputationMetadata | undefined,
): boolean {
  return computation?.state === "live" || computation?.state === "snapshot";
}

export function planArborMaterialization(
  producerId: ArborBlockId,
  children: readonly Pick<ArborBlockNode, "id" | "computation">[],
  run: Pick<ArborProducerRun, "mode" | "results">,
): ArborMaterializationPlan {
  const live = children.filter((block) => (
    block.computation?.producerId === producerId && block.computation.state === "live"
  ));
  const freezeIds = run.mode === "append" ? live.map((block) => block.id) : [];
  const available = new Map<string, ArborBlockId[]>();
  if (run.mode === "refresh") {
    for (const block of live) {
      const key = block.computation!.resultKey;
      available.set(key, [...(available.get(key) ?? []), block.id]);
    }
  }

  const results = run.results.map((result) => {
    const matches = available.get(result.key) ?? [];
    const blockId = matches.shift();
    available.set(result.key, matches);
    return { ...(blockId ? { blockId } : {}), result };
  });
  const deleteIds = [...available.values()].flat();
  return { freezeIds, deleteIds, results };
}

function liveMetadata(run: ArborProducerRun, resultKey: string): ArborComputationMetadata {
  const result = run.results.find((candidate) => candidate.key === resultKey);
  const originBlockId = result?.origin?.blockID as ArborBlockId | undefined;
  return {
    version: originBlockId && result?.updatePolicy ? 2 : 1,
    state: "live",
    producerId: run.producerId,
    resultKey,
    generation: run.generation,
    inputHash: run.inputHash,
    ...(run.worldRevision === undefined ? {} : { worldRevision: run.worldRevision }),
    ...(originBlockId && result?.updatePolicy
      ? { originBlockId, updatePolicy: result.updatePolicy }
      : {}),
  };
}

export function applyArborMaterialization(
  store: ArborOutlineStore,
  run: ArborProducerRun,
): ArborEditResult {
  const producer = store.getBlock(run.producerId);
  if (!producer) throw new Error(`Unknown Arbor producer: ${run.producerId}`);
  const children = store.childIds(producer.pageId, run.producerId)
    .map((id) => store.getBlock(id))
    .filter((block): block is Readonly<ArborBlockNode> => Boolean(block));
  const plan = planArborMaterialization(run.producerId, children, run);

  return store.transaction(run.mode === "append" ? "Run producer as new" : "Run producer", () => {
    for (const id of plan.freezeIds) {
      const computation = store.getBlock(id)?.computation;
      if (computation) store.setBlockComputation(id, { ...computation, state: "snapshot" });
    }
    for (const id of plan.deleteIds) {
      if (store.hasBlock(id)) store.deleteBlock(id);
    }

    const liveIds: ArborBlockId[] = [];
    for (const item of plan.results) {
      const computation = liveMetadata(run, item.result.key);
      if (item.blockId && store.hasBlock(item.blockId)) {
        store.setBlockText(item.blockId, item.result.markdown, { preserveComputation: true });
        store.setBlockComputation(item.blockId, computation);
        liveIds.push(item.blockId);
      } else {
        const inserted = store.insertBlock({
          pageId: producer.pageId,
          parentId: run.producerId,
          afterId: store.getBlock(run.producerId)?.lastChildId ?? null,
          text: item.result.markdown,
          computation,
        });
        if (inserted.focus) liveIds.push(inserted.focus.blockId);
      }
    }

    const liveSet = new Set(liveIds);
    const fixed = store.childIds(producer.pageId, run.producerId)
      .filter((id) => !liveSet.has(id));
    let afterId = fixed.at(-1) ?? null;
    for (const id of liveIds) {
      store.moveBlock(id, {
        pageId: producer.pageId,
        parentId: run.producerId,
        afterId,
      }, "Order materialized result", { preserveComputation: true });
      afterId = id;
    }
  });
}
