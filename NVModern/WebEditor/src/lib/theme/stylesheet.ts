const NV3_USER_THEME_STYLE_ID = "nv3-user-theme-styles";
const NV3_INSPECTOR_THEME_STYLE_ID = "nv3-inspector-theme-styles";

/**
 * The base theme for the document: the global or filetype theme plus
 * `editor_theme_css`. It always precedes the inspector sheet, which sets the
 * same tokens at the same specificity and must win by source order.
 */
export function applyNv3UserStylesheet(
  cssText: string | null | undefined,
  targetDocument: Document = document,
): HTMLStyleElement | null {
  return applyNv3Stylesheet(
    cssText,
    NV3_USER_THEME_STYLE_ID,
    "data-nv3-user-theme",
    targetDocument,
    targetDocument.getElementById(NV3_INSPECTOR_THEME_STYLE_ID),
  );
}

/** Per-document appearance: inspector and frontmatter width, font and theme. */
export function applyNv3InspectorStylesheet(
  cssText: string | null | undefined,
  targetDocument: Document = document,
): HTMLStyleElement | null {
  return applyNv3Stylesheet(cssText, NV3_INSPECTOR_THEME_STYLE_ID, "data-nv3-inspector-theme", targetDocument, null);
}

function applyNv3Stylesheet(
  cssText: string | null | undefined,
  styleID: string,
  markerAttribute: string,
  targetDocument: Document,
  insertBefore: Element | null,
): HTMLStyleElement | null {
  const existingStyle = targetDocument.getElementById(styleID) as HTMLStyleElement | null;
  const normalizedCSS = typeof cssText === "string" ? cssText.trim() : "";

  if (!normalizedCSS) {
    existingStyle?.remove();
    return null;
  }

  const styleElement = existingStyle ?? targetDocument.createElement("style");
  styleElement.id = styleID;
  styleElement.setAttribute(markerAttribute, "true");

  if (styleElement.textContent !== normalizedCSS) {
    styleElement.textContent = normalizedCSS;
  }

  if (!styleElement.parentNode) {
    const anchor = insertBefore?.parentNode ? insertBefore : null;
    const parent = anchor?.parentNode ?? targetDocument.head ?? targetDocument.documentElement;
    parent.insertBefore(styleElement, anchor);
  }

  return styleElement;
}
