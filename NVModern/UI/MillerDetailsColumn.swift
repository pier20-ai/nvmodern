import Combine
import Foundation
import SwiftUI

/// Where the browser's details-mode preference lives.
///
/// It is a view preference rather than per-document state, so it belongs in
/// `UserDefaults` and not the persisted session — that also keeps the session
/// schema untouched. `MillerColumnsView` and the View menu both bind this key.
enum MillerDetailsPreference {
    static let key = "nvmodern.miller.detailsMode"
    static let sortOverridesKey = "nvmodern.miller.sortOverrides"
}

/// Fixed geometry for details mode.
///
/// Every real folder column shows the same three fields — icon, name, compact
/// modified date — at the same width the plain list uses. Column width never
/// changes with mode or depth: the earlier design widened only the last column
/// to 520 points, so every arrow press reflowed the column being left behind.
enum MillerDetailsMetrics {
    static let iconWidth: CGFloat = 14
    static let modifiedWidth: CGFloat = 46
    /// Folder rows end in a chevron. Details mode reserves the slot on every
    /// row so the date column lines up between folders and notes.
    static let chevronWidth: CGFloat = 10
}

enum MillerDetailsSortField: String, CaseIterable {
    case kind
    case name
    case modified

    /// The kind column is the icon column and deliberately has no label; the
    /// icons say what the rows are. The title only appears in tooltips.
    var title: String {
        switch self {
        case .kind: return "Kind"
        case .name: return "Name"
        case .modified: return "Modified"
        }
    }
}

struct MillerDetailsSort: Equatable {
    var field: MillerDetailsSortField = .name
    var ascending: Bool = true

    /// Recent lists newest-first by definition, so that is its baseline sort
    /// rather than the alphabetical default every other root inherits.
    static let recentDefault = MillerDetailsSort(field: .modified, ascending: false)

    /// Clicking the active field flips direction; a new field starts ascending,
    /// except dates, which are far more useful newest-first.
    mutating func select(_ newField: MillerDetailsSortField) {
        if field == newField {
            ascending.toggle()
        } else {
            field = newField
            ascending = newField != .modified
        }
    }

    /// Folders first so the hierarchy stays readable; ties fall back to name.
    func sorted(_ items: [MillerItem]) -> [MillerItem] {
        items.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .folder }

            switch field {
            case .name:
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            case .modified:
                let left = lhs.modifiedDate ?? .distantPast
                let right = rhs.modifiedDate ?? .distantPast
                if left == right { return Self.nameAscending(lhs, rhs) }
                return ascending ? left < right : left > right
            case .kind:
                let left = Self.kindLabel(for: lhs)
                let right = Self.kindLabel(for: rhs)
                if left == right { return Self.nameAscending(lhs, rhs) }
                let order = left.localizedStandardCompare(right)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
    }

    static func kindLabel(for item: MillerItem) -> String {
        if item.kind == .folder { return "Folder" }
        let ext = (item.name as NSString).pathExtension
        return ext.isEmpty ? "Document" : ext.uppercased()
    }

    private static func nameAscending(_ lhs: MillerItem, _ rhs: MillerItem) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // MARK: — persistence encoding

    var storageValue: String {
        "\(field.rawValue):\(ascending ? "asc" : "desc")"
    }

    init(field: MillerDetailsSortField = .name, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let field = MillerDetailsSortField(rawValue: parts[0]),
              parts[1] == "asc" || parts[1] == "desc" else {
            return nil
        }
        self.field = field
        self.ascending = parts[1] == "asc"
    }
}

