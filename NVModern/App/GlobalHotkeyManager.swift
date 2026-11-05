import AppKit
import Carbon

@MainActor
final class GlobalHotkeyManager {
    private static let hotKeySignature: OSType = 0x4E565143 // NVQC

    private let keybindingParser = ActionKeybindingManager()
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var callbacks: [UInt32: () -> Void] = [:]
    private var nextHotKeyID: UInt32 = 1

    func register(keystroke: String, callback: @escaping () -> Void) throws {
        let stroke = try keybindingParser.parseKeystroke(keystroke)
        let keyCode = try carbonKeyCode(for: stroke.key, keystroke: keystroke)
        let modifiers = carbonModifiers(from: stroke.modifiers)

        try installEventHandlerIfNeeded()

        let id = nextHotKeyID
        nextHotKeyID &+= 1
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            throw NSError(
                domain: "NVModern.GlobalHotkey",
                code: Int(registerStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to register global hotkey '\(keystroke)' (\(registerStatus))"]
            )
        }

        guard let hotKeyRef else {
            throw NSError(
                domain: "NVModern.GlobalHotkey",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Global hotkey '\(keystroke)' registered without a usable reference"]
            )
        }
        hotKeyRefs[id] = hotKeyRef
        callbacks[id] = callback
    }

    func unregister() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        callbacks.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        nextHotKeyID = 1
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handleHotKeyEvent(event)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            throw NSError(
                domain: "NVModern.GlobalHotkey",
                code: Int(handlerStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to install global hotkey handler (\(handlerStatus))"]
            )
        }
    }

    private func handleHotKeyEvent(_ event: EventRef?) {
        guard let event else { return }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr,
              hotKeyID.signature == Self.hotKeySignature else {
            return
        }

        callbacks[hotKeyID.id]?()
    }

    private func carbonModifiers(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    private func carbonKeyCode(for key: ActionKeyStroke.Key, keystroke: String) throws -> UInt16 {
        switch key {
        case .keyCode(let keyCode):
            return keyCode
        case .character(let character):
            if let keyCode = Self.namedKeyCode(for: character) ?? Self.ansiKeyCode(for: character) {
                return keyCode
            }

            throw NSError(
                domain: "NVModern.GlobalHotkey",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported global hotkey '\(keystroke)'"]
            )
        }
    }

    private static func namedKeyCode(for name: String) -> UInt16? {
        switch name {
        case "tab": return 48
        case "space": return 49
        case "return", "enter": return 36
        case "escape", "esc": return 53
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        case "[", "leftbracket": return 33
        case "]", "rightbracket": return 30
        default: return nil
        }
    }

    private static func ansiKeyCode(for character: String) -> UInt16? {
        switch character {
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "=": return 24
        case "9": return 25
        case "7": return 26
        case "-": return 27
        case "8": return 28
        case "0": return 29
        case "o": return 31
        case "u": return 32
        case "i": return 34
        case "p": return 35
        case "l": return 37
        case "j": return 38
        case "'": return 39
        case "k": return 40
        case ";": return 41
        case "\\": return 42
        case ",": return 43
        case "/": return 44
        case "n": return 45
        case "m": return 46
        case ".": return 47
        case "`": return 50
        default: return nil
        }
    }
}
