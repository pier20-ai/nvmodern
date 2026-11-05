// @ts-check
/// <reference path="../nv.d.ts" />

// Today's `[capture]` table and `Cmd+N` options, as a plugin: a daily note
// that is created from a template once and reopened afterwards, and a
// timestamped scratchpad.

const TEMPLATES = "Templates";
const DAILY = "Daily";
const SCRATCHPADS = "Scratchpads";

/**
 * @param {string | null} templateName
 * @param {string} fallback
 * @param {Date} now
 */
async function renderTemplate(templateName, fallback, now) {
  const template = templateName ? await nv.files.read(`${TEMPLATES}/${templateName}`) : fallback;
  if (template === null) throw new Error(`Capture template '${TEMPLATES}/${templateName}' was not found`);
  const clipboard = (await nv.clipboard.read()) ?? "";
  return template
    .replaceAll("{{date}}", nv.date.format("yyyy-MM-dd", now))
    .replaceAll("{{time}}", nv.date.format("HH:mm", now))
    .replaceAll("{{clipboard}}", clipboard)
    .replaceAll("{{cursor}}", "");
}

nv.actions.register({
  id: "daily",
  title: "Daily",
  palette: { category: "Capture", icon: "calendar", key: "d" },
  async run({ now }) {
    const file = `${DAILY}/${nv.date.format("yyyy-MM-dd", now)}.md`;
    if (!(await nv.files.exists(file))) {
      await nv.files.write(file, await renderTemplate("_daily_template.md", "# {{date}}\n\n", now));
    }
    await nv.workspace.open(file, { in: "currentTab" });
  },
});

nv.actions.register({
  id: "scratchpad",
  title: "Scratchpad",
  palette: { category: "Capture", icon: "note.text.badge.plus", key: "s" },
  async run({ now }) {
    const stem = `${SCRATCHPADS}/${nv.date.format("yyyy-MM-dd HH-mm-ss", now)}`;
    let file = `${stem}.md`;
    for (let copy = 2; await nv.files.exists(file); copy += 1) file = `${stem} ${copy}.md`;
    await nv.files.write(file, await renderTemplate("_scratchpad_template.md", "", now));
    await nv.workspace.open(file, { in: "newTab" });
  },
});
