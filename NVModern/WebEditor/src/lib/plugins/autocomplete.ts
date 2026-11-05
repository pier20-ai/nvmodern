import {
  autocompletion,
  startCompletion,
  type Completion,
  type CompletionContext,
  type CompletionResult,
  type CompletionSource,
} from "@codemirror/autocomplete";
import { syntaxTree } from "@codemirror/language";
import { EditorState, Facet, type Extension } from "@codemirror/state";
import { EditorView, type ViewUpdate } from "@codemirror/view";
import { parseNv3WikilinkTarget } from "./wikilinks.ts";

// Editor-native features can contribute before the prose providers' fence exclusions.
export const nv3AdditionalCompletionSources = Facet.define<CompletionSource>();

export interface Nv3AutocompleteMatch {
  trigger: string;
  from: number;
  to: number;
  text: string;
  validFor?: CompletionResult["validFor"];
}

export interface Nv3AutocompleteQueryInput {
  trigger: string;
  text: string;
  from: number;
  to: number;
  filePath?: string;
  signal: AbortSignal;
}

export interface Nv3AutocompleteItem {
  label: string;
  insertText?: string;
  filterText?: string;
  detail?: string;
  info?: string;
  type?: string;
  boost?: number;
  sortText?: string;
}

export interface Nv3AutocompleteProvider<TItem = Nv3AutocompleteItem> {
  source: string;
  trigger: string;
  query: (input: Nv3AutocompleteQueryInput) => Promise<readonly TItem[]> | readonly TItem[];
  mapItem?: (item: TItem, input: Nv3AutocompleteQueryInput) => Nv3AutocompleteItem;
  match?: (input: {
    state: EditorState;
    pos: number;
    explicit: boolean;
    trigger: string;
  }) => Nv3AutocompleteMatch | null;
}

export interface Nv3AutocompleteError {
  providerSource: string;
  error: unknown;
}

export interface Nv3AutocompleteExtensionOptions {
  providers: readonly Nv3AutocompleteProvider[];
  filePath?: string;
  activateOnTypingDelay?: number;
  onError?: (error: Nv3AutocompleteError) => void;
}

const BLOCKED_ANCESTORS = new Set(["InlineCode", "FencedCode", "CodeText", "Frontmatter"]);

function hasBlockedAncestor(state: EditorState, pos: number): boolean {
  let node = syntaxTree(state).resolveInner(pos, -1);

  for (;;) {
    if (BLOCKED_ANCESTORS.has(node.name)) {
      return true;
    }

    const parent = node.parent;
    if (!parent) {
      return false;
    }

    node = parent;
  }
}

function isWordLikeCharacter(char: string | undefined): boolean {
  if (!char) return false;
  return /[A-Za-z0-9_]/.test(char);
}

function matchWikilinkTrigger(state: EditorState, pos: number): Nv3AutocompleteMatch | null {
  const line = state.doc.lineAt(pos);
  const cursorOffset = pos - line.from;
  const text = line.text;
  const beforeCursor = text.slice(0, cursorOffset);

  const openOffset = beforeCursor.lastIndexOf("[[");
  if (openOffset < 0) return null;

  if (openOffset > 0 && text[openOffset - 1] === "!") {
    return null;
  }

  const between = beforeCursor.slice(openOffset + 2);
  if (between.includes("]]")) return null;
  if (between.includes("\n")) return null;

  const closeOffset = text.indexOf("]]", openOffset + 2);
  if (closeOffset >= 0 && cursorOffset > closeOffset + 2) {
    return null;
  }

  const toOffset = closeOffset >= 0 ? closeOffset : cursorOffset;
  const query = text.slice(openOffset + 2, cursorOffset);

  if (query.includes("]") || query.includes("\n")) {
    return null;
  }

  return {
    trigger: "[[",
    from: line.from + openOffset + 2,
    to: line.from + toOffset,
    text: query,
  };
}

function matchSimpleTrigger(
  state: EditorState,
  pos: number,
  trigger: string,
): Nv3AutocompleteMatch | null {
  const line = state.doc.lineAt(pos);
  const cursorOffset = pos - line.from;
  const text = line.text;
  const beforeCursor = text.slice(0, cursorOffset);

  const openOffset = beforeCursor.lastIndexOf(trigger);
  if (openOffset < 0) return null;

  if (trigger.length === 1) {
    const prevChar = beforeCursor[openOffset - 1];
    const nextChar = beforeCursor[openOffset + trigger.length];

    if (isWordLikeCharacter(prevChar) && isWordLikeCharacter(nextChar)) {
      return null;
    }
  }

  const query = beforeCursor.slice(openOffset + trigger.length);
  if (/\s/.test(query)) return null;

  return {
    trigger,
    from: line.from + openOffset + trigger.length,
    to: pos,
    text: query,
    validFor: /^\S*$/,
  };
}

