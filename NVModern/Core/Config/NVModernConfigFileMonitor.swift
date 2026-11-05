import Foundation
import TOMLKit

/// One owner for disk changes and runtime refresh classification. Byte equality
/// suppresses the later FSEvent for an edit the app has already processed.
@MainActor
final class NVModernConfigFileMonitor {
    static let shared = NVModernConfigFileMonitor(configURL: NVModernConfigSchema.defaultConfigURL())
    let configURL: URL
    private let schema: NVModernConfigSchema
    private var lastData: Data?
    private var lastDraft: NVModernConfigDraft?
    private var lastReadFailed = false
    private var watcher: PluginDirectoryWatcher?

    init(configURL: URL, schema: NVModernConfigSchema = .shared) {
        self.configURL = configURL
        self.schema = schema
        lastData = try? Data(contentsOf: configURL)
        lastDraft = try? readDraft()
    }

    func start() {
        guard watcher == nil else { return }
        watcher = PluginDirectoryWatcher { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        watcher?.watch(directoryURL: configURL.deletingLastPathComponent())
    }

    func stop() { watcher?.stop(); watcher = nil }

    func readDraft() throws -> NVModernConfigDraft {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return schema.defaultDraft() }
        return try TOMLDecoder().decode(NVModernConfigDraft.self, from: String(contentsOf: configURL, encoding: .utf8))
    }

    func refresh(announceRuntime: Bool = true) {
        let data = try? Data(contentsOf: configURL)
        guard data != lastData else { return }
        lastData = data
        do {
            let draft = try readDraft()
            let pluginOnly = lastDraft.map { Self.isPluginOnlyChange(from: $0, to: draft) } ?? false
            let changed = lastDraft != draft || lastReadFailed
            let recovering = lastReadFailed
            lastReadFailed = false
            lastDraft = draft
            NotificationCenter.default.post(name: .nvModernConfigFileDidChange, object: configURL)
            if announceRuntime && changed {
                NotificationCenter.default.post(name: pluginOnly && !recovering ? .nvModernPluginsConfigDidChange : .nvModernConfigDidChange, object: configURL)
            }
        } catch {
            lastReadFailed = true
            NotificationCenter.default.post(name: .nvModernConfigFileDidChange, object: configURL,
                                            userInfo: ["error": error.localizedDescription])
        }
    }

    @discardableResult
    func write(_ edited: NVModernConfigDraft, basedOn base: NVModernConfigDraft) throws -> NVModernConfigDraft {
        let latest = try readDraft()
        var merged = try Self.mergingEdits(base: base, edited: edited, latest: latest)
        let defaultPath = merged.defaultProject?.path
        for index in merged.projects.indices {
            if let row = edited.projects.first(where: { $0.path == merged.projects[index].path }) {
                merged.projects[index]._uiID = row._uiID
            }
        }
        merged.defaultProjectID = merged.projects.first { $0.path == defaultPath }?._uiID
        merged.normalizeDefaultProject()
        for index in merged.substitutions.indices {
            if let row = edited.substitutions.first(where: { $0 == merged.substitutions[index] }) {
                merged.substitutions[index]._uiID = row._uiID
            }
        }
        try schema.saveDraft(merged, configURL: configURL)
        refresh()
        return merged
    }

    static func isPluginOnlyChange(from old: NVModernConfigDraft, to new: NVModernConfigDraft) -> Bool {
        var old = old, new = new
        let changed = old.plugins != new.plugins
        old.plugins = .init(); new.plugins = .init()
        return changed && old == new
    }

    /// Preserve concurrent edits elsewhere; never overwrite a conflicting field.
    static func mergingEdits(base: NVModernConfigDraft, edited: NVModernConfigDraft,
                             latest: NVModernConfigDraft) throws -> NVModernConfigDraft {
        if base == latest { return edited }
        func merge(_ before: ActionValue?, _ after: ActionValue?, _ current: ActionValue?, path: String) throws -> ActionValue? {
            if before == after { return current }
            if current == before || current == after { return after }
            if let newObject = after?.objectValue, let currentObject = current?.objectValue {
                let oldObject = before?.objectValue ?? [:]
                var result = currentObject
                for key in Set(oldObject.keys).union(newObject.keys) {
                    result[key] = try merge(oldObject[key], newObject[key], currentObject[key], path: path.isEmpty ? key : "\(path).\(key)")
                }
                return .object(result)
            }
            throw ActionError.executionFailed("\(path) changed on disk. Its current value has been loaded; edit it again.")
        }
        let value = try merge(ActionValue.fromEncodable(base), ActionValue.fromEncodable(edited),
                              ActionValue.fromEncodable(latest), path: "")
        return try JSONDecoder().decode(NVModernConfigDraft.self, from: JSONEncoder().encode(value))
    }
}
