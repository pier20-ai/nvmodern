export const ARBOR_FILE_EXTENSION = ".outline";
export const ARBOR_LANGUAGE_DIRECTIVE = "#lang arbor/0";

export function isArborDocumentPath(path: string | undefined): boolean {
  if (!path) return false;
  const cleanPath = path.split("?", 1)[0]?.split("#", 1)[0] ?? "";
  return cleanPath.toLocaleLowerCase().endsWith(ARBOR_FILE_EXTENSION);
}

export function prepareArborSource(source: string): {
  source: string;
  insertedLanguageDirective: boolean;
} {
  const sourceWithoutBOM = source.replace(/^\uFEFF/, "");
  const firstLine = sourceWithoutBOM.split(/\r?\n/, 1)[0]?.trim() ?? "";
  if (firstLine === ARBOR_LANGUAGE_DIRECTIVE) {
    return { source, insertedLanguageDirective: false };
  }
  return {
    source: source.length > 0
      ? `${ARBOR_LANGUAGE_DIRECTIVE}\n${source}`
      : `${ARBOR_LANGUAGE_DIRECTIVE}\n`,
    insertedLanguageDirective: true,
  };
}
