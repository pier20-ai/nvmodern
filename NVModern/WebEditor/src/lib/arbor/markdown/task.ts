export interface ArborMarkdownTask {
  checked: boolean;
  checkOffset: number;
  contentOffset: number;
}

const TASK_PATTERN = /^\[([ xX])\](?:\s+|$)/;

export function parseArborMarkdownTask(source: string): ArborMarkdownTask | null {
  const match = TASK_PATTERN.exec(source);
  if (!match) return null;
  return {
    checked: match[1]?.toLowerCase() === "x",
    checkOffset: match.index + match[0].indexOf("[") + 1,
    contentOffset: match[0].length,
  };
}

export function setArborMarkdownTaskChecked(source: string, checked: boolean): string {
  const task = parseArborMarkdownTask(source);
  if (!task) return source;
  return source.slice(0, task.checkOffset)
    + (checked ? "X" : " ")
    + source.slice(task.checkOffset + 1);
}
