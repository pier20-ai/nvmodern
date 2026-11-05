import CoreServices
import Foundation

/// Watches the plugins folder with FSEvents at file granularity, so an editor
/// that saves in place (no rename) still triggers a reload — a directory-level
/// dispatch source only sees entries appear and disappear.
final class PluginDirectoryWatcher {
    private static let latency: CFTimeInterval = 0.3

    private let changedHandler: () -> Void
    private var stream: FSEventStreamRef?
    private var watchedPath: String?

    init(changedHandler: @escaping () -> Void) {
        self.changedHandler = changedHandler
    }

    deinit {
        stop()
    }

    /// Starts (or re-targets) watching. Nil stops. The same path is a no-op.
    func watch(directoryURL: URL?) {
        let path = directoryURL?.standardizedFileURL.path
        guard path != watchedPath else { return }
        stop()
        guard let path else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<PluginDirectoryWatcher>.fromOpaque(info).takeUnretainedValue().changedHandler()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        watchedPath = path
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        watchedPath = nil
    }
}
