import AppKit
import SwiftUI

/// The palette's input field — the sentence's open slot.
///
/// An `NSTextField` rather than SwiftUI's `TextField` because the palette needs
/// keys the field editor would otherwise swallow — Return, arrows, Tab, Space,
/// Backspace over an empty query — and a local key monitor is the only reliable
/// way to see them before the editor does.
struct OmniboxTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var autoFocus: Bool = true
    var onSubmit: () -> Void = {}
    var onCommandSubmit: () -> Void = {}
    /// Shift-Return. Returns true when it was handled (a note row pushed to
    /// the side stack); otherwise it acts as Return.
    var onShiftSubmit: () -> Bool = { false }
    var onEscape: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    /// Tab, and `Cmd+K` while the palette is open: commit this slot and step
    /// into the selection. Returns true when there was something to step into.
    var onStepInto: () -> Bool = { false }
    /// Backspace over an empty field. Returns true when a frame was popped.
    var onBackspaceWhenEmpty: () -> Bool = { false }
    /// Space in multi-select mode. Returns true when it marked a row rather
    /// than typing a space.
    var onSpace: () -> Bool = { false }
    var onToggleMode: (PaletteMode) -> Void = { _ in }
    var onPresetShortcut: (PalettePreset) -> Void = { _ in }
    var allowsPresetShortcuts: Bool = true

    func makeNSView(context: Context) -> OmniboxNSTextField {
        let field = OmniboxNSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.font = NSFont.systemFont(ofSize: DesignTokens.Typography.inputPointSize)
        field.textColor = NSColor.labelColor
        field.stringValue = text
        field.placeholderAttributedString = Self.placeholderString(placeholder)
        apply(to: field)
        field.wantsFocus = autoFocus
        return field
    }

    func updateNSView(_ nsView: OmniboxNSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
            // A programmatic rewrite of the slot (a preset swap carrying the
            // typed text) leaves the caret where the user expects to keep
            // typing.
            if let editor = nsView.currentEditor() {
                editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
        }
        nsView.placeholderAttributedString = Self.placeholderString(placeholder)
        apply(to: nsView)
        if autoFocus && nsView.window?.firstResponder !== nsView.currentEditor() {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }

    private func apply(to field: OmniboxNSTextField) {
        field.onSubmit = onSubmit
        field.onCommandSubmit = onCommandSubmit
        field.onShiftSubmit = onShiftSubmit
        field.onEscape = onEscape
        field.onMoveUp = onMoveUp
        field.onMoveDown = onMoveDown
        field.onStepInto = onStepInto
        field.onBackspaceWhenEmpty = onBackspaceWhenEmpty
        field.onSpace = onSpace
        field.onToggleMode = onToggleMode
        field.onPresetShortcut = onPresetShortcut
        field.allowsPresetShortcuts = allowsPresetShortcuts
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private static func placeholderString(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: DesignTokens.Typography.inputPointSize),
            ]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmniboxTextField

        init(_ parent: OmniboxTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField, parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab always belongs to the palette: it is the step key, and a
                // no-op step must not move focus out of the field.
                _ = parent.onStepInto()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty else { return false }
                return parent.onBackspaceWhenEmpty()
            default:
                return false
            }
        }
    }
}

final class OmniboxNSTextField: NSTextField {
    var onSubmit: (() -> Void)?
    var onCommandSubmit: (() -> Void)?
    var onShiftSubmit: (() -> Bool)?
    var onEscape: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onStepInto: (() -> Bool)?
    var onBackspaceWhenEmpty: (() -> Bool)?
    var onSpace: (() -> Bool)?
    var onToggleMode: ((PaletteMode) -> Void)?
    var onPresetShortcut: ((PalettePreset) -> Void)?
    var allowsPresetShortcuts = true
    var wantsFocus: Bool = false

    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installKeyMonitorIfNeeded()
            if wantsFocus {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.window?.makeFirstResponder(self)
                }
            }
        } else {
            removeKeyMonitor()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            installKeyMonitorIfNeeded()
            // A text field selects its whole value on focus, which would let
            // the first keystroke replace a preset's prefix (`>` for actions).
            // Put the caret at the end instead.
            currentEditor()?.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
        }
        return became
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only consume events targeted at the same window that hosts this
            // field; otherwise let the app-wide monitor handle them.
            guard let self,
                  let hostWindow = self.window,
                  event.window === hostWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let meaningfulFlags = flags.subtracting([.function, .numericPad])
            if meaningfulFlags.isEmpty {
                if event.keyCode == 36 || event.keyCode == 76 {
                    paletteDebugLog("textField key submit keyCode=\(event.keyCode)")
                    self.onSubmit?()
                    return nil
                }
                if event.keyCode == 126 {
                    paletteDebugLog("textField key up")
                    self.onMoveUp?()
                    return nil
                }
                if event.keyCode == 125 {
                    paletteDebugLog("textField key down")
                    self.onMoveDown?()
                    return nil
                }
                if event.keyCode == 48 {
                    paletteDebugLog("textField key tab step")
                    _ = self.onStepInto?()
                    return nil
                }
                // Space marks the selected note in multi-select; everywhere
                // else it is an ordinary character.
                if event.keyCode == 49, self.onSpace?() == true {
                    paletteDebugLog("textField key space mark")
                    return nil
                }
                if event.keyCode == 51,
                   self.stringValue.isEmpty,
                   self.onBackspaceWhenEmpty?() == true {
                    paletteDebugLog("textField key backspace pop")
                    return nil
                }
            }

            if meaningfulFlags == [.shift], event.keyCode == 36 || event.keyCode == 76 {
                paletteDebugLog("textField key shiftSubmit keyCode=\(event.keyCode)")
                if self.onShiftSubmit?() != true {
                    self.onSubmit?()
                }
                return nil
            }

            guard flags.contains(.command) else { return event }

            if event.keyCode == 36 || event.keyCode == 76 {
                paletteDebugLog("textField key commandSubmit keyCode=\(event.keyCode)")
                self.onCommandSubmit?()
                return nil
            }

            let shift = flags.contains(.shift)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if !shift, let mode = Self.mode(forKey: key) {
                paletteDebugLog("textField key mode \(mode.rawValue)")
                self.onToggleMode?(mode)
                return nil
            }

            // Cmd+K inside the palette returns to the root frame. On a lone
            // root it is swallowed: it never closes, and Tab is the one key
            // that steps into a row.
            if !shift, key == "k" {
                paletteDebugLog("textField key commandK root")
                self.onPresetShortcut?(.root)
                return nil
            }

            guard self.allowsPresetShortcuts else { return event }

            guard let preset = Self.preset(forKey: key, shift: shift) else { return event }
            paletteDebugLog("textField key preset \(preset.debugLabel)")
            self.onPresetShortcut?(preset)
            return nil
        }
    }

    private static func mode(forKey key: String) -> PaletteMode? {
        switch key {
        case "p": return .preview
        case "m": return .multiSelect
        case ".": return .pin
        default: return nil
        }
    }

    private static func preset(forKey key: String, shift: Bool) -> PalettePreset? {
        switch (key, shift) {
        case ("k", true): return .actions
        case ("f", true): return .contentSearch(initialQuery: "")
        case ("o", true): return .outline
        case ("n", false): return .capture
        default: return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
