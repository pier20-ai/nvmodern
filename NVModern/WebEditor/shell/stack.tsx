/**
 * Dev shell preview of the side stack (`make dev`, then /stack). A local mock
 * plays the native host: it loads cards from the dev content root, pushes a
 * card on Shift-click, flashes duplicates, and logs every stack event.
 */
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { ThemeToggle } from "./components/ThemeToggle.tsx";
import { StackSurface, type StackHost, type StackRequest } from "../src/stack/StackSurface.tsx";
import {
  normalizeStackPayload,
  titleFromPath,
  type StackCardFocus,
  type StackState,
} from "../src/stack/model.ts";

interface DevCard {
  id: string;
  path: string;
  body: string;
  focus: StackCardFocus | null;
  collapsed: boolean;
}

const SAMPLE_CARDS: Array<{ path: string; focus?: StackCardFocus; collapsed?: boolean }> = [
  { path: "calc-playground.md", focus: { heading: "List comprehensions" } },
  { path: "calc-plots.md" },
  { path: "org-comprehensive.org", collapsed: true },
];

async function readFile(path: string): Promise<string | null> {
  const response = await fetch(`/api/file?path=${encodeURIComponent(path)}`);
  return response.ok ? response.text() : null;
}

function dirname(path: string): string {
  const slash = path.lastIndexOf("/");
  return slash >= 0 ? path.slice(0, slash) : "";
}

/** A rough stand-in for Swift's wikilink resolution. */
async function resolveNote(note: string, fromPath: string): Promise<{ path: string; body: string } | null> {
  if (!note) {
    const body = await readFile(fromPath);
    return body == null ? null : { path: fromPath, body };
  }
  const bases = [note, dirname(fromPath) ? `${dirname(fromPath)}/${note}` : null].filter(Boolean) as string[];
  const candidates = bases.flatMap((base) => (/\.[A-Za-z0-9]+$/.test(base) ? [base] : [`${base}.md`, `${base}.org`, base]));
  for (const candidate of candidates) {
    const body = await readFile(candidate);
    if (body != null) return { path: candidate, body };
  }
  return null;
}

function StackDevShell() {
  const [cards, setCards] = useState<DevCard[]>([]);
  const [log, setLog] = useState<string[]>([]);
  const [reveal, setReveal] = useState<StackRequest | null>(null);
  const [flash, setFlash] = useState<StackRequest | null>(null);
  const nonce = useRef(0);
  const cardsRef = useRef(cards);
  cardsRef.current = cards;

  useEffect(() => {
    void Promise.all(
      SAMPLE_CARDS.map(async (sample) => {
        const body = await readFile(sample.path);
        if (body == null) return null;
        return {
          id: `${sample.path}#${sample.focus?.heading ?? ""}`,
          path: sample.path,
          body,
          focus: sample.focus ?? null,
          collapsed: sample.collapsed ?? false,
        } satisfies DevCard;
      }),
    ).then((loaded) => setCards(loaded.filter((card): card is DevCard => card != null)));
  }, []);

  const push = useCallback(async (note: string, fromPath: string, focus: StackCardFocus | null) => {
    const resolved = await resolveNote(note, fromPath);
    if (!resolved) return;
    const id = `${resolved.path}#${focus?.heading ?? (focus?.block ? `^${focus.block}` : "")}`;
    if (cardsRef.current.some((card) => card.id === id)) {
      setFlash({ id, nonce: ++nonce.current });
      return;
    }
    setCards((current) => [{ id, path: resolved.path, body: resolved.body, focus, collapsed: false }, ...current]);
    setReveal({ id, nonce: ++nonce.current });
  }, []);

  const host = useMemo<StackHost>(
    () => ({
      emit(event, payload = {}) {
        setLog((current) => [`${event} ${JSON.stringify(payload)}`, ...current].slice(0, 40));
        if (event === "stackClose") {
          setCards((current) => current.filter((card) => card.id !== payload.id));
        } else if (event === "stackCollapse") {
          setCards((current) =>
            current.map((card) => (card.id === payload.id ? { ...card, collapsed: payload.collapsed === true } : card)),
          );
        } else if (event === "stackLinkOpen" && payload.intent === "push") {
          void push(String(payload.note ?? ""), String(payload.fromPath ?? ""), (payload.focus as StackCardFocus | null) ?? null);
        }
      },
    }),
    [push],
  );

  const state: StackState = useMemo(
    () => normalizeStackPayload({ cards: cards.map((card) => ({ ...card, title: titleFromPath(card.path) })) }),
    [cards],
  );

  return (
    <>
      <main className="stack-dev-main">
        <header>
          <h1>Side stack</h1>
          <ThemeToggle />
          <button type="button" onClick={() => setFlash({ id: cards[0]?.id ?? null, nonce: ++nonce.current })}>
            Flash first
          </button>
        </header>
        <p>Shift-click a wikilink in a card to push its note; click opens “in main” (logged below).</p>
        <pre className="stack-dev-log">{log.join("\n")}</pre>
      </main>
      <div className="stack-dev-column">
        <StackSurface state={state} host={host} reveal={reveal} flash={flash} />
      </div>
    </>
  );
}

createRoot(document.getElementById("root")!).render(<StackDevShell />);