/// Resolves which sort a column uses.
///
/// Overrides are keyed by the folder a column lists, not by depth: sorting the
/// Inbox by date should not also sort every other second-level folder by date,
/// and coming back to the Inbox by another route should find it as it was left.
/// A column without its own override inherits from its parent column, all the
/// way up to the root's baseline. That recursion is the whole inheritance rule:
/// "the N+1th column inherits from the Nth unless overridden".
enum MillerDetailsSortResolver {
    static func orderedColumns(
        _ columns: [[MillerItem]],
        chain: [String],
        detailsEnabled: Bool,
        override: (_ folderKey: String) -> MillerDetailsSort?
    ) -> [[MillerItem]] {
        guard detailsEnabled else { return columns }
        return columns.enumerated().map { depth, items in
            guard depth > 0 else { return items }
            return effectiveSort(chain: chain, depth: depth, override: override).sorted(items)
        }
    }

    /// The identity of the folder that column `depth` lists.
    ///
    /// Column 1 lists the root source's contents and is keyed by the synthetic
    /// root path (Workspace, Recent, a capture root), so each root keeps its
    /// own top-level sort. Deeper columns are keyed by the real folder path.
    /// Column 0 is the synthetic list itself and is never sorted.
    static func folderKey(chain: [String], depth: Int) -> String? {
        guard depth >= 1 else { return nil }
        let normalized = LaunchpadRootColumn.normalized(chain)
        guard normalized.indices.contains(depth - 1) else { return nil }
        return normalized[depth - 1]
    }

    static func effectiveSort(
        chain: [String],
        depth: Int,
        override: (_ folderKey: String) -> MillerDetailsSort?
    ) -> MillerDetailsSort {
        var current = depth
        while current >= 1 {
            if let key = folderKey(chain: chain, depth: current),
               let sort = override(key) {
                return sort
            }
            current -= 1
        }

        let normalized = LaunchpadRootColumn.normalized(chain)
        if normalized.first == LaunchpadRootColumn.recentPath {
            return .recentDefault
        }
        return MillerDetailsSort()
    }
}

/// Per-folder sort overrides, scoped to a workspace root so paths from
/// different projects cannot collide. Lives in `UserDefaults` next to the
/// details toggle because it is a view preference, not document state.
@MainActor
final class MillerSortPreferences: ObservableObject {
    static let shared = MillerSortPreferences()

    @Published private(set) var overrides: [String: MillerDetailsSort]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: MillerDetailsPreference.sortOverridesKey) as? [String: String] ?? [:]
        overrides = stored.compactMapValues(MillerDetailsSort.init(storageValue:))
    }

    func override(root: String, folderKey: String) -> MillerDetailsSort? {
        overrides[Self.storageKey(root: root, folderKey: folderKey)]
    }

    func setOverride(_ sort: MillerDetailsSort, root: String, folderKey: String) {
        overrides[Self.storageKey(root: root, folderKey: folderKey)] = sort
        persist()
    }

    private func persist() {
        defaults.set(overrides.mapValues(\.storageValue), forKey: MillerDetailsPreference.sortOverridesKey)
    }

    /// U+0000 cannot appear in a path, so the join is unambiguous.
    private static func storageKey(root: String, folderKey: String) -> String {
        "\(root)\u{0}\(folderKey)"
    }
}

/// Short modification stamps that fit a 46-point column.
///
/// Today shows the time, the last week the weekday, the current year the
/// month and day, and anything older just the year. The full timestamp goes
/// in the row's tooltip.
enum MillerCompactDate {
    private enum Style: Hashable {
        case time
        case weekday
        case monthDay
        case year
        case full
    }

    private struct FormatterKey: Hashable {
        let style: Style
        let calendarIdentifier: Calendar.Identifier
        let timeZoneIdentifier: String
        let localeIdentifier: String
    }

    /// Creating a DateFormatter initializes ICU locale data and is far too
    /// expensive for a SwiftUI row body. A window activation can reevaluate
    /// every visible Miller row, so reuse one formatter per effective locale.
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [FormatterKey: DateFormatter] = [:]

