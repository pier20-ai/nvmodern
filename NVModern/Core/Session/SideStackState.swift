import Foundation

/// Section a side-stack card is focused on: a heading or a `^block` id, as in
/// `[[note#Heading]]` / `[[note#^block]]`. Ticket 0031.
struct SideStackFocus: Codable, Hashable, Sendable {
    var heading: String?
    /// Block id without the leading `^`.
    var block: String?

    /// Normalises the parts the way the stack does: trimmed, `^` dropped from
    /// the block, a heading wins over a block, and nothing at all is nil.
    init?(heading: String?, block: String?) {
        let heading = heading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var block = block?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while block.hasPrefix("^") {
            block.removeFirst()
        }
        if !heading.isEmpty {
            self.heading = heading
            self.block = nil
        } else if !block.isEmpty {
            self.heading = nil
            self.block = block
        } else {
            return nil
        }
    }

    init?(reference: MarkdownReferenceTarget?) {
        guard let reference else { return nil }
        switch reference.kind {
        case .heading:
            self.init(heading: reference.query, block: nil)
        case .block:
            self.init(heading: nil, block: reference.query)
        }
    }

    /// The reference the main editor's `jumpToMarkdownReference` takes.
    var reference: MarkdownReferenceTarget {
        if let heading {
            return MarkdownReferenceTarget(kind: .heading, query: heading)
        }
        return MarkdownReferenceTarget(kind: .block, query: block ?? "")
    }

    /// Wikilink-style suffix (`#Heading`, `#^block`), used in card ids.
    var linkSuffix: String {
        if let heading { return "#\(heading)" }
        if let block { return "#^\(block)" }
        return ""
    }

    var bridgePayload: [String: Any] {
        var payload: [String: Any] = [:]
        if let heading { payload["heading"] = heading }
        if let block { payload["block"] = block }
        return payload
    }
}

