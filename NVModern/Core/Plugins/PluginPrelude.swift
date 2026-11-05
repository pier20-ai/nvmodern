import Foundation

/// The JavaScript half of the bridge: turns the flat native `host` object
/// into the `nv` API that `NVModern/Plugins/nv.d.ts` describes. Evaluating
/// this yields `function (host)`, which returns `makeAPI(info)`; `makeAPI`
/// returns the `{ nv, console }` pair handed to one plugin.
enum PluginPrelude {
    static let source = #"""
    (function (host) {
      "use strict";

      globalThis.setTimeout = (callback, milliseconds) => host.setTimeout(callback, Number(milliseconds) || 0);
      globalThis.clearTimeout = (handle) => host.clearTimeout(handle);

      const describe = (value) => {
        if (typeof value === "string") return value;
        if (value instanceof Error) return value.stack ? `${value.message}\n${value.stack}` : value.message;
        try {
          return JSON.stringify(value);
        } catch (_) {
          return String(value);
        }
      };

      const orNull = (promise) => promise.catch(() => null);

      return function makeAPI(info) {
        const logger = (level) => (...values) => host.log(info.name, level, values.map(describe).join(" "));
        const console = Object.freeze({ log: logger("log"), warn: logger("warn"), error: logger("error") });

        const actions = Object.freeze({
          register(spec) {
            if (!spec || typeof spec.run !== "function") {
              throw new TypeError("nv.actions.register needs { id, title, run }");
            }
            const { run, ...descriptor } = spec;
            host.register(info.name, descriptor, (context) => run(context));
          },
          invoke: (method, args) => host.invoke(info.name, String(method), args ?? {}),
        });

        const ui = Object.freeze({
          input: (options) => host.input(options ?? {}),
          panel: (file, options) => host.panel(file, options ?? {}),
          window: (file, options) => host.window(file, options ?? {}),
          pick: (items, options) => host.pick("items", items ?? [], options ?? {}),
          prompt: (options) => host.pick("text", [], options ?? {}),
          pickNote: (options) => host.pick("note", [], options ?? {}),
          pickFolder: (options) => host.pick("folder", [], options ?? {}),
          confirm: (message, options) => host.confirm(String(message), options ?? {}),
          notify: (message, options) => host.notify(String(message), options ?? {}),
        });

        const files = Object.freeze({
          resolve: (file) => host.resolve(file),
          exists: (file) => host.exists(file),
          read: (file) => host.read(file),
          write: (file, text) => host.write(file, String(text)),
          edit: (file, transform) => {
            if (typeof transform !== "function") {
              return Promise.reject(new TypeError("nv.files.edit needs a transform function"));
            }
            return host.edit(file, transform);
          },
          append: (file, text) => host.append(file, String(text)),
        });

        const workspace = Object.freeze({
          project: () => Promise.resolve(host.project()),
          projects: () => Promise.resolve(host.projects()),
          open: (file, options) => host.open(file, options?.in === "newTab"),
          activeDocument: () =>
            orNull(
              actions.invoke("workspace.note.current").then((document) =>
                document
                  ? {
                      title: document.title,
                      path: document.absolutePath ?? null,
                      relativePath: document.relativePath ?? null,
                      kind: document.kind,
                    }
                  : null
              )
            ),
          selection: () =>
            orNull(
              actions.invoke("workspace.editor.selection.get").then((selection) =>
                selection ? { text: selection.text ?? "", empty: Boolean(selection.empty) } : null
              )
            ),
          replaceSelection: (text) =>
            actions.invoke("workspace.editor.selection.replace", { text: String(text) }).then(() => undefined),
        });

        const clipboard = Object.freeze({
          read: () => host.clipboardRead(),
          write: (text) => host.clipboardWrite(String(text)),
        });

        const date = Object.freeze({
          format: (pattern, value, options) =>
            host.formatDate(String(pattern), (value ?? new Date()).getTime(), options?.locale ?? null),
        });

        const nv = Object.freeze({
          plugin: Object.freeze({ ...info }),
          actions,
          ui,
          files,
          workspace,
          clipboard,
          date,
          settings: Object.freeze({
            define: (fields) => host.defineSettings(info.name, fields),
            get: () => host.getSettings(info.name),
          }),
        });
        return { nv, console };
      };
    })
    """#
}
