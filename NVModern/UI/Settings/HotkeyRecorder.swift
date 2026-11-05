import AppKit
import SwiftUI

/// A SwiftUI hotkey-recording control. Click to start recording, press a shortcut to
/// commit, press Escape to cancel, press Delete with no modifiers to clear.
///
/// The binding stores the normalized form (`cmd+shift+d`); the UI renders the
/// macOS-glyph form (`⌘⇧D`). Combos without at least one of cmd/ctrl/opt are
/// rejected (shift-only and bare keys would be too easy to fat-finger).
struct HotkeyRecorder: View {
    @Binding var keystroke: String?
    var width: CGFloat = 96

    @StateObject private var coordinator = HotkeyRecorderCoordinator()
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            if hasShortcut && !coordinator.isRecording {
                Button { keystroke = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear shortcut")
                .accessibilityLabel("Clear shortcut")
            }
            field
        }
        .onDisappear { coordinator.stop() }
    }

    private var field: some View {
        Button(action: toggle) {
            Text(displayText)
                .foregroundStyle(textStyle)
                .monospacedDigit()
                .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minWidth: width, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(coordinator.isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(coordinator.isRecording ? "Type a shortcut. Esc cancels, Delete clears." : "Click to record a shortcut")
        .accessibilityLabel(hasShortcut ? "Shortcut \(displayText)" : "Record shortcut")
    }

    /// Empty rows stay quiet until hovered, so a long list doesn't read as a wall of buttons.
    private var fill: Color {
        if coordinator.isRecording { return Color.accentColor.opacity(0.12) }
        return hasShortcut || isHovered ? Color.primary.opacity(0.06) : .clear
    }

    private var hasShortcut: Bool { !(keystroke ?? "").isEmpty }

    private var textStyle: AnyShapeStyle {
        if coordinator.isRecording { return AnyShapeStyle(Color.accentColor) }
        return hasShortcut ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
    }

    private var displayText: String {
        if coordinator.isRecording { return "Type Shortcut" }
        if let keystroke, !keystroke.isEmpty { return Keystroke.symbolize(keystroke) }
        return "Add Shortcut"
    }

    private func toggle() {
        if coordinator.isRecording {
            coordinator.stop()
        } else {
            coordinator.start { captured in
                keystroke = captured
            }
        }
    }
}

/// Owns the NSEvent monitor that intercepts key presses while recording. Lives as
/// long as the recorder view so cleanup is deterministic.
@MainActor
final class HotkeyRecorderCoordinator: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?

    func start(_ onCapture: @escaping (String?) -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, onCapture: onCapture)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    private func handle(
        _ event: NSEvent,
        onCapture: @escaping (String?) -> Void
    ) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])

        // Escape with no modifiers → cancel.
        if event.keyCode == 0x35, mods.isEmpty {
            stop()
            return nil
        }

        // Delete with no modifiers → explicit clear.
        if event.keyCode == 0x33, mods.isEmpty {
            onCapture(nil)
            stop()
            return nil
        }

        guard let keyName = keyName(forEvent: event) else { return nil }
        if let captured = Keystroke.fromComponents(
            commandKey: event.modifierFlags.contains(.command),
            controlKey: event.modifierFlags.contains(.control),
            optionKey: event.modifierFlags.contains(.option),
            shiftKey: event.modifierFlags.contains(.shift),
            keyName: keyName
        ) {
            onCapture(captured)
            stop()
        }
        // Consume the event either way so it doesn't fire menus while recording.
        return nil
    }

    private func keyName(forEvent event: NSEvent) -> String? {
        switch event.keyCode {
        case 0x35: return "escape"
        case 0x33: return "delete"
        case 0x31: return "space"
        case 0x30: return "tab"
        case 0x24: return "return"
        case 0x4C: return "return"  // numeric enter
        case 0x7B: return "left"
        case 0x7C: return "right"
        case 0x7D: return "down"
        case 0x7E: return "up"
        case 0x7A: return "f1"
        case 0x78: return "f2"
        case 0x63: return "f3"
        case 0x76: return "f4"
        case 0x60: return "f5"
        case 0x61: return "f6"
        case 0x62: return "f7"
        case 0x64: return "f8"
        case 0x65: return "f9"
        case 0x6D: return "f10"
        case 0x67: return "f11"
        case 0x6F: return "f12"
        default: break
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              !chars.isEmpty
        else { return nil }
        return chars
    }
}
