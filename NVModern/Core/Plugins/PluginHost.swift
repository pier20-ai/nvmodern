import Foundation
import JavaScriptCore
import Combine

/// Runs user plugins: plain JavaScript files that register actions.
///
/// One `JSContext` holds every plugin. Each file is evaluated inside its own
/// function scope and handed an `nv` object (see `NVModern/Plugins/nv.d.ts`).
/// `nv` is built in JavaScript by `PluginPrelude`; everything it does lands on
/// the native `host` object installed here, which is the whole bridge.
///
/// A plugin action is an ordinary `ActionRegistry` registration, so the
/// palette, keybindings, the socket and external callers need no plugin-specific code.
/// JavaScript runs on the main actor only.
@MainActor
final class PluginHost: ObservableObject {
    static let shared = PluginHost()

    struct Source: Equatable {
        let url: URL
        let isBuiltin: Bool

        /// Method-name segment: the file name, reduced to `[A-Za-z0-9_-]`.
        var pluginName: String {
            let stem = url.deletingPathExtension().lastPathComponent
            let cleaned = stem.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "-" }
            return String(cleaned)
        }
    }

    struct GlobalHotkey: Equatable {
        let keystroke: String
        let method: String
    }

    typealias ProjectsProvider = @MainActor () -> (projects: [PluginFileAccess.Project], defaultRootURL: URL)

    weak var environment: (any PluginHostEnvironment)?

    /// Configured projects and the default root, for resolving file references.
    var projectsProvider: ProjectsProvider = {
        let config = NVModernConfigLoader.loadAppConfig()
        return (
            config.projects.map { PluginFileAccess.Project(name: $0.name, rootURL: $0.rootURL) },
            config.defaultProject.rootURL
        )
    }

    private(set) var loadedPluginNames: [String] = []
    private(set) var loadErrors: [String] = []
    private(set) var globalHotkeys: [GlobalHotkey] = []
    /// Default in-app shortcuts declared by plugins, as keybinding rows.
    private(set) var keybindings: [ActionKeybindingDefinition] = []
    @Published private(set) var pluginInfos: [PluginInfo] = []
    private var pluginConfiguration = NVModernPluginsDraft()
    private var schemas: [String: [PluginSettingsField]] = [:]
    private var loadingPlugin: String?

    private let registry: ActionRegistry
    private let executor: ActionExecutor
    private var context: JSContext?
    private var methodsByPlugin: [String: [String]] = [:]
    private var timers: [Int32: JSValue] = [:]
    private var nextTimerID: Int32 = 1
    /// `projectsProvider` parses config.toml; it is asked once per reload,
    /// and a config change is what triggers a reload.
    private var cachedProjects: (projects: [PluginFileAccess.Project], defaultRootURL: URL)?

    init(registry: ActionRegistry? = nil, executor: ActionExecutor? = nil) {
        self.registry = registry ?? ActionRegistry.shared
        self.executor = executor ?? ActionExecutor.shared
    }

    /// `*.js` directly inside a folder, in name order. Subfolders are ignored.
    static func sources(inDirectory directoryURL: URL, isBuiltin: Bool, fileManager: FileManager = .default) -> [Source] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "js" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Source(url: $0.standardizedFileURL, isBuiltin: isBuiltin) }
    }

    // MARK: Lifecycle

    /// Drop every plugin and evaluate `sources` in a fresh context. A user
    /// plugin replaces a built-in of the same name.
    func reload(sources: [Source], configuration: NVModernPluginsDraft = .init()) {
        unload()
        pluginConfiguration = configuration

        guard let context = JSContext() else {
            loadErrors.append("Could not create a JavaScript context")
            return
        }
        context.name = "nvModern plugins"
        self.context = context

        let host = makeHostObject(in: context)
        guard let makeAPI = context.evaluateScript(PluginPrelude.source)?.call(withArguments: [host as Any]),
              takeException(in: context) == nil,
              !makeAPI.isUndefined else {
            loadErrors.append("Plugin prelude failed to load")
            self.context = nil
            return
        }

        let userNames = Set(sources.filter { !$0.isBuiltin }.map(\.pluginName))
        var seenNames: Set<String> = []
        for source in sources {
            let name = source.pluginName
            if source.isBuiltin, userNames.contains(name) { continue }
            var info = PluginInfo(name: name, path: source.url.path, isBuiltin: source.isBuiltin, state: .running)
            if !seenNames.insert(name).inserted {
                let error = "\(source.url.lastPathComponent): another plugin is already named '\(name)'"
                loadErrors.append(error)
                info.state = .failed
                info.loadError = error
                pluginInfos.append(info)
                continue
            }
            if configuration.disabled.contains(name) {
                info.state = .disabled
                pluginInfos.append(info)
                continue
            }
            if let failure = load(source, named: name, makeAPI: makeAPI, in: context) {
                unregisterActions(ofPlugin: name)
                schemas.removeValue(forKey: name)
                loadErrors.append("\(source.url.lastPathComponent): \(failure)")
                info.state = .failed
                info.loadError = "\(source.url.lastPathComponent): \(failure)"
                print("[NVModern][Plugin][\(name)] Failed to load: \(failure)")
            } else {
                loadedPluginNames.append(name)
                info.actionMethods = Array(Set(methodsByPlugin[name] ?? [])).sorted()
                info.settingsSchema = schemas[name] ?? []
            }
            pluginInfos.append(info)
        }
    }

    func unload() {
        environment?.dismissPluginSurfaces()
        for name in Array(methodsByPlugin.keys) {
            unregisterActions(ofPlugin: name)
        }
        methodsByPlugin.removeAll()
        loadedPluginNames.removeAll()
        loadErrors.removeAll()
        globalHotkeys.removeAll()
        keybindings.removeAll()
        timers.removeAll()
        cachedProjects = nil
        context = nil
        schemas.removeAll()
        pluginInfos.removeAll()
        loadingPlugin = nil
    }

    private func load(_ source: Source, named name: String, makeAPI: JSValue, in context: JSContext) -> String? {
        loadingPlugin = name
        defer { loadingPlugin = nil }
        let script: String
        do {
            script = try String(contentsOf: source.url, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }

        // The wrapper opens on the plugin's first line so reported line
        // numbers match the file.
        let wrapped = "(function (nv, console) { \"use strict\"; \(script)\n})"
        let body = context.evaluateScript(wrapped, withSourceURL: source.url)
        if let failure = takeException(in: context) { return failure }

        let info: [String: Any] = [
            "name": name,
            "path": source.url.path,
            "isBuiltin": source.isBuiltin,
        ]
        guard let api = makeAPI.call(withArguments: [info]), takeException(in: context) == nil else {
            return "could not build the nv object"
        }
        let console = api.objectForKeyedSubscript("console") as Any
        _ = body?.call(withArguments: [api.objectForKeyedSubscript("nv") as Any, console])
        return takeException(in: context)
    }

    private func unregisterActions(ofPlugin name: String) {
        let methods = Set(methodsByPlugin.removeValue(forKey: name) ?? [])
        for method in methods {
            registry.unregister(method: method)
        }
        globalHotkeys.removeAll { methods.contains($0.method) }
        keybindings.removeAll { $0.invocation.methodName.map(methods.contains) ?? false }
    }

    // MARK: Registration

    private static let actionIDPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$"#)

    private func register(plugin: String, spec: [String: Any], run: JSValue) throws {
        guard let id = spec["id"] as? String,
              Self.actionIDPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil else {
            throw ActionError.invalidArguments("Action id must be letters, digits, '-', '_' and '.'")
        }
        guard let title = spec["title"] as? String, !title.isEmpty else {
            throw ActionError.invalidArguments("Action '\(id)' needs a title")
        }

        let method = "plugin.\(plugin).\(id)"
        let palette = (spec["palette"] as? [String: Any]).flatMap(Self.palettePresentation)
        let arguments = (spec["args"] as? [[String: Any]] ?? []).compactMap(Self.argumentDescriptor)
        let descriptor = ActionDescriptor(
            method: method,
            title: title,
            summary: spec["summary"] as? String ?? "Run the \(title) plugin action.",
            discussion: "Plugin action from \(plugin).js.",
            domain: .automation,
            mutationKind: .mutating,
            targetRequirement: .none,
            capabilities: [.automationExecute],
            tags: ["plugin", plugin] + (palette?.keywords ?? []),
            arguments: arguments,
            result: ActionResultDescriptor(summary: "Plugin result", kind: .object),
            palette: palette
        )

        // Re-registering an id replaces it, including its shortcuts.
        globalHotkeys.removeAll { $0.method == method }
        keybindings.removeAll { $0.invocation.methodName == method }

        registry.register(descriptor) { [weak self] request, executionContext in
            guard let self else { throw ActionError.unavailable("Plugin host is gone") }
            return try await self.runAction(run, plugin: plugin, request: request, executionContext: executionContext)
        }
        methodsByPlugin[plugin, default: []].append(method)

        if let keystroke = spec["globalHotkey"] as? String, !keystroke.isEmpty {
            globalHotkeys.append(GlobalHotkey(keystroke: keystroke, method: method))
        }
        if let keystroke = spec["keybinding"] as? String, !keystroke.isEmpty {
            keybindings.append(
                ActionKeybindingDefinition(
                    id: "plugin:\(method)",
                    title: title,
                    keystroke: keystroke,
                    invocation: .method(method: method, args: [:], target: nil),
                    when: nil
                )
            )
        }
    }

    private static func palettePresentation(_ spec: [String: Any]) -> ActionPalettePresentation? {
        guard let category = spec["category"] as? String, !category.isEmpty else { return nil }
        // The accelerator leads the keywords: the ranker scores an exact alias
        // match highest, which is what makes `Cmd+N` `n` land on the row.
        let key = (spec["key"] as? String).map { [$0] } ?? []
        return ActionPalettePresentation(
            category: category,
            iconSystemName: spec["icon"] as? String,
            when: spec["when"] as? String,
            rank: (spec["rank"] as? NSNumber)?.intValue ?? 100,
            keywords: key + (spec["keywords"] as? [String] ?? []),
            nounArguments: spec["nounArguments"] as? [String: String] ?? [:]
        )
    }

    private static func argumentDescriptor(_ spec: [String: Any]) -> ActionArgumentDescriptor? {
        guard let name = spec["name"] as? String,
              let kind = (spec["kind"] as? String).flatMap(ActionValue.Kind.init(rawValue:)) else {
            return nil
        }
        return ActionArgumentDescriptor(
            name: name,
            summary: spec["summary"] as? String ?? name,
            kind: kind,
            isRequired: (spec["required"] as? NSNumber)?.boolValue ?? false
        )
    }

    // MARK: Running actions

    private func runAction(
        _ run: JSValue,
        plugin: String,
        request: ActionRequest,
        executionContext: ActionExecutionContext
    ) async throws -> ActionValue {
        guard let context = run.context else {
            throw ActionError.unavailable("Plugin '\(plugin)' was unloaded")
        }
        let argument: [String: Any] = [
            "args": request.args.mapValues { $0.jsonObject() },
            "source": [
                "kind": request.source.kind.rawValue,
                "identifier": request.source.identifier ?? NSNull(),
            ] as [String: Any],
            "now": executionContext.now,
        ]

        let startedAt = ProcessInfo.processInfo.systemUptime
        func logFinished(_ outcome: String) {
            LocalDiagnosticsCenter.shared.log(
                category: "plugin",
                event: "action.finished",
                metadata: [
                    "method": request.method,
                    "outcome": outcome,
                    "duration": String(format: "%.1fms", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000),
                ]
            )
        }

        do {
            let returned = run.call(withArguments: [argument])
            if let failure = takeException(in: context) {
                throw ActionError.executionFailed(failure)
            }
            let result = Self.actionValue(from: try await settle(returned))
            logFinished("ok")
            return result
        } catch {
            logFinished("failed")
            LocalDiagnosticsCenter.shared.log(category: "plugin", event: "action.failed", metadata: [
                "method": request.method,
                "errorCode": (error as? ActionError)?.code.rawValue ?? "execution_failed",
                "errorMessage": error.localizedDescription,
            ])
            print("[NVModern][Plugin][\(plugin)] \(request.method) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Wait for a returned promise; pass anything else straight through.
    private func settle(_ value: JSValue?) async throws -> JSValue? {
        guard let value, value.isObject, value.hasProperty("then") else { return value }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSValue?, Error>) in
            let onFulfilled: @convention(block) (JSValue?) -> Void = { result in
                continuation.resume(returning: result)
            }
            let onRejected: @convention(block) (JSValue?) -> Void = { reason in
                continuation.resume(throwing: Self.actionError(fromRejection: reason))
            }
            value.invokeMethod("then", withArguments: [
                unsafeBitCast(onFulfilled, to: AnyObject.self),
                unsafeBitCast(onRejected, to: AnyObject.self),
            ])
        }
    }

    // MARK: Host object

    private func makeHostObject(in context: JSContext) -> JSValue? {
        let host = JSValue(newObjectIn: context)
        func install(_ name: String, _ block: AnyObject) {
            host?.setObject(block, forKeyedSubscript: name as NSString)
        }

        let register: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] plugin, spec, run in
            MainActor.assumeIsolated {
                guard let self, let current = JSContext.current() else { return }
                do {
                    guard let fields = spec.toObject() as? [String: Any], !run.isUndefined else {
                        throw ActionError.invalidArguments("nv.actions.register needs { id, title, run }")
                    }
                    try self.register(plugin: plugin.toString(), spec: fields, run: run)
                } catch {
                    current.exception = Self.jsError(error, in: current)
                }
            }
        }
        install("register", unsafeBitCast(register, to: AnyObject.self))

        let defineSettings: @convention(block) (JSValue, JSValue) -> Void = { [weak self] plugin, fields in
            MainActor.assumeIsolated {
                guard let self, let current = JSContext.current() else { return }
                do {
                    let name = plugin.toString() ?? ""
                    guard self.loadingPlugin == name, self.schemas[name] == nil else {
                        throw ActionError.invalidArguments("nv.settings.define is allowed once, during plugin load")
                    }
                    let data = try JSONEncoder().encode(ActionValue(fields.toObject()))
                    let schema = try JSONDecoder().decode([PluginSettingsField].self, from: data)
                    var keys: Set<String> = []
                    for field in schema {
                        guard !field.key.isEmpty, !field.title.isEmpty, keys.insert(field.key).inserted,
                              field.accepts(field.defaultValue),
                              field.kind != .choice || (!field.options.isEmpty && Set(field.options).count == field.options.count) else {
                            throw ActionError.invalidArguments("Invalid or duplicate plugin setting '\(field.key)'")
                        }
                    }
                    self.schemas[name] = schema
                } catch { current.exception = Self.jsError(error, in: current) }
            }
        }
        install("defineSettings", unsafeBitCast(defineSettings, to: AnyObject.self))
        let getSettings: @convention(block) (JSValue) -> JSValue? = { [weak self] plugin in
            MainActor.assumeIsolated {
                guard let self, let current = JSContext.current() else { return nil }
                let name = plugin.toString() ?? ""
                var values = self.pluginConfiguration.settings[name] ?? [:]
                for field in self.schemas[name] ?? [] {
                    if !field.accepts(values[field.key] ?? field.defaultValue) {
                        print("[NVModern][Plugin][\(name)] Invalid setting '\(field.key)'; using default")
                        values[field.key] = field.defaultValue
                    } else if values[field.key] == nil {
                        values[field.key] = field.defaultValue
                    }
                }
                return JSValue(object: ActionValue.object(values).jsonObject(), in: current)
            }
        }
        install("getSettings", unsafeBitCast(getSettings, to: AnyObject.self))

        let invoke: @convention(block) (JSValue, JSValue, JSValue) -> JSValue? = { [weak self] plugin, method, args in
            MainActor.assumeIsolated {
                let methodName = method.toString() ?? ""
                let arguments = ActionValue(args.toObject()).objectValue ?? [:]
                let pluginName = plugin.toString() ?? ""
                return self?.promise { host in
                    let request = ActionRequest(
                        method: methodName,
                        args: arguments,
                        source: ActionSource(kind: .automation, identifier: "plugin:\(pluginName)")
                    )
                    return try await host.executor.invoke(request).jsonObject()
                }
            }
        }
        install("invoke", unsafeBitCast(invoke, to: AnyObject.self))

        let resolve: @convention(block) (JSValue) -> String? = { [weak self] file in
            MainActor.assumeIsolated {
                guard let self, let current = JSContext.current() else { return nil }
                do {
                    return try self.resolvedURL(for: file).path
                } catch {
                    current.exception = Self.jsError(error, in: current)
                    return nil
                }
            }
        }
        install("resolve", unsafeBitCast(resolve, to: AnyObject.self))

        let exists: @convention(block) (JSValue) -> JSValue? = { [weak self] file in
            MainActor.assumeIsolated {
                self?.promise { host in
                    host.fileAccess().exists(try host.resolvedURL(for: file))
                }
            }
        }
        install("exists", unsafeBitCast(exists, to: AnyObject.self))

        let read: @convention(block) (JSValue) -> JSValue? = { [weak self] file in
            MainActor.assumeIsolated {
                self?.promise { host in
                    try host.fileAccess().read(try host.resolvedURL(for: file))
                }
            }
        }
        install("read", unsafeBitCast(read, to: AnyObject.self))

        let write: @convention(block) (JSValue, JSValue) -> JSValue? = { [weak self] file, text in
            MainActor.assumeIsolated {
                self?.promise { host in
                    try host.fileAccess().write(text.toString() ?? "", to: try host.resolvedURL(for: file))
                    return nil
                }
            }
        }
        install("write", unsafeBitCast(write, to: AnyObject.self))

        let append: @convention(block) (JSValue, JSValue) -> JSValue? = { [weak self] file, text in
            MainActor.assumeIsolated {
                self?.promise { host in
                    try host.fileAccess().append(text.toString() ?? "", to: try host.resolvedURL(for: file))
                    return nil
                }
            }
        }
        install("append", unsafeBitCast(append, to: AnyObject.self))

        let edit: @convention(block) (JSValue, JSValue) -> JSValue? = { [weak self] file, transform in
            MainActor.assumeIsolated {
                self?.promise { host in
                    let url = try host.resolvedURL(for: file)
                    return try host.fileAccess().edit(url) { current in
                        let returned = transform.call(withArguments: [current])
                        if let context = transform.context, let failure = host.takeException(in: context) {
                            throw ActionError.executionFailed(failure)
                        }
                        guard let returned, !returned.isNull, !returned.isUndefined else { return nil }
                        guard returned.isString else {
                            throw ActionError.invalidArguments("nv.files.edit transform must return a string, null or undefined")
                        }
                        return returned.toString()
                    }
                }
            }
        }
        install("edit", unsafeBitCast(edit, to: AnyObject.self))

        let input: @convention(block) (JSValue) -> JSValue? = { [weak self] options in
            MainActor.assumeIsolated {
                let request = Self.inputRequest(from: options.toObject() as? [String: Any] ?? [:])
                return self?.promise { host in
                    try await host.requireEnvironment().input(request)
                }
            }
        }
        install("input", unsafeBitCast(input, to: AnyObject.self))

        let panel: @convention(block) (JSValue, JSValue) -> JSValue? = { [weak self] file, options in
            MainActor.assumeIsolated {
                let fields = options.toObject() as? [String: Any] ?? [:]
                return self?.promise { host in
                    let url = try host.resolvedURL(for: file)
                    let request = PluginPanelRequest(
                        fileURL: url,
                        cursor: (fields["cursor"] as? String).flatMap(PluginPanelRequest.CursorPlacement.init(rawValue:)) ?? .end,
                        id: fields["id"] as? String ?? url.path
                    )
                    try await host.requireEnvironment().panel(request)
                    return nil
                }
            }
        }
        install("panel", unsafeBitCast(panel, to: AnyObject.self))

        let window: @convention(block) (JSValue, JSValue) -> JSValue? = { [weak self] file, options in
            MainActor.assumeIsolated {
                let fields = options.toObject() as? [String: Any] ?? [:]
                return self?.promise { host in
                    let url = try host.resolvedURL(for: file)
                    let size = fields["size"] as? [String: Any] ?? [:]
                    let width = (size["width"] as? NSNumber)?.doubleValue ?? 420
                    let height = (size["height"] as? NSNumber)?.doubleValue ?? 340
                    guard width.isFinite, height.isFinite, width >= 240, height >= 160,
                          width <= 10000, height <= 10000 else {
                        throw ActionError.invalidArguments("Window size must be between 240×160 and 10000×10000")
                    }
                    let position: PluginWindowRequest.Position?
                    if fields["position"] == nil {
                        position = nil
                    } else if fields["position"] as? String == "right" {
                        position = .right
                    } else if let coordinates = fields["position"] as? [String: Any],
                              let x = (coordinates["x"] as? NSNumber)?.doubleValue,
                              let y = (coordinates["y"] as? NSNumber)?.doubleValue,
                              x.isFinite, y.isFinite {
                        position = .coordinates(x: x, y: y)
                    } else {
                        throw ActionError.invalidArguments("Window position must be right or { x, y } with finite coordinates")
                    }
                    let request = PluginWindowRequest(
                        fileURL: url,
                        toggle: fields["toggle"] as? Bool ?? false,
                        alwaysOnTop: fields["alwaysOnTop"] as? Bool ?? false,
                        allSpaces: fields["allSpaces"] as? Bool ?? false,
                        position: position,
                        width: width,
                        height: height,
                        cursor: (fields["cursor"] as? String).flatMap(PluginPanelRequest.CursorPlacement.init(rawValue:)) ?? .end
                    )
                    try await host.requireEnvironment().window(request)
                    return nil
                }
            }
        }
        install("window", unsafeBitCast(window, to: AnyObject.self))

        // One block serves every palette picker; `kind` says which.
        let pick: @convention(block) (String, JSValue, JSValue) -> JSValue? = { [weak self] kind, items, options in
            MainActor.assumeIsolated {
                let fields = options.toObject() as? [String: Any] ?? [:]
                let request = PluginPickRequest(
                    kind: PalettePluginPick.Kind(rawValue: kind) ?? .items,
                    items: (items.toObject() as? [[String: Any]] ?? []).compactMap(Self.pickItem),
                    placeholder: fields["placeholder"] as? String,
                    initialText: fields["initialText"] as? String
                )
                return self?.promise { host in
                    try await host.requireEnvironment().pick(request)?.jsonObject()
                }
            }
        }
        install("pick", unsafeBitCast(pick, to: AnyObject.self))

        let confirm: @convention(block) (String, JSValue) -> JSValue? = { [weak self] message, options in
            MainActor.assumeIsolated {
                let fields = options.toObject() as? [String: Any] ?? [:]
                let request = PluginConfirmRequest(
                    message: message,
                    detail: fields["detail"] as? String,
                    confirmLabel: fields["confirmLabel"] as? String,
                    cancelLabel: fields["cancelLabel"] as? String,
                    isDestructive: (fields["destructive"] as? NSNumber)?.boolValue ?? false
                )
                return self?.promise { host in
                    try await host.requireEnvironment().confirm(request)
                }
            }
        }
        install("confirm", unsafeBitCast(confirm, to: AnyObject.self))

        let notify: @convention(block) (String, JSValue) -> JSValue? = { [weak self] message, options in
            MainActor.assumeIsolated {
                let title = (options.toObject() as? [String: Any])?["title"] as? String
                return self?.promise { host in
                    try await host.requireEnvironment().notify(title: title, message: message)
                    return nil
                }
            }
        }
        install("notify", unsafeBitCast(notify, to: AnyObject.self))

        let open: @convention(block) (JSValue, JSValue) -> JSValue? = { [weak self] file, inNewTab in
            MainActor.assumeIsolated {
                let newTab = inNewTab.toBool()
                return self?.promise { host in
                    let url = try host.resolvedURL(for: file)
                    guard try host.requireEnvironment().open(fileURL: url, inNewTab: newTab) else {
                        throw ActionError.unavailable("Could not open \(url.path)", details: ["path": .string(url.path)])
                    }
                    return nil
                }
            }
        }
        install("open", unsafeBitCast(open, to: AnyObject.self))

        let project: @convention(block) () -> Any? = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let rootPath = self.environment?.activeProjectRootPath else { return NSNull() }
                let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
                let known = self.configuredProjects().projects.first { $0.rootURL.standardizedFileURL == rootURL }
                return ["name": known?.name ?? rootURL.lastPathComponent, "rootPath": rootURL.path]
            }
        }
        install("project", unsafeBitCast(project, to: AnyObject.self))

        let projects: @convention(block) () -> Any? = { [weak self] in
            MainActor.assumeIsolated {
                (self?.configuredProjects().projects ?? []).map {
                    ["name": $0.name, "rootPath": $0.rootURL.standardizedFileURL.path]
                }
            }
        }
        install("projects", unsafeBitCast(projects, to: AnyObject.self))

        let clipboardRead: @convention(block) () -> JSValue? = { [weak self] in
            MainActor.assumeIsolated {
                self?.promise { host in try host.requireEnvironment().readClipboard() }
            }
        }
        install("clipboardRead", unsafeBitCast(clipboardRead, to: AnyObject.self))

        let clipboardWrite: @convention(block) (JSValue) -> JSValue? = { [weak self] text in
            MainActor.assumeIsolated {
                self?.promise { host in
                    try host.requireEnvironment().writeClipboard(text.toString() ?? "")
                    return nil
                }
            }
        }
        install("clipboardWrite", unsafeBitCast(clipboardWrite, to: AnyObject.self))

        let formatDate: @convention(block) (String, Double, JSValue) -> String = { pattern, milliseconds, locale in
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: locale.isString ? locale.toString() : "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = pattern
            return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
        }
        install("formatDate", unsafeBitCast(formatDate, to: AnyObject.self))

        let log: @convention(block) (String, String, String) -> Void = { plugin, level, message in
            let marker = level == "log" ? "" : "[\(level)] "
            print("[NVModern][Plugin][\(plugin)] \(marker)\(message)")
        }
        install("log", unsafeBitCast(log, to: AnyObject.self))

        let setTimeout: @convention(block) (JSValue, Double) -> Int32 = { [weak self] callback, milliseconds in
            MainActor.assumeIsolated {
                guard let self else { return 0 }
                let id = self.nextTimerID
                self.nextTimerID &+= 1
                self.timers[id] = callback
                let delay = max(0, milliseconds.isFinite ? milliseconds : 0) / 1000
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let callback = self.timers.removeValue(forKey: id) else { return }
                        callback.call(withArguments: [])
                        if let context = callback.context, let failure = self.takeException(in: context) {
                            print("[NVModern][Plugin] Timer callback failed: \(failure)")
                        }
                    }
                }
                return id
            }
        }
        install("setTimeout", unsafeBitCast(setTimeout, to: AnyObject.self))

        let clearTimeout: @convention(block) (Int32) -> Void = { [weak self] id in
            MainActor.assumeIsolated {
                _ = self?.timers.removeValue(forKey: id)
            }
        }
        install("clearTimeout", unsafeBitCast(clearTimeout, to: AnyObject.self))

        return host
    }

    /// A JS promise settled by native async work. Created in the calling
    /// context, so work started by a plugin that has since been reloaded
    /// still completes there — a capture typed before a reload is not lost.
    private func promise(_ work: @escaping @MainActor (PluginHost) async throws -> Any?) -> JSValue? {
        guard let context = JSContext.current() else { return nil }
        return JSValue(newPromiseIn: context) { [weak self] resolve, reject in
            Task { @MainActor in
                do {
                    guard let self else { throw ActionError.unavailable("Plugin host is gone") }
                    let value = try await work(self)
                    resolve?.call(withArguments: [value ?? NSNull()])
                } catch {
                    reject?.call(withArguments: [Self.jsError(error, in: context) as Any])
                }
            }
        }
    }

    // MARK: Helpers

    private func requireEnvironment() throws -> any PluginHostEnvironment {
        guard let environment else {
            throw ActionError.unavailable("No app environment is attached to the plugin host")
        }
        return environment
    }

    private func configuredProjects() -> (projects: [PluginFileAccess.Project], defaultRootURL: URL) {
        if let cachedProjects { return cachedProjects }
        let configured = projectsProvider()
        cachedProjects = configured
        return configured
    }

    private func fileAccess() -> PluginFileAccess {
        let configured = configuredProjects()
        let activeRootURL = environment?.activeProjectRootPath
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? configured.defaultRootURL
        return PluginFileAccess(projects: configured.projects, activeRootURL: activeRootURL)
    }

    private func resolvedURL(for file: JSValue) throws -> URL {
        let reference: PluginFileAccess.Reference
        if file.isString {
            reference = .path(file.toString())
        } else if let fields = file.toObject() as? [String: Any],
                  let project = fields["project"] as? String,
                  let path = fields["path"] as? String {
            reference = .project(name: project, path: path)
        } else {
            throw ActionError.invalidArguments("Expected a path string or { project, path }")
        }
        return try fileAccess().resolve(reference)
    }

    private func takeException(in context: JSContext) -> String? {
        guard let exception = context.exception else { return nil }
        context.exception = nil
        let message = exception.toString() ?? "JavaScript exception"
        let line = exception.objectForKeyedSubscript("line")
        guard let line, line.isNumber else { return message }
        return "\(message) (line \(line.toInt32()))"
    }

    private static func inputRequest(from fields: [String: Any]) -> PluginInputRequest {
        PluginInputRequest(
            placeholder: fields["placeholder"] as? String,
            initialText: fields["initialText"] as? String,
            submitKey: (fields["submitKey"] as? String).flatMap(PluginInputRequest.SubmitKey.init(rawValue:)) ?? .commandReturn,
            onDismiss: (fields["onDismiss"] as? String).flatMap(PluginInputRequest.DismissBehavior.init(rawValue:)) ?? .cancel,
            id: fields["id"] as? String
        )
    }

    private static func pickItem(_ fields: [String: Any]) -> PluginPickItem? {
        guard let title = fields["title"] as? String else { return nil }
        let key = (fields["key"] as? String).map { [$0] } ?? []
        return PluginPickItem(
            title: title,
            subtitle: fields["subtitle"] as? String,
            iconSystemName: fields["icon"] as? String,
            keywords: key + (fields["keywords"] as? [String] ?? []),
            value: ActionValue(fields["value"])
        )
    }

    private static func actionValue(from value: JSValue?) -> ActionValue {
        guard let value, !value.isUndefined, !value.isNull else { return .null }
        return ActionValue(value.toObject())
    }

    private static func jsError(_ error: Error, in context: JSContext) -> JSValue? {
        let value = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
        if let actionError = error as? ActionError {
            value?.setObject(actionError.code.rawValue, forKeyedSubscript: "code" as NSString)
            value?.setObject(actionError.details.mapValues { $0.jsonObject() }, forKeyedSubscript: "details" as NSString)
        }
        return value
    }

    private static func actionError(fromRejection reason: JSValue?) -> ActionError {
        guard let reason, !reason.isUndefined, !reason.isNull else {
            return .executionFailed("Plugin action rejected")
        }
        let message = reason.toString() ?? "Plugin action rejected"
        guard reason.isObject else { return .executionFailed(message) }
        let code = reason.objectForKeyedSubscript("code")
            .flatMap { $0.isString ? ActionError.Code(rawValue: $0.toString()) : nil }
        let details = ActionValue(reason.objectForKeyedSubscript("details")?.toObject()).objectValue ?? [:]
        return ActionError(code: code ?? .executionFailed, message: message, details: details)
    }
}
