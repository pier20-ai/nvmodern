import { markdownLanguage } from "@codemirror/lang-markdown";
import { cppLanguage } from "@codemirror/lang-cpp";
import { cssLanguage } from "@codemirror/lang-css";
import { goLanguage } from "@codemirror/lang-go";
import { htmlLanguage } from "@codemirror/lang-html";
import { javaLanguage } from "@codemirror/lang-java";
import {
  javascriptLanguage,
  jsxLanguage,
  tsxLanguage,
  typescriptLanguage,
} from "@codemirror/lang-javascript";
import { jsonLanguage } from "@codemirror/lang-json";
import { phpLanguage } from "@codemirror/lang-php";
import { pythonLanguage } from "@codemirror/lang-python";
import { rustLanguage } from "@codemirror/lang-rust";
import { sql, StandardSQL } from "@codemirror/lang-sql";
import { xmlLanguage } from "@codemirror/lang-xml";
import { yamlLanguage } from "@codemirror/lang-yaml";
import { StreamLanguage, type Language } from "@codemirror/language";
import { oCaml } from "@codemirror/legacy-modes/mode/mllike";
import { zigLanguage } from "@ndim/codemirror-lang-zig";

const sqlLanguage = sql({ dialect: StandardSQL }).language;
const ocamlLanguage = StreamLanguage.define(oCaml);

export function normalizeCodeLanguageName(info: string): string {
  const trimmed = info.trim().toLowerCase();
  if (!trimmed) return "";

  const separator = trimmed.search(/[\s,{(]/);
  const head = separator < 0 ? trimmed : trimmed.slice(0, separator);
  return head.replace(/^language-/, "");
}

export function codeLanguageForInfo(info: string): Language | null {
  switch (normalizeCodeLanguageName(info)) {
    case "javascript":
    case "js":
    case "mjs":
    case "cjs":
      return javascriptLanguage;
    case "typescript":
    case "ts":
      return typescriptLanguage;
    case "jsx":
      return jsxLanguage;
    case "tsx":
      return tsxLanguage;
    case "json":
    case "jsonc":
    case "json5":
      return jsonLanguage;
    case "html":
    case "htm":
      return htmlLanguage;
    case "xml":
    case "svg":
    case "rss":
    case "atom":
      return xmlLanguage;
    case "css":
    case "scss":
    case "less":
      return cssLanguage;
    case "yaml":
    case "yml":
      return yamlLanguage;
    case "python":
    case "py":
      return pythonLanguage;
    case "java":
      return javaLanguage;
    case "c":
    case "cpp":
    case "c++":
    case "cc":
    case "cxx":
    case "h":
    case "hpp":
      return cppLanguage;
    case "go":
    case "golang":
      return goLanguage;
    case "rust":
    case "rs":
      return rustLanguage;
    case "zig":
      return zigLanguage;
    case "ocaml":
    case "caml":
    case "ml":
    case "mli":
    case "mll":
    case "mly":
      return ocamlLanguage;
    case "php":
      return phpLanguage;
    case "sql":
    case "postgres":
    case "postgresql":
    case "mysql":
    case "sqlite":
      return sqlLanguage;
    case "md":
    case "markdown":
      return markdownLanguage;
    default:
      return null;
  }
}
