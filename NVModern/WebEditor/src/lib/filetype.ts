export type Nv3FileType = "markdown" | "org" | "plain";

const MARKDOWN_EXTENSIONS = new Set([".md", ".markdown", ".mdown", ".mkd"]);
const ORG_EXTENSIONS = new Set([".org"]);

function extensionOf(path: string): string {
  const clean = path.split("?")[0]?.split("#")[0] ?? "";
  const lastDot = clean.lastIndexOf(".");
  if (lastDot < 0) return "";
  return clean.slice(lastDot).toLowerCase();
}

export function detectNv3FileType(filePath: string): Nv3FileType {
  const ext = extensionOf(filePath);
  if (MARKDOWN_EXTENSIONS.has(ext)) return "markdown";
  if (ORG_EXTENSIONS.has(ext)) return "org";
  return "plain";
}
