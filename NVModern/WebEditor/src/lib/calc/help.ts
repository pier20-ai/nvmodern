import { calcCatalog, calcPresenterAliases, calcSignature } from "./catalog.ts";
import type { HelpProvider } from "../help/model.ts";

export function calcHelpExampleTemplate(example: { source: string; expected?: string }): string {
  return example.source.replace(/[{}]/g, "\\$&") + (example.expected !== undefined ? " -> " : "");
}

/** The runtime, editor discovery, and native help share one calc catalog. */
export function createCalcHelpProvider(): HelpProvider {
  return {
    id: "calc",
    title: "Calc",
    topics: [...calcCatalog, ...calcPresenterAliases()].map((entry) => ({
      id: entry.name,
      title: entry.name,
      category: entry.category,
      summary: entry.summary,
      keywords: entry.keywords,
      signatures: entry.signatures.map((_, index) => calcSignature(entry, entry.name, false, index)),
      aliases: entry.aliases ?? [],
      examples: entry.examples.map((example) => ({ code: example.source, result: example.expected })),
      insertions: [
        ...(entry.snippet ? [{ id: "template", label: "Insert template", template: entry.snippet }] : []),
        ...entry.examples.map((example, index) => ({
          id: `example-${index}`,
          label: entry.examples.length === 1 ? "Insert example" : `Insert example ${index + 1}`,
          template: calcHelpExampleTemplate(example),
        })),
      ],
    })),
  };
}
