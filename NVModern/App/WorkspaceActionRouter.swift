import AppKit
import Combine

@MainActor
final class WorkspaceActionRouterState: ObservableObject {
    static let shared = WorkspaceActionRouterState()

    @Published private(set) var revision = 0

    private init() {}

    fileprivate func invalidate() {
        revision &+= 1
    }
}

@MainActor
enum WorkspaceActionRouter {
    private static var runtimesByWindowNumber: [Int: any WorkspaceActionRuntime] = [:]
    private static var lastActiveWindowNumber: Int?
    private static var unrequestedWorkspaceWindowNumbers = Set<Int>()

    static func register(runtime: any WorkspaceActionRuntime) {
        runtimesByWindowNumber[runtime.windowNumber] = runtime
        WorkspaceActionRouterState.shared.invalidate()
    }

    static func unregister(windowNumber: Int) {
        let removedRuntime = runtimesByWindowNumber.removeValue(forKey: windowNumber) != nil
        unrequestedWorkspaceWindowNumbers.remove(windowNumber)
        if lastActiveWindowNumber == windowNumber {
            lastActiveWindowNumber = nil
        }
        if removedRuntime {
            WorkspaceActionRouterState.shared.invalidate()
        }
    }

    static func markUnrequestedWorkspaceWindow(_ windowNumber: Int) {
        guard runtimesByWindowNumber[windowNumber] == nil else { return }
        unrequestedWorkspaceWindowNumbers.insert(windowNumber)
    }

    static func markWindowActive(_ windowNumber: Int) {
        guard runtimesByWindowNumber[windowNumber] != nil else { return }
        guard lastActiveWindowNumber != windowNumber else { return }
        lastActiveWindowNumber = windowNumber
        WorkspaceActionRouterState.shared.invalidate()
    }

    static func runtime(for windowNumber: Int?) -> (any WorkspaceActionRuntime)? {
        resolveRuntime(for: windowNumber)
    }

    static func runtime(forWindowID windowID: String) -> (any WorkspaceActionRuntime)? {
        runtimesByWindowNumber.values.first(where: { $0.windowID == windowID })
    }

    static func runtime(forWorkspaceID workspaceID: String) -> (any WorkspaceActionRuntime)? {
        runtimesByWindowNumber.values.first(where: { $0.workspaceID == workspaceID })
    }

    /// The workspace window whose selected tab shows the file at `absolutePath`.
    static func runtime(showingDocumentAt absolutePath: String) -> (any WorkspaceActionRuntime)? {
        let wanted = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let candidates = runtimesByWindowNumber.values.filter { runtime in
            guard let path = runtime.currentDocumentSnapshot()?.absolutePath else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == wanted
        }
        if let lastActiveWindowNumber,
           let active = candidates.first(where: { $0.windowNumber == lastActiveWindowNumber }) {
            return active
        }
        return candidates.first
    }

    static func runtime(for resolvedTarget: ActionResolvedTarget) -> (any WorkspaceActionRuntime)? {
        if let windowID = resolvedTarget.windowID,
           let runtime = runtime(forWindowID: windowID) {
            return runtime
        }

        if let workspaceID = resolvedTarget.workspaceID,
           let runtime = runtime(forWorkspaceID: workspaceID) {
            return runtime
        }

        if let projectRootPath = resolvedTarget.projectRootPath {
            return resolveRuntime(projectRootPath: projectRootPath)
        }

        return resolveRuntime(for: nil)
    }

    static func resolveRuntime(target: ActionTarget) -> (any WorkspaceActionRuntime)? {
        if let windowSelector = target.window {
            switch windowSelector {
            case .frontmost:
                return resolveRuntime(for: nil)
            case .identifier(let identifier):
                return runtime(forWindowID: identifier)
            }
        }

        if let workspaceSelector = target.workspace {
            switch workspaceSelector {
            case .frontmost:
                return resolveRuntime(for: nil)
            case .identifier(let identifier):
                return runtime(forWorkspaceID: identifier)
            }
        }

        if let projectSelector = target.project {
            switch projectSelector {
            case .active:
                return resolveRuntime(for: nil)
            case .rootPath(let path):
                return resolveRuntime(projectRootPath: path)
            case .named(let name):
                return resolveRuntime(projectName: name)
            }
        }

        return resolveRuntime(for: nil)
    }

    @discardableResult
    static func performCloseCurrentTab(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.closeCurrentTab()
        return true
    }

    @discardableResult
    static func performNewTab(in windowNumber: Int?, trigger: String = "action") -> Bool {
        PerformanceDiagnostics.beginNewTab(
            trigger: trigger,
            requestedWindowNumber: windowNumber
        )
        guard let runtime = resolveRuntime(for: windowNumber) else {
            PerformanceDiagnostics.markPendingNewTab("router.runtimeMissing")
            return false
        }
        PerformanceDiagnostics.markPendingNewTab("router.runtimeResolved")
        runtime.newTab()
        PerformanceDiagnostics.markPendingNewTab("router.runtimeReturned")
        return true
    }