function matchProvider(provider: Nv3AutocompleteProvider, context: CompletionContext) {
  if (provider.match) {
    return provider.match({
      state: context.state,
      pos: context.pos,
      explicit: context.explicit,
      trigger: provider.trigger,
    });
  }

  if (provider.trigger === "[[") {
    return matchWikilinkTrigger(context.state, context.pos);
  }

  return matchSimpleTrigger(context.state, context.pos, provider.trigger);
}

function completionFromItem(item: Nv3AutocompleteItem): Completion {
  return {
    label: item.filterText ?? item.label,
    displayLabel: item.label,
    apply: item.insertText ?? item.label,
    detail: item.detail,
    info: item.info,
    type: item.type,
    boost: item.boost,
    sortText: item.sortText,
  };
}

function shouldTriggerCompletionAfterTypedCharacter(
  state: EditorState,
  pos: number,
  text: string,
): boolean {
  if (text !== "#" && text !== "^") return false;
  return matchWikilinkTrigger(state, pos) !== null;
}

function shouldTriggerCompletionAfterUpdate(update: ViewUpdate): boolean {
  let shouldTrigger = false;

  for (const transaction of update.transactions) {
    if (!transaction.isUserEvent("input.type")) continue;

    transaction.changes.iterChanges((_fromA, _toA, _fromB, toB, inserted) => {
      if (shouldTrigger) return;

      const insertedText = inserted.toString();
      if (insertedText !== "#" && insertedText !== "^") {
        return;
      }

      shouldTrigger = shouldTriggerCompletionAfterTypedCharacter(update.state, toB, insertedText);
    });

    if (shouldTrigger) {
      return true;
    }
  }

  return false;
}

function providerCompletionSource(options: Nv3AutocompleteExtensionOptions): CompletionSource {
  return async (context) => {
    for (const source of context.state.facet(nv3AdditionalCompletionSources)) {
      const result = await source(context);
      if (result) return result;
    }
    if (hasBlockedAncestor(context.state, context.pos)) {
      return null;
    }

    let chosenProvider: Nv3AutocompleteProvider | null = null;
    let chosenMatch: Nv3AutocompleteMatch | null = null;
    let chosenOpenPosition = -1;

    for (const provider of options.providers) {
      const match = matchProvider(provider, context);
      if (!match) continue;

      const openPosition = match.from - provider.trigger.length;
      const isCloser = openPosition > chosenOpenPosition;
      const isSameButLongerTrigger =
        openPosition === chosenOpenPosition &&
        chosenProvider !== null &&
        provider.trigger.length > chosenProvider.trigger.length;

      if (!isCloser && !isSameButLongerTrigger) continue;

      chosenProvider = provider;
      chosenMatch = match;
      chosenOpenPosition = openPosition;
    }

    if (!chosenProvider || !chosenMatch) {
      return null;
    }

    const controller = new AbortController();
    context.addEventListener(
      "abort",
      () => {
        controller.abort();
      },
      { onDocChange: true },
    );

    const input: Nv3AutocompleteQueryInput = {
      trigger: chosenMatch.trigger,
      text: chosenMatch.text,
      from: chosenMatch.from,
      to: chosenMatch.to,
      filePath: options.filePath,
      signal: controller.signal,
    };

    try {
      const rawItems = await Promise.resolve(chosenProvider.query(input));

      if (controller.signal.aborted) {
        return null;
      }

      if (!rawItems.length) {
        return null;
      }

      const mapped = rawItems.map((item) => {
        if (chosenProvider.mapItem) {
          return chosenProvider.mapItem(item, input);
        }
        return item as Nv3AutocompleteItem;
      });

      const optionsList = mapped.map(completionFromItem);

      return {
        from: chosenMatch.from,
        to: chosenMatch.to,
        options: optionsList,
        validFor: chosenMatch.validFor,
        filter: chosenProvider.trigger === "[[" ? false : undefined,
      } satisfies CompletionResult;
    } catch (error) {
      if (!controller.signal.aborted) {
        options.onError?.({
          providerSource: chosenProvider.source,
          error,
        });
      }
      return null;
    }
  };
}

export function createNv3AutocompleteExtension(
  options: Nv3AutocompleteExtensionOptions,
): Extension {
  return [
    autocompletion({
      activateOnTyping: true,
      activateOnTypingDelay: options.activateOnTypingDelay ?? 120,
      override: [providerCompletionSource(options)],
    }),
    EditorView.updateListener.of((update) => {
      if (!update.docChanged) return;
      if (!shouldTriggerCompletionAfterUpdate(update)) return;
      if (update.state.facet(EditorState.readOnly)) return;

      queueMicrotask(() => {
        startCompletion(update.view);
      });
    }),
  ];
}
