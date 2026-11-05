import Foundation

/// Records a palette lifecycle breadcrumb. Debug builds only.
///
/// Goes to stderr for a terminal-launched build, and to `LocalDiagnosticsCenter`
/// so the palette can also be debugged from a normally launched app bundle,
/// where stderr goes nowhere the user can reach. That combination is what
/// diagnosed the macOS 26 compositing failure, so it is worth keeping.
///
/// It is compiled out of Release because the palette is chatty — row hover and
/// selection fire on every mouse move, over a hundred events per second while
/// the pointer travels the result list — and that is real breadcrumb churn and
/// disk traffic to impose on a shipped build. `make` builds Debug, so anyone
/// building from source still gets it.
///
/// Call sites use a `namespace.event key=value …` shape; the leading token
/// becomes the breadcrumb event and the remainder is carried verbatim as
/// `detail` rather than parsed, so values containing spaces survive intact.
func paletteDebugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    let text = message()
    let line = "[NVModern][PaletteDebug] \(text)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }

    let event = text.prefix { !$0.isWhitespace }
    let detail = text.dropFirst(event.count).trimmingCharacters(in: .whitespaces)
    LocalDiagnosticsCenter.shared.log(
        category: "palette",
        event: event.isEmpty ? "message" : String(event),
        metadata: detail.isEmpty ? [:] : ["detail": detail]
    )
    #endif
}

extension Notification.Name {
    /// Asks the focused workspace tab to open the palette on a given preset.
    static let palettePresetOpenRequested = Notification.Name("nvmodern.palettePresetOpenRequested")
}

enum PaletteOpenNotification {
    static let presetKey = "preset"
    static let windowNumberKey = "windowNumber"
}
