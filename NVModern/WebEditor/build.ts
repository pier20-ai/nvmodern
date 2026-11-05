import { createCalcHelpProvider } from "./src/lib/calc/help.ts";
import { createArborHelpProvider } from "./src/arbor/help.ts";
import { renderHelpMarkdown } from "./src/lib/help/markdown.ts";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";

const projectDir = import.meta.dir;
const outDir = path.resolve(projectDir, "../Resources/WebEditor");

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });

const result = await Bun.build({
  entrypoints: [
    path.resolve(projectDir, "src/main.tsx"),
    path.resolve(projectDir, "src/help.tsx"),
    path.resolve(projectDir, "src/diff.tsx"),
    path.resolve(projectDir, "src/canvas.tsx"),
    path.resolve(projectDir, "src/stack.tsx"),
    path.resolve(projectDir, "src/epub.ts"),
  ],
  outdir: outDir,
  target: "browser",
  format: "iife",
  conditions: ["production"],
  define: { "import.meta.url": "undefined", "import.meta.env": '{"MODE":"production"}' },
  splitting: false,
  sourcemap: "none",
  minify: false,
});

if (!result.success) {
  for (const log of result.logs) {
    console.error(log);
  }
  process.exit(1);
}

const mainBundle = readFileSync(path.join(outDir, "main.js"), "utf8");
if (mainBundle.includes("EPUBJS_VERSION")) {
  throw new Error("epubjs leaked into main.js; keep the EPUB renderer in epub.js");
}

const indexHtml = `<!doctype html>
<html lang="en" data-theme="system">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>NVModern Editor</title>
    <link rel="stylesheet" href="./main.css" />
  </head>
  <body>
    <div id="root"></div>
    <script>
      (function () {
        function post(event, payload) {
          try {
            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nvmodern;
            if (!handler) return;
            handler.postMessage({ kind: "event", event: event, payload: payload || {} });
          } catch (_) {}
        }

        var script = document.createElement("script");
        script.src = "./main.js";
        script.defer = true;
        script.onerror = function () {
          var root = document.getElementById("root");
          if (root) {
            root.textContent = "Failed to load editor script (main.js). Open console for details.";
            root.style.padding = "12px";
            root.style.fontFamily = "ui-monospace, Menlo, monospace";
            root.style.fontSize = "12px";
          }
          post("mainScriptLoadError", { src: script.src });
        };
        document.body.appendChild(script);
      })();
    </script>
  </body>
</html>
`;

writeFileSync(path.join(outDir, "index.html"), indexHtml, "utf8");

const diffHtml = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>NVModern Diff</title>
    <link rel="stylesheet" href="./diff.css" />
  </head>
  <body>
    <div id="root"></div>
    <script src="./diff.js"></script>
  </body>
</html>
`;

writeFileSync(path.join(outDir, "diff.html"), diffHtml, "utf8");

// Side stack (ticket 0031): read-only note cards beside a tab's content,
// hosted in its own WKWebView over the same `nvmodern` bridge as index.html.
const stackHtml = `<!doctype html>
<html lang="en" data-theme="system">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>nvModern Side Stack</title>
    <link rel="stylesheet" href="./stack.css" />
  </head>
  <body>
    <div id="root"></div>
    <script>
      (function () {
        var script = document.createElement("script");
        script.src = "./stack.js";
        script.defer = true;
        script.onerror = function () {
          var root = document.getElementById("root");
          if (root) root.textContent = "Failed to load the side stack script (stack.js).";
          try {
            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nvmodern;
            if (handler) handler.postMessage({ kind: "event", event: "mainScriptLoadError", payload: { src: script.src } });
          } catch (_) {}
        };
        document.body.appendChild(script);
      })();
    </script>
  </body>
</html>
`;

writeFileSync(path.join(outDir, "stack.html"), stackHtml, "utf8");
console.log(`[web-editor] Built assets to ${outDir}`);

const excalidrawDist = path.resolve(projectDir, "node_modules/@excalidraw/excalidraw/dist/prod");
cpSync(path.join(excalidrawDist, "index.css"), path.join(outDir, "excalidraw.css"));
cpSync(path.join(excalidrawDist, "fonts"), path.join(outDir, "fonts"), { recursive: true });
cpSync(path.resolve(projectDir, "src/styles/canvas.css"), path.join(outDir, "canvas.css"));

const canvasHtml = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>nvModern Canvas</title>
    <link rel="stylesheet" href="./excalidraw.css" />
    <link rel="stylesheet" href="./canvas.css" />
  </head>
  <body>
    <div id="root">Loading canvas…</div>
    <script>window.EXCALIDRAW_ASSET_PATH = new URL(".", location.href).href;</script>
    <script>
      window.addEventListener("error", function (event) {
        document.getElementById("root").textContent = "Canvas error: " + (event.error && event.error.stack || event.message) + " at " + event.filename + ":" + event.lineno;
      });
      window.addEventListener("unhandledrejection", function (event) {
        document.getElementById("root").textContent = "Canvas error: " + event.reason;
      });
    </script>
    <script src="./canvas.js" onerror="document.getElementById('root').textContent = 'Failed to load canvas.js'"></script>
  </body>
</html>`;
writeFileSync(path.join(outDir, "canvas.html"), canvasHtml, "utf8");

const helpProviders = [createCalcHelpProvider(), createArborHelpProvider()];
writeFileSync(path.join(outDir, "help-catalog.json"), JSON.stringify(helpProviders));
mkdirSync(path.join(outDir, "help"), { recursive: true });
for (const provider of helpProviders) writeFileSync(path.join(outDir, "help", `${provider.id}.md`), renderHelpMarkdown(provider));
writeFileSync(path.join(outDir, "help.html"), `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>nvModern Help</title><link rel="stylesheet" href="./help.css"></head>
<body><div id="root"></div><script src="./help.js"></script></body></html>`);