    @discardableResult
    static func performSplitHorizontally(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.splitHorizontally()
        return true
    }

    @discardableResult
    static func performSplitVertically(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.splitVertically()
        return true
    }

    @discardableResult
    static func performFocusPreviousSplit(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.focusPreviousSplit()
        return true
    }

    @discardableResult
    static func performFocusNextSplit(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.focusNextSplit()
        return true
    }

    @discardableResult
    static func performSelectTab(publicID: String, in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        return runtime.selectTab(publicID: publicID)
    }

    @discardableResult
    static func performSelectPreviousTab(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.selectPreviousTab()
        return true
    }

    @discardableResult
    static func performSelectNextTab(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.selectNextTab()
        return true
    }

    static func isSidebarVisible(in windowNumber: Int?) -> Bool {
        resolveRuntime(for: windowNumber)?.isSidebarVisible ?? false
    }

    @discardableResult
    static func performSetSidebarVisible(_ isVisible: Bool, in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.setSidebarVisible(isVisible)
        WorkspaceActionRouterState.shared.invalidate()
        return true
    }

    @discardableResult
    static func performToggleSidebar(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.setSidebarVisible(!runtime.isSidebarVisible)
        WorkspaceActionRouterState.shared.invalidate()
        return true
    }

    @discardableResult
    static func performCycleTabSwitcher(reverse: Bool, in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        return runtime.cycleTabSwitcher(reverse: reverse)
    }

    @discardableResult
    static func performCommitTabSwitcher(in windowNumber: Int?) -> Bool {
        let preferredRuntime = resolveRuntime(for: windowNumber)
        if preferredRuntime?.commitTabSwitcher() == true {
            return true
        }

        for runtime in runtimesInFrontToBackOrder()
        where runtime.windowNumber != preferredRuntime?.windowNumber {
            if runtime.commitTabSwitcher() {
                return true
            }
        }
        return false
    }

    @discardableResult
    static func performCancelTabSwitcher(in windowNumber: Int?) -> Bool {
        let preferredRuntime = resolveRuntime(for: windowNumber)
        if preferredRuntime?.cancelTabSwitcher() == true {
            return true
        }

        for runtime in runtimesInFrontToBackOrder()
        where runtime.windowNumber != preferredRuntime?.windowNumber {
            if runtime.cancelTabSwitcher() {
                return true
            }
        }
        return false
    }

    @discardableResult
    static func performDuplicateCurrentTab(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.duplicateCurrentTab()
        return true
    }

    @discardableResult
    static func performPresentNewNotePanel(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.presentNewNotePanel(inFolderRelativePath: nil)
        return true
    }

    @discardableResult
    static func performShowAllTabs(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.showAllTabs()
        return true
    }

    @discardableResult
    static func performRevealCurrentDocumentInFinder(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        return runtime.revealCurrentDocumentInFinder()
    }

    @discardableResult
    static func performCopyCurrentDocumentLink(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        return runtime.copyCurrentDocumentLink()
    }

    @discardableResult
    static func performDuplicateCurrentWorkspaceNote(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        return ((try? runtime.duplicateCurrentWorkspaceNote()) ?? nil) != nil
    }

    @discardableResult
    static func performReloadCurrentDocumentFromDisk(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        return runtime.reloadCurrentDocumentFromDisk()
    }

    @discardableResult
    static func performOpenNoteInNewTab(relativePath: String, in windowNumber: Int?) -> Bool {
        performOpenDocument(.workspaceNote(relativePath: relativePath), disposition: .newTab, in: windowNumber)
    }

    @discardableResult
    static func performOpenDocumentInNewTab(_ document: WorkspaceOpenedDocument, in windowNumber: Int?) -> Bool {
        performOpenDocument(document, disposition: .newTab, in: windowNumber)
    }

    @discardableResult
    static func performOpenDocument(_ document: WorkspaceOpenedDocument, disposition: WorkspaceActionOpenDisposition, in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        runtime.openDocument(document, disposition: disposition)
        return true
    }

    static func runtime(forProjectRootPath projectRootPath: String) -> (any WorkspaceActionRuntime)? {
        resolveRuntime(projectRootPath: projectRootPath)
    }

    static func runtimesFrontToBack() -> [any WorkspaceActionRuntime] {
        runtimesInFrontToBackOrder()
    }

    @discardableResult
    static func performExternalFileOpen(_ document: WorkspaceOpenedDocument) -> Bool {
        for runtime in runtimesInFrontToBackOrder() {
            if runtime.focusDocument(document) {
                return true
            }
        }

        guard let runtime = resolveTopmostWindowRuntime() ?? runtimesByWindowNumber.values.first else {
            return false
        }

        runtime.openDocument(document, disposition: .newTab)
        _ = runtime.focusDocument(document)
        return true
    }

