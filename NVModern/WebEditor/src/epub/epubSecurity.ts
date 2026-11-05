import type Contents from "epubjs/types/contents";
import {
  EPUB_CONTENT_SECURITY_POLICY,
  isBlockedEpubAttribute,
  isBlockedEpubElementName,
  isExternalEpubHref,
} from "./epubHelpers.ts";

export interface EpubSanitizationResult {
  removedElements: number;
  removedAttributes: number;
}

export function sanitizeEpubDocument(document: Document): EpubSanitizationResult {
  let removedElements = 0;
  let removedAttributes = 0;

  for (const element of [...document.querySelectorAll("*")]) {
    if (isBlockedEpubElementName(element.localName)) {
      element.remove();
      removedElements += 1;
      continue;
    }

    for (const attribute of [...element.attributes]) {
      if (isBlockedEpubAttribute(attribute.name, attribute.value)) {
        element.removeAttribute(attribute.name);
        removedAttributes += 1;
      }
    }
  }

  let head = document.head;
  if (!head) {
    head = document.createElement("head");
    document.documentElement.prepend(head);
  }
  let policy = head.querySelector<HTMLMetaElement>('meta[data-nvmodern-epub-csp="true"]');
  if (!policy) {
    policy = document.createElement("meta");
    policy.dataset.nvmodernEpubCsp = "true";
    policy.httpEquiv = "Content-Security-Policy";
    head.prepend(policy);
  }
  policy.content = EPUB_CONTENT_SECURITY_POLICY;

  return { removedElements, removedAttributes };
}

export function installEpubLinkGuard(
  contents: Contents,
  openExternal: (href: string, label: string) => void,
): () => void {
  const document = contents.document;
  const handleClick = (event: MouseEvent) => {
    const eventElement = event.target && (event.target as Node).nodeType === 1
      ? event.target as Element
      : null;
    const target = eventElement?.closest("a[href]") ?? null;
    if (!target || target.localName !== "a") return;

    const rawHref = target.getAttribute("href")?.trim() ?? "";
    if (isExternalEpubHref(rawHref)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      openExternal(rawHref, target.textContent?.trim() ?? "");
      return;
    }

    if (isBlockedEpubAttribute("href", rawHref)) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  };

  document.addEventListener("click", handleClick, true);
  return () => document.removeEventListener("click", handleClick, true);
}