/// One card in a tab's side stack. Bodies are not persisted; they are read
/// from the workspace whenever the stack renders.
struct SideStackCard: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var path: String
    var focus: SideStackFocus?
    var collapsed: Bool
    /// Nil until the reader toggles "show whole note" on a focused card.
    var showWholeNote: Bool?

    init(path: String, focus: SideStackFocus? = nil, collapsed: Bool = false, showWholeNote: Bool? = nil) {
        self.id = Self.id(path: path, focus: focus)
        self.path = path
        self.focus = focus
        self.collapsed = collapsed
        self.showWholeNote = showWholeNote
    }

    /// Stable per path + focus, so the same note focused on two different
    /// sections is two cards, and pushing either again finds its card.
    static func id(path: String, focus: SideStackFocus?) -> String {
        path + (focus?.linkSuffix ?? "")
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case focus
        case collapsed
        case showWholeNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        let focus = try? container.decodeIfPresent(SideStackFocus.self, forKey: .focus)
        let normalized = focus.flatMap { SideStackFocus(heading: $0.heading, block: $0.block) }
        self.init(
            path: path,
            focus: normalized,
            collapsed: (try? container.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false,
            showWholeNote: try? container.decodeIfPresent(Bool.self, forKey: .showWholeNote)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(focus, forKey: .focus)
        try container.encode(collapsed, forKey: .collapsed)
        try container.encodeIfPresent(showWholeNote, forKey: .showWholeNote)
    }
}

/// A tab's side stack: the cards (top first), whether the column is shown,
/// and its width. Owned by `WorkspaceTabState` and persisted with the tab.
struct SideStackState: Codable, Equatable, Sendable {
    static let defaultWidth: Double = 360
    static let widthRange: ClosedRange<Double> = 260...720

    var cards: [SideStackCard]
    var isOpen: Bool
    /// Nil keeps the default width.
    var width: Double?

    init(cards: [SideStackCard] = [], isOpen: Bool = false, width: Double? = nil) {
        self.cards = cards
        self.isOpen = isOpen
        self.width = width.map(Self.clampedWidth)
    }

    static let empty = SideStackState()

    /// Nothing worth persisting.
    var isDefault: Bool {
        cards.isEmpty && !isOpen && width == nil
    }

    var resolvedWidth: Double {
        width ?? Self.defaultWidth
    }

    static func clampedWidth(_ width: Double) -> Double {
        min(widthRange.upperBound, max(widthRange.lowerBound, width))
    }

    enum PushOutcome: Equatable {
        /// A new card went on top of the stack.
        case added(id: String)
        /// A card with the same path and focus was already there.
        case existing(id: String)

        var id: String {
            switch self {
            case .added(let id), .existing(let id):
                return id
            }
        }
    }

    func card(id: String) -> SideStackCard? {
        cards.first { $0.id == id }
    }

    func containsCard(path: String, focus: SideStackFocus?) -> Bool {
        card(id: SideStackCard.id(path: path, focus: focus)) != nil
    }

    /// Pushes `path` (focused on `focus`) on top, or finds the existing card
    /// for the same path and focus. Either way the column opens.
    @discardableResult
    mutating func push(path: String, focus: SideStackFocus? = nil) -> PushOutcome {
        isOpen = true
        let id = SideStackCard.id(path: path, focus: focus)
        if let existing = cards.firstIndex(where: { $0.id == id }) {
            if cards[existing].collapsed {
                cards[existing].collapsed = false
            }
            return .existing(id: id)
        }
        cards.insert(SideStackCard(path: path, focus: focus), at: 0)
        return .added(id: id)
    }

    /// Removes the card; closing the last one hides the column.
    @discardableResult
    mutating func close(id: String) -> Bool {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return false }
        cards.remove(at: index)
        if cards.isEmpty {
            isOpen = false
        }
        return true
    }

    mutating func clear() {
        cards.removeAll()
        isOpen = false
    }

    @discardableResult
    mutating func setCollapsed(_ collapsed: Bool, id: String) -> Bool {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return false }
        cards[index].collapsed = collapsed
        return true
    }

    @discardableResult
    mutating func setShowWholeNote(_ showWholeNote: Bool, id: String) -> Bool {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return false }
        cards[index].showWholeNote = showWholeNote
        return true
    }

    /// Follows renames on disk. A card whose new id collides with an existing
    /// card is dropped rather than duplicated.
    @discardableResult
    mutating func applyRenames(_ renamedPaths: [String: String]) -> Bool {
        guard !renamedPaths.isEmpty else { return false }
        var changed = false
        var seen = Set<String>()
        var next: [SideStackCard] = []
        for card in cards {
            var card = card
            if let newPath = renamedPaths[card.path] {
                card = SideStackCard(
                    path: newPath,
                    focus: card.focus,
                    collapsed: card.collapsed,
                    showWholeNote: card.showWholeNote
                )
                changed = true
            }
            guard seen.insert(card.id).inserted else {
                changed = true
                continue
            }
            next.append(card)
        }
        cards = next
        return changed
    }

    /// Drops cards for notes deleted from disk.
    @discardableResult
    mutating func removeCards(atPaths paths: Set<String>) -> Bool {
        guard !paths.isEmpty else { return false }
        let before = cards.count
        cards.removeAll { paths.contains($0.path) }
        if cards.isEmpty, before > 0 {
            isOpen = false
        }
        return cards.count != before
    }

    private enum CodingKeys: String, CodingKey {
        case cards
        case isOpen
        case width
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A malformed card drops out instead of losing the stack.
        let lossy = (try? container.decodeIfPresent([LossyCard].self, forKey: .cards)) ?? []
        var seen = Set<String>()
        let cards = lossy.compactMap(\.card).filter { seen.insert($0.id).inserted }
        self.init(
            cards: cards,
            isOpen: (try? container.decodeIfPresent(Bool.self, forKey: .isOpen)) ?? !cards.isEmpty,
            width: try? container.decodeIfPresent(Double.self, forKey: .width)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cards, forKey: .cards)
        try container.encode(isOpen, forKey: .isOpen)
        try container.encodeIfPresent(width, forKey: .width)
    }

    private struct LossyCard: Decodable {
        let card: SideStackCard?

        init(from decoder: Decoder) throws {
            card = try? SideStackCard(from: decoder)
        }
    }
}
