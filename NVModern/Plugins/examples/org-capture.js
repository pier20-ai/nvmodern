// @ts-check
/// <reference path="../nv.d.ts" />

// Emacs `org-capture` with a `file+datetree` target and the template
// `* %U %?`: `Cmd+N` `n`, type the note, and it lands under today's heading.
//
//     * 2026
//     ** 2026-10 October
//     *** 2026-10-03 Saturday
//     **** [2026-10-03 Sat 14:22] the note

/** @type {NV.FileRef} */
const DAILY = { project: "Personal Notes", path: "org/general/daily.org" };

/**
 * Find the subtree headed by `heading` within `lines[from..<to]`, adding the
 * heading at the end of that range when it is missing. Returns the [start,
 * end) line range of the subtree's body.
 *
 * @param {string[]} lines
 * @param {string} heading
 * @param {number} from
 * @param {number} to
 * @returns {[number, number]}
 */
function ensureSubtree(lines, heading, from, to) {
  const depth = heading.indexOf(" ");
  let at = from;
  while (at < to && lines[at].trimEnd() !== heading) at += 1;
  if (at === to) {
    lines.splice(to, 0, heading);
    return [to + 1, to + 1];
  }
  let end = at + 1;
  while (end < to) {
    const stars = /^(\*+) /.exec(lines[end]);
    if (stars && stars[1].length <= depth) break;
    end += 1;
  }
  return [at + 1, end];
}

/**
 * @param {string} body
 * @param {Date} now
 * @param {string} entry
 */
function insertIntoDatetree(body, now, entry) {
  const lines = body.replace(/\n+$/, "").split("\n");
  if (lines.length === 1 && lines[0] === "") lines.length = 0;

  let [from, to] = ensureSubtree(lines, `* ${nv.date.format("yyyy", now)}`, 0, lines.length);
  [from, to] = ensureSubtree(lines, `** ${nv.date.format("yyyy-MM MMMM", now)}`, from, to);
  [from, to] = ensureSubtree(lines, `*** ${nv.date.format("yyyy-MM-dd EEEE", now)}`, from, to);

  lines.splice(to, 0, `**** ${nv.date.format("[yyyy-MM-dd EEE HH:mm]", now)} ${entry}`);
  return lines.join("\n") + "\n";
}

nv.actions.register({
  id: "daily",
  title: "Daily note",
  palette: { category: "Capture", icon: "calendar", key: "n" },
  async run({ now }) {
    const note = await nv.ui.input({ id: "org-daily", placeholder: "Daily note…", submitKey: "return" });
    if (!note) return;
    await nv.files.edit(DAILY, (body) => insertIntoDatetree(body, now, note));
  },
});
