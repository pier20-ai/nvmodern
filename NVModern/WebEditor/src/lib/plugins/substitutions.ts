import { Annotation, type Extension } from "@codemirror/state";
import { ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { resolveDocumentScanIndex } from "./documentIndex.ts";

const substitutionAnnotation = Annotation.define<boolean>();

export interface Nv3TextSubstitutionRule {
  from: string;
  to: string;
}

const DEFAULT_SUBSTITUTION_RULES: readonly Nv3TextSubstitutionRule[] = [
  { from: ":check:", to: "✓" },
  { from: "<=>", to: "⇔" },
  { from: "<->", to: "↔" },
  { from: "⇐>", to: "⇔" },
  { from: "←>", to: "↔" },
  { from: "=>", to: "⇒" },
  { from: "<=", to: "⇐" },
  { from: "->", to: "→" },
  { from: "<-", to: "←" },
];

export interface Nv3TextSubstitutionChange {
  from: number;
  to: number;
  insert: string;
}

function findSubstitutionsInSegment(
  segment: string,
  offset: number,
  rules: readonly Nv3TextSubstitutionRule[],
): Nv3TextSubstitutionChange[] {
  const changes: Nv3TextSubstitutionChange[] = [];

  for (let index = 0; index < segment.length; index++) {
    let matched = false;

    for (const substitution of rules) {
      if (!segment.startsWith(substitution.from, index)) continue;

      changes.push({
        from: offset + index,
        to: offset + index + substitution.from.length,
        insert: substitution.to,
      });

      index += substitution.from.length - 1;
      matched = true;
      break;
    }

    if (matched) continue;
  }

  return changes;
}

function dedupeChanges(changes: Nv3TextSubstitutionChange[]): Nv3TextSubstitutionChange[] {
  const byKey = new Map<string, Nv3TextSubstitutionChange>();

  for (const change of changes) {
    byKey.set(`${change.from}:${change.to}:${change.insert}`, change);
  }

  return [...byKey.values()].sort((left, right) => {
    if (left.from !== right.from) return left.from - right.from;
    return left.to - right.to;
  });
}

export interface Nv3SubstitutionsOptions {
  rules?: readonly Nv3TextSubstitutionRule[];
}

function mergedSubstitutionRules(
  rules: readonly Nv3TextSubstitutionRule[] | undefined,
): readonly Nv3TextSubstitutionRule[] {
  if (!rules?.length) return DEFAULT_SUBSTITUTION_RULES;

  const merged = [...DEFAULT_SUBSTITUTION_RULES];
  const indexesByFrom = new Map(merged.map((rule, index) => [rule.from, index]));

  for (const rule of rules) {
    const existingIndex = indexesByFrom.get(rule.from);
    if (existingIndex == null) {
      indexesByFrom.set(rule.from, merged.length);
      merged.push(rule);
      continue;
    }

    merged[existingIndex] = rule;
  }

  return merged;
}

export function applyNv3TextSubstitutions(
  text: string,
  changedFrom: number,
  changedTo: number,
  customRules?: readonly Nv3TextSubstitutionRule[],
): { text: string; changes: readonly Nv3TextSubstitutionChange[] } {
  const rules = mergedSubstitutionRules(customRules);
  const maxRuleLength = rules.reduce((length, rule) => Math.max(length, rule.from.length), 0);
  const padding = Math.max(0, maxRuleLength - 1);
  const from = Math.max(0, Math.min(changedFrom, changedTo, text.length));
  const to = Math.max(from, Math.min(Math.max(changedFrom, changedTo), text.length));
  const scanFrom = Math.max(0, from - padding);
  const scanTo = Math.min(text.length, to + padding);
  const changes = dedupeChanges(findSubstitutionsInSegment(
    text.slice(scanFrom, scanTo),
    scanFrom,
    rules,
  ));
  let substituted = text;
  for (const change of [...changes].reverse()) {
    substituted = `${substituted.slice(0, change.from)}${change.insert}${substituted.slice(change.to)}`;
  }
  return { text: substituted, changes };
}

export function createNv3SubstitutionsExtension(options: Nv3SubstitutionsOptions = {}): Extension {
  const rules = mergedSubstitutionRules(options.rules);
  const maxRuleLength = rules.reduce((maxLength, rule) => Math.max(maxLength, rule.from.length), 0);
  const scanPadding = Math.max(0, maxRuleLength - 1);

  return ViewPlugin.fromClass(
    class {
      update(update: ViewUpdate) {
        if (!update.docChanged) return;

        const alreadySubstituting = update.transactions.some((transaction) =>
          transaction.annotation(substitutionAnnotation),
        );
        if (alreadySubstituting) return;

        const pendingChanges: Nv3TextSubstitutionChange[] = [];

        update.changes.iterChangedRanges((_fromA, _toA, fromB, toB) => {
          const scanFrom = Math.max(0, fromB - scanPadding);
          const scanTo = Math.min(update.state.doc.length, toB + scanPadding);
          const segment = update.state.doc.sliceString(scanFrom, scanTo);

          pendingChanges.push(...findSubstitutionsInSegment(segment, scanFrom, rules));
        });

        const mermaidRanges = resolveDocumentScanIndex(update.state).codeBlocks
          .filter((block) => block.language?.toLowerCase() === "mermaid")
          .map((block) => ({
            from: update.state.doc.line(block.fromLine).from,
            to: update.state.doc.line(block.toLine).to,
          }));
        const changes = dedupeChanges(pendingChanges).filter((change) =>
          !mermaidRanges.some((range) => change.from < range.to && change.to > range.from),
        );
        if (!changes.length) return;

        const view = update.view;
        queueMicrotask(() => {
          if (!view.dom.isConnected) return;
          view.dispatch({
            changes,
            annotations: substitutionAnnotation.of(true),
          });
        });
      }
    },
  );
}

export const nv3DefaultSubstitutionRules = DEFAULT_SUBSTITUTION_RULES;
