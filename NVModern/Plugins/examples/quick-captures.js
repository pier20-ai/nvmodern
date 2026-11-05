// @ts-check
/// <reference path="../nv.d.ts" />

// Today's `[[quick_capture]]` rows, as a plugin. `append` mode is an input
// panel plus a timestamped append; `full` mode is the editor panel on a file.

/**
 * @param {string} id
 * @param {string} globalHotkey
 * @param {NV.FileRef} file
 * @param {string} placeholder
 */
function appendCapture(id, globalHotkey, file, placeholder) {
  nv.actions.register({
    id,
    title: placeholder,
    globalHotkey,
    async run({ now }) {
      const thought = await nv.ui.input({ id, placeholder, onDismiss: "submit" });
      if (!thought) return;
      const stamp = nv.date.format("MMM d, yyyy EEE HH:mm", now);
      await nv.files.append(file, `\n[${stamp}]\n${thought}\n`);
    },
  });
}

appendCapture("stream", "cmd+ctrl+opt+shift+s", "~/notes/stream.md", "Add to stream..");
appendCapture("log", "cmd+ctrl+opt+shift+p", "~/notes/personal-log.md", "Add to personal log..");

nv.actions.register({
  id: "inbox",
  title: "Quick Capture",
  globalHotkey: "cmd+shift+space",
  run: () => nv.ui.panel("~/notes/Inbox/Quick Capture.md"),
});
