import React, { useState, useEffect, useCallback } from "react";

interface FileEntry {
  name: string;
  path: string;
  isDir: boolean;
}

interface Props {
  onSelect: (path: string) => void;
  selectedPath: string | null;
}

export function FilePicker({ onSelect, selectedPath }: Props) {
  const [cwd, setCwd] = useState(".");
  const [entries, setEntries] = useState<FileEntry[]>([]);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async (dir: string) => {
    try {
      const res = await fetch(`/api/files?dir=${encodeURIComponent(dir)}`);
      if (!res.ok) throw new Error(await res.text());
      const data = await res.json();
      setEntries(data);
      setError(null);
    } catch (e) {
      setError(String(e));
    }
  }, []);

  useEffect(() => {
    load(cwd);
  }, [cwd, load]);

  const navigate = (dir: string) => setCwd(dir);
  const goUp = () => {
    if (cwd === ".") return;
    const parts = cwd.split("/");
    parts.pop();
    setCwd(parts.length ? parts.join("/") : ".");
  };

  return (
    <div className="file-picker">
      <div className="file-picker-nav">
        <button onClick={goUp} disabled={cwd === "."} title="Go up">
          ↑
        </button>
        <span className="file-picker-cwd" title={cwd}>
          {cwd === "." ? "/" : `/${cwd}`}
        </span>
      </div>

      {error && <div className="file-picker-error">{error}</div>}

      <ul className="file-picker-list">
        {entries.map((entry) => (
          <li
            key={entry.path}
            className={[
              "file-picker-entry",
              entry.isDir ? "is-dir" : "is-file",
              entry.path === selectedPath ? "is-selected" : "",
            ]
              .filter(Boolean)
              .join(" ")}
          >
            <button
              onClick={() => (entry.isDir ? navigate(entry.path) : onSelect(entry.path))}
            >
              <span className="file-icon">{entry.isDir ? "📁" : "📄"}</span>
              {entry.name}
            </button>
          </li>
        ))}
        {entries.length === 0 && !error && (
          <li className="file-picker-empty">No files found</li>
        )}
      </ul>
    </div>
  );
}