        func string(
            from date: Date,
            style: Style,
            calendar: Calendar,
            locale: Locale
        ) -> String {
            let key = FormatterKey(
                style: style,
                calendarIdentifier: calendar.identifier,
                timeZoneIdentifier: calendar.timeZone.identifier,
                localeIdentifier: locale.identifier
            )

            lock.lock()
            defer { lock.unlock() }

            let formatter: DateFormatter
            if let cached = formatters[key] {
                formatter = cached
            } else {
                let created = DateFormatter()
                created.calendar = calendar
                created.timeZone = calendar.timeZone
                created.locale = locale
                switch style {
                case .time:
                    created.dateFormat = "HH:mm"
                case .weekday:
                    created.dateFormat = "EEE"
                case .monthDay:
                    created.setLocalizedDateFormatFromTemplate("MMM d")
                case .year:
                    created.dateFormat = "yyyy"
                case .full:
                    created.dateStyle = .long
                    created.timeStyle = .short
                }
                formatters[key] = created
                formatter = created
            }
            return formatter.string(from: date)
        }
    }

    private static let formatterCache = FormatterCache()

    static func string(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let style: Style
        if calendar.isDate(date, inSameDayAs: now) {
            style = .time
        } else if let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day, days > 0, days < 7 {
            style = .weekday
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            style = .monthDay
        } else {
            style = .year
        }

        return formatterCache.string(
            from: date,
            style: style,
            calendar: calendar,
            locale: locale
        )
    }

    static func fullString(for date: Date) -> String {
        let calendar = Calendar.current
        return formatterCache.string(
            from: date,
            style: .full,
            calendar: calendar,
            locale: .current
        )
    }
}

/// The metadata shown alongside a row's name in details mode.
struct MillerRowDetails {
    let modified: String
    let modifiedTooltip: String?

    init(item: MillerItem, now: Date = Date()) {
        if let date = item.modifiedDate {
            modified = MillerCompactDate.string(for: date, now: now)
            modifiedTooltip = MillerCompactDate.fullString(for: date)
        } else {
            modified = "—"
            modifiedTooltip = nil
        }
    }
}

/// Clickable column headers for details mode: an unlabelled icon column that
/// sorts by kind, Name, and Modified. Laid out with the row's own spacing and
/// paddings so the header cells sit exactly over the fields they sort.
struct MillerDetailsHeader: View {
    let sort: MillerDetailsSort
    let onSelect: (MillerDetailsSortField) -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.space3) {
            headerButton(.kind, label: nil)
                .frame(width: MillerDetailsMetrics.iconWidth, alignment: .center)

            headerButton(.name, label: "Name")
                .frame(maxWidth: .infinity, alignment: .leading)

            headerButton(.modified, label: "Modified", alignment: .trailing)
                .frame(width: MillerDetailsMetrics.modifiedWidth, alignment: .trailing)

            Color.clear
                .frame(width: MillerDetailsMetrics.chevronWidth)
        }
        .padding(.horizontal, DesignTokens.Spacing.space3)
        .frame(minHeight: 22)
        .padding(.horizontal, DesignTokens.Spacing.space2)
        .padding(.bottom, DesignTokens.Spacing.space1)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignTokens.TextStyle.tertiary.opacity(0.18))
                .frame(height: 1)
                .padding(.horizontal, DesignTokens.Spacing.space2)
        }
    }

    private func headerButton(
        _ field: MillerDetailsSortField,
        label: String?,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        let isActive = sort.field == field

        return Button {
            onSelect(field)
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }

                if let label {
                    Text(label)
                        .font(DesignTokens.Typography.caption.weight(.semibold))
                        .foregroundStyle(
                            isActive
                                ? DesignTokens.TextStyle.secondary
                                : DesignTokens.TextStyle.tertiary
                        )
                        .lineLimit(1)
                }

                // The icon column stays visually empty unless it is the active
                // sort, so the leftmost column reads as pure icons by default.
                if isActive {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(DesignTokens.TextStyle.tertiary)
                }

                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(field.title)")
    }
}
