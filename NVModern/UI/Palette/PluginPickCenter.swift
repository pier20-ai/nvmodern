import Foundation

/// Pending `nv.ui.pick` requests: the rows a plugin supplied, and the
/// continuation waiting on the user's choice.
///
/// A request is answered exactly once — by a row (`resolve`), by the palette
/// closing or moving on (`cancel`), or by the watchdog when no tab ever
/// presented it.
@MainActor
final class PluginPickCenter {
    static let shared = PluginPickCenter()

    /// How long a request may wait for a tab to present it.
    static let presentationTimeout: TimeInterval = 1.5

    private struct Pending {
        let items: [PluginPickItem]
        var isPresented = false
        let continuation: CheckedContinuation<ActionValue?, Never>
    }

    private var pending: [String: Pending] = [:]

    /// Registers a request, asks `present` to open the palette on it, and
    /// waits for the answer. Nil means dismissed.
    func choose(
        _ request: PluginPickRequest,
        present: (PalettePluginPick) -> Void
    ) async -> ActionValue? {
        let pick = PalettePluginPick(
            requestID: UUID().uuidString,
            kind: request.kind,
            placeholder: request.placeholder,
            initialText: request.initialText
        )
        return await withCheckedContinuation { continuation in
            pending[pick.requestID] = Pending(items: request.items, continuation: continuation)
            present(pick)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.presentationTimeout) { [weak self] in
                guard let self, self.pending[pick.requestID]?.isPresented == false else { return }
                paletteDebugLog("pluginPick.neverPresented id=\(pick.requestID)")
                self.cancel(pick.requestID)
            }
        }
    }

    func markPresented(_ requestID: String) {
        pending[requestID]?.isPresented = true
    }

    func resolve(_ requestID: String, with value: ActionValue) {
        pending.removeValue(forKey: requestID)?.continuation.resume(returning: value)
    }

    func cancel(_ requestID: String) {
        pending.removeValue(forKey: requestID)?.continuation.resume(returning: nil)
    }

    func cancelAll() {
        for requestID in Array(pending.keys) {
            cancel(requestID)
        }
    }

    /// The rows for an `items` or `text` picker.
    func sections(for pick: PalettePluginPick, query: String) -> [PaletteSection] {
        switch pick.kind {
        case .text:
            guard !query.isEmpty else { return [] }
            let item = PaletteItem(
                id: "plugin.pick.text",
                title: "Use \u{201C}\(query)\u{201D}",
                iconSystemName: "character.cursor.ibeam",
                activation: .pluginPick(requestID: pick.requestID, value: .string(query))
            )
            return [PaletteSection(id: "plugin.pick", title: "", items: [item])]

        case .items:
            guard let items = pending[pick.requestID]?.items else { return [] }
            let indices: [Int]
            if query.isEmpty {
                indices = Array(items.indices)
            } else {
                let candidates = items.enumerated().map { index, item in
                    PaletteSearchRanker.Candidate(
                        id: index,
                        label: item.title,
                        items: [item.title],
                        properties: ["aliases": item.keywords, "subtitle": [item.subtitle].compactMap { $0 }],
                        fallbackRank: index
                    )
                }
                indices = PaletteSearchRanker.rank(query: query, candidates: candidates).map(\.candidate.id)
            }
            let rows = indices.map { index in
                PaletteItem(
                    id: "plugin.pick.\(index)",
                    title: items[index].title,
                    subtitle: items[index].subtitle,
                    iconSystemName: items[index].iconSystemName,
                    activation: .pluginPick(requestID: pick.requestID, value: items[index].value)
                )
            }
            return [PaletteSection(id: "plugin.pick", title: "", items: rows)]

        case .note, .folder:
            return []
        }
    }
}
