import Combine
import Foundation
import Sparkle
import SwiftUI

/// Thin wrapper over Sparkle's standard updater.
///
/// Updates come from GitHub Releases: `SUFeedURL` points at the `appcast.xml`
/// asset of the latest release, and Sparkle verifies every download against
/// `SUPublicEDKey` before installing it. The updater only starts when the build
/// carries a public key, so source builds and forks never contact the feed or
/// show update UI. See `docs/releasing.md`.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController?
    private var cancellables: Set<AnyCancellable> = []

    /// True when this build is configured to receive updates.
    var isEnabled: Bool { controller != nil }
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false

    /// Test seam: pass `bundle` to exercise the configuration check.
    init(bundle: Bundle = .main, startUpdater: Bool = true) {
        guard Self.isConfigured(bundle: bundle), startUpdater else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.automaticallyChecks = $0 }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    /// An updater is configured only with both a feed URL and a non-empty
    /// EdDSA public key.
    nonisolated static func isConfigured(bundle: Bundle) -> Bool {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return !value("SUFeedURL").isEmpty && !value("SUPublicEDKey").isEmpty
    }
}

/// App-menu item. Hidden entirely in builds without an update feed.
struct CheckForUpdatesCommand: Commands {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isEnabled {
                Button("Check for Updates\u{2026}") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
