import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App.tsx";
import "./styles/editor.lib.css";
import "./styles/app.css";
import "./styles/arbor.css";

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Missing #root mount element");
}

createRoot(rootElement).render(<App />);
