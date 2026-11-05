import Foundation

/// Watches a themes directory and reports changes so a theme file edit can be
/// picked up without restarting or touching `config.toml`.
///
/// DispatchSource file-system sources need a re-arm after directory events
/// (the descriptor can go stale when the directory is replaced), so every event
/// tears the source down and re-arms after the debounced handler runs. Re-arming
/// opens a fresh descriptor, which also recovers from the directory being
/// recreated between events.
final class UserEditorThemeDirectoryWatcher {
    private static let debounceInterval: TimeInterval = 0.3

    private let changedHandler: () -> Void
    private let debounceQueue = DispatchQueue.main

    private var source: DispatchSourceFileSystemObject?
    private var watchedDirectoryURL: URL?
    private var debounceWorkItem: DispatchWorkItem?

    init(changedHandler: @escaping () -> Void) {
        self.changedHandler = changedHandler
    }

    deinit {
        stop()
    }

    /// Starts (or re-targets) watching. Passing nil stops watching. Repeated
    /// calls with the same directory are no-ops.
    func watch(directoryURL: URL?) {
        guard let directoryURL else {
            stop()
            return
        }
        guard directoryURL.standardizedFileURL.path != watchedDirectoryURL?.standardizedFileURL.path else {
            return
        }
        arm(for: directoryURL)
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        teardownSource()
        watchedDirectoryURL = nil
    }

    // MARK: - Private

    private func arm(for directoryURL: URL) {
        teardownSource()
        // A pending re-arm from an old directory must not clobber the new one.
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        watchedDirectoryURL = directoryURL

        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The directory may not exist yet; a later config change or theme
            // save re-enters watch(directoryURL:) and retries.
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .link],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.handleDirectoryEvent()
        }
        // Close the descriptor this source was created with — the handler runs
        // asynchronously and must not close a descriptor a newer arm() opened.
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    private func teardownSource() {
        source?.cancel()
        source = nil
    }

    private func handleDirectoryEvent() {
        // Events can arrive in bursts (editors often write via temp file +
        // rename). Cancel the source first so the debounce window stays quiet.
        teardownSource()

        let directoryURL = watchedDirectoryURL
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changedHandler()
            if let directoryURL = self.watchedDirectoryURL {
                self.arm(for: directoryURL)
            }
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = workItem
        debounceQueue.asyncAfter(
            deadline: .now() + Self.debounceInterval,
            execute: workItem
        )
    }
}
