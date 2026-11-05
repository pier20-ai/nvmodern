import type { EditorView } from "@codemirror/view";
import {
  addNv3Annotations,
  answerNv3Annotation,
  listNv3Annotations,
  nv3AnnotationSpecs,
  removeNv3Annotations,
  revealNv3Annotation,
  type Nv3AnnotationAddResult,
  type Nv3AnnotationAuthor,
  type Nv3AnnotationInput,
  type Nv3AnnotationSnapshot,
  type Nv3AnnotationSpec,
} from "./lib/index.ts";

export interface EditorAnnotationRequest {
  op: "add" | "remove" | "list" | "reveal" | "answer";
  /** Document the caller means; a mismatch returns null so the host retries. */
  expectedPath?: string;
  annotations?: Nv3AnnotationInput[];
  replace?: boolean | Nv3AnnotationAuthor;
  /** After add: true reveals the first added annotation, a string reveals that label. */
  reveal?: boolean | string;
  ids?: string[];
  labels?: string[];
  /** remove: only this author's. list: only this author's. */
  author?: Nv3AnnotationAuthor;
  /** list: only annotations without an answer. */
  unansweredOnly?: boolean;
  /** Id or label for `reveal` and `answer`. */
  target?: string;
  answer?: string;
  answeredBy?: string;
}

export interface EditorAnnotationResponse {
  path: string | null;
  op: EditorAnnotationRequest["op"];
  results?: Nv3AnnotationAddResult[];
  removed?: number;
  revealed?: boolean;
  answered?: boolean;
  annotations?: Nv3AnnotationSnapshot[];
  error?: string;
}

// Annotations outlive their editor: editors are rebuilt when presentation or
// context changes, and a reader's questions should survive a relaunch. Specs
// are kept per document in memory and in the web view's local storage.
const specsByPath = new Map<string, Nv3AnnotationSpec[]>();
const STORAGE_PREFIX = "nvmodern.annotations:";

function storedSpecs(path: string): Nv3AnnotationSpec[] | undefined {
  try {
    const raw = window.localStorage.getItem(STORAGE_PREFIX + path);
    const parsed: unknown = raw ? JSON.parse(raw) : undefined;
    return Array.isArray(parsed) ? (parsed as Nv3AnnotationSpec[]) : undefined;
  } catch {
    return undefined;
  }
}

function store(path: string, specs: Nv3AnnotationSpec[]) {
  try {
    if (specs.length > 0) window.localStorage.setItem(STORAGE_PREFIX + path, JSON.stringify(specs));
    else window.localStorage.removeItem(STORAGE_PREFIX + path);
  } catch {
    // Storage can be unavailable or full; memory still holds them this session.
  }
}

/** Record the editor's annotations for its document; call after they change. */
export function rememberEditorAnnotations(view: EditorView, path: string | null) {
  if (!path) return;
  const specs = nv3AnnotationSpecs(view.state);
  if (specs.length > 0) specsByPath.set(path, specs);
  else specsByPath.delete(path);
  store(path, specs);
}

export function restoreEditorAnnotations(view: EditorView, path: string | null) {
  if (!path) return;
  const specs = specsByPath.get(path) ?? storedSpecs(path);
  if (specs?.length) addNv3Annotations(view, specs, { replace: true, keepUnanchored: true });
}

export function handleEditorAnnotationRequest(
  view: EditorView,
  path: string | null,
  request: EditorAnnotationRequest,
): EditorAnnotationResponse | null {
  if (request.expectedPath && request.expectedPath !== path) return null;

  const response: EditorAnnotationResponse = { path, op: request.op };
  switch (request.op) {
    case "add": {
      const inputs = Array.isArray(request.annotations) ? request.annotations : [];
      const results = addNv3Annotations(view, inputs, { replace: request.replace });
      response.results = results;
      if (request.reveal) {
        const target =
          typeof request.reveal === "string"
            ? request.reveal
            : results.find((result) => result.status === "anchored" || result.status === "ambiguous")?.id;
        response.revealed = target ? revealNv3Annotation(view, target) : false;
      }
      break;
    }
    case "remove":
      response.removed = removeNv3Annotations(view, {
        ids: request.ids,
        labels: request.labels,
        author: request.author,
      });
      break;
    case "reveal":
      response.revealed = request.target ? revealNv3Annotation(view, request.target) : false;
      break;
    case "answer":
      response.answered = request.target
        ? answerNv3Annotation(view, request.target, request.answer ?? "", request.answeredBy)
        : false;
      if (response.answered && request.reveal !== false) revealNv3Annotation(view, request.target!);
      break;
    case "list":
      response.annotations = listNv3Annotations(view.state).filter(
        (annotation) =>
          (!request.author || annotation.author === request.author) &&
          // An answer to an earlier wording of the question doesn't count.
          (!request.unansweredOnly || !annotation.answer || annotation.answerStale),
      );
      break;
    default:
      response.error = `unknown annotation op: ${String((request as { op?: unknown }).op)}`;
  }

  rememberEditorAnnotations(view, path);
  return response;
}

declare global {
  interface Window {
    nvmodernAnnotations?: (request: EditorAnnotationRequest) => EditorAnnotationResponse | null;
  }
}
