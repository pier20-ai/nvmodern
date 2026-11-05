import React, { useEffect, useState } from "react";
import { applyNv3InspectorStylesheet, applyNv3UserStylesheet } from "../../src/lib/theme/stylesheet.ts";

type DocumentWidth = "narrow" | "comfortable" | "wide" | "extraWide" | "full";
type DocumentScale = "small" | "normal" | "large" | "extraLarge";
type ThemeOption = { id: string; label: string };

const THEME_STORAGE_KEY = "nv3-shell-document-theme";
const WIDTH_STORAGE_KEY = "nv3-shell-document-width";
const SCALE_STORAGE_KEY = "nv3-shell-document-scale";
const FONT_STORAGE_KEY = "nv3-shell-document-font";

const WIDTHS: { value: DocumentWidth; label: string }[] = [
  { value: "narrow", label: "Narrow" },
  { value: "comfortable", label: "Comfort" },
  { value: "wide", label: "Wide" },
  { value: "extraWide", label: "XL" },
  { value: "full", label: "Full" },
];

const SCALES: { value: DocumentScale; label: string }[] = [
  { value: "small", label: "90%" },
  { value: "normal", label: "100%" },
  { value: "large", label: "110%" },
  { value: "extraLarge", label: "125%" },
];

// Body-font overrides exercise the same path as a filetype default or
// frontmatter `font-family`: the face changes, the theme's x-height stays.
const FONTS = ["", "IBM Plex Mono", "Google Sans Code", "Berkeley Mono Variable", "Iowan Old Style"];

function storedValue<T extends string>(key: string, allowed: readonly T[], fallback: T): T {
  const value = localStorage.getItem(key);
  return allowed.includes(value as T) ? (value as T) : fallback;
}

function shellParam(name: string): string | null {
  return new URLSearchParams(window.location.search).get(name);
}

function fontOverrideCSS(family: string): string {
  if (!family) return "";
  return `:root, [data-theme="light"], [data-theme="dark"] {
  --nv3-font-sans: ${JSON.stringify(family)}, ui-sans-serif, -apple-system, sans-serif;
  --nv3-font-display: ${JSON.stringify(family)}, ui-sans-serif, -apple-system, sans-serif;
  --nv3-content-font-size-adjust: var(--nv3-font-size-adjust);
}`;
}

export function DocumentThemeControls() {
  const [themes, setThemes] = useState<ThemeOption[]>([]);
  const [theme, setTheme] = useState<string>(
    () => shellParam("theme") ?? localStorage.getItem(THEME_STORAGE_KEY) ?? "system",
  );
  const [font, setFont] = useState<string>(() => shellParam("font") ?? storedValue(FONT_STORAGE_KEY, FONTS, ""));
  const [width, setWidth] = useState<DocumentWidth>(() =>
    storedValue(
      WIDTH_STORAGE_KEY,
      WIDTHS.map((item) => item.value),
      "comfortable",
    ),
  );
  const [scale, setScale] = useState<DocumentScale>(() =>
    storedValue(
      SCALE_STORAGE_KEY,
      SCALES.map((item) => item.value),
      "normal",
    ),
  );

  useEffect(() => {
    fetch("/api/themes")
      .then((response) => response.json())
      .then((list: ThemeOption[]) => setThemes(list))
      .catch(() => setThemes([]));
  }, []);

  useEffect(() => {
    document.documentElement.setAttribute("data-doc-theme", theme);
    localStorage.setItem(THEME_STORAGE_KEY, theme);
    if (theme === "system") {
      applyNv3UserStylesheet("");
      return;
    }
    let cancelled = false;
    fetch(`/api/theme?id=${encodeURIComponent(theme)}`)
      .then((response) => (response.ok ? response.text() : ""))
      .then((css) => {
        if (!cancelled) applyNv3UserStylesheet(css);
      })
      .catch(() => {
        if (!cancelled) applyNv3UserStylesheet("");
      });
    return () => {
      cancelled = true;
    };
  }, [theme]);

  useEffect(() => {
    applyNv3InspectorStylesheet(fontOverrideCSS(font));
    localStorage.setItem(FONT_STORAGE_KEY, font);
  }, [font]);

  useEffect(() => {
    document.documentElement.setAttribute("data-doc-width", width);
    localStorage.setItem(WIDTH_STORAGE_KEY, width);
  }, [width]);

  useEffect(() => {
    document.documentElement.setAttribute("data-doc-scale", scale);
    localStorage.setItem(SCALE_STORAGE_KEY, scale);
  }, [scale]);

  return (
    <div className="document-theme-controls">
      <label className="document-theme-control">
        <span>Theme</span>
        <select value={theme} onChange={(event) => setTheme(event.target.value)}>
          <option value="system">System</option>
          {themes.map((item) => (
            <option key={item.id} value={item.id}>
              {item.label}
            </option>
          ))}
        </select>
      </label>

      <label className="document-theme-control">
        <span>Font</span>
        <select value={font} onChange={(event) => setFont(event.target.value)}>
          {FONTS.map((family) => (
            <option key={family || "theme"} value={family}>
              {family || "Theme"}
            </option>
          ))}
        </select>
      </label>

      <label className="document-theme-control">
        <span>Width</span>
        <select value={width} onChange={(event) => setWidth(event.target.value as DocumentWidth)}>
          {WIDTHS.map((item) => (
            <option key={item.value} value={item.value}>
              {item.label}
            </option>
          ))}
        </select>
      </label>

      <label className="document-theme-control">
        <span>Scale</span>
        <select value={scale} onChange={(event) => setScale(event.target.value as DocumentScale)}>
          {SCALES.map((item) => (
            <option key={item.value} value={item.value}>
              {item.label}
            </option>
          ))}
        </select>
      </label>
    </div>
  );
}
