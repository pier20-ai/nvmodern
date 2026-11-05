import AppKit
import Foundation

struct ActionKeyStroke: Hashable {
    let key: Key
    let modifiers: NSEvent.ModifierFlags

    enum Key: Hashable {
        case character(String)
        case keyCode(UInt16)
    }

    static func == (lhs: ActionKeyStroke, rhs: ActionKeyStroke) -> Bool {
        lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }
}

@MainActor
final class ActionKeybindingManager {
    private var bindingsByStroke: [ActionKeyStroke: [ActionKeybindingDefinition]] = [:]
    private(set) var invalidBindings: [String] = []

    func updateBindings(_ bindings: [ActionKeybindingDefinition]) {
        bindingsByStroke.removeAll()
        invalidBindings.removeAll()

        for binding in bindings {
            do {
                let stroke = try parseKeystroke(binding.keystroke)
                bindingsByStroke[stroke, default: []].append(binding)
            } catch {
                invalidBindings.append("\(binding.id): \(error.localizedDescription)")
            }
        }
    }

    func matchingBinding(for event: NSEvent) -> ActionKeybindingDefinition? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if let key = normalizedCharacter(from: event) {
            let stroke = ActionKeyStroke(key: .character(key), modifiers: modifiers)
            if let binding = bindingsByStroke[stroke]?.first {
                return binding
            }
        }

        let keyCodeStroke = ActionKeyStroke(key: .keyCode(event.keyCode), modifiers: modifiers)
        return bindingsByStroke[keyCodeStroke]?.first
    }

    func parseKeystroke(_ rawValue: String) throws -> ActionKeyStroke {
        let pieces = rawValue
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard let last = pieces.last else {
            throw ActionError.invalidArguments("Keybinding is empty", details: ["keystroke": .string(rawValue)])
        }

        var modifiers: NSEvent.ModifierFlags = []
        for piece in pieces.dropLast() {
            switch piece {
            case "cmd", "command":
                modifiers.insert(.command)
            case "shift":
                modifiers.insert(.shift)
            case "alt", "opt", "option":
                modifiers.insert(.option)
            case "ctrl", "control":
                modifiers.insert(.control)
            default:
                throw ActionError.invalidArguments(
                    "Unsupported modifier in keybinding",
                    details: [
                        "keystroke": .string(rawValue),
                        "modifier": .string(piece)
                    ]
                )
            }
        }

        if let keyCode = namedKeyCode(for: last) {
            return ActionKeyStroke(key: .keyCode(keyCode), modifiers: modifiers)
        }

        guard last.count == 1 else {
            throw ActionError.invalidArguments(
                "Keybinding must end in a single character or a supported named key",
                details: ["keystroke": .string(rawValue)]
            )
        }

        return ActionKeyStroke(key: .character(last), modifiers: modifiers)
    }

    private func normalizedCharacter(from event: NSEvent) -> String? {
        guard let raw = event.charactersIgnoringModifiers?.lowercased(), !raw.isEmpty else {
            return nil
        }

        switch raw {
        case "\r", "\n":
            return "return"
        case "\u{1b}":
            return "escape"
        case "\t":
            return "tab"
        case " ":
            return "space"
        default:
            return raw.count == 1 ? raw : nil
        }
    }

    private func namedKeyCode(for name: String) -> UInt16? {
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
}
