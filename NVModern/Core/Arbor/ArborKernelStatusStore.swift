import Combine
import Foundation

/// Observable summary of the Arbor kernel's most recent exchange.
///
/// The kernel can fail in ways nothing on screen reflects: it can time out and
/// restart, reject a producer run for a stale revision, or be missing Racket
/// entirely. Each of those leaves the outline looking merely inert — an effect
/// runs, consent is granted, and no result appears — with the reason visible
/// only in the diagnostics file. This surfaces it.
@MainActor
final class ArborKernelStatusStore: ObservableObject {
    static let shared = ArborKernelStatusStore()

    /// One short line for the document inspector, e.g. "Arbor: ok" or
    /// "Arbor: ARBOR3302 producer/run".
    @Published private(set) var summary: String = "Arbor: idle"

    private init() {}

    func record(operation: String?, outcome: String, diagnostics: [ArborKernelDiagnostic]) {
        // The first error diagnostic explains the failure; the rest are usually
        // consequences of it.
        if let failure = diagnostics.first(where: { $0.severity == "error" }) {
            summary = "Arbor: \(failure.code) — \(failure.message)"
            return
        }
        if outcome == "error" {
            summary = "Arbor: error\(operation.map { " (\($0))" } ?? "")"
            return
        }
        summary = "Arbor: ok\(operation.map { " (\($0))" } ?? "")"
    }

    func recordUnavailable(_ reason: String) {
        summary = "Arbor: \(reason)"
    }
}
