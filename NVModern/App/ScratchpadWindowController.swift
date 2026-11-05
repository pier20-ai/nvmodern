import AppKit
import SwiftUI
import CoreServices

/// Owns document windows independently of workspace tabs and plugin sessions.
@MainActor
final class ScratchpadWindowController {
    private var windows: [URL: ScratchpadWindow] = [:]

    func open(_ request: PluginWindowRequest) throws {
        let url = request.fileURL.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = windows[url] {
            if request.toggle {
                existing.window?.performClose(nil)
                return
            }
            existing.apply(request)
            existing.applyPosition(request.position)
            existing.present()
            return
        }
        let controller = try ScratchpadWindow(fileURL: url, request: request)
        controller.onClose = { [weak self] in self?.windows.removeValue(forKey: url) }
        windows[url] = controller
        controller.present()
    }

    func prepareForTermination() -> Bool {
        for controller in windows.values {
            guard controller.prepareToClose() else { return false }
        }
        return true
    }
}

@MainActor
private final class ScratchpadWindow: NSWindowController, NSWindowDelegate {
    private let editor = QuickCaptureEditorController()
    private let fileURL: URL
    private var watcher: ScratchpadFileWatcher?
    var onClose: (() -> Void)?

    init(fileURL: URL, request: PluginWindowRequest) throws {
        self.fileURL = fileURL
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: request.width, height: request.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .textBackgroundColor
        window.title = fileURL.lastPathComponent
        window.representedURL = fileURL
        window.contentMinSize = NSSize(width: 240, height: 160)
        WindowFocusCoordinator.shared.registerWindow(window, kind: .scratchpad, identifier: "scratchpad:\(fileURL.path)")
        editor.onScratchpadBackgroundChange = { [weak window] color in
            window?.backgroundColor = color
        }
        do {
            try editor.openScratchpad(fileURL: fileURL, cursorPlacement: request.cursor.rawValue)
        } catch {
            WindowFocusCoordinator.shared.unregisterWindow(window)
            window.delegate = nil
            window.close()
            throw error
        }
        window.contentViewController = NSHostingController(rootView: QuickCaptureEditorView(controller: editor))
        apply(request)
        window.center()
        let frameName = "nvModern.scratchpad.\(fileURL.path)"
        _ = window.setFrameUsingName(frameName)
        _ = window.setFrameAutosaveName(frameName)
        // A remembered display may no longer be connected.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.center()
        }
        applyPosition(request.position)
        watcher = ScratchpadFileWatcher(directoryURL: fileURL.deletingLastPathComponent()) { [weak self] in
            self?.editor.refreshScratchpadFromDisk()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ request: PluginWindowRequest) {
        window?.level = request.alwaysOnTop ? .floating : .normal
        window?.collectionBehavior = request.allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        window?.hidesOnDeactivate = false
    }

    func present() {
        guard let window else { return }
        editor.refreshScratchpadFromDisk()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        editor.requestFocus()
    }

    func applyPosition(_ position: PluginWindowRequest.Position?) {
        guard let position, let window,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        let origin: NSPoint
        switch position {
        case .right:
            origin = NSPoint(x: visible.maxX - frame.width, y: visible.maxY - frame.height)
        case let .coordinates(x, y):
            origin = NSPoint(x: visible.minX + x, y: visible.maxY - frame.height - y)
        }
        window.setFrameOrigin(NSPoint(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
        ))
    }

    func prepareToClose() -> Bool {
        if !editor.flushScratchpadSave() {
            present()
            guard editor.hasScratchpadConflict else {
                showSaveFailure()
                present()
                return false
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(fileURL.lastPathComponent)” changed outside this window."
            alert.informativeText = "Your edits are still here. Choose which version to keep before closing. Reload from Disk discards your edits; Overwrite with My Changes replaces the file on disk."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Reload from Disk").hasDestructiveAction = true
            alert.addButton(withTitle: "Overwrite with My Changes").hasDestructiveAction = true
            let response = alert.runModal()
            guard response == .alertSecondButtonReturn || response == .alertThirdButtonReturn else {
                present()
                return false
            }
            guard editor.resolveScratchpadConflict(reloadFromDisk: response == .alertSecondButtonReturn) else {
                showSaveFailure()
                present()
                return false
            }
        }
        if let window { window.saveFrame(usingName: window.frameAutosaveName) }
        return true
    }

    private func showSaveFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t save “\(fileURL.lastPathComponent)”."
        alert.informativeText = (editor.scratchpadSaveErrorMessage ?? "The file couldn’t be written.")
            + " Your edits are still in the window."
        alert.addButton(withTitle: "Keep Editing")
        alert.runModal()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { prepareToClose() }

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        if let window { WindowFocusCoordinator.shared.unregisterWindow(window) }
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window else { return }
        WindowFocusCoordinator.shared.notifyWindowDidBecomeKey(window)
        editor.refreshScratchpadFromDisk()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window else { return }
        WindowFocusCoordinator.shared.notifyWindowDidResignKey(window)
        _ = editor.flushScratchpadSave()
    }
}

/// Watch the parent directory at file granularity so atomic replacement and
/// in-place writes both reach the editor. Its baseline filters unrelated events.
private final class ScratchpadFileWatcher {
    private var stream: FSEventStreamRef?
    private let changed: @MainActor () -> Void

    init(directoryURL: URL, changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ScratchpadFileWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.changed() }
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
            [directoryURL.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit { stop() }
}