    static func closeUnrequestedWorkspaceWindows() {
        let targetWindows = NSApp.windows.filter { window in
            guard unrequestedWorkspaceWindowNumbers.contains(window.windowNumber),
                  runtimesByWindowNumber[window.windowNumber] == nil,
                  !(window is NSPanel) else {
                return false
            }

            return true
        }

        guard !targetWindows.isEmpty else {
            return
        }

        for window in targetWindows {
            window.orderOut(nil)
            window.close()
            unrequestedWorkspaceWindowNumbers.remove(window.windowNumber)
        }
    }

    @discardableResult
    static func performOpenDocument(_ document: WorkspaceOpenedDocument, disposition: WorkspaceActionOpenDisposition, inProjectRootPath projectRootPath: String) -> Bool {
        guard let runtime = resolveRuntime(projectRootPath: projectRootPath) else { return false }
        runtime.openDocument(document, disposition: disposition)
        return true
    }

    static func currentDocumentSnapshot(in windowNumber: Int?) -> WorkspaceActionDocumentSnapshot? {
        resolveRuntime(for: windowNumber)?.currentDocumentSnapshot()
    }

    static func currentEditorCommandTarget(in windowNumber: Int?) -> WorkspaceEditorCommandTargetSnapshot? {
        resolveRuntime(for: windowNumber)?.currentEditorCommandTargetSnapshot()
    }

    @discardableResult
    static func performReplaceCurrentEditorSelection(with text: String, in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        return runtime.replaceCurrentEditorSelection(with: text)
    }

    @discardableResult
    static func performToggleCurrentEditorSelectionHighlight(in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        return runtime.toggleCurrentEditorSelectionHighlight()
    }

    @discardableResult
    static func performCurrentEditorBridgeCommand(_ command: String, in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber) else { return false }
        return runtime.performCurrentEditorBridgeCommand(command)
    }

    @discardableResult
    static func performInsertMarkdownTable(rows: Int = 2, columns: Int = 2, in windowNumber: Int?) -> Bool {
        guard let runtime = resolveRuntime(for: windowNumber),
              MarkdownTableFactory.canInsertTable(in: runtime.currentEditorCommandTargetSnapshot()) else {
            return false
        }

        let table = MarkdownTableFactory.makeMarkdownTable(rows: rows, columns: columns)
        return runtime.replaceCurrentEditorSelection(with: table)
    }

    private static func resolveRuntime(for windowNumber: Int?) -> (any WorkspaceActionRuntime)? {
        if let windowNumber,
           NSApp.windows.contains(where: {
               $0.windowNumber == windowNumber && WindowFocusCoordinator.shared.kind(of: $0) == .scratchpad
           }) { return nil }
        if windowNumber == nil, WindowFocusCoordinator.shared.kind(of: NSApp.keyWindow) == .scratchpad {
            return nil
        }
        if let windowNumber,
           let runtime = runtimesByWindowNumber[windowNumber] {
            return runtime
        }

        if let keyWindowNumber = NSApp.keyWindow?.windowNumber,
           let runtime = runtimesByWindowNumber[keyWindowNumber] {
            return runtime
        }

        if let mainWindowNumber = NSApp.mainWindow?.windowNumber,
           let runtime = runtimesByWindowNumber[mainWindowNumber] {
            return runtime
        }

        if let lastActiveWindowNumber,
           let runtime = runtimesByWindowNumber[lastActiveWindowNumber] {
            return runtime
        }

        if let runtime = resolveTopmostWindowRuntime() {
            return runtime
        }

        return runtimesByWindowNumber.values.first
    }

    private static func resolveRuntime(projectRootPath: String) -> (any WorkspaceActionRuntime)? {
        let normalizedPath = URL(fileURLWithPath: projectRootPath, isDirectory: true).standardizedFileURL.path
        if let frontmost = resolveRuntime(for: nil),
           frontmost.projectRootPath == normalizedPath {
            return frontmost
        }

        return runtimesByWindowNumber.values.first(where: { $0.projectRootPath == normalizedPath })
    }

    private static func resolveRuntime(projectName: String) -> (any WorkspaceActionRuntime)? {
        let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let appConfig = NVModernConfigLoader.loadAppConfig()
        guard let project = appConfig.projects.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            return nil
        }

        return resolveRuntime(projectRootPath: project.id)
    }

    private static func resolveTopmostWindowRuntime() -> (any WorkspaceActionRuntime)? {
        for window in NSApp.orderedWindows {
            guard let runtime = runtimesByWindowNumber[window.windowNumber] else { continue }
            return runtime
        }

        return nil
    }

    private static func runtimesInFrontToBackOrder() -> [any WorkspaceActionRuntime] {
        var seenWindowNumbers = Set<Int>()
        var orderedRuntimes: [any WorkspaceActionRuntime] = []

        for window in NSApp.orderedWindows {
            guard let runtime = runtimesByWindowNumber[window.windowNumber] else { continue }
            seenWindowNumbers.insert(window.windowNumber)
            orderedRuntimes.append(runtime)
        }

        for (windowNumber, runtime) in runtimesByWindowNumber where !seenWindowNumbers.contains(windowNumber) {
            orderedRuntimes.append(runtime)
        }

        return orderedRuntimes
    }
}
