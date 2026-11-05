import AppKit
import WebKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let externallyOpenableExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "org", "html", "epub", "outline", "excalidraw"
    ]
    private let keybindingManager = ActionKeybindingManager()
    private let socketServer = ActionSocketServer()
    private let globalHotkeyManager = GlobalHotkeyManager()
    private let quickCapturePanelController = QuickCapturePanelController()
    private lazy var pluginEnvironment = PluginAppEnvironment(panels: quickCapturePanelController)
    private var pluginDirectoryWatcher: PluginDirectoryWatcher?
    private var keyMonitor: Any?
    private var configChangeObserver: NSObjectProtocol?
    private var pluginConfigChangeObserver: NSObjectProtocol?
    private var themeDirectoryWatcher: UserEditorThemeDirectoryWatcher?
    private var activeTabSwitcherWindowNumber: Int?
    private var tabSwitcherReleaseTask: Task<Void, Never>?
    private var pluginFailureNotifications = PluginFailureNotificationPolicy()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LocalDiagnosticsCenter.shared.install()
        LocalDiagnosticsCenter.shared.log(
            level: .info,
            category: "app",
            event: "applicationDidFinishLaunching",
            metadata: ["diagnosticsPath": LocalDiagnosticsCenter.shared.diagnosticsPath]
        )

        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        WorkspaceApplicationCoordinator.shared.installLaunchHandler()
        UserDefaults.standard.set(true, forKey: "WebKitDeveloperExtras")
        UNUserNotificationCenter.current().delegate = self

        ActionExecutor.shared.contentSurface = MarkdownActionContentSurface()
        PluginHost.shared.environment = pluginEnvironment
        // Plugin saves only rebuild plugins and their shortcuts. Config/theme
        // changes keep the broader notification path below.
        pluginDirectoryWatcher = PluginDirectoryWatcher { [weak self] in
            self?.reloadPluginsAndShortcuts(appConfig: NVModernConfigLoader.loadAppConfig())
        }
        reloadActionConfiguration()
        // Theme file edits announce themselves through the same notification as
        // config changes so open editors re-push CSS; the observer below re-arms
        // the watcher in case themes_dir moved.
        themeDirectoryWatcher = UserEditorThemeDirectoryWatcher {
            NotificationCenter.default.post(name: .nvModernConfigDidChange, object: nil)
        }
        refreshThemeDirectoryWatcher()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .nvModernConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                NVModernConfigFileMonitor.shared.refresh(announceRuntime: false)
                self?.reloadActionConfiguration()
                self?.refreshThemeDirectoryWatcher()
            }
        }
        paletteDebugLog("appDelegate.didFinishLaunching instrumentation=2026-04-21T2248Z")
        pluginConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .nvModernPluginsConfigDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                NVModernConfigFileMonitor.shared.refresh(announceRuntime: false)
                self?.reloadPluginsAndShortcuts(appConfig: NVModernConfigLoader.loadAppConfig())
            }
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            NVModernConfigFileMonitor.shared.start()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return handleKeyEvent(event)
        }

        quickCapturePanelController.prewarm()
        DispatchQueue.main.async {
            WorkspaceApplicationCoordinator.shared.bootstrap()
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        PerformanceDiagnostics.appLifecycle("applicationWillResignActive")
    }

    func applicationDidResignActive(_ notification: Notification) {
        PerformanceDiagnostics.appLifecycle("applicationDidResignActive")
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        PerformanceDiagnostics.appLifecycle("applicationWillBecomeActive")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        PerformanceDiagnostics.appLifecycle("applicationDidBecomeActive")
        DispatchQueue.main.async {
            PerformanceDiagnostics.appLifecycle("applicationDidBecomeActive.nextRunLoop")
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WorkspaceApplicationCoordinator.shared.reopenWorkspace()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        var queuedAnyDocument = false

        var queuedDocuments: [WorkspaceOpenedDocument] = []
        let fallbackProjectRootPath = WorkspaceActionRouter.runtime(for: nil)?.projectRootPath
        LocalDiagnosticsCenter.shared.log(
            level: .info,
            category: "workspace.externalOpen",
            event: "received",
            metadata: [
                "paths": urls.map(\.path).joined(separator: " | "),
                "runtimeWindow": WorkspaceActionRouter.runtime(for: nil)
                    .map { String($0.windowNumber) } ?? "none",
                "appWindows": NSApp.windows.map { String($0.windowNumber) }.joined(separator: ",")
            ]
        )

        for url in urls {
            if (url.scheme ?? "").lowercased() == NVModernURLScheme.scheme {
                URLSchemeRouter.open(url)
                continue
            }
            guard url.isFileURL else { continue }
            let standardizedURL = url.standardizedFileURL
            let pathExtension = standardizedURL.pathExtension.lowercased()
            guard externallyOpenableExtensions.contains(pathExtension) else { continue }
            if WorkspaceWindowLaunchStore.shared.consumeInternalOpenFileMarkIfPresent(path: standardizedURL.path) {
                continue
            }

            let document = WorkspaceOpenedDocument.externalMarkdown(filePath: standardizedURL.path)
            if WorkspaceActionRouter.performExternalFileOpen(document) {
                LocalDiagnosticsCenter.shared.log(
                    level: .info,
                    category: "workspace.externalOpen",
                    event: "routedToExistingWindow",
                    metadata: [
                        "path": standardizedURL.path,
                        "runtimeWindow": WorkspaceActionRouter.runtime(for: nil)
                            .map { String($0.windowNumber) } ?? "none"
                    ]
                )
                continue
            }

            queuedDocuments.append(document)
        }

        if !queuedDocuments.isEmpty {
            WorkspaceWindowLaunchStore.shared.enqueueWindowRequest(
                projectRootPath: fallbackProjectRootPath,
                documents: queuedDocuments
            )
            queuedAnyDocument = true
        }

        if queuedAnyDocument {
            WorkspaceWindowLaunchStore.shared.requestWorkspaceWindow()
        }
        LocalDiagnosticsCenter.shared.log(
            level: .info,
            category: "workspace.externalOpen",
            event: "completed",
            metadata: [
                "queuedDocumentCount": String(queuedDocuments.count),
                "requestedWindow": String(queuedAnyDocument),
                "appWindows": NSApp.windows.map { String($0.windowNumber) }.joined(separator: ",")
            ]
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LocalDiagnosticsCenter.shared.log(level: .info, category: "app", event: "applicationShouldTerminate")
        guard pluginEnvironment.documentWindows.prepareForTermination() else { return .terminateCancel }
        LocalDiagnosticsCenter.shared.markLaunchEndedCleanly()
        // Pre-warmed spare windows are not tabs; drop them before the session
        // store closes so they cannot be mistaken for restorable state.
        WorkspaceApplicationCoordinator.shared.discardSpareWindows()
        NVModernConfigFileMonitor.shared.stop()
        socketServer.stop()
        globalHotkeyManager.unregister()
        quickCapturePanelController.close()
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        if let pluginConfigChangeObserver { NotificationCenter.default.removeObserver(pluginConfigChangeObserver) }
        WorkspaceSessionStore.shared.beginTermination()
        return .terminateNow
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func refreshThemeDirectoryWatcher() {
        let result = NVModernConfigSchema.shared.loadDraft()
        let directory = UserEditorThemeCatalog.resolvedDirectoryURL(
            from: result.draft.themes_dir,
            configURL: result.configURL
        )
        themeDirectoryWatcher?.watch(directoryURL: directory)
    }

    /// Plugins live next to config.toml, in `plugins/`; built-ins ship in the
    /// bundle and yield to a user plugin of the same name.
    private func reloadPlugins(configURL: URL) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            pluginDirectoryWatcher?.stop()
            print("[NVModern][Plugin] Skipping plugins in the XCTest host")
            return
        }
        let userDirectory = configURL.deletingLastPathComponent().appendingPathComponent("plugins", isDirectory: true)
        var sources: [PluginHost.Source] = []
        if let builtinDirectory = Bundle.main.resourceURL?.appendingPathComponent("BuiltinPlugins", isDirectory: true) {
            sources += PluginHost.sources(inDirectory: builtinDirectory, isBuiltin: true)
        }
        sources += PluginHost.sources(inDirectory: userDirectory, isBuiltin: false)

        PluginHost.shared.reload(sources: sources, configuration: NVModernConfigLoader.loadAppConfig().plugins)
        pluginDirectoryWatcher?.watch(directoryURL: userDirectory)

        if !PluginHost.shared.loadedPluginNames.isEmpty {
            print("[NVModern][Plugin] Loaded: \(PluginHost.shared.loadedPluginNames.joined(separator: ", "))")
        }
        for error in PluginHost.shared.loadErrors {
            print("[NVModern][Plugin] Load error: \(error)")
        }
        for error in pluginFailureNotifications.loadFailuresToNotify(PluginHost.shared.loadErrors) {
            notifyPluginFailure(title: "Plugin failed to load", message: error)
        }
    }

    private func reloadActionConfiguration() {
        let appConfig = NVModernConfigLoader.loadAppConfig()
        reloadPluginsAndShortcuts(appConfig: appConfig)

        if let warning = appConfig.warning {
            print("[NVModern][Actions][Config] \(warning)")
        }

        // The XCTest app host must not claim or unlink the running app's
        // user-configured socket when live-config fixtures post notifications.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        socketServer.stop()
        if let socket = appConfig.socket, socket.isEnabled {
            socketServer.configure(socketURL: socket.socketURL)
            socketServer.start()

            switch socketServer.state {
            case .running(let socketPath):
                print("[NVModern][Actions][Socket] Listening on \(socketPath)")
            case .failed(let message):
                print("[NVModern][Actions][Socket] Failed to start: \(message)")
            case .stopped:
                break
            }
        }
    }

    private func reloadPluginsAndShortcuts(appConfig: NVModernAppConfig) {
        // A plugin-file save while TOML is broken must not re-enable plugins
        // or replace shortcuts using the loader's fallback configuration.
        guard (try? NVModernConfigFileMonitor.shared.readDraft()) != nil else { return }
        reloadPlugins(configURL: appConfig.configURL)
        // A `[[keybindings]]` row for a plugin method replaces the shortcut the
        // plugin declared for it.
        let configuredMethods = Set(NVModernConfigSchema.shared.loadDraft().draft.keybindings.compactMap(\.method))
        let pluginBindings = PluginHost.shared.keybindings.filter { binding in
            binding.invocation.methodName.map { !configuredMethods.contains($0) } ?? true
        }
        let availableBindings = appConfig.keybindings.filter { binding in
            guard let method = binding.invocation.methodName, method.hasPrefix("plugin.") else { return true }
            return ActionRegistry.shared.descriptor(for: method) != nil
        }
        keybindingManager.updateBindings(availableBindings + pluginBindings)
        PaletteShortcutResolver.invalidate()

        for invalidBinding in keybindingManager.invalidBindings {
            print("[NVModern][Actions][Keybinding] Invalid binding: \(invalidBinding)")
        }

        globalHotkeyManager.unregister()
        for hotkey in PluginHost.shared.globalHotkeys {
            do {
                try globalHotkeyManager.register(keystroke: hotkey.keystroke) { [weak self] in
                    Task { @MainActor [weak self] in
                        let response = await ActionExecutor.shared.execute(
                            ActionRequest(
                                method: hotkey.method,
                                source: ActionSource(kind: .keybinding, identifier: "global:\(hotkey.keystroke)")
                            )
                        )
                        if !response.ok {
                            NSSound.beep()
                            if let self, self.pluginFailureNotifications.shouldNotifyRuntimeFailure(
                                method: hotkey.method, uptime: ProcessInfo.processInfo.systemUptime
                            ) {
                                let title = ActionRegistry.shared.descriptor(for: hotkey.method)?.title ?? hotkey.method
                                self.notifyPluginFailure(title: title, message: response.error?.message ?? "Action failed")
                            }
                        }
                    }
                }
                print("[NVModern][Plugin] Registered global hotkey \(hotkey.keystroke) for \(hotkey.method)")
            } catch {
                print("[NVModern][Plugin] Failed to register global hotkey \(hotkey.keystroke): \(error.localizedDescription)")
            }
        }
    }

    private func notifyPluginFailure(title: String, message: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await pluginEnvironment.notify(title: title, message: message)
                LocalDiagnosticsCenter.shared.log(category: "plugin", event: "failureNotification.sent", metadata: [
                    "title": title, "message": message
                ])
            } catch {
                print("[NVModern][Plugin] Could not show failure notification: \(error.localizedDescription)")
                LocalDiagnosticsCenter.shared.log(level: .warning, category: "plugin", event: "failureNotification.failed", metadata: [
                    "title": title, "error": error.localizedDescription
                ])
            }
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // `charactersIgnoringModifiers` and `keyCode` raise
        // NSInternalInconsistencyException on event types that do not carry
        // them, and this monitor is reachable with other types: AppKit routes
        // events to observers via _NSSendEventToObservers, so anything calling
        // sendEvent: directly can land here regardless of the monitor's mask.
        // WebKit's spell-check correction panel does exactly that from
        // -[NSCorrectionPanel _interceptEvents], which crashed the app.
        guard event.type == .keyDown
                || event.type == .keyUp
                || event.type == .flagsChanged else {
            return event
        }

        // Stay out of modal sessions entirely. -[NSApplication _doModalLoop:]
        // pumps events through sendEvent:, so this monitor keeps running while
        // an NSAlert is up — which both routes app shortcuts like Cmd+W to the
        // workspace behind the dialog, and is how the type-confusion crash
        // above was reached from -[NSAlert runModal]. The modal window owns the
        // keyboard until it is dismissed.
        guard NSApp.modalWindow == nil else { return event }

        // F1 opens help from anywhere. Inside a web editor the page decides first, so calc can open
        // contextual help and other text falls back to `help.browse`; F1 inside help closes it.
        if event.type == .keyDown, event.keyCode == 122,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if (event.window ?? NSApp.keyWindow) is HelpPanel {
                AppHelpService.shared.dismiss()
                return nil
            }
            var responder = NSApp.keyWindow?.firstResponder
            while let current = responder, !(current is WKWebView) { responder = current.nextResponder }
            if responder == nil {
                AppHelpService.shared.presentFromActiveWindow()
                return nil
            }
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Only key events carry characters — a flagsChanged event raises here.
        let key = event.type == .flagsChanged
            ? nil
            : event.charactersIgnoringModifiers?.lowercased()
        let keyCode = event.keyCode
        let eventWindow = event.window ?? NSApp.keyWindow
        let windowNumber = eventWindow?.windowNumber

        if WindowFocusCoordinator.shared.kind(of: eventWindow) == .scratchpad {
            if event.type == .keyDown, flags == [.command], key == "w" {
                eventWindow?.performClose(nil)
                return nil
            }
            // Stand down before workspace routing, including the palette bypass.
            if event.type == .keyDown,
               (flags == [.command] && ["k", "t", "n", "o", "f"].contains(key ?? ""))
                || (event.type == .keyDown && flags == [.command, .shift] && ["k", "f"].contains(key ?? ""))
                || (event.type == .keyDown && keyCode == 48 && flags.contains(.control)) {
                NSSound.beep()
                return nil
            }
            return event
        }

        if event.type == .flagsChanged {
            if !flags.contains(.control) {
                _ = commitTrackedTabSwitcher(fallbackWindowNumber: windowNumber)
            }
            return event
        }

        if event.type == .keyUp {
            guard keyCode == 48, !flags.contains(.control) else {
                return event
            }
            let handled = commitTrackedTabSwitcher(fallbackWindowNumber: windowNumber)
            return handled ? nil : event
        }

        if keyCode == 48, flags == [.control] || flags == [.control, .shift] {
            let handled = WorkspaceActionRouter.performCycleTabSwitcher(
                reverse: flags.contains(.shift),
                in: windowNumber
            )
            if handled {
                beginTrackingTabSwitcherRelease(windowNumber: windowNumber)
            }
            return handled ? nil : event
        }

        if keyCode == 53 {
            let handled = WorkspaceActionRouter.performCancelTabSwitcher(
                in: activeTabSwitcherWindowNumber ?? windowNumber
            )
            if handled {
                endTrackingTabSwitcherRelease()
                return nil
            }
        }

        // Handle palette shortcuts before any filter so they work from the main
        // window, including when the WebView is first responder. These
        // intentionally bypass `shouldHandleApplicationShortcutEvent` so the
        // palette can always be opened or mode-swapped. The Go and Edit menus
        // declare the same shortcuts for discoverability and validation, but
        // this monitor runs ahead of menu key-equivalent dispatch, so it stays
        // the handler — both paths call the same command layer.
        if flags == [.command], key == "k" {
            WorkspaceMenuCommands.openPalette(.root, windowNumber: windowNumber)
            return nil
        }

        if flags == [.command, .shift], key == "k" {
            WorkspaceMenuCommands.openPalette(.actions, windowNumber: windowNumber)
            return nil
        }

        if flags == [.command, .shift], key == "f" {
            WorkspaceMenuCommands.openPalette(.contentSearch(initialQuery: ""), windowNumber: windowNumber)
            return nil
        }

        guard WindowEventRouting.shouldHandleApplicationShortcutEvent(event) else {
            return event
        }

        // New Tab, the split commands, and tab selection moved to the Window and
        // File menus, which validate and display them. `Cmd+W` stays here:
        // AppKit contributes its own File > Close on that key, and two menu
        // items cannot share one equivalent.
        if flags == [.command], key == "w" {
            let handled = WorkspaceActionRouter.performCloseCurrentTab(in: windowNumber)
            return handled ? nil : event
        }

        guard let binding = keybindingManager.matchingBinding(for: event) else {
            return event
        }

        if let when = binding.when?.trimmingCharacters(in: .whitespacesAndNewlines),
           !when.isEmpty {
            let context = ActionAutomationContextBuilder.build(
                source: ActionSource(kind: .keybinding, identifier: binding.id),
                fallbackTarget: .automatic
            )
            if !ActionExpressionEvaluator.evaluate(when, variables: context.variables) {
                return event
            }
        }

        let source = ActionSource(
            kind: .keybinding,
            identifier: binding.id,
            metadata: [
                "bindingID": .string(binding.id),
                "keystroke": .string(binding.keystroke)
            ]
        )

        Task { @MainActor in
            let response = await ActionInvocationDispatcher.shared.execute(
                invocation: binding.invocation,
                source: source,
                fallbackTarget: .automatic
            )

            if !response.ok, let error = response.error {
                print("[NVModern][Actions][Keybinding] \(binding.id) failed: \(error.message)")
            }
        }
        return nil
    }

    private func beginTrackingTabSwitcherRelease(windowNumber: Int?) {
        activeTabSwitcherWindowNumber = WorkspaceActionRouter.runtime(for: windowNumber)?.windowNumber
            ?? windowNumber

        guard tabSwitcherReleaseTask == nil else { return }
        tabSwitcherReleaseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled else { return }

                let flags = CGEventSource.flagsState(.combinedSessionState)
                guard !flags.contains(.maskControl) else { continue }

                _ = self?.commitTrackedTabSwitcher(fallbackWindowNumber: nil)
                return
            }
        }
    }

    @discardableResult
    private func commitTrackedTabSwitcher(fallbackWindowNumber: Int?) -> Bool {
        let handled = WorkspaceActionRouter.performCommitTabSwitcher(
            in: activeTabSwitcherWindowNumber ?? fallbackWindowNumber
        )
        endTrackingTabSwitcherRelease()
        return handled
    }

    private func endTrackingTabSwitcherRelease() {
        tabSwitcherReleaseTask?.cancel()
        tabSwitcherReleaseTask = nil
        activeTabSwitcherWindowNumber = nil
    }

}
