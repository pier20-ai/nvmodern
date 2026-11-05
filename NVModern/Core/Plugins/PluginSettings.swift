import Foundation

struct NVModernPluginsDraft: Codable, Equatable {
    var disabled: [String] = []
    var settings: [String: [String: ActionValue]] = [:]

    init(disabled: [String] = [], settings: [String: [String: ActionValue]] = [:]) {
        self.disabled = disabled
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        disabled = try values.decodeIfPresent([String].self, forKey: .disabled) ?? []
        settings = try values.decodeIfPresent([String: [String: ActionValue]].self, forKey: .settings) ?? [:]
    }

    var isEmpty: Bool { disabled.isEmpty && settings.isEmpty }
}

struct PluginSettingsField: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case text, bool, number, choice, folder }
    let key: String
    let title: String
    let kind: Kind
    let defaultValue: ActionValue
    var options: [String] = []
    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, title, kind, options
        case defaultValue = "default"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        title = try values.decode(String.self, forKey: .title)
        kind = try values.decode(Kind.self, forKey: .kind)
        defaultValue = try values.decode(ActionValue.self, forKey: .defaultValue)
        options = try values.decodeIfPresent([String].self, forKey: .options) ?? []
    }

    func accepts(_ value: ActionValue) -> Bool {
        switch kind {
        case .bool: return value.boolValue != nil
        case .number: return value.doubleValue?.isFinite == true
        case .text: return value.stringValue != nil
        case .choice: return value.stringValue.map(options.contains) ?? false
        case .folder:
            guard let path = value.stringValue else { return false }
            return !path.hasPrefix("/") && !path.hasPrefix("~") && !path.split(separator: "/").contains("..")
        }
    }
}

struct PluginInfo: Codable, Equatable, Identifiable {
    enum State: String, Codable { case running, disabled, failed }
    let name: String
    let path: String
    let isBuiltin: Bool
    var state: State
    var actionMethods: [String] = []
    var loadError: String?
    var settingsSchema: [PluginSettingsField] = []
    var id: String { path }
    var isDisabled: Bool { state == .disabled }
}
