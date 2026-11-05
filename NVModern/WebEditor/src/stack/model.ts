/**
 * Side stack state: the card list Swift pushes with `setStack`, normalised,
 * plus the pure helpers the stack surface renders from. See the "Stack bridge
 * protocol" section of docs/tickets/0031-side-stack.md.
 */
import {
  detectNv3FileType,
  parseNv3WikilinkTarget,
  resolveNv3SectionRange,
  type Nv3FileType,
  type Nv3SectionRange,
} from "../lib/index.ts";

export interface StackCardFocus {
  heading?: string;
  block?: string;
}

export interface StackCard {
  id: string;
  path: string;
  title: string;
  body: string;
  fileType: Nv3FileType;
  focus: StackCardFocus | null;
  collapsed: boolean;
  /** Undefined when Swift does not track it; the surface then keeps its own. */
  showWholeNote: boolean | undefined;
}

export interface StackState {
  cards: StackCard[];
  revealId: string | null;
}

export type StackLinkIntent = "openInMain" | "push";

export interface StackClickModifiers {
  shiftKey: boolean;
  metaKey: boolean;
  altKey: boolean;
  ctrlKey: boolean;
}

export const EMPTY_STACK: StackState = { cards: [], revealId: null };

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function nonEmptyString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

export function titleFromPath(path: string): string {
  const name = path.split("/").pop() ?? path;
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(0, dot) : name;
}

function normalizeFileType(value: unknown, path: string): Nv3FileType {
  if (value === "markdown" || value === "org" || value === "plain") return value;
  if (value === "md") return "markdown";
  return detectNv3FileType(path);
}

export function normalizeStackFocus(value: unknown): StackCardFocus | null {
  const record = asRecord(value);
  if (!record) return null;
  const heading = nonEmptyString(record.heading)?.trim();
  const block = nonEmptyString(record.block)?.trim().replace(/^\^/, "");
  if (heading) return { heading };
  if (block) return { block };
  return null;
}

/** Validates a `setStack` payload. Malformed cards and duplicate ids are dropped. */
export function normalizeStackPayload(payload: unknown): StackState {
  const record = asRecord(payload);
  if (!record) return EMPTY_STACK;

  const seen = new Set<string>();
  const cards: StackCard[] = [];
  const rawCards = Array.isArray(record.cards) ? record.cards : [];

  for (const rawCard of rawCards) {
    const card = asRecord(rawCard);
    if (!card) continue;
    const path = nonEmptyString(card.path);
    if (!path) continue;
    const id = nonEmptyString(card.id) ?? path;
    if (seen.has(id)) continue;
    seen.add(id);

    cards.push({
      id,
      path,
      title: nonEmptyString(card.title) ?? titleFromPath(path),
      body: typeof card.body === "string" ? card.body.replace(/\r\n?/g, "\n") : "",
      fileType: normalizeFileType(card.fileType, path),
      focus: normalizeStackFocus(card.focus),
      collapsed: card.collapsed === true,
      showWholeNote: typeof card.showWholeNote === "boolean" ? card.showWholeNote : undefined,
    });
  }

  const revealId = nonEmptyString(record.revealId) ?? null;
  return { cards, revealId: revealId && seen.has(revealId) ? revealId : null };
}

/** Section focus carried by a wikilink target (`note#Heading`, `note#^id`). */
export function focusFromWikilinkTarget(target: string): StackCardFocus | null {
  const parsed = parseNv3WikilinkTarget(target);
  if (!parsed.referenceQuery) return null;
  if (parsed.referenceKind === "heading") return { heading: parsed.referenceQuery };
  if (parsed.referenceKind === "block") return { block: parsed.referenceQuery };
  return null;
}

export function focusLabel(focus: StackCardFocus | null): string {
  if (!focus) return "";
  if (focus.heading) return focus.heading;
  if (focus.block) return `^${focus.block}`;
  return "";
}

/** Shift-click pushes a card; any other click opens the note in the main view. */
export function stackLinkIntent(modifiers: Pick<StackClickModifiers, "shiftKey">): StackLinkIntent {
  return modifiers.shiftKey ? "push" : "openInMain";
}

export interface StackCardDisplay {
  /** Text the card's editor shows: the focused section, or the whole note. */
  doc: string;
  /** The focused section within the whole note, when it resolved. */
  section: Nv3SectionRange | null;
  /** True when the card has a focus that the note no longer contains. */
  sectionMissing: boolean;
  /** True when only the section is shown. */
  showingSection: boolean;
}

export function stackCardDisplay(card: StackCard, showWholeNote: boolean): StackCardDisplay {
  const section = card.focus ? resolveNv3SectionRange(card.body, card.fileType, card.focus) : null;
  const sectionMissing = Boolean(card.focus) && !section;
  const showingSection = Boolean(section) && !showWholeNote;
  return {
    doc: showingSection && section ? card.body.slice(section.from, section.to) : card.body,
    section,
    sectionMissing,
    showingSection,
  };
}

/**
 * Optimistic per-card UI flags (collapsed, show whole note): the surface
 * applies a toggle at once and emits it; the override is dropped once Swift
 * echoes the same value back, or the card leaves the stack.
 */
export function reconcileOverrides(
  overrides: ReadonlyMap<string, boolean>,
  cards: readonly StackCard[],
  hostValue: (card: StackCard) => boolean | undefined,
): Map<string, boolean> {
  const next = new Map<string, boolean>();
  for (const card of cards) {
    const override = overrides.get(card.id);
    if (override === undefined) continue;
    if (hostValue(card) === override) continue;
    next.set(card.id, override);
  }
  return next;
}
