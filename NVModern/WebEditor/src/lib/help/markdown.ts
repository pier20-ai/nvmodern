import type { HelpProvider, HelpTopic } from "./model.ts";

function fence(code: string): string {
  const longest = Math.max(2, ...(code.match(/`+/g) ?? []).map((run) => run.length));
  const ticks = "`".repeat(longest + 1);
  return `${ticks}\n${code}\n${ticks}`;
}

function renderTopic(topic: HelpTopic): string {
  const lines = [`### ${topic.title}`, "", topic.summary, ""];
  if (topic.signatures.length) lines.push(...topic.signatures.map((s) => `- \`${s}\``), "");
  if (topic.aliases.length) lines.push(`Also available as ${topic.aliases.map((a) => `\`${a}\``).join(", ")}.`, "");
  if (topic.shortcuts?.length) lines.push(...topic.shortcuts.map((s) => `- \`${s.keys}\`: ${s.action}`), "");
  for (const example of topic.examples) {
    lines.push(fence(example.code), "");
    if (example.result !== undefined) lines.push(`Result: \`${example.result}\``, "");
  }
  return lines.join("\n");
}

/**
 * Plain-Markdown rendering of a provider, generated from the same data as the in-app drawer
 * so AI models and humans can read the docs without the UI. Topics are grouped by category in first-seen order.
 */
export function renderHelpMarkdown(provider: HelpProvider): string {
  const categories = new Map<string, HelpTopic[]>();
  for (const topic of provider.topics) categories.set(topic.category, [...(categories.get(topic.category) ?? []), topic]);
  const out = [`# ${provider.title} help`, ""];
  for (const [category, topics] of categories) out.push(`## ${category}`, "", ...topics.map(renderTopic));
  return out.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";
}
