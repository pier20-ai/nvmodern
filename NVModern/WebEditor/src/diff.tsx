import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { MultiFileDiff } from "@pierre/diffs/react";
import "./styles/diff.css";

interface DiffFile {
  path?: string;
  title?: string;
  body?: string;
}

interface DiffContextMessage {
  kind: "nvmodern-diff-context";
  left?: DiffFile;
  right?: DiffFile;
  layout?: "split" | "unified";
}

function DiffRenderer() {
  const [context, setContext] = useState<DiffContextMessage | null>(null);

  useEffect(() => {
    const receiveContext = (event: MessageEvent<unknown>) => {
      const data = event.data as Partial<DiffContextMessage> | null;
      if (data?.kind === "nvmodern-diff-context") {
        setContext(data as DiffContextMessage);
      }
    };
    window.addEventListener("message", receiveContext);
    window.parent.postMessage({ kind: "nvmodern-diff-ready" }, "*");
    return () => window.removeEventListener("message", receiveContext);
  }, []);

  const left = context?.left;
  const right = context?.right;
  if (!left || !right || typeof left.body !== "string" || typeof right.body !== "string") {
    return <div className="nvmodern-diff-loading">Loading comparison…</div>;
  }

  return (
    <div className="nvmodern-diff-renderer">
      <MultiFileDiff
        oldFile={{ name: left.title || left.path || "Before.md", contents: left.body, lang: "markdown" }}
        newFile={{ name: right.title || right.path || "After.md", contents: right.body, lang: "markdown" }}
        options={{
          diffStyle: context.layout === "unified" ? "unified" : "split",
          diffIndicators: "bars",
          disableBackground: true,
          disableFileHeader: true,
          hunkSeparators: "simple",
          lineDiffType: "word-alt",
          overflow: "wrap",
          themeType: "system",
          collapsedContextThreshold: 8,
          expansionLineCount: 20,
          lineHoverHighlight: "disabled",
          disableWorkerPool: true,
        }}
      />
    </div>
  );
}

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("Missing #root element");
createRoot(rootElement).render(<DiffRenderer />);
