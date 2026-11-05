// @ts-check
/// <reference path="../nv.d.ts" />
// Selection-formatting actions migrated from config.toml.
const availability = 'activeEditor.surface == "text" && activeEditor.isEditable';
const prefixes = [
  { id: "user-quote-selected", title: "User Quote Selected", summary: "Format the selection as a user callout", icon: "person.crop.circle", keywords: ["callout", "quote", "user"], rank: 15, first: "> [!user] ", rest: "> " },
  { id: "important-callout-selected", title: "Important Callout Selected", summary: "Format the selection as an important callout", icon: "exclamationmark.bubble", keywords: ["callout", "important", "quote"], rank: 16, first: "> [!important] ", rest: "> " },
  { id: "checklist-selected-lines", title: "Checklist Selected Lines", summary: "Turn every selected Markdown line into an unchecked task", icon: "checklist", keywords: ["checklist", "task", "todo"], rank: 17, first: "- [ ] ", rest: "- [ ] " },
];

for (const action of prefixes) {
  nv.actions.register({
    id: action.id,
    title: action.title,
    summary: action.summary,
    palette: { category: "Format", when: availability, icon: action.icon, keywords: action.keywords, rank: action.rank },
    async run() {
      return nv.actions.invoke("markdown.selection.prefixLines", {
        firstPrefix: action.first,
        continuationPrefix: action.rest,
      });
    },
  });
}

nv.actions.register({
  id: "mark-selected-reviewed",
  title: "Mark Selected Reviewed",
  summary: "Wrap the selection with a timestamped reviewed label",
  palette: { category: "Format", when: availability, icon: "clock.badge.checkmark", keywords: ["reviewed", "timestamp", "selection"], rank: 18 },
  async run({ now }) {
    const selection = await nv.workspace.selection();
    if (!selection || selection.empty) return;
    await nv.workspace.replaceSelection(`**Reviewed ${nv.date.format("yyyy-MM-dd HH:mm", now)}:** ${selection.text}`);
  },
});
