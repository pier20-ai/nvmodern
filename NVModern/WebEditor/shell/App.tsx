import React, { useCallback, useEffect, useState } from "react";
import { DocumentThemeControls } from "./components/DocumentThemeControls.tsx";
import { Editor } from "./components/Editor.tsx";
import { FilePicker } from "./components/FilePicker.tsx";
import { ThemeToggle } from "./components/ThemeToggle.tsx";
import { ArborDevSurface } from "./ArborDevSurface.tsx";
import { isArborDocumentPath } from "../src/arbor/documentType.ts";

function shellParam(name: string): string | null {
  return new URLSearchParams(window.location.search).get(name);
}

interface OpenFile {
  path: string;
  content: string;
}

export function App() {
  const [file, setFile] = useState<OpenFile | null>(null);
  // `?file=calc-plots.md&sidebar=0` opens a file directly, for scripted captures.
  const [sidebarOpen, setSidebarOpen] = useState(() => shellParam("sidebar") !== "0");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleFileSelect = useCallback(async (path: string) => {
    setLoading(true);
    setError(null);

    try {
      const res = await fetch(`/api/file?path=${encodeURIComponent(path)}`);
      if (!res.ok) {
        throw new Error(await res.text());
      }
      const content = await res.text();
      setFile({ path, content });
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    const path = shellParam("file");
    if (path) void handleFileSelect(path);
  }, [handleFileSelect]);

  return (
    <div className="app">
      <header className="app-header">
        <button
          className="sidebar-toggle"
          onClick={() => setSidebarOpen((s) => !s)}
          title="Toggle sidebar"
        >
          ☰
        </button>
        <span className="app-title">nv3</span>
        {file && <span className="file-path">{file.path}</span>}
        <span className="app-header-spacer" />
        <DocumentThemeControls />
        <span>
          <ThemeToggle />
        </span>
      </header>

      <div className="app-body">
        {sidebarOpen && (
          <aside className="sidebar">
            <FilePicker onSelect={handleFileSelect} selectedPath={file?.path ?? null} />
          </aside>
        )}

        <main className="editor-pane">
          {loading ? (
            <div className="empty-state">
              <p>Loading file…</p>
            </div>
          ) : !file || isArborDocumentPath(file.path) ? (
            <ArborDevSurface key={file?.path ?? "arbor-playground"} file={file ?? undefined} />
          ) : file ? (
            <Editor
              key={file.path}
              filePath={file.path}
              content={file.content}
              onOpenFile={handleFileSelect}
            />
          ) : null}
        </main>
      </div>
    </div>
  );
}
