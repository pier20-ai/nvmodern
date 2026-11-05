import type { ArborBlockId, ArborIdFactory, ArborPageId } from "./types.ts";

let fallbackCounter = 0;

function randomToken(): string {
  const bytes = new Uint8Array(10);
  globalThis.crypto?.getRandomValues?.(bytes);
  if (bytes.some((byte) => byte !== 0)) {
    return Array.from(bytes, (byte) => byte.toString(36).padStart(2, "0")).join("");
  }

  fallbackCounter += 1;
  return `${Date.now().toString(36)}${fallbackCounter.toString(36).padStart(4, "0")}`;
}

export const defaultArborIdFactory: ArborIdFactory = {
  blockId: () => `b_${randomToken()}` as ArborBlockId,
  pageId: () => `p_${randomToken()}` as ArborPageId,
};

export function arborBlockId(value: string): ArborBlockId {
  return value as ArborBlockId;
}

export function arborPageId(value: string): ArborPageId {
  return value as ArborPageId;
}

export function createSequentialArborIdFactory(prefix = "test"): ArborIdFactory {
  let block = 0;
  let page = 0;
  return {
    blockId: () => `${prefix}_b${++block}` as ArborBlockId,
    pageId: () => `${prefix}_p${++page}` as ArborPageId,
  };
}
