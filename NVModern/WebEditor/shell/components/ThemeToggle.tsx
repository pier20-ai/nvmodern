import React, { useState, useEffect } from "react";

type Theme = "light" | "dark" | "system";

const ICONS: Record<Theme, string> = {
  light: "☀️",
  dark: "🌙",
  system: "💻",
};

const CYCLE: Theme[] = ["light", "dark", "system"];

export function ThemeToggle() {
  const [theme, setTheme] = useState<Theme>(() => {
    const requested = new URLSearchParams(window.location.search).get("appearance");
    if (requested === "light" || requested === "dark") return requested;
    return (localStorage.getItem("nv3-theme") as Theme) ?? "system";
  });

  // The app only ever sets `light` or `dark` on <html>; resolve `system`
  // the same way so themes see what they will see in the app.
  useEffect(() => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const apply = () => {
      const resolved = theme === "system" ? (media.matches ? "dark" : "light") : theme;
      document.documentElement.setAttribute("data-theme", resolved);
    };
    apply();
    localStorage.setItem("nv3-theme", theme);
    media.addEventListener("change", apply);
    return () => media.removeEventListener("change", apply);
  }, [theme]);

  const next = () => {
    setTheme((t) => CYCLE[(CYCLE.indexOf(t) + 1) % CYCLE.length]!);
  };

  return (
    <button className="theme-toggle" onClick={next} title={`Theme: ${theme}`}>
      {ICONS[theme]}
    </button>
  );
}
