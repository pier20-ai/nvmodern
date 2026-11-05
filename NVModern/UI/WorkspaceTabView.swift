import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func arborDiagnosticJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8)
    else {
        return String(describing: value)
    }
    return text
}

private struct NativeDatePickerSheetState: Identifiable {
    let id = UUID()
    let initialDate: Date
    let initialStartTime: Date
    let initialEndTime: Date
    let includesTime: Bool
    let includesEndTime: Bool
}

private enum DocumentNavigationSessionOwner {
    case navigator
    case findBar
    case outlinePalette
}

/// Pins a reversible palette session to its editor, even if focus changes.
private struct OutlinePaletteNavigation {
    let controller: EditorWebContentController
    let path: String
}

private enum NativeDatePickerDateCodec {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private static let monthTitleFormat: Date.FormatStyle = Date.FormatStyle()
        .month(.wide)
        .year()

    static func date(fromISODate isoDate: String) -> Date? {
        let parts = isoDate.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return nil
        }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return calendar.date(from: components)
    }

    static func todayDate() -> Date {
        normalizedDate(Date())
    }

    static func isoDateString(from date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func time(from value: String?, on date: Date) -> Date? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute)
        else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    static func timeString(from date: Date) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    static func currentTime(on date: Date) -> Date {
        let now = Date()
        let time = timeString(from: now)
        return self.time(from: time, on: date) ?? date
    }

    static func addingMinutes(_ value: Int, to date: Date) -> Date {
        calendar.date(byAdding: .minute, value: value, to: date) ?? date
    }

    static func startOfMonth(for date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: normalizedDate(date))
        var monthStart = DateComponents()
        monthStart.calendar = calendar
        monthStart.timeZone = calendar.timeZone
        monthStart.year = components.year
        monthStart.month = components.month
        monthStart.day = 1
        monthStart.hour = 12
        return calendar.date(from: monthStart) ?? normalizedDate(date)
    }

    static func addingMonths(_ value: Int, to date: Date) -> Date {
        if let shiftedDate = calendar.date(byAdding: .month, value: value, to: startOfMonth(for: date)) {
            return startOfMonth(for: shiftedDate)
        }
        return startOfMonth(for: date)
    }

    static func addingDays(_ value: Int, to date: Date) -> Date {
        if let shiftedDate = calendar.date(byAdding: .day, value: value, to: normalizedDate(date)) {
            return normalizedDate(shiftedDate)
        }
        return normalizedDate(date)
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    static func isSameMonth(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, equalTo: rhs, toGranularity: .month)
    }

    static func isWeekend(_ date: Date) -> Bool {
        calendar.isDateInWeekend(date)
    }

    static func monthTitle(for date: Date) -> String {
        startOfMonth(for: date).formatted(monthTitleFormat)
    }

    static func weekdayHeaders() -> [NativeDatePickerWeekday] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        return (0..<7).map { offset in
            let weekday = ((calendar.firstWeekday - 1 + offset) % 7) + 1
            return NativeDatePickerWeekday(
                index: weekday,
                symbol: symbols[weekday - 1],
                isWeekend: isWeekend(weekdayIndex: weekday)
            )
        }
    }

    static func monthGrid(for month: Date) -> [NativeDatePickerDay] {
        let monthStart = startOfMonth(for: month)
        let leadingDayCount = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        let gridStart = addingDays(-leadingDayCount, to: monthStart)
        let today = todayDate()

        return (0..<42).map { offset in
            let date = addingDays(offset, to: gridStart)
            return NativeDatePickerDay(
                date: date,
                dayNumber: String(calendar.component(.day, from: date)),
                isInDisplayedMonth: isSameMonth(date, monthStart),
                isWeekend: isWeekend(date),
                isToday: isSameDay(date, today)
            )
        }
    }

    private static func isWeekend(weekdayIndex: Int) -> Bool {
        let referenceSunday = date(fromISODate: "2024-06-02") ?? todayDate()
        let offset = (weekdayIndex + 6) % 7
        let referenceDate = addingDays(offset, to: referenceSunday)
        return isWeekend(referenceDate)
    }

    private static func normalizedDate(_ date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        var normalized = DateComponents()
        normalized.calendar = calendar
        normalized.timeZone = calendar.timeZone
        normalized.year = components.year
        normalized.month = components.month
        normalized.day = components.day
        normalized.hour = 12
        return calendar.date(from: normalized) ?? date
    }
}

private struct NativeDatePickerWeekday: Identifiable {
    let index: Int
    let symbol: String
    let isWeekend: Bool

    var id: Int { index }
}

private struct NativeDatePickerDay: Identifiable {
    let date: Date
    let dayNumber: String
    let isInDisplayedMonth: Bool
    let isWeekend: Bool
    let isToday: Bool

    var id: Date { date }
}

private struct NativeDatePickerMonthView: View {
    let monthStart: Date
    let selectedDate: Date
    let onSelectDate: (Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(minimum: 38, maximum: 50), spacing: 8), count: 7)

    private var weekdayHeaders: [NativeDatePickerWeekday] {
        NativeDatePickerDateCodec.weekdayHeaders()
    }

    private var days: [NativeDatePickerDay] {
        NativeDatePickerDateCodec.monthGrid(for: monthStart)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NativeDatePickerDateCodec.monthTitle(for: monthStart))
                .font(.headline.weight(.semibold))

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(weekdayHeaders) { weekday in
                    Text(weekday.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(weekday.isWeekend ? Color.red.opacity(0.8) : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                        .textSelection(.disabled)
                }

                ForEach(days) { day in
                    NativeDatePickerDayCell(
                        day: day,
                        isSelected: NativeDatePickerDateCodec.isSameDay(day.date, selectedDate),
                        action: {
                            onSelectDate(day.date)
                        }
                    )
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }
}

private struct NativeDatePickerDayCell: View {
    let day: NativeDatePickerDay
    let isSelected: Bool
    let action: () -> Void

    private var backgroundColor: Color {
        if isSelected {
            return .accentColor
        }
        if day.isWeekend {
            return Color.red.opacity(day.isInDisplayedMonth ? 0.14 : 0.07)
        }
        return Color.primary.opacity(day.isInDisplayedMonth ? 0.05 : 0.025)
    }

    private var textColor: Color {
        if isSelected {
            return .white
        }
        if !day.isInDisplayedMonth {
            return Color.secondary.opacity(0.8)
        }
        if day.isToday {
            return .accentColor
        }
        return .primary
    }

    private var borderColor: Color {
        if day.isToday && !isSelected {
            return .accentColor
        }
        return .clear
    }

    private var borderLineWidth: CGFloat {
        day.isToday && !isSelected ? 2 : 0
    }

    private var fontWeight: Font.Weight {
        (isSelected || day.isToday) ? .semibold : .medium
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(backgroundColor)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor, lineWidth: borderLineWidth)

                Text(day.dayNumber)
                    .font(.system(size: 15, weight: fontWeight))
                    .foregroundStyle(textColor)
                    .textSelection(.disabled)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct NativeDatePickerNavigationButton: View {
    let systemImage: String
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
                .padding(8)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help(helpText)
    }
}

@MainActor
private final class NativeDatePickerPresenter: ObservableObject {
    @Published var activeSheet: NativeDatePickerSheetState?

    private var continuation: CheckedContinuation<DocumentDatePickerResult?, Never>?

    func present(request: DocumentDatePickerRequest) async -> DocumentDatePickerResult? {
        finish(result: nil)

        let initialDate = NativeDatePickerDateCodec.date(fromISODate: request.isoDate ?? "")
            ?? NativeDatePickerDateCodec.todayDate()
        let initialStartTime = NativeDatePickerDateCodec.time(from: request.startTime, on: initialDate)
            ?? NativeDatePickerDateCodec.currentTime(on: initialDate)
        let initialEndTime = NativeDatePickerDateCodec.time(from: request.endTime, on: initialDate)
            ?? NativeDatePickerDateCodec.addingMinutes(60, to: initialStartTime)

        activeSheet = NativeDatePickerSheetState(
            initialDate: initialDate,
            initialStartTime: initialStartTime,
            initialEndTime: initialEndTime,
            includesTime: request.startTime != nil,
            includesEndTime: request.endTime != nil
        )

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func confirm(_ result: DocumentDatePickerResult) {
        finish(result: result)
    }

    func cancel() {
        finish(result: nil)
    }

    func cancelIfNeeded() {
        guard continuation != nil || activeSheet != nil else { return }
        finish(result: nil)
    }

    private func finish(result: DocumentDatePickerResult?) {
        let continuation = self.continuation
        self.continuation = nil
        activeSheet = nil
        continuation?.resume(returning: result)
    }
}

private struct NativeDatePickerSheet: View {
    let initialDate: Date
    let initialStartTime: Date
    let initialEndTime: Date
    let initiallyIncludesTime: Bool
    let initiallyIncludesEndTime: Bool
    let onCancel: () -> Void
    let onConfirm: (DocumentDatePickerResult) -> Void

    @State private var selectedDate: Date
    @State private var displayedMonthStart: Date
    @State private var includesTime: Bool
    @State private var includesEndTime: Bool
    @State private var selectedStartTime: Date
    @State private var selectedEndTime: Date

    private static let selectedDateFormat: Date.FormatStyle = Date.FormatStyle()
        .weekday(.wide)
        .month(.wide)
        .day()
        .year()

    private var secondDisplayedMonthStart: Date {
        NativeDatePickerDateCodec.addingMonths(1, to: displayedMonthStart)
    }

    init(
        initialDate: Date,
        initialStartTime: Date,
        initialEndTime: Date,
        includesTime: Bool,
        includesEndTime: Bool,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (DocumentDatePickerResult) -> Void
    ) {
        self.initialDate = initialDate
        self.initialStartTime = initialStartTime
        self.initialEndTime = initialEndTime
        self.initiallyIncludesTime = includesTime
        self.initiallyIncludesEndTime = includesEndTime
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedDate = State(initialValue: initialDate)
        _displayedMonthStart = State(initialValue: NativeDatePickerDateCodec.startOfMonth(for: initialDate))
        _includesTime = State(initialValue: includesTime)
        _includesEndTime = State(initialValue: includesEndTime)
        _selectedStartTime = State(initialValue: initialStartTime)
        _selectedEndTime = State(initialValue: initialEndTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pick Date")
                        .font(.title3.weight(.semibold))

                    Text(selectedDate.formatted(Self.selectedDateFormat))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    NativeDatePickerNavigationButton(
                        systemImage: "chevron.left",
                        helpText: "Previous month",
                        action: {
                            displayedMonthStart = NativeDatePickerDateCodec.addingMonths(-1, to: displayedMonthStart)
                        }
                    )

                    NativeDatePickerNavigationButton(
                        systemImage: "chevron.right",
                        helpText: "Next month",
                        action: {
                            displayedMonthStart = NativeDatePickerDateCodec.addingMonths(1, to: displayedMonthStart)
                        }
                    )
                }
            }

            HStack(alignment: .top, spacing: 20) {
                NativeDatePickerMonthView(
                    monthStart: displayedMonthStart,
                    selectedDate: selectedDate,
                    onSelectDate: selectDate
                )

                NativeDatePickerMonthView(
                    monthStart: secondDisplayedMonthStart,
                    selectedDate: selectedDate,
                    onSelectDate: selectDate
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Include time", isOn: $includesTime)

                if includesTime {
                    HStack(spacing: 18) {
                        DatePicker(
                            "Start",
                            selection: $selectedStartTime,
                            displayedComponents: [.hourAndMinute]
                        )
                        .datePickerStyle(.field)

                        Toggle("Time range", isOn: $includesEndTime)

                        if includesEndTime {
                            DatePicker(
                                "End",
                                selection: $selectedEndTime,
                                displayedComponents: [.hourAndMinute]
                            )
                            .datePickerStyle(.field)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)

            HStack(spacing: 12) {
                Button("Today") {
                    let today = NativeDatePickerDateCodec.todayDate()
                    selectedDate = today
                    displayedMonthStart = NativeDatePickerDateCodec.startOfMonth(for: today)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .controlSize(.large)

                Button("Done") {
                    onConfirm(
                        DocumentDatePickerResult(
                            isoDate: NativeDatePickerDateCodec.isoDateString(from: selectedDate),
                            startTime: includesTime
                                ? NativeDatePickerDateCodec.timeString(from: selectedStartTime)
                                : nil,
                            endTime: includesTime && includesEndTime
                                ? NativeDatePickerDateCodec.timeString(from: selectedEndTime)
                                : nil
                        )
                    )
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(minWidth: 820, idealWidth: 840)
    }

    private func selectDate(_ date: Date) {
        selectedDate = date

        if NativeDatePickerDateCodec.isSameMonth(date, displayedMonthStart) ||
            NativeDatePickerDateCodec.isSameMonth(date, secondDisplayedMonthStart) {
            return
        }

        displayedMonthStart = NativeDatePickerDateCodec.startOfMonth(for: date)
    }
}

@MainActor
final class WorkspaceOpenDocumentPathRegistry: ObservableObject {
    @Published var entries: [WorkspaceOpenDocumentPathEntry] = []

    /// Keyed by the tab id, unlike `entries`, which is keyed by the
    /// public action tab id.
    ///
    /// This exists so long-lived closures — the tab bar's context-menu provider
    /// above all — can resolve a tab's document without reading the window's
    /// `@State`. Such a closure captures a copy of the view struct and keeps
    /// reading whatever that copy held when the closure was installed, which is
    /// an empty tab table at `onAppear`. Reading through this object instead
    /// keeps the menu on live values, the same way `WorkspaceSidebarState` does
    /// for sidebar visibility.
    @Published var documentsByTabID: [TabID: WorkspaceOpenedDocument] = [:]

    var paths: Set<String> {
        Set(entries.map(\.relativePath))
    }
}

struct WorkspaceOpenDocumentPathEntry: Identifiable, Hashable {
    let tabID: String
    let relativePath: String
    let title: String

    var id: String { tabID }
}

private enum NativeInspectorPane: String, CaseIterable, Identifiable {
    case outline
    case line
    case document

    var id: String { rawValue }
}

/// Native-shell chrome for `TabWorkspaceView`: hosts the document navigator
/// and inspector in a trailing content split. Keeping the split inside the
/// tab's content view prevents it from extending behind AppKit's window tab
/// bar, while the drag target retains native inspector resizing without a
/// full-height AppKit divider bleeding through the titlebar.
private struct NativeShellInspector<InspectorContent: View>: ViewModifier {
    let isEnabled: Bool
    @Binding var isPresented: Bool
    let onAnchorResolve: (NSView) -> Void
    let backgroundColor: NSColor
    @ViewBuilder let inspectorContent: () -> InspectorContent
    @State private var inspectorWidth: CGFloat = 300
    @State private var inspectorDragStartWidth: CGFloat?

    private let inspectorWidthRange: ClosedRange<CGFloat> = 240...420

    static var presentationAnimation: Animation { .easeInOut(duration: 0.25) }

    /// `content` keeps one structural position whether or not the column is
    /// shown, so toggling the inspector never tears down and rebuilds the tab
    /// surface; only the column itself is inserted or removed, sliding in
    /// from the trailing edge under `presentationAnimation`.
    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            HStack(spacing: 0) {
                content
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

                if isPresented {
                    inspectorDivider

                    inspectorContent()
                        .frame(width: inspectorWidth)
                        .frame(maxHeight: .infinity)
                        .background(Color(nsColor: backgroundColor))
                        .transition(.move(edge: .trailing))
                }
            }
            .clipped()
            .background(WorkspaceAnchorResolverView(onResolve: onAnchorResolve))
        } else {
            content
        }
    }

    private var inspectorDivider: some View {
        Rectangle()
            .fill(DesignTokens.TextStyle.tertiary.opacity(0.22))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let startWidth = inspectorDragStartWidth ?? inspectorWidth
                                if inspectorDragStartWidth == nil {
                                    inspectorDragStartWidth = startWidth
                                }
                                inspectorWidth = min(
                                    inspectorWidthRange.upperBound,
                                    max(inspectorWidthRange.lowerBound, startWidth - value.translation.width)
                                )
                            }
                            .onEnded { _ in
                                inspectorDragStartWidth = nil
                            }
                    )
            }
            .onHover { isHovering in
                (isHovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
    }
}

/// Resolves an `NSView` anchor once it has joined a window, replacing the
/// anchor the omnibox header used to provide.
private struct WorkspaceAnchorResolverView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        WorkspaceAnchorResolverViewBox(onResolve: onResolve)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WorkspaceAnchorResolverViewBox: NSView {
        private let onResolve: (NSView) -> Void
        private var hasResolved = false

        init(onResolve: @escaping (NSView) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !hasResolved else { return }
            hasResolved = true
            onResolve(self)
        }
    }
}

private struct WorkspaceContentDiagnosticsSnapshot: Equatable, CustomStringConvertible {
    let showLaunchpad: Bool
    let openedDocument: String
    let selectedNotePath: String
    let contextKind: String
    let contextPath: String
    let hasPDFURL: Bool
    let hasImageURL: Bool
    let hasCSVURL: Bool
    let hasHTMLURL: Bool
    let hasWebController: Bool
    let hasPDFController: Bool
    let hasImageController: Bool
    let hasCSVController: Bool
    let hasHTMLController: Bool

    var description: String {
        "showLaunchpad=\(showLaunchpad) opened=\(openedDocument) selectedNote=\(selectedNotePath) context=\(contextKind):\(contextPath) pdfURL=\(hasPDFURL) imageURL=\(hasImageURL) csvURL=\(hasCSVURL) htmlURL=\(hasHTMLURL) web=\(hasWebController) pdfController=\(hasPDFController) imageController=\(hasImageController) csvController=\(hasCSVController) htmlController=\(hasHTMLController)"
    }
}

private struct MillerSelectionAnchor {
    let depth: Int
    let row: Int
    let relativePath: String
}

@MainActor
struct TabWorkspaceView: View {
    private static let paletteEstimatedHeight: CGFloat = 480

    let tabID: TabID
    @Binding var state: WorkspaceTabState
    @ObservedObject var notesModel: NotesWorkspaceModel
    @ObservedObject var workspaceTabController: WorkspaceTabController
    @ObservedObject var openDocumentPathRegistry: WorkspaceOpenDocumentPathRegistry
    @ObservedObject private var millerSortPreferences = MillerSortPreferences.shared
    @AppStorage(MillerDetailsPreference.key) private var isMillerDetailsModeEnabled = false
    var onTabPresentationChange: (WorkspaceTabPresentation) -> Void
    var onCloseTabRequest: (TabID) -> Void
    var onWorkspaceItemRenamed: (String, String, MillerItemKind) -> Void
    var onWorkspaceItemTrashed: (String, MillerItemKind) -> Void
    /// Opens the window's New Note panel, starting in the given folder.
    var onCreateNote: (_ folderRelativePath: String?) -> Void
    var isControllerFocusedLeaf: Bool
    var onLeafInteraction: () -> Void
    /// The colour the window chrome should take from the visible document;
    /// nil hands the chrome back to the system.
    var onChromeTintChange: (NSColor?) -> Void
    /// Native-shell mode: the window chrome (breadcrumb, history, palette,
    /// find, navigator, inspector affordances) is provided by the native
    /// toolbar and inspector instead of the omnibox header, so the header and
    /// context ribbon are not rendered here. Presentation notifications keep
    /// working and the navigator/inspector move into a trailing
    /// `.inspector` column.
    var omitsHeaderChrome: Bool = false
    @StateObject private var nativeDatePickerPresenter = NativeDatePickerPresenter()
    @State private var editorController: EditorWebContentController?
    @State private var epubController: EditorWebContentController?
    @State private var previewController: EditorWebContentController?
    @State private var pdfController: PDFPreviewContentController?
    @State private var csvController: CSVPreviewContentController?
    @State private var canvasController: CanvasDocumentContentController?
    @State private var imageController: ImagePreviewContentController?
    @State private var htmlController: HTMLPreviewContentController?
    @State private var pendingSaveTasks: [String: Task<Void, Never>] = [:]
    @State private var omniboxAnchor: NSView?
    @ObservedObject var paletteHost: WorkspacePaletteHost
    @StateObject private var paletteSession = PaletteSession()
    @State private var pendingPaletteOpenPreset: PalettePreset?
    @State private var palettePreviewDocument: WorkspaceOpenedDocument?
    @State private var palettePreviewOriginalTextContextOverride: EditorSelectionContext?
    @State private var palettePreviewOriginalImageAdjustments: ImageAdjustmentSettings?
    @State private var isContextRibbonVisible: Bool = false
    @State private var launchpadMillerFocusRequestID = 0
    @State private var launchpadMillerPreview: MillerPreviewColumnContent?
    @State private var launchpadMillerSelectedPaths = Set<String>()
    @State private var launchpadMillerSelectionAnchor: MillerSelectionAnchor?
    @State private var launchpadMillerShelfPaths: [String] = []
    @State private var activeEditorContext: EditorSelectionContext?
    /// Page background last reported by each web surface, for the window tint.
    @State private var pageBackgrounds: [ChromeTintSurface: NSColor] = [:]
    @State private var asyncTextContextOverride: EditorSelectionContext?
    @State private var pendingTextContextLoadTask: Task<Void, Never>?
    @State private var pendingTextContextLoadKey: String?
    @State private var pendingDocumentResolutionRetryTask: Task<Void, Never>?
    @State private var pendingDocumentResolutionRetryKey: String?
    @State private var pendingDocumentResolutionRetryAttempt = 0
    @State private var pdfZoomCommandID = 0
    @State private var pendingPDFZoomCommand: PDFZoomCommand?
    @State private var pdfNavigationCommandID = 0
    @State private var pendingPDFNavigationCommand: PDFNavigationCommand?
    @State private var currentPDFPageInfo = PDFPageInfo(currentPageIndex: 0, currentPageLabel: "—", pageCount: 0)
    @State private var pendingPDFDisplayedPageIndex: Int?
    @State private var pdfPageFieldText = ""
    @State private var pdfOutlineItems: [PDFOutlineItem] = []
    @State private var isPDFOutlinePopoverPresented = false
    @State private var documentNavigatorOutlineItems: [DocumentNavigatorOutlineItem] = []
    @State private var documentNavigatorActiveOutlineItemID: String?
    @State private var documentNavigatorInitialMode: DocumentNavigatorMode = .outline
    @State private var documentNavigatorSearchMatches: [DocumentNavigatorSearchMatch] = []
    @State private var documentNavigatorSearchQuery = ""
    @State private var documentNavigatorActiveSearchIndex: Int?
    @State private var documentNavigatorLineCount = 0
    @State private var isDocumentNavigatorPresented = false
    @State private var isDocumentFindBarPresented = false
    @State private var documentFindBarFocusRequestID = 0
    @State private var documentNavigationSessionOwner: DocumentNavigationSessionOwner?
    @State private var outlinePaletteNavigation: OutlinePaletteNavigation?
    @State private var isDocumentInspectorPresented = false
    @State private var documentFrontmatterAppearance: DocumentFrontmatterAppearance?
    @State private var pdfFocusRequestID = 0
    @State private var imageZoomCommandID = 0
    @State private var pendingImageZoomCommand: ImageZoomCommand?
    @State private var imageAdjustments = ImageAdjustmentSettings.identity
    @State private var imageFocusRequestID = 0
    @State private var csvFocusRequestID = 0
    @State private var canvasFocusRequestID = 0
    @State private var htmlFocusRequestID = 0
    @State private var contentFocusAnchorView: NSView?
    @State private var contentRegionView: NSView?
    private let liveSyncObserverID: String
    @FocusState private var isPDFPageFieldFocused: Bool

    init(
        tabID: TabID,
        state: Binding<WorkspaceTabState>,
        notesModel: NotesWorkspaceModel,
        workspaceTabController: WorkspaceTabController,
        openDocumentPathRegistry: WorkspaceOpenDocumentPathRegistry,
        paletteHost: WorkspacePaletteHost,
        onTabPresentationChange: @escaping (WorkspaceTabPresentation) -> Void,
        onCloseTabRequest: @escaping (TabID) -> Void,
        onWorkspaceItemRenamed: @escaping (String, String, MillerItemKind) -> Void,
        onWorkspaceItemTrashed: @escaping (String, MillerItemKind) -> Void,
        onCreateNote: @escaping (_ folderRelativePath: String?) -> Void,
        isControllerFocusedLeaf: Bool,
        onLeafInteraction: @escaping () -> Void,
        omitsHeaderChrome: Bool = false,
        onChromeTintChange: @escaping (NSColor?) -> Void = { _ in }
    ) {
        self.tabID = tabID
        self._state = state
        self.notesModel = notesModel
        self.workspaceTabController = workspaceTabController
        self.openDocumentPathRegistry = openDocumentPathRegistry
        self.paletteHost = paletteHost
        self.onTabPresentationChange = onTabPresentationChange
        self.onCloseTabRequest = onCloseTabRequest
        self.onWorkspaceItemRenamed = onWorkspaceItemRenamed
        self.onWorkspaceItemTrashed = onWorkspaceItemTrashed
        self.onCreateNote = onCreateNote
        self.isControllerFocusedLeaf = isControllerFocusedLeaf
        self.onLeafInteraction = onLeafInteraction
        self.omitsHeaderChrome = omitsHeaderChrome
        self.onChromeTintChange = onChromeTintChange
        self.liveSyncObserverID = String(describing: tabID)
        _editorController = State(initialValue: workspaceTabController.existingTextEditorController)
        _epubController = State(initialValue: workspaceTabController.existingEPUBController)
        _previewController = State(initialValue: workspaceTabController.existingPreviewController)
        _pdfController = State(initialValue: workspaceTabController.existingPDFController)
        _csvController = State(initialValue: workspaceTabController.existingCSVController)
        _canvasController = State(initialValue: workspaceTabController.existingCanvasController)
        _imageController = State(initialValue: workspaceTabController.existingImageController)
        _htmlController = State(initialValue: workspaceTabController.existingHTMLController)
    }

    private func debugFocusLog(_ message: String) {
        #if DEBUG
        print("[NVModern][WorkspaceFocus] tab=\(tabID) \(message)")
        #endif
    }

    private func debugContentLog(_ message: String) {
        #if DEBUG
        print("[NVModern][WorkspaceContent] tab=\(tabID) \(message)")
        #endif
    }

    private enum WorkspaceResponderArea: Hashable {
        case content
    }

    private var effectiveResponderArea: WorkspaceResponderArea? {
        guard isControllerFocusedLeaf else { return nil }

        if isPDFPageFieldFocused {
            return .content
        }

        guard let firstResponderView = currentFirstResponderView() else {
            return nil
        }

        if isDescendant(firstResponderView, of: contentRegionView) {
            return .content
        }

        return nil
    }

    private var millerLineagePaths: Set<String> {
        var paths = Set(state.selectedFolderChain)
        if let selectedNotePath = state.selectedNotePath {
            paths.insert(selectedNotePath)
        }
        return paths
    }

    private var effectiveLaunchpadMillerSelectedPaths: Set<String> {
        if !launchpadMillerSelectedPaths.isEmpty {
            return launchpadMillerSelectedPaths
        }
        guard let activePath = state.activeMillerItemPath else { return [] }
        return [activePath]
    }

    private var launchpadMillerShelfItems: [MillerItem] {
        launchpadMillerShelfPaths.compactMap { millerItem(relativePath: $0) }
    }

    /// The palette can temporarily replace the rendered content without
    /// changing the tab's committed document or either navigation stack.
    private var displayedDocument: WorkspaceOpenedDocument? {
        palettePreviewDocument ?? state.openedDocument
    }

    private var isPaletteDocumentPreviewActive: Bool {
        palettePreviewDocument != nil
    }

    /// Accent of the frame doing the previewing, so the overlay badge matches
    /// the palette that produced it.
    private var palettePreviewAccentColor: Color {
        switch paletteSession.stack.top.spec.accent {
        case .nav: return DesignTokens.Accent.nav
        case .intent: return DesignTokens.Accent.intent
        case .search: return DesignTokens.Accent.search
        }
    }

    private var activeWorkspaceRelativePath: String? {
        guard case .workspaceNote(let relativePath)? = displayedDocument else {
            return nil
        }
        return relativePath
    }

    private var isLiveSyncEditableWorkspaceDocument: Bool {
        guard !isPaletteDocumentPreviewActive else { return false }

        guard !notesModel.runtimeConfig.sync.mode.automaticallyReloadsFileChanges else {
            return false
        }

        guard activeWorkspaceRelativePath != nil,
              let context = activeEditorContext else {
            return false
        }

        switch context.kind {
        case .text, .csv, .canvas:
            return true
        case .folder, .epub, .pdf, .image, .html, .diff, .unsupported:
            return false
        }
    }

    private var activePDFURL: URL? {
        guard let context = activeEditorContext,
              context.kind == .pdf else {
            return nil
        }

        if case .externalMarkdown(let filePath)? = state.openedDocument,
           context.relativePath == filePath {
            let fileURL = URL(fileURLWithPath: filePath)
            return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
        }

        if let fileURL = notesModel.workspaceURL(for: context.relativePath),
           FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        if let snapshot = state.liveDeletedSnapshot,
           snapshot.relativePath == context.relativePath,
           snapshot.kind == .pdf {
            return temporaryDeletedSnapshotURL(for: snapshot)
        }

        return nil
    }

    private var activeImageURL: URL? {
        guard let context = activeEditorContext,
              context.kind == .image else {
            return nil
        }

        if case .externalMarkdown(let filePath)? = state.openedDocument,
           context.relativePath == filePath {
            let fileURL = URL(fileURLWithPath: filePath)
            return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
        }

        if let fileURL = notesModel.workspaceURL(for: context.relativePath),
           FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        if let snapshot = state.liveDeletedSnapshot,
           snapshot.relativePath == context.relativePath,
           snapshot.kind == .image {
            return temporaryDeletedSnapshotURL(for: snapshot)
        }

        return nil
    }

    private var activeCSVURL: URL? {
        guard let context = activeEditorContext,
              context.kind == .csv else {
            return nil
        }

        if case .externalMarkdown(let filePath)? = state.openedDocument,
           context.relativePath == filePath {
            let fileURL = URL(fileURLWithPath: filePath)
            return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
        }

        if let fileURL = notesModel.workspaceURL(for: context.relativePath),
           FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        if let snapshot = state.liveDeletedSnapshot,
           snapshot.relativePath == context.relativePath,
           snapshot.kind == .csv {
            return temporaryDeletedSnapshotURL(for: snapshot)
        }

        return nil
    }

    private var activeHTMLURL: URL? {
        guard let context = activeEditorContext,
              context.kind == .html else { return nil }
        return previewFileURL(for: context)
    }

    private var activeCanvasURL: URL? {
        guard let context = activeEditorContext,
              context.kind == .canvas else { return nil }
        return previewFileURL(for: context)
    }

    private func previewFileURL(for context: EditorSelectionContext) -> URL? {
        if case .externalMarkdown(let filePath)? = state.openedDocument,
           context.relativePath == filePath {
            let url = URL(fileURLWithPath: filePath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let url = notesModel.workspaceURL(for: context.relativePath),
           FileManager.default.fileExists(atPath: url.path) { return url }
        if let snapshot = state.liveDeletedSnapshot,
           snapshot.relativePath == context.relativePath,
           snapshot.kind == context.kind { return temporaryDeletedSnapshotURL(for: snapshot) }
        return nil
    }

    private var activeHTMLReadAccessURL: URL? {
        guard let htmlURL = activeHTMLURL else { return nil }

        if case .workspaceNote? = state.openedDocument {
            return notesModel.runtimeConfig.rootURL
        }

        return htmlURL.deletingLastPathComponent()
    }

    private var activeWebContentController: EditorWebContentController? {
        guard let context = activeEditorContext else {
            return nil
        }

        switch context.kind {
        case .text:
            return editorController
        case .epub:
            return epubController
        case .folder, .diff, .unsupported:
            return previewController
        case .pdf, .csv, .canvas, .image, .html:
            return nil
        }
    }

    private var canOpenDocumentNavigator: Bool {
        guard let context = activeEditorContext,
              context.kind == .text || context.kind == .epub,
              activeWebContentController != nil else {
            return false
        }

        return true
    }

    private var canOpenDocumentInspector: Bool {
        guard let context = activeEditorContext,
              context.kind == .text || context.kind == .epub,
              activeWebContentController != nil else {
            return false
        }

        return true
    }

    private var canOpenDocumentFind: Bool {
        return activeEditorContext?.kind == .text && activeWebContentController != nil
    }

    private var activePDFScrollRatio: Double? {
        guard !isPaletteDocumentPreviewActive,
              let context = activeEditorContext,
              context.kind == .pdf,
              let relativePath = activeWorkspaceRelativePath,
              relativePath == context.relativePath else {
            return nil
        }

        return WorkspaceSessionStore.shared.documentScrollRatio(
            rootURL: notesModel.runtimeConfig.rootURL,
            relativePath: relativePath,
            kind: .pdf
        )
    }

    private var activePreviewReloadToken: String {
        let manualReloadToken = String(format: "%.6f", notesModel.lastReloadDate.timeIntervalSinceReferenceDate)
        return "\(manualReloadToken)|local=\(state.liveLocalRefreshRevision)"
    }

    private var isNativePreviewActive: Bool {
        activePDFURL != nil || activeImageURL != nil || activeCSVURL != nil || activeCanvasURL != nil || activeHTMLURL != nil
    }

    private var isZoomableNativePreviewActive: Bool {
        activePDFURL != nil || activeImageURL != nil
    }

    private var contentDiagnosticsSnapshot: WorkspaceContentDiagnosticsSnapshot {
        WorkspaceContentDiagnosticsSnapshot(
            showLaunchpad: showLaunchpad,
            openedDocument: state.openedDocument.map { String(describing: $0) } ?? "nil",
            selectedNotePath: state.selectedNotePath ?? "nil",
            contextKind: activeEditorContext?.kind.rawValue ?? "nil",
            contextPath: activeEditorContext?.relativePath ?? "nil",
            hasPDFURL: activePDFURL != nil,
            hasImageURL: activeImageURL != nil,
            hasCSVURL: activeCSVURL != nil,
            hasHTMLURL: activeHTMLURL != nil,
            hasWebController: activeWebContentController != nil,
            hasPDFController: pdfController != nil,
            hasImageController: imageController != nil,
            hasCSVController: csvController != nil,
            hasHTMLController: htmlController != nil
        )
    }

    private var contentDiagnosticsView: some View {
        let snapshot = contentDiagnosticsSnapshot
        return Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                debugContentLog("diagnostics.onAppear \(snapshot.description)")
            }
            .onChange(of: snapshot) { _, newSnapshot in
                debugContentLog("diagnostics.changed \(newSnapshot.description)")
            }
    }

    private var currentDisplayedPDFPageIndex: Int {
        if let pendingPDFDisplayedPageIndex {
            return pendingPDFDisplayedPageIndex
        }
        return currentPDFPageInfo.currentPageIndex
    }

    private var currentPDFPageNumberText: String {
        guard currentPDFPageInfo.pageCount > 0 else { return "" }
        return String(currentDisplayedPDFPageIndex + 1)
    }

    private var hasCustomPDFPageLabel: Bool {
        pendingPDFDisplayedPageIndex == nil &&
        currentPDFPageInfo.pageCount > 0 &&
        currentPDFPageInfo.currentPageLabel != currentPDFPageNumberText
    }

    private var canGoBackInHistory: Bool {
        !state.backHistory.isEmpty
    }

    private var canGoForwardInHistory: Bool {
        !state.forwardHistory.isEmpty
    }

    private var activeProject: NVModernProject {
        notesModel.runtimeConfig.activeProject
    }

    private var activeProjectIconName: String {
        let trimmed = activeProject.icon?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return "folder.fill"
    }

    private var activeProjectIconColor: Color {
        Color(
            // hue: Double(projectHue(for: activeProject.name)) / 360.0,
            hue: Double(projectHue(for: "\(activeProject.name)|\(activeProject.rootURL.path)")) / 360.0,
            saturation: 0.68,
            brightness: 0.88
        )
    }

    private var omniboxBreadcrumb: OmniboxBreadcrumb {
        var segments: [OmniboxBreadcrumb.Segment] = []

        // Emit every folder in the chain with its full relative path. OmniboxView
        // handles any truncation/expansion internally, so we never insert an
        // ellipsis here.
        for relativePath in state.selectedFolderChain {
            if LaunchpadRootColumn.isSynthetic(relativePath) {
                // Workspace is the implicit default and would be noise in every
                // breadcrumb; the other roots are worth naming.
                guard case .workspace = LaunchpadRootColumn.source(for: relativePath) else {
                    segments.append(
                        .folder(
                            name: LaunchpadRootColumn.title(
                                for: LaunchpadRootColumn.source(for: relativePath)
                            ),
                            path: relativePath
                        )
                    )
                    continue
                }
                continue
            }
            let name = (relativePath as NSString).lastPathComponent
            segments.append(.folder(name: name, path: relativePath))
        }

        if let notePath = state.selectedNotePath {
            let fileName = (notePath as NSString).lastPathComponent
            let stem = (fileName as NSString).deletingPathExtension
            segments.append(.note(stem))
        }

        return OmniboxBreadcrumb(segments: segments)
    }

    private var omniboxSiblingFiles: [OmniboxSiblingFile] {
        guard let notePath = state.selectedNotePath else { return [] }

        let parentPath = (notePath as NSString).deletingLastPathComponent
        let normalizedParentPath = parentPath == "." ? "" : parentPath
        return notesModel.childrenByFolder[normalizedParentPath, default: []]
            .filter { $0.kind == .note }
            .map { item in
                OmniboxSiblingFile(
                    relativePath: item.relativePath,
                    name: item.name,
                    iconSystemName: workspaceFileIconName(forPath: item.relativePath)
                )
            }
    }

    private var omniboxEmptyPlaceholder: String {
        guard case .externalMarkdown(let filePath)? = state.openedDocument else {
            return "New Tab"
        }

        return compactExternalPathLabel(for: filePath)
    }

    private func compactExternalPathLabel(for filePath: String) -> String {
        let components = URL(fileURLWithPath: filePath)
            .standardizedFileURL
            .pathComponents
            .filter { component in
                component != "/" && !component.isEmpty
            }

        guard !components.isEmpty else {
            return URL(fileURLWithPath: filePath).lastPathComponent
        }

        let visibleComponents = Array(components.suffix(4))
        let prefix = components.count > visibleComponents.count ? "… / " : ""
        return prefix + visibleComponents.joined(separator: " / ")
    }

    /// The magnifier and `Cmd+K`: close when the plain root frame is already
    /// showing, otherwise open (or fall back) to it.
    private func togglePalette() {
        if paletteHost.isVisible,
           paletteSession.stack.depth == 1,
           paletteSession.stack.top.spec.isRoot {
            paletteHost.close()
        } else {
            openPalette(preset: .root)
        }
    }

    /// Routed through the action runtime rather than through tab state: the
    /// sidebar belongs to the window, not to this tab, and this is the same
    /// path the View menu's Sidebar toggle takes.
    private func toggleSidebar() {
        guard let windowNumber = omniboxAnchor?.window?.windowNumber else { return }
        let isVisible = WorkspaceActionRouter.isSidebarVisible(in: windowNumber)
        _ = WorkspaceActionRouter.performSetSidebarVisible(!isVisible, in: windowNumber)
    }

    private func resolveOmniboxAnchor(_ anchor: NSView) {
        omniboxAnchor = anchor
        guard anchor.window != nil, let pendingPreset = pendingPaletteOpenPreset else {
            return
        }
        pendingPaletteOpenPreset = nil
        DispatchQueue.main.async {
            openPalette(preset: pendingPreset)
        }
    }

    // MARK: — launchpad

    /// Render the launchpad whenever a tab has no open document. The explicit
    /// `kind` field is still authoritative for persisted state intent; this
    /// accessor keeps the rendering path simple and avoids empty-document
    /// tabs from showing a blank note surface.
    private var showLaunchpad: Bool {
        switch state.kind {
        case .launchpad, .note:
            return displayedDocument == nil
        }
    }

    private var launchpadRecents: [LaunchpadRecentItem] {
        return WorkspaceSessionStore.shared
            .recentDocuments(rootURL: notesModel.runtimeConfig.rootURL, limit: 8)
            .compactMap { recent -> LaunchpadRecentItem? in
                guard case .workspaceNote(let relativePath) = recent.document else {
                    return nil
                }
                let fileName = (relativePath as NSString).lastPathComponent
                let title = (fileName as NSString).deletingPathExtension
                let folderPath = (relativePath as NSString).deletingLastPathComponent
                let folderLabel = folderPath.isEmpty ? "Workspace" : (folderPath as NSString).lastPathComponent
                return LaunchpadRecentItem(
                    id: relativePath,
                    title: title.isEmpty ? recent.title : title,
                    relativePath: relativePath,
                    folderLabel: folderLabel
                )
            }
    }

    @ViewBuilder
    private var launchpadMillerView: some View {
        MillerColumnsView(
            columns: orderedMillerColumns,
            lineageFolderChain: state.selectedFolderChain,
            lineagePaths: millerLineagePaths,
            activeDepth: state.millerActiveDepth,
            activeItemPath: state.activeMillerItemPath,
            showActiveSelection: true,
            onSelectFolder: { depth, _, folderPath in
                onLeafInteraction()
                applyMillerSelection(relativePath: folderPath, kind: .folder, depth: depth)
            },
            onSelectNote: { depth, _, notePath in
                onLeafInteraction()
                applyMillerSelection(relativePath: notePath, kind: .note, depth: depth)
            },
            onOpenNote: { relativePath in
                onLeafInteraction()
                navigateToNote(relativePath: relativePath)
            },
            onOpenNoteInNewTab: { relativePath in
                _ = WorkspaceActionRouter.performOpenDocument(
                    .workspaceNote(relativePath: relativePath),
                    disposition: .backgroundTab,
                    in: nil
                )
            },
            onShowInFinder: { relativePath in
                showWorkspaceItemInFinder(relativePath: relativePath)
            },
            onCopyPath: { relativePath in
                copyRelativePathToPasteboard(relativePath)
            },
            onCopyAbsolutePath: { relativePath in
                copyAbsolutePathToPasteboard(relativePath)
            },
            onRenameItem: { relativePath, kind, currentName in
                promptForWorkspaceItemRename(relativePath: relativePath, kind: kind, currentName: currentName)
            },
            onDuplicateNote: { relativePath in
                duplicateWorkspaceNote(relativePath: relativePath)
            },
            onMoveItemToTrash: { relativePath, kind, currentName in
                confirmMoveWorkspaceItemToTrash(relativePath: relativePath, kind: kind, currentName: currentName)
            },
            onCreateNote: {
                startCreateNoteFlow()
            },
            onCreateNoteInFolder: { relativePath in
                startCreateNoteFlow(inFolderRelativePath: relativePath)
            },
            onCreateFolderInFolder: { relativePath in
                promptForFolderCreation(inFolderRelativePath: relativePath)
            },
            onCreateNoteFromClipboardInFolder: { relativePath in
                runWorkspaceAction("workspace.note.createFromClipboard", args: folderActionArgs(for: relativePath))
            },
            onSearchFolder: { relativePath in
                openContentSearch(inFolderRelativePath: relativePath)
            },
            onOpenFolderInFinder: { relativePath in
                openWorkspaceFolderInFinder(relativePath: relativePath)
            },
            onCopyFolderPath: { relativePath in
                copyFolderRelativePathToPasteboard(relativePath)
            },
            onCopyFolderAbsolutePath: { relativePath in
                copyFolderAbsolutePathToPasteboard(relativePath)
            },
            onEditFinderTags: { relativePath, displayName in
                promptForFinderTags(relativePath: relativePath, displayName: displayName)
            },
            onKeyboardFocus: {
                prepareMillerSelectionForSearchFocusTransfer()
            },
            onKeyboardTab: {
                handleLaunchpadMillerTab()
            },
            onMoveCommand: { direction in
                handleMillerMove(direction)
            },
            isKeyboardFocused: true,
            ownsKeyboard: launchpadMillerOwnsKeyboard,
            focusRequestID: launchpadMillerFocusRequestID,
            preview: launchpadMillerPreview,
            horizontalScrollRequest: workspaceTabController.millerHorizontalScrollRequest,
            horizontalScrollOrigin: $state.millerHorizontalOrigin,
            dropRouter: workspaceTabController.millerDropRouter,
            selectedPaths: effectiveLaunchpadMillerSelectedPaths,
            workspaceRootURL: notesModel.runtimeConfig.rootURL,
            shelfItems: launchpadMillerShelfItems,
            onSelectionGesture: { depth, row, item, gesture in
                onLeafInteraction()
                handleMillerSelectionGesture(depth: depth, row: row, item: item, gesture: gesture)
            },
            onStageItems: { relativePaths in
                stageMillerItems(relativePaths)
            },
            onRemoveShelfItem: { relativePath in
                launchpadMillerShelfPaths.removeAll { $0 == relativePath }
            },
            onClearShelf: {
                launchpadMillerShelfPaths.removeAll()
            },
            onMoveItems: { relativePaths, destinationFolderPath in
                moveMillerItems(relativePaths, toFolderRelativePath: destinationFolderPath)
            },
            onOpenItemsInNewTabs: { relativePaths in
                openMillerItemsInNewTabs(relativePaths)
            },
            onRevealItems: { relativePaths in
                revealMillerItemsInFinder(relativePaths)
            },
            onCopyItemPaths: { relativePaths, absolute in
                copyMillerItemPaths(relativePaths, absolute: absolute)
            },
            onMoveItemsToTrash: { relativePaths in
                confirmMoveMillerItemsToTrash(relativePaths)
            }
        )
    }

    private var orderedMillerColumns: [[MillerItem]] {
        let columns = notesModel.columns(
            for: state.selectedFolderChain,
            recentItems: launchpadRecentMillerItems
        )
        let root = notesModel.runtimeConfig.rootURL.standardizedFileURL.path
        return MillerDetailsSortResolver.orderedColumns(
            columns,
            chain: state.selectedFolderChain,
            detailsEnabled: isMillerDetailsModeEnabled
        ) { folderKey in
            millerSortPreferences.override(root: root, folderKey: folderKey)
        }
    }

    private func handleLaunchpadRecentOpen(_ item: LaunchpadRecentItem) {
        navigateToNote(relativePath: item.relativePath)
    }

    // MARK: — palette

    /// Everything the palette providers are allowed to know about this tab.
    /// Built inside the resolve task, never during a render pass.
    private func makePaletteContext() -> PaletteContext {
        let windowNumber = omniboxAnchor?.window?.windowNumber
        let selectedThemeID = UserEditorThemeSelection.selectedThemeID()
        return PaletteContext(
            notesModel: notesModel,
            openTabEntries: openDocumentPathRegistry.entries,
            currentDocumentRelativePath: committedWorkspaceNoteRelativePath,
            currentDocumentTitle: committedDocumentTitle,
            currentFolderRelativePath: currentMillerFolderPath,
            projectRootPath: notesModel.runtimeConfig.rootURL.path,
            windowNumber: windowNumber,
            currentDocumentThemeID: effectiveDocumentInspectorAppearance.settings.theme.rawValue,
            currentDocumentWidth: effectiveDocumentInspectorAppearance.settings.width,
            currentThemeTitle: selectedThemeID.map(UserEditorThemeCatalog.displayTitle(for:)) ?? "System",
            isCompactToolbarEnabled: CompactToolbarPreference.isEnabled,
            isSidebarVisible: WorkspaceActionRouter.isSidebarVisible(in: windowNumber),
            outlineItems: paletteOutlineItems,
            activeOutlineItemID: documentNavigatorActiveOutlineItemID
        )
    }

    private var paletteOutlineItems: [DocumentOutlineItem] {
        guard activeEditorContext?.kind == .text else { return [] }
        return documentNavigatorOutlineItems
    }

    private func handlePaletteFrameChanged(_ frame: PaletteFrameSpec) {
        guard frame.sources == [.outline] else {
            endOutlinePaletteNavigation(commit: false, restoreFocus: false)
            return
        }
        guard outlinePaletteNavigation == nil else { return }
        closeDocumentFindBar(restoreFocus: false)
        if documentNavigationSessionOwner == .navigator {
            documentNavigationSessionOwner = nil
            sendDocumentNavigatorAction(["kind": "commit", "focus": false])
        }
        isDocumentNavigatorPresented = false
        guard let context = activeEditorContext,
              context.kind == .text,
              let controller = activeWebContentController else { return }
        outlinePaletteNavigation = OutlinePaletteNavigation(
            controller: controller, path: context.relativePath
        )
        documentNavigationSessionOwner = .outlinePalette
        sendOutlinePaletteAction(["kind": "begin"])
    }

    private func sendOutlinePaletteAction(_ action: [String: Any]) {
        guard let navigation = outlinePaletteNavigation else { return }
        navigation.controller.bridge.sendCommand(
            "documentNavigation", payload: ["path": navigation.path, "action": action]
        )
    }

    private func endOutlinePaletteNavigation(commit: Bool, restoreFocus: Bool) {
        guard let navigation = outlinePaletteNavigation else { return }
        sendOutlinePaletteAction(["kind": commit ? "commit" : "cancel", "focus": restoreFocus])
        outlinePaletteNavigation = nil
        if documentNavigationSessionOwner == .outlinePalette { documentNavigationSessionOwner = nil }
        if restoreFocus { navigation.controller.requestFocus() }
    }

    private func refreshOutlinePalette() {
        guard paletteHost.isVisible, paletteSession.stack.top.spec.sources == [.outline] else { return }
        paletteSession.resolve(immediate: true)
    }

    /// Title of the document the tab shows, ignoring any palette preview. Nil
    /// on a launchpad tab, which is what drops the "on <file>" subject group.
    private var committedDocumentTitle: String? {
        state.openedDocument?.tabPresentation.title
    }

    /// The tab's committed workspace note, ignoring any palette preview: a
    /// preview must not change which folder Refile excludes or which note the
    /// verbs frame would act on.
    private var committedWorkspaceNoteRelativePath: String? {
        guard case .workspaceNote(let relativePath)? = state.openedDocument else { return nil }
        return relativePath
    }

    private func handlePaletteSelectionChanged(_ item: PaletteItem?) {
        if paletteSession.stack.top.spec.sources == [.outline] {
            // Opening highlights the current section without moving its cursor.
            guard paletteSession.shouldPreviewOutlineSelection else { return }
            if case .jumpToOutlineItem(let id)? = item?.activation,
               let heading = paletteOutlineItems.first(where: { $0.id == id }),
               case .text(let from, _, _) = heading.destination {
                sendOutlinePaletteAction(["kind": "jumpToOutlineItem", "id": id, "from": from])
            }
            return
        }
        guard paletteSession.isPreviewModeActive, let relativePath = item?.target?.noteRelativePath else {
            clearPaletteDocumentPreview()
            return
        }

        let previewDocument = WorkspaceOpenedDocument.workspaceNote(relativePath: relativePath)
        if previewDocument == state.openedDocument {
            clearPaletteDocumentPreview()
            return
        }
        guard palettePreviewDocument != previewDocument else { return }

        if palettePreviewDocument == nil {
            palettePreviewOriginalTextContextOverride = asyncTextContextOverride
            palettePreviewOriginalImageAdjustments = imageAdjustments
        }
        palettePreviewDocument = previewDocument
        asyncTextContextOverride = nil
        pushEditorContext()
    }

    private func clearPaletteDocumentPreview() {
        guard palettePreviewDocument != nil else { return }
        palettePreviewDocument = nil
        asyncTextContextOverride = palettePreviewOriginalTextContextOverride
        palettePreviewOriginalTextContextOverride = nil
        if let originalImageAdjustments = palettePreviewOriginalImageAdjustments {
            imageAdjustments = originalImageAdjustments
        }
        palettePreviewOriginalImageAdjustments = nil
        pushEditorContext()
    }

    /// Everything a palette item can do that is not "push another frame".
    private func handlePaletteActivation(
        item: PaletteItem,
        activation: PaletteActivation,
        openInNewTab: Bool,
        frame: PaletteFrameSpec
    ) {
        clearPaletteDocumentPreview()

        // A plugin's picker: whatever the row would have done, it answers the
        // plugin instead. Resolved before the close so the close hook finds
        // nothing left to cancel.
        if let pick = frame.pluginPick {
            switch activation {
            case .pluginPick(_, let value):
                PluginPickCenter.shared.resolve(pick.requestID, with: value)
            case .openNote(let relativePath, _), .openFolder(let relativePath):
                PluginPickCenter.shared.resolve(pick.requestID, with: .string(relativePath))
            default:
                PluginPickCenter.shared.cancel(pick.requestID)
            }
            paletteHost.close()
            return
        }

        switch activation {
        case .jumpToOutlineItem(let id):
            guard let heading = paletteOutlineItems.first(where: { $0.id == id }),
                  case .text(let from, _, _) = heading.destination else { return }
            sendOutlinePaletteAction(["kind": "jumpToOutlineItem", "id": id, "from": from])
            endOutlinePaletteNavigation(commit: true, restoreFocus: true)
            paletteHost.close()
        case .openNote(let relativePath, let findTerm):
            if openInNewTab {
                _ = WorkspaceActionRouter.performOpenNoteInNewTab(relativePath: relativePath, in: nil)
            } else {
                navigateToNote(relativePath: relativePath)
                if let findTerm, !findTerm.isEmpty {
                    seedDocumentFindBar(with: findTerm)
                }
            }
            finishPaletteRun()

        case .openFolder(let relativePath):
            selectMillerFolder(relativePath: relativePath)
            finishPaletteRun()

        case .focusTab(let tabID):
            _ = WorkspaceActionRouter.performSelectTab(publicID: tabID, in: nil)
            finishPaletteRun()

        case .runAction(let method, let args, let target):
            finishPaletteRun()
            // Next turn: the action can present its own sheet or alert, which
            // must not race the palette's teardown.
            DispatchQueue.main.async {
                runWorkspaceAction(method, args: args, target: target, surface: "palette")
            }

        case .push, .pluginPick:
            // `.push` is handled inside `PaletteSession`, and a plugin pick
            // only occurs in a picker frame, answered above.
            break
        }
    }

    /// A verb run once per marked noun. Sequential and awaited so a refile of
    /// several notes cannot interleave its index reloads.
    private func handlePaletteBatchActivation(
        item: PaletteItem,
        activations: [PaletteActivation],
        frame: PaletteFrameSpec
    ) {
        clearPaletteDocumentPreview()
        finishPaletteRun()

        DispatchQueue.main.async {
            Task { @MainActor in
                var failures = 0
                for activation in activations {
                    guard case .runAction(let method, let args, let target) = activation else { continue }
                    do {
                        _ = try await ActionExecutor.shared.invoke(
                            ActionRequest(
                                method: method,
                                args: args,
                                target: target,
                                source: .internalCall,
                                metadata: ["surface": .string("palette.batch")]
                            )
                        )
                    } catch {
                        failures += 1
                        paletteDebugLog("batch.failed method=\(method) error=\(error)")
                    }
                }
                if failures > 0 { NSSound.beep() }
            }
        }
    }

    /// Pin mode keeps the palette open at root after a run; otherwise a run
    /// dismisses it.
    private func finishPaletteRun() {
        if paletteSession.isPinModeActive {
            paletteSession.handleDidRun()
        } else {
            paletteHost.close()
        }
    }

    /// A passage's default verb: open the note, then hand its term to the find
    /// bar once the document is on screen. Silently skipped on a surface with
    /// no find bar.
    private func seedDocumentFindBar(with term: String) {
        DispatchQueue.main.async {
            guard canOpenDocumentNavigator else { return }
            documentNavigatorSearchQuery = term
            openDocumentFindBar()
        }
    }

    private func folderActionArgs(for folderPath: String?) -> [String: ActionValue] {
        if let folder = folderPath, !folder.isEmpty {
            return ["folder": .string(folder)]
        }
        return [:]
    }

    private func runWorkspaceAction(
        _ method: String,
        args: [String: ActionValue] = [:],
        target: ActionTarget = .automatic,
        surface: String = "workspaceTab"
    ) {
        Task { @MainActor in
            do {
                _ = try await ActionExecutor.shared.invoke(
                    ActionRequest(
                        method: method,
                        args: args,
                        target: target,
                        source: .internalCall,
                        metadata: ["surface": .string(surface)]
                    )
                )
            } catch {
                print("[NVModern][PaletteAction] method=\(method) failed: \(error)")
                NSSound.beep()
            }
        }
    }

    // MARK: — context ribbon

    private var contextRibbonFolderName: String {
        guard let folderPath = currentMillerFolderPath else {
            return LaunchpadRootColumn.title(
                for: currentRootSource
            )
        }
        let name = (folderPath as NSString).lastPathComponent
        return name.isEmpty ? activeProject.name : name
    }

    private var contextRibbonNearbyNotes: [MillerItem] {
        guard state.openedDocument == nil || state.selectedNotePath != nil else { return [] }
        return notesModel.columns(for: state.selectedFolderChain, recentItems: launchpadRecentMillerItems).last?.filter { $0.kind == .note } ?? []
    }

    @ViewBuilder
    private var contextRibbon: some View {
        HStack(spacing: DesignTokens.Spacing.space2) {
            if state.openedDocument == nil || state.selectedNotePath != nil {
                Label(contextRibbonFolderName, systemImage: "folder")
                    .font(DesignTokens.Typography.secondary.weight(.medium))
                    .foregroundStyle(DesignTokens.TextStyle.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                    .help(currentMillerFolderPath ?? notesModel.runtimeConfig.rootURL.path)

                Divider()
                    .frame(height: 18)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignTokens.Spacing.space1) {
                        ForEach(contextRibbonNearbyNotes) { item in
                            ContextRibbonDocumentButton(
                                title: (item.name as NSString).deletingPathExtension,
                                relativePath: item.relativePath,
                                isCurrent: item.relativePath == state.selectedNotePath
                            ) {
                                navigateToNote(relativePath: item.relativePath)
                            }
                        }
                    }
                }

                Divider()
                    .frame(height: 18)

                ContextRibbonButton(icon: "plus", label: "New note") {
                    startCreateNoteFlow(inFolderRelativePath: currentMillerFolderPath)
                }
                ContextRibbonButton(icon: "folder.badge.plus", label: "New folder") {
                    promptForFolderCreation(inFolderRelativePath: currentMillerFolderPath)
                }
                if state.selectedNotePath != nil {
                    ContextRibbonButton(icon: "doc.on.doc", label: "Duplicate") {
                        runWorkspaceAction("workspace.note.duplicateCurrent")
                    }
                }
            } else {
                ContextRibbonButton(icon: "square.on.square", label: "Duplicate tab") {
                    runWorkspaceAction("workspace.tab.duplicate")
                }
                ContextRibbonButton(icon: "rectangle.split.2x1", label: "Split right") {
                    runWorkspaceAction("workspace.split.right")
                }
                ContextRibbonButton(icon: "rectangle.split.1x2", label: "Split down") {
                    runWorkspaceAction("workspace.split.down")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(DesignTokens.Surface.base)
    }

    private func openContentSearch(inFolderRelativePath folderPath: String?) {
        let initialQuery: String
        if let folderPath, !folderPath.isEmpty {
            selectMillerFolder(relativePath: folderPath)
            initialQuery = folderPath
        } else {
            state.openedDocument = nil
            state.selectedNotePath = nil
            state.selectedFolderChain = [LaunchpadRootColumn.workspacePath]
            state.millerActiveDepth = 0
            state.activeMillerItemPath = nil
            initialQuery = ""
        }

        openPalette(preset: .contentSearch(initialQuery: initialQuery))
    }

    private func handlePaletteDidClose() {
        endOutlinePaletteNavigation(commit: false, restoreFocus: true)
        paletteSession.handleDidClose()
        clearPaletteDocumentPreview()
    }

    private func requestLaunchpadMillerFocus() {
        guard showLaunchpad else { return }
        launchpadMillerFocusRequestID &+= 1
    }

    /// The browser owns the keyboard whenever this tab is the focused leaf and
    /// is showing the launchpad, unless the palette is up. Deliberately
    /// independent of SwiftUI focus: the browser is the only keyboard surface
    /// on a launchpad tab, so it should answer arrow keys from the moment the
    /// tab opens, not after a click lands on a row.
    private var launchpadMillerOwnsKeyboard: Bool {
        isControllerFocusedLeaf && showLaunchpad && !paletteHost.isVisible
    }

    private func handleLaunchpadMillerTab() {
        guard showLaunchpad else { return }
        openPalette(preset: .root)
    }

    /// Presents the palette on a preset.
    ///
    /// The deferred dispatch and the anchor retry are not incidental: a
    /// menu-bar item dispatches while the anchor's window is momentarily
    /// detached, and presenting then would drop the palette on the floor.
    private func openPalette(
        preset: PalettePreset,
        remainingAnchorRetries: Int = 4
    ) {
        paletteHost.closeImmediately()
        paletteDebugLog("tab.openPalette preset=\(preset.debugLabel) retries=\(remainingAnchorRetries) anchorWindow=\(String(describing: omniboxAnchor?.window?.windowNumber))")
        clearPaletteDocumentPreview()
        pendingPaletteOpenPreset = preset

        DispatchQueue.main.async {
            guard let anchor = omniboxAnchor, anchor.window != nil else {
                paletteDebugLog("tab.openPalette noAnchor retries=\(remainingAnchorRetries)")
                if remainingAnchorRetries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                        guard pendingPaletteOpenPreset == preset, !paletteHost.isVisible else { return }
                        openPalette(preset: preset, remainingAnchorRetries: remainingAnchorRetries - 1)
                    }
                }
                return
            }
            pendingPaletteOpenPreset = nil

            paletteSession.makeContext = { makePaletteContext() }
            paletteSession.onFrameChanged = { frame in
                handlePaletteFrameChanged(frame)
            }
            paletteSession.onSelectionChanged = { item in
                handlePaletteSelectionChanged(item)
            }
            paletteSession.onActivation = { item, activation, openInNewTab, frame in
                handlePaletteActivation(
                    item: item,
                    activation: activation,
                    openInNewTab: openInNewTab,
                    frame: frame
                )
            }
            paletteSession.onBatchActivation = { item, activations, frame in
                handlePaletteBatchActivation(
                    item: item,
                    activations: activations,
                    frame: frame
                )
            }
            paletteSession.onClose = {
                paletteHost.close()
            }
            paletteSession.open(preset: preset)

            paletteHost.present(
                preferredHeight: Self.paletteEstimatedHeight,
                onEscape: {
                    paletteSession.handleEscape()
                },
                onClose: {
                    handlePaletteDidClose()
                }
            ) {
                PaletteFrameView(session: paletteSession)
            }
        }
    }

    private var documentNavigatorPopover: some View {
        DocumentNavigatorPopoverView(
            outlineItems: documentNavigatorOutlineItems,
            activeOutlineItemID: documentNavigatorActiveOutlineItemID,
            lineCount: documentNavigatorLineCount,
            initialMode: documentNavigatorInitialMode,
            onPreviewOutline: previewDocumentNavigatorOutlineItem,
            onPreviewLine: previewDocumentNavigatorLine,
            onCommit: commitDocumentNavigator,
            onCancel: cancelDocumentNavigator
        )
    }

    private var documentFindBar: some View {
        DocumentFindBarView(
            query: $documentNavigatorSearchQuery,
            matchCount: documentNavigatorSearchMatches.count,
            activeMatchIndex: documentNavigatorActiveSearchIndex,
            focusRequestID: documentFindBarFocusRequestID,
            onQueryChange: updateDocumentNavigatorSearch,
            onNext: { moveDocumentFindMatch(by: 1) },
            onPrevious: { moveDocumentFindMatch(by: -1) },
            onClose: { closeDocumentFindBar() }
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignTokens.TextStyle.tertiary.opacity(0.18))
                .frame(height: 1)
        }
    }

    private var documentInspectorPopover: some View {
        DocumentInspectorPopoverView(
            settings: $state.documentInspectorSettings,
            effectiveAppearance: effectiveDocumentInspectorAppearance,
            frontmatterAppearance: documentFrontmatterAppearance,
            wordCount: documentInspectorWordCount,
            canUnwrapProseLines: canUnwrapProseLines,
            usesPublisherThemeDefault: activeEditorContext?.kind == .epub,
            onReset: resetDocumentInspector
        )
    }

    /// Inspector-column variants: popover chrome and its nested mode switcher
    /// are stripped because the column provides three root-level panes.
    private var documentNavigatorColumn: some View {
        DocumentNavigatorPopoverView(
            outlineItems: documentNavigatorOutlineItems,
            activeOutlineItemID: documentNavigatorActiveOutlineItemID,
            lineCount: documentNavigatorLineCount,
            initialMode: documentNavigatorInitialMode,
            embedsInColumn: true,
            showsModeBar: false,
            onPreviewOutline: previewDocumentNavigatorOutlineItem,
            onPreviewLine: previewDocumentNavigatorLine,
            onCommit: commitDocumentNavigatorInColumn,
            onCancel: cancelDocumentNavigator
        )
        .id(documentNavigatorInitialMode)
    }

    private var documentInspectorColumn: some View {
        NativeDocumentInspectorView(
            settings: $state.documentInspectorSettings,
            frontmatterAppearance: documentFrontmatterAppearance,
            title: activeEditorContext?.title,
            relativePath: activeEditorContext?.relativePath,
            modifiedDate: activeEditorContext?.modifiedDate,
            mimeType: activeEditorContext?.mimeType,
            fileSize: activeEditorContext?.fileSize,
            wordCount: documentInspectorWordCount,
            canUnwrapProseLines: canUnwrapProseLines,
            usesPublisherThemeDefault: activeEditorContext?.kind == .epub,
            onReset: resetDocumentInspector,
            canRunFileActions: inspectorDocumentHasFile,
            onShowInFinder: { runWorkspaceAction("workspace.document.reveal", surface: "documentInspector") },
            onReloadFromDisk: { runWorkspaceAction("workspace.document.reload", surface: "documentInspector") }
        )
    }

    private var inspectorDocumentHasFile: Bool {
        switch state.openedDocument {
        case .workspaceNote, .externalMarkdown: return true
        default: return false
        }
    }

    /// The trailing inspector column exposes navigation and document settings
    /// as peers, matching the flat pane structure of standard Mac inspectors.
    private var inspectorColumn: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: inspectorPaneSelection) {
                Label("Outline", systemImage: "list.bullet.indent").tag(NativeInspectorPane.outline)
                if activeEditorContext?.kind == .text {
                    Label("Line", systemImage: "number").tag(NativeInspectorPane.line)
                }
                Label("Document", systemImage: "info.circle").tag(NativeInspectorPane.document)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            Group {
                if isDocumentNavigatorPresented {
                    documentNavigatorColumn
                } else if isDocumentInspectorPresented {
                    documentInspectorColumn
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var inspectorPaneSelection: Binding<NativeInspectorPane> {
        Binding(
            get: {
                if isDocumentInspectorPresented {
                    return .document
                }
                return documentNavigatorInitialMode == .line ? .line : .outline
            },
            set: { pane in
                switch pane {
                case .outline:
                    documentNavigatorInitialMode = .outline
                    isDocumentNavigatorPresented = true
                case .line:
                    documentNavigatorInitialMode = .line
                    isDocumentNavigatorPresented = true
                case .document:
                    isDocumentInspectorPresented = true
                }
            }
        )
    }

    /// One trailing inspector column backing both the document navigator and
    /// the document info panel; whichever was requested most recently wins,
    /// and dismissing the inspector clears both.
    private var isAnyDocumentInspectorPresented: Binding<Bool> {
        Binding(
            get: {
                isDocumentNavigatorPresented || isDocumentInspectorPresented
            },
            set: { isPresented in
                if isPresented {
                    if !isDocumentNavigatorPresented && !isDocumentInspectorPresented {
                        isDocumentInspectorPresented = true
                    }
                } else {
                    isDocumentNavigatorPresented = false
                    isDocumentInspectorPresented = false
                }
            }
        )
    }

    private func syncHistoryNavigationToController() {
        workspaceTabController.updateHistoryNavigation(
            canGoBack: canGoBackInHistory,
            canGoForward: canGoForwardInHistory,
            navigateBack: { navigateBackInHistory() },
            navigateForward: { navigateForwardInHistory() }
        )
    }

    private func syncMillerNavigationToController() {
        workspaceTabController.updateMillerNavigation { relativePath, selectDocument in
            showInParentFolder(relativePath: relativePath, selectDocument: selectDocument)
        }
    }

    var body: some View {
        contentStateModifiers(
            shellPresentationHandlers(
                lifecycleModifiers(tabContentStack)
            )
        )
        .onChange(of: chromeTint) { _, tint in
            onChromeTintChange(tint)
        }
        .onAppear {
            onChromeTintChange(chromeTint)
        }
    }

    private enum ChromeTintSurface: Hashable {
        case text
        case epub
    }

    /// The page colour of the web surface this tab shows. Native surfaces
    /// (PDF, CSV, image, canvas), folders and the launchpad leave the chrome
    /// to the system.
    private var chromeTint: NSColor? {
        guard state.kind == .note, let kind = activeEditorContext?.kind else { return nil }
        switch kind {
        case .text, .diff:
            return pageBackgrounds[.text]
        case .epub:
            return pageBackgrounds[.epub]
        default:
            return nil
        }
    }

    /// The tab's backdrop, which also fills the titlebar and tab bar above it.
    private var backdropColor: NSColor {
        (notesModel.runtimeConfig.documentDefaults.tintsWindow ? chromeTint : nil) ?? .windowBackgroundColor
    }

    /// Records a `pageBackground` report; true when the event was one.
    private func recordPageBackground(_ event: String, _ payload: [String: Any], surface: ChromeTintSurface?) -> Bool {
        guard event == "pageBackground" else { return false }
        if let surface, let color = PageBackgroundReporter.color(from: payload) {
            pageBackgrounds[surface] = color
        }
        return true
    }

    private var tabContentStack: some View {
        VStack(spacing: 0) {
            if !omitsHeaderChrome {
                OmniboxView(
                    breadcrumb: omniboxBreadcrumb,
                    emptyPlaceholder: omniboxEmptyPlaceholder,
                    presentation: .standard,
                    reservesTrafficLightSpace: false,
                    isFocusedPane: isControllerFocusedLeaf,
                    isContextRibbonOpen: isContextRibbonVisible,
                    canGoBack: canGoBackInHistory,
                    canGoForward: canGoForwardInHistory,
                    canOpenDocumentNavigator: canOpenDocumentNavigator,
                    canOpenDocumentInspector: canOpenDocumentInspector,
                    isDocumentNavigatorPresented: $isDocumentNavigatorPresented,
                    isDocumentInspectorPresented: $isDocumentInspectorPresented,
                    documentNavigatorPopoverContent: AnyView(documentNavigatorPopover),
                    documentInspectorPopoverContent: AnyView(documentInspectorPopover),
                    siblingFiles: omniboxSiblingFiles,
                    onAnchorResolved: resolveOmniboxAnchor,
                    onMagnifierTap: togglePalette,
                    onToggleSidebar: toggleSidebar,
                    onSegmentTap: { path in
                        guard let depth = state.selectedFolderChain.firstIndex(of: path) else { return }
                        applyMillerSelection(relativePath: path, kind: .folder, depth: depth)
                    },
                    onSiblingFileTap: { relativePath in
                        navigateToNote(relativePath: relativePath)
                    },
                    onEllipsisTap: {},
                    onPrevTap: navigateBackInHistory,
                    onNextTap: navigateForwardInHistory,
                    onReloadTap: reloadCurrentDocumentFromDisk,
                    onRevealTap: {
                        if let notePath = state.selectedNotePath {
                            showWorkspaceItemInFinder(relativePath: notePath)
                        }
                    },
                    onFindInDocument: openDocumentFindBar,
                    onExpandTap: {
                        withAnimation(DesignTokens.Motion.bloom) {
                            isContextRibbonVisible.toggle()
                        }
                    }
                )
                .padding(.horizontal, DesignTokens.Spacing.space2)
                .padding(.vertical, DesignTokens.WorkspaceChrome.standardToolbarVerticalPadding)
                .background(DesignTokens.Surface.base)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(DesignTokens.WorkspaceChrome.separatorColor)
                        .frame(height: 1)
                }
            }

            if !omitsHeaderChrome && isContextRibbonVisible {
                contextRibbon
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }

//            Divider()

            // The side stack belongs to the tab, so its column sits beside
            // whatever the tab shows: the launchpad or any document kind.
            SideStackColumnLayout(
                isPresented: state.sideStack.isOpen,
                width: state.sideStack.resolvedWidth,
                onWidthCommit: { width in
                    workspaceTabController.sideStack.setWidth(width)
                }
            ) {
            if showLaunchpad {
                LaunchpadView(browseContent: { launchpadMillerView })
                .onAppear {
                    debugContentLog("render.launchpad \(contentDiagnosticsSnapshot.description)")
                }
            } else {
                VStack(spacing: 0) {
                if isDocumentFindBarPresented, canOpenDocumentFind {
                    documentFindBar
                }
                Group {
                if let pdfURL = activePDFURL {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            iconToolbarButton(systemName: "chevron.left", help: "Previous Page") {
                                issuePDFNavigationCommand(.previousPage)
                            }
                            .disabled(currentPDFPageInfo.pageCount <= 1 || currentDisplayedPDFPageIndex <= 0)

                            iconToolbarButton(systemName: "chevron.right", help: "Next Page") {
                                issuePDFNavigationCommand(.nextPage)
                            }
                            .disabled(
                                currentPDFPageInfo.pageCount <= 1 ||
                                currentDisplayedPDFPageIndex >= max(0, currentPDFPageInfo.pageCount - 1)
                            )

                            Text("Page")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            TextField("1", text: $pdfPageFieldText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .frame(width: 52)
                                .disabled(currentPDFPageInfo.pageCount == 0)
                                .focused($isPDFPageFieldFocused)
                                .onSubmit {
                                    commitPDFPageField()
                                }
                                .onChange(of: isPDFPageFieldFocused) { _, isFocused in
                                    if !isFocused {
                                        commitPDFPageField()
                                    }
                                }

                            Text("of \(currentPDFPageInfo.pageCount)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            if hasCustomPDFPageLabel {
                                Text("(\(currentPDFPageInfo.currentPageLabel))")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }

                            Divider()
                                .frame(height: 14)

                            Button {
                                isPDFOutlinePopoverPresented.toggle()
                            } label: {
                                Label("Contents", systemImage: "list.bullet.indent")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .disabled(pdfOutlineItems.isEmpty)
                            .popover(isPresented: $isPDFOutlinePopoverPresented, arrowEdge: .bottom) {
                                PDFOutlinePopoverView(items: pdfOutlineItems) { pageIndex in
                                    isPDFOutlinePopoverPresented = false
                                    issuePDFNavigationCommand(.goToPage(index: pageIndex))
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(nsColor: .textBackgroundColor))

                        Divider()

                        if let pdfController,
                           let context = activeEditorContext {
                            PDFPreviewContentHost(controller: pdfController, backgroundColor: .windowBackgroundColor) { controller in
                                controller.update(
                                    marker: PDFPreviewContentController.Marker(
                                        fileURL: pdfURL,
                                        reloadToken: activePreviewReloadToken
                                    ),
                                    initialScrollRatio: activePDFScrollRatio,
                                    traceDocumentPath: context.relativePath,
                                    zoomCommand: pendingPDFZoomCommand,
                                    navigationCommand: pendingPDFNavigationCommand,
                                    focusRequestID: pdfFocusRequestID,
                                    onInteraction: {
                                        adoptLeafContentFocusFromInteraction()
                                    },
                                    onScrollChange: { ratio in
                                        guard let context = activeEditorContext,
                                              context.kind == .pdf,
                                              case .workspaceNote(let relativePath)? = state.openedDocument,
                                              relativePath == context.relativePath else { return }
                                        WorkspaceSessionStore.shared.recordDocumentScroll(
                                            rootURL: notesModel.runtimeConfig.rootURL,
                                            relativePath: relativePath,
                                            kind: .pdf,
                                            verticalRatio: ratio
                                        )
                                    },
                                    onPageInfoChange: { pageInfo in
                                        WorkspaceActivationTraceCenter.shared.mark(
                                            tabID: tabID,
                                            event: "pdf.pageInfoChange",
                                            details: [
                                                "pageCount": String(pageInfo.pageCount),
                                                "currentPage": String(pageInfo.currentPageIndex + 1)
                                            ]
                                        )
                                        if pageInfo.pageCount > 0,
                                           let context = activeEditorContext {
                                            WorkspaceActivationTraceCenter.shared.finishIfExpected(
                                                path: context.relativePath,
                                                mode: .pdfPageInfo,
                                                event: "pdf.ready.pageInfo",
                                                details: [
                                                    "pageCount": String(pageInfo.pageCount),
                                                    "currentPage": String(pageInfo.currentPageIndex + 1)
                                                ]
                                            )
                                        }
                                        currentPDFPageInfo = pageInfo
                                        pendingPDFDisplayedPageIndex = nil
                                        syncPDFPageFieldFromCurrentPageInfo()
                                    },
                                    onOutlineChange: { outlineItems in
                                        pdfOutlineItems = outlineItems
                                        if outlineItems.isEmpty {
                                            isPDFOutlinePopoverPresented = false
                                        }
                                    }
                                )
                            }
                            .background(Color(nsColor: .windowBackgroundColor))
                        } else {
                            Color(nsColor: .windowBackgroundColor)
                        }
                    }
                    .onAppear {
                        debugContentLog("render.pdf url=\(pdfURL.path) \(contentDiagnosticsSnapshot.description)")
                    }
                } else if let imageURL = activeImageURL {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            iconToolbarButton(systemName: "minus.magnifyingglass", help: "Zoom Out") {
                                issueImageZoomCommand(.zoomOut)
                            }

                            iconToolbarButton(systemName: "plus.magnifyingglass", help: "Zoom In") {
                                issueImageZoomCommand(.zoomIn)
                            }

                            textToolbarButton("Fit") {
                                issueImageZoomCommand(.fit)
                            }

                            textToolbarButton("100%") {
                                issueImageZoomCommand(.reset)
                            }

                            Divider()
                                .frame(height: 14)

                            imageAdjustmentSlider(
                                label: "Exposure",
                                value: $imageAdjustments.exposure,
                                range: -2...2
                            )

                            imageAdjustmentSlider(
                                label: "Saturation",
                                value: $imageAdjustments.saturation,
                                range: 0...2
                            )

                            imageAdjustmentSlider(
                                label: "Contrast",
                                value: $imageAdjustments.contrast,
                                range: 0.5...2
                            )

                            textToolbarButton("Reset") {
                                imageAdjustments = .identity
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(nsColor: .textBackgroundColor))

                        Divider()

                        if let imageController {
                            ImagePreviewContentHost(controller: imageController, backgroundColor: .windowBackgroundColor) { controller in
                                controller.update(
                                    marker: ImagePreviewContentController.Marker(
                                        fileURL: imageURL,
                                        reloadToken: activePreviewReloadToken
                                    ),
                                    adjustments: imageAdjustments,
                                    zoomCommand: pendingImageZoomCommand,
                                    focusRequestID: imageFocusRequestID
                                )
                            }
                            .background(Color(nsColor: .windowBackgroundColor))
                        } else {
                            Color(nsColor: .windowBackgroundColor)
                        }
                    }
                    .onAppear {
                        debugContentLog("render.image url=\(imageURL.path) \(contentDiagnosticsSnapshot.description)")
                    }
                } else if let csvURL = activeCSVURL,
                          let csvController,
                          let context = activeEditorContext {
                    CSVPreviewContentHost(controller: csvController, backgroundColor: .windowBackgroundColor) { controller in
                        controller.update(
                            marker: CSVPreviewContentController.Marker(
                                fileURL: csvURL,
                                reloadToken: activePreviewReloadToken
                            ),
                            sourceRelativePath: context.relativePath,
                            focusRequestID: csvFocusRequestID,
                            onDocumentChange: { snapshot in
                                guard !isPaletteDocumentPreviewActive,
                                      let context = activeEditorContext,
                                      context.kind == .csv else { return }
                                state.liveCachedData = snapshot.data
                                state.liveCachedKind = .csv
                                state.liveDeletedSnapshot = WorkspaceDeletedDocumentSnapshot(
                                    title: state.liveCachedTitle ?? context.title,
                                    kind: .csv,
                                    relativePath: context.relativePath,
                                    textBody: nil,
                                    data: snapshot.data,
                                    mimeType: "text/csv"
                                )
                                scheduleCSVSave(path: context.relativePath, snapshot: snapshot)
                            },
                            onOpenWikilink: { target in
                                guard let context = activeEditorContext,
                                      context.kind == .csv,
                                      let resolvedPath = notesModel.resolveWikilinkTarget(target, from: context.relativePath) else {
                                    return
                                }
                                navigateToNote(relativePath: resolvedPath)
                            },
                            onOpenWikilinkInNewTab: { target in
                                guard let context = activeEditorContext,
                                      context.kind == .csv,
                                      let resolvedPath = notesModel.resolveWikilinkTarget(target, from: context.relativePath) else {
                                    return
                                }
                                _ = WorkspaceActionRouter.performOpenNoteInNewTab(relativePath: resolvedPath, in: nil)
                            },
                            wikilinkSuggestionsProvider: { query, sourceRelativePath in
                                notesModel.autocompleteWikilinks(query: query, sourceRelativePath: sourceRelativePath)
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .background(Color(nsColor: .windowBackgroundColor))
                    .onAppear {
                        debugContentLog("render.csv url=\(csvURL.path) context=\(context.relativePath) \(contentDiagnosticsSnapshot.description)")
                    }
                } else if let htmlURL = activeHTMLURL,
                          let readAccessURL = activeHTMLReadAccessURL,
                          let htmlController {
                    HTMLPreviewContentHost(controller: htmlController, backgroundColor: .windowBackgroundColor) { controller in
                        controller.update(
                            marker: HTMLPreviewContentController.Marker(
                                fileURL: htmlURL,
                                readAccessURL: readAccessURL,
                                reloadToken: activePreviewReloadToken
                            ),
                            focusRequestID: htmlFocusRequestID
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .onAppear {
                        debugContentLog("render.html url=\(htmlURL.path) \(contentDiagnosticsSnapshot.description)")
                    }
                } else if let canvasURL = activeCanvasURL,
                          let canvasController {
                    CanvasDocumentContentHost(controller: canvasController) { controller in
                        controller.update(
                            marker: CanvasDocumentContentController.Marker(fileURL: canvasURL, reloadToken: activePreviewReloadToken, isReadOnly: isPaletteDocumentPreviewActive),
                            focusRequestID: canvasFocusRequestID,
                            onSave: canvasSaveHandler(for: displayedDocument)
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                } else if let activeWebContentController {
                    EditorWebContentHost(controller: activeWebContentController, backgroundColor: .textBackgroundColor) { controller in
                        controller.updateRootURL(notesModel.runtimeConfig.rootURL)
                    }
                    .onAppear {
                        debugContentLog("render.web \(contentDiagnosticsSnapshot.description)")
                    }
                } else {
                    Color(nsColor: .windowBackgroundColor)
                        .onAppear {
                            debugContentLog("render.grayFallback \(contentDiagnosticsSnapshot.description)")
                        }
                }
                }
            .overlay {
                if isPaletteDocumentPreviewActive {
                    PaletteDocumentPreviewOverlay(
                        title: activeEditorContext?.title ?? "Selected document",
                        accentColor: palettePreviewAccentColor
                    )
                    .transition(.opacity)
                }
            }
            .animation(DesignTokens.Motion.bloom, value: isPaletteDocumentPreviewActive)
            .onTapGesture {
                workspaceTabController.focusContent()
            }
            .background(
                FocusRegionBridgeView { focusAnchorView, regionView in
                    contentFocusAnchorView = focusAnchorView
                    contentRegionView = regionView
                    installWorkspaceFocusHandlers()
                }
            )
            .background(
                NativePreviewZoomKeyMonitor(
                    isActive: effectiveResponderArea == .content && isZoomableNativePreviewActive,
                    onZoomIn: issueActiveNativePreviewZoomIn,
                    onZoomOut: issueActiveNativePreviewZoomOut,
                    onReset: issueActiveNativePreviewZoomReset
                )
                .frame(width: 0, height: 0)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            } stack: {
                sideStackColumn
            }
            .animation(NativeShellInspector<EmptyView>.presentationAnimation, value: state.sideStack.isOpen)
        }
    }

    private var sideStackColumn: some View {
        SideStackSurface(
            controller: workspaceTabController.sideStack.ensureWebController(
                rootURL: notesModel.runtimeConfig.rootURL
            )
        )
    }

    /// Connects the tab's side stack to this tab's state and navigation.
    private func bindSideStack() {
        let sideStack = workspaceTabController.sideStack
        sideStack.onOpenInMain = { path, focus in
            openFromSideStack(path: path, focus: focus)
        }
        sideStack.onOpenWorkspaceFile = { path in
            openInlineWorkspaceFile(relativePath: path)
        }
        sideStack.onInteraction = {
            adoptLeafContentFocusFromInteraction()
        }
        sideStack.onFocusMain = {
            workspaceTabController.focusContent()
        }
        sideStack.bind(
            notesModel: notesModel,
            read: { state.sideStack },
            write: { state.sideStack = $0 }
        )
    }

    private func openFromSideStack(path: String, focus: SideStackFocus?) {
        let isCurrent: Bool
        if case .workspaceNote(let current)? = state.openedDocument {
            isCurrent = current == path
        } else {
            isCurrent = false
        }
        if !isCurrent {
            navigateToNote(relativePath: path)
        }
        if let focus {
            sendMarkdownReferenceJump(path: path, reference: focus.reference)
        }
        workspaceTabController.focusContent()
    }

    private func lifecycleModifiers<V: View>(_ view: V) -> some View {
        view
        .onAppear {
            debugFocusLog("onAppear selectedNote=\(String(describing: state.selectedNotePath))")
            debugContentLog("tabView.onAppear \(contentDiagnosticsSnapshot.description)")
            WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "tabView.onAppear")
            workspaceTabController.bridgeService.presentDatePicker = { request in
                await nativeDatePickerPresenter.present(request: request)
            }
            bindSideStack()
            installWorkspaceFocusHandlers()
            pushEditorContext()
        }
        .background(contentDiagnosticsView)
        .onChange(of: isControllerFocusedLeaf) { _, isFocusedLeaf in
            debugFocusLog("isControllerFocusedLeaf changed value=\(isFocusedLeaf)")
            guard isFocusedLeaf else { return }
            installWorkspaceFocusHandlers()
        }
        .onChange(of: state.selectedNotePath) { _, _ in
            // Launchpad browsing uses selectedNotePath for its breadcrumb and preview,
            // but it has no committed document. Avoid rebuilding editor/focus state for
            // what should be a lightweight Miller selection update.
            guard state.openedDocument != nil else { return }
            resetDocumentNavigatorState()
            isDocumentInspectorPresented = false
            pushEditorContext()
            if shouldMaintainContentFocusAcrossContentChanges {
                DispatchQueue.main.async {
                    workspaceTabController.focusContent()
                }
            }
        }
    }

    private func shellPresentationHandlers<V: View>(_ view: V) -> some View {
        view
        .onChange(of: isDocumentNavigatorPresented) { _, isPresented in
            handleDocumentNavigatorPresentationChange(isPresented)
            if !isPresented {
                documentNavigatorInitialMode = .outline
            }
            if isPresented {
                isDocumentInspectorPresented = false
            }
        }
        .onChange(of: isDocumentInspectorPresented) { _, isPresented in
            if isPresented {
                isDocumentNavigatorPresented = false
            }
        }
        .onChange(of: state.documentInspectorSettings) { _, _ in
            pushDocumentInspectorAppearance()
        }
        .onReceive(NotificationCenter.default.publisher(for: .palettePresetOpenRequested)) { notification in
            guard let preset = notification.userInfo?[PaletteOpenNotification.presetKey] as? PalettePreset else { return }
            if let requestedWindowNumber = notification.userInfo?[
                PaletteOpenNotification.windowNumberKey
            ] as? Int {
                // A request that names this tab's window is answered whatever
                // the focus bookkeeping says: one window is one tab, and the
                // key-window state can lag behind just after launch.
                guard requestedWindowNumber == omniboxAnchor?.window?.windowNumber else { return }
            } else {
                guard isControllerFocusedLeaf else {
                    paletteDebugLog("tab.notification ignored notFocusedLeaf tab=\(tabID)")
                    return
                }
                guard omniboxAnchor?.window?.isKeyWindow == true
                    || omniboxAnchor?.window?.isMainWindow == true else {
                    return
                }
            }
            paletteDebugLog("tab.notification received preset=\(preset.debugLabel) tab=\(tabID)")
            openPalette(preset: preset)
        }
        .onChange(of: documentNavigatorOutlineItems) { _, _ in refreshOutlinePalette() }
        .onChange(of: documentNavigatorActiveOutlineItemID) { _, _ in
            if !paletteSession.shouldPreviewOutlineSelection { refreshOutlinePalette() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .documentNavigatorOpenRequested)) { notification in
            guard isControllerFocusedLeaf, canOpenDocumentNavigator else { return }
            guard let mode = notification.userInfo?[DocumentNavigatorNotification.modeKey] as? DocumentNavigatorMode else { return }
            if let requestedWindowNumber = notification.userInfo?[
                DocumentNavigatorNotification.windowNumberKey
            ] as? Int {
                guard requestedWindowNumber == omniboxAnchor?.window?.windowNumber else { return }
            }
            closeDocumentFindBar(restoreFocus: false)
            documentNavigatorInitialMode = mode
            // Toolbar and menu affordances toggle: the outline button closes
            // an open outline instead of re-asserting it.
            withAnimation(NativeShellInspector<EmptyView>.presentationAnimation) {
                isDocumentNavigatorPresented.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .documentFindOpenRequested)) { notification in
            guard isControllerFocusedLeaf, canOpenDocumentNavigator else { return }
            if let requestedWindowNumber = notification.userInfo?[
                DocumentNavigatorNotification.windowNumberKey
            ] as? Int {
                guard requestedWindowNumber == omniboxAnchor?.window?.windowNumber else { return }
            }
            openDocumentFindBar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .documentInspectorOpenRequested)) { notification in
            guard isControllerFocusedLeaf, canOpenDocumentInspector else { return }
            if let requestedWindowNumber = notification.userInfo?[
                DocumentInspectorNotification.windowNumberKey
            ] as? Int {
                guard requestedWindowNumber == omniboxAnchor?.window?.windowNumber else { return }
            }
            withAnimation(NativeShellInspector<EmptyView>.presentationAnimation) {
                if isDocumentNavigatorPresented || isDocumentInspectorPresented {
                    isDocumentNavigatorPresented = false
                    isDocumentInspectorPresented = false
                } else {
                    isDocumentInspectorPresented = true
                }
            }
        }
        .onChange(of: state.backHistory) { _, _ in
            syncHistoryNavigationToController()
        }
        .onChange(of: state.forwardHistory) { _, _ in
            syncHistoryNavigationToController()
        }
        .onChange(of: state.historyCurrentItem) { _, _ in
            syncHistoryNavigationToController()
        }
        .onAppear {
            syncHistoryNavigationToController()
            syncMillerNavigationToController()
        }
        .modifier(
            NativeShellInspector(
                isEnabled: omitsHeaderChrome,
                isPresented: isAnyDocumentInspectorPresented,
                onAnchorResolve: resolveOmniboxAnchor,
                backgroundColor: backdropColor
            ) {
                inspectorColumn
            }
        )
    }

    private func contentStateModifiers<V: View>(_ view: V) -> some View {
        view
        .onChange(of: state.openedDocument) { _, _ in
            resetDocumentNavigatorState()
            isDocumentInspectorPresented = false
            pushEditorContext()
            if shouldMaintainContentFocusAcrossContentChanges {
                DispatchQueue.main.async {
                    workspaceTabController.focusContent()
                }
            }
        }
        .onChange(of: activePDFURL) { _, _ in
            resetPDFPreviewControls()
            if shouldMaintainContentFocusAcrossContentChanges {
                DispatchQueue.main.async {
                    workspaceTabController.focusContent()
                }
            }
        }
        .onChange(of: state.selectedFolderChain) { _, _ in
            pushEditorContext()
        }
        .onChange(of: notesModel.lastReloadDate) { _, _ in
            pruneMillerTransientPaths()
            pushEditorContext()
        }
        .onChange(of: notesModel.liveTreeRevision) { _, _ in
            if activeWorkspaceRelativePath == nil || pendingDocumentResolutionRetryKey != nil {
                pushEditorContext()
            }
        }
        .onChange(of: state.liveLocalRefreshRevision) { _, _ in
            pushEditorContext()
        }
        .onChange(of: state.liveDiskReloadRevision) { _, _ in
            invalidateDocumentCacheForLiveRefresh()
            pushEditorContext()
        }
        .onDisappear {
            paletteHost.closeImmediately()
            pendingDocumentResolutionRetryTask?.cancel()
            pendingDocumentResolutionRetryTask = nil
            pendingDocumentResolutionRetryKey = nil
            pendingDocumentResolutionRetryAttempt = 0
            for task in pendingSaveTasks.values {
                task.cancel()
            }
            pendingSaveTasks.removeAll()
            nativeDatePickerPresenter.cancelIfNeeded()
            workspaceTabController.installFocusHandlers(content: nil)
            workspaceTabController.updateEditorCommandTarget(nil, replaceCurrentSelection: nil, toggleCurrentSelectionHighlight: nil, performEditorBridgeCommand: nil)
            workspaceTabController.updateMillerNavigation(showInParentFolder: nil)
            // Keep controller-owned sessions alive across SwiftUI subtree rebuilds.
            // The host representable detaches the native surface automatically when this
            // view disappears, and tab/window teardown invalidates sessions explicitly.
            notesModel.unregisterLiveSyncObserver(observerID: liveSyncObserverID)
        }
        .background(
            PDFArrowKeyMonitor(
                isActive: effectiveResponderArea == .content && activePDFURL != nil && !isPDFPageFieldFocused,
                onPrevious: {
                    issuePDFNavigationCommand(.previousPage)
                },
                onNext: {
                    issuePDFNavigationCommand(.nextPage)
                }
            )
            .frame(width: 0, height: 0)
        )
        .overlay(alignment: .top) {
            if let banner = state.liveBanner {
                WorkspaceStatusBanner(banner: banner, onAction: handleBannerAction)
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: 720)
            }
        }
        // SwiftUI extends this backdrop under the titlebar and tab bar, so it
        // is what the window chrome shows; it carries the window tint.
        .background(Color(nsColor: backdropColor))
        .sheet(item: $nativeDatePickerPresenter.activeSheet, onDismiss: {
            nativeDatePickerPresenter.cancelIfNeeded()
        }) { sheet in
            NativeDatePickerSheet(
                initialDate: sheet.initialDate,
                initialStartTime: sheet.initialStartTime,
                initialEndTime: sheet.initialEndTime,
                includesTime: sheet.includesTime,
                includesEndTime: sheet.includesEndTime,
                onCancel: {
                    nativeDatePickerPresenter.cancel()
                },
                onConfirm: { result in
                    nativeDatePickerPresenter.confirm(result)
                }
            )
        }
    }

    private func publishLiveSyncObservation() {
        guard !isPaletteDocumentPreviewActive else { return }

        notesModel.updateLiveSyncVisibleWorkspaceDocument(
            observerID: liveSyncObserverID,
            relativePath: activeWorkspaceRelativePath,
            kind: activeEditorContext?.kind,
            isEditable: isLiveSyncEditableWorkspaceDocument
        )
    }

    private func publishEditorCommandTarget() {
        guard let context = activeEditorContext else {
            workspaceTabController.updateEditorCommandTarget(nil, replaceCurrentSelection: nil, toggleCurrentSelectionHighlight: nil, performEditorBridgeCommand: nil)
            return
        }

        let isEditable: Bool
        if let document = displayedDocument {
            isEditable = isDocumentEditable(document, context: context)
        } else {
            isEditable = false
        }

        let supportsSelectionReplacement =
            context.kind == .text &&
            isEditable &&
            editorController?.isAttached == true &&
            activeWebContentController === editorController

        let replacementHandler: ((String) -> Bool)? = supportsSelectionReplacement
            ? { replacementText in
                replaceCurrentTextSelection(with: replacementText)
            }
            : nil

        let highlightHandler: (() -> Bool)? = supportsSelectionReplacement
            ? {
                toggleCurrentTextSelectionHighlight()
            }
            : nil

        let bridgeCommandHandler: ((String, [String: ActionValue]) -> Bool)? = supportsSelectionReplacement
            ? { command, payload in
                performCurrentTextBridgeCommand(command, payload: payload)
            }
            : nil

        workspaceTabController.updateEditorCommandTarget(
            WorkspaceEditorCommandTargetSnapshot(
                surfaceKind: editorCommandSurfaceKind(for: context.kind),
                title: context.title,
                path: context.relativePath,
                isEditable: isEditable,
                supportsSelectionReplacement: supportsSelectionReplacement
            ),
            replaceCurrentSelection: replacementHandler,
            toggleCurrentSelectionHighlight: highlightHandler,
            performEditorBridgeCommand: bridgeCommandHandler
        )
    }

    private func editorCommandSurfaceKind(for kind: EditorSelectionContext.Kind) -> WorkspaceEditorCommandSurfaceKind {
        switch kind {
        case .text:
            return .text
        case .epub:
            return .epub
        case .folder:
            return .folder
        case .pdf:
            return .pdf
        case .csv:
            return .csv
        case .canvas:
            return .canvas
        case .image:
            return .image
        case .html:
            return .html
        case .diff:
            return .diff
        case .unsupported:
            return .unsupported
        }
    }

    @discardableResult
    private func replaceCurrentTextSelection(with text: String) -> Bool {
        guard let context = activeEditorContext,
              context.kind == .text,
              let document = state.openedDocument,
              isDocumentEditable(document, context: context),
              let editorController else {
            return false
        }

        return editorController.replaceSelection(with: text, expectedPath: context.relativePath)
    }

    @discardableResult
    private func toggleCurrentTextSelectionHighlight() -> Bool {
        guard let context = activeEditorContext,
              context.kind == .text,
              let document = state.openedDocument,
              isDocumentEditable(document, context: context),
              let editorController else {
            return false
        }

        return editorController.toggleMarkdownHighlightSelection(expectedPath: context.relativePath)
    }

    @discardableResult
    private func performCurrentTextBridgeCommand(
        _ command: String,
        payload: [String: ActionValue] = [:]
    ) -> Bool {
        guard let context = activeEditorContext,
              context.kind == .text,
              let document = state.openedDocument,
              isDocumentEditable(document, context: context),
              let editorController else {
            return false
        }

        return editorController.performEditorCommand(
            command,
            expectedPath: context.relativePath,
            payload: payload
        )
    }

    private func handleBannerAction(_ actionID: WorkspaceTabBannerActionID) {
        switch actionID {
        case .reloadFromDisk:
            reloadCurrentDocumentFromDisk()
        case .keepLocal:
            state.liveBanner = nil
        case .restoreDeleted:
            restoreDeletedCurrentDocumentIfPossible()
        case .closeTab:
            onCloseTabRequest(tabID)
        }
    }

    private func reloadCurrentDocumentFromDisk() {
        guard case .workspaceNote(let relativePath)? = state.openedDocument else {
            invalidateDocumentCacheForLiveRefresh()
            notesModel.reload()
            pushEditorContext()
            return
        }

        invalidateDocumentCacheForLiveRefresh()
        notesModel.reload()
        if notesModel.contextForNote(relativePath: relativePath) != nil {
            navigateToNote(relativePath: relativePath, recordHistory: false)
        }
        pushEditorContext()
    }

    private func invalidateDocumentCacheForLiveRefresh() {
        state.liveBanner = nil
        state.liveDeletedSnapshot = nil
        state.liveCachedTextBody = nil
        state.liveCachedData = nil
        state.liveCachedKind = nil
        state.liveCachedTitle = nil
        state.persistedTextSnapshot = nil
        asyncTextContextOverride = nil
        pendingTextContextLoadTask?.cancel()
        pendingTextContextLoadTask = nil
        pendingTextContextLoadKey = nil
        workspaceTabController.clearWebContextMarkers()
    }

    private func restoreDeletedCurrentDocumentIfPossible() {
        guard let snapshot = state.liveDeletedSnapshot else {
            state.liveBanner = nil
            return
        }

        do {
            switch snapshot.kind {
            case .text:
                try notesModel.saveTextNote(relativePath: snapshot.relativePath, body: snapshot.textBody ?? "")
            case .csv, .canvas, .epub, .pdf, .image, .html, .unsupported:
                try notesModel.saveDataNote(relativePath: snapshot.relativePath, data: snapshot.data ?? Data())
            case .folder, .diff:
                state.liveBanner = nil
                return
            }

            state.liveBanner = nil
            state.liveDeletedSnapshot = nil
            notesModel.reload()
            pushEditorContext()
        } catch {
            print("[NVModern][LiveSync] Restore deleted document failed path=\(snapshot.relativePath) error=\(error)")
        }
    }

    private func temporaryDeletedSnapshotURL(for snapshot: WorkspaceDeletedDocumentSnapshot) -> URL? {
        guard let data = snapshot.data else { return nil }
        let fileManager = FileManager.default
        let baseURL = fileManager.temporaryDirectory
            .appendingPathComponent("nvmodern-live-sync", isDirectory: true)
            .appendingPathComponent(String(describing: tabID), isDirectory: true)

        try? fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let fileName = URL(fileURLWithPath: snapshot.relativePath).lastPathComponent
        let targetURL = baseURL.appendingPathComponent(fileName)
        try? data.write(to: targetURL, options: .atomic)
        return targetURL
    }

    private func showWorkspaceItemInFinder(relativePath: String) {
        guard let fileURL = notesModel.workspaceURL(for: relativePath),
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func openWorkspaceFolderInFinder(relativePath: String?) {
        guard let folderURL = notesModel.workspaceItemURL(allowingRootRelativePath: relativePath),
              FileManager.default.fileExists(atPath: folderURL.path)
        else {
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        NSWorkspace.shared.open(folderURL)
    }

    private func copyRelativePathToPasteboard(_ relativePath: String) {
        guard !relativePath.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(relativePath, forType: .string)
    }

    private func copyFolderRelativePathToPasteboard(_ relativePath: String?) {
        let value: String
        if let relativePath, !relativePath.isEmpty {
            value = relativePath
        } else {
            value = "/"
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func copyAbsolutePathToPasteboard(_ relativePath: String) {
        guard let fileURL = notesModel.workspaceURL(for: relativePath) else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fileURL.path, forType: .string)
    }

    private func copyFolderAbsolutePathToPasteboard(_ relativePath: String?) {
        guard let fileURL = notesModel.workspaceItemURL(allowingRootRelativePath: relativePath) else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fileURL.path, forType: .string)
    }

    @ViewBuilder
    private func imageAdjustmentSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)

            Slider(value: value, in: range)
                .controlSize(.mini)
                .frame(width: 92)
        }
    }

    @ViewBuilder
    private func iconToolbarButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            workspaceTabController.focusContent()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 16)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func textToolbarButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label) {
            workspaceTabController.focusContent()
            action()
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
    }

    @ViewBuilder
    private func searchToolbarButton<Label: View>(
        help: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) -> some View {
        SearchToolbarIconButton(
            help: help,
            isEnabled: isEnabled,
            action: action,
            label: label
        )
    }

    private struct SearchToolbarIconButton<Label: View>: View {
        let help: String
        let isEnabled: Bool
        let action: () -> Void
        let label: () -> Label

        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                label()
                    .foregroundStyle(foregroundColor)
                    .frame(width: 14, height: 14)
                    .frame(width: 26, height: 26)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .background(backgroundShape.fill(backgroundColor))
                    .overlay(
                        backgroundShape
                            .strokeBorder(borderColor, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(help)
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }

        private var backgroundShape: RoundedRectangle {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
        }

        private var foregroundColor: Color {
            if !isEnabled {
                return .secondary.opacity(0.75)
            }
            return .primary
        }

        private var backgroundColor: Color {
            if !isEnabled {
                return Color.clear
            }
            if isHovered {
                return Color.primary.opacity(0.08)
            }
            return Color.clear
        }

        private var borderColor: Color {
            if !isEnabled {
                return Color.clear
            }
            if isHovered {
                return Color.primary.opacity(0.12)
            }
            return Color.clear
        }
    }

    private func issuePDFZoomCommand(_ action: PDFZoomCommand.Action) {
        guard activePDFURL != nil else { return }
        pdfZoomCommandID += 1
        pendingPDFZoomCommand = PDFZoomCommand(id: pdfZoomCommandID, action: action)
    }

    private func issuePDFNavigationCommand(_ action: PDFNavigationCommand.Action) {
        guard activePDFURL != nil else { return }
        pdfNavigationCommandID += 1
        pendingPDFNavigationCommand = PDFNavigationCommand(id: pdfNavigationCommandID, action: action)
        syncPDFPageFieldForPendingNavigation(action)
    }

    private func syncPDFPageFieldForPendingNavigation(_ action: PDFNavigationCommand.Action) {
        guard !isPDFPageFieldFocused,
              currentPDFPageInfo.pageCount > 0 else {
            return
        }

        let basePageIndex = pendingPDFDisplayedPageIndex ?? currentPDFPageInfo.currentPageIndex
        let targetPageIndex: Int
        switch action {
        case .previousPage:
            targetPageIndex = max(0, basePageIndex - 1)
        case .nextPage:
            targetPageIndex = min(currentPDFPageInfo.pageCount - 1, basePageIndex + 1)
        case .goToPage(let index):
            targetPageIndex = min(max(index, 0), currentPDFPageInfo.pageCount - 1)
        }

        pendingPDFDisplayedPageIndex = targetPageIndex
        pdfPageFieldText = String(targetPageIndex + 1)
    }

    private func syncPDFPageFieldFromCurrentPageInfo() {
        guard !isPDFPageFieldFocused else { return }
        pdfPageFieldText = currentPDFPageNumberText
    }

    private func commitPDFPageField() {
        guard currentPDFPageInfo.pageCount > 0 else {
            pdfPageFieldText = ""
            return
        }

        let trimmed = pdfPageFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestedPage = Int(trimmed) else {
            syncPDFPageFieldFromCurrentPageInfo()
            return
        }

        let clampedPage = min(max(requestedPage, 1), currentPDFPageInfo.pageCount)
        pdfPageFieldText = String(clampedPage)
        issuePDFNavigationCommand(.goToPage(index: clampedPage - 1))
    }

    private func issueImageZoomCommand(_ action: ImageZoomCommand.Action) {
        guard activeImageURL != nil else { return }
        imageZoomCommandID += 1
        pendingImageZoomCommand = ImageZoomCommand(id: imageZoomCommandID, action: action)
    }

    private func issueActiveNativePreviewZoomIn() {
        if activePDFURL != nil {
            issuePDFZoomCommand(.zoomIn)
        } else {
            issueImageZoomCommand(.zoomIn)
        }
    }

    private func issueActiveNativePreviewZoomOut() {
        if activePDFURL != nil {
            issuePDFZoomCommand(.zoomOut)
        } else {
            issueImageZoomCommand(.zoomOut)
        }
    }

    private func issueActiveNativePreviewZoomReset() {
        if activePDFURL != nil {
            issuePDFZoomCommand(.reset)
        } else {
            issueImageZoomCommand(.reset)
        }
    }

    private func installWorkspaceFocusHandlers() {
        debugFocusLog("installHandlers contentAnchor=\(contentFocusAnchorView != nil) contentRegionView=\(contentRegionView != nil) focusedLeaf=\(isControllerFocusedLeaf)")
        workspaceTabController.installFocusHandlers(
            content: { focusActiveContentSurface() }
        )
    }

    private func currentFirstResponderView() -> NSView? {
        let window = contentRegionView?.window
        return window?.firstResponder as? NSView
    }

    private func isDescendant(_ view: NSView, of ancestor: NSView?) -> Bool {
        guard let ancestor else { return false }

        var currentView: NSView? = view
        while let resolvedView = currentView {
            if resolvedView === ancestor {
                return true
            }
            currentView = resolvedView.superview
        }

        return false
    }

    private func requestRegionFocus(_ view: NSView?) {
        DispatchQueue.main.async {
            guard let view,
                  let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    private var shouldMaintainContentFocusAcrossContentChanges: Bool {
        effectiveResponderArea == .content
    }

    private func restoreContentFocusIfNeeded(reason: String) {
        guard shouldMaintainContentFocusAcrossContentChanges else { return }
        DispatchQueue.main.async {
            WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: reason)
            workspaceTabController.focusContent()
        }
    }

    private func focusActiveContentSurface() {
        debugFocusLog("focusActiveContentSurface activePDF=\(activePDFURL != nil) activeImage=\(activeImageURL != nil) activeCSV=\(activeCSVURL != nil) activeHTML=\(activeHTMLURL != nil) hasWebController=\(activeWebContentController != nil)")
        onLeafInteraction()
        isPDFPageFieldFocused = false

        if activePDFURL != nil {
            pdfFocusRequestID += 1
            return
        }

        if activeImageURL != nil {
            imageFocusRequestID += 1
            return
        }

        if activeCSVURL != nil {
            csvFocusRequestID += 1
            return
        }

        if activeCanvasURL != nil {
            canvasFocusRequestID += 1
            return
        }

        if activeHTMLURL != nil {
            htmlFocusRequestID += 1
            return
        }

        if let activeWebContentController {
            activeWebContentController.requestFocus()
            return
        }

        requestRegionFocus(contentFocusAnchorView)
    }

    private func adoptLeafContentFocusFromInteraction() {
        onLeafInteraction()
    }

    private func resetPDFPreviewControls() {
        pendingPDFNavigationCommand = nil
        currentPDFPageInfo = PDFPageInfo(currentPageIndex: 0, currentPageLabel: "—", pageCount: 0)
        pendingPDFDisplayedPageIndex = nil
        pdfPageFieldText = ""
        pdfOutlineItems = []
        isPDFOutlinePopoverPresented = false
        isPDFPageFieldFocused = false
    }

    private func resetDocumentNavigatorState() {
        endOutlinePaletteNavigation(commit: false, restoreFocus: false)
        if documentNavigationSessionOwner != nil {
            sendDocumentNavigatorAction(["kind": "cancel"])
        }
        documentNavigationSessionOwner = nil
        isDocumentNavigatorPresented = false
        isDocumentFindBarPresented = false
        documentNavigatorOutlineItems = []
        documentNavigatorActiveOutlineItemID = nil
        documentNavigatorSearchMatches = []
        documentNavigatorSearchQuery = ""
        documentNavigatorActiveSearchIndex = nil
        documentNavigatorLineCount = 0
    }

    private func projectHue(for input: String) -> Int {
        var hash: Int32 = 0
        for codeUnit in input.utf16 {
            let scalar = Int32(codeUnit)
            hash = scalar &+ ((hash << 5) &- hash)
        }
        return Int(abs(Int64(hash)) % 360)
    }

    private func startCreateNoteFlow(inFolderRelativePath folderRelativePath: String? = nil) {
        onCreateNote(folderRelativePath ?? currentMillerFolderPath)
    }

    private func promptForFolderCreation(inFolderRelativePath folderRelativePath: String?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Create New Folder"
        alert.informativeText = "Location: \(displayPath(forFolderRelativePath: folderRelativePath))"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: "")
        field.placeholderString = "Folder name"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let relativePath = try notesModel.createFolder(
                inFolderRelativePath: folderRelativePath,
                name: field.stringValue
            )
            notesModel.reload()
            selectMillerFolder(relativePath: relativePath)
            requestLaunchpadMillerFocus()
        } catch {
            presentWorkspaceItemOperationError(error)
        }
    }

    private func promptForWorkspaceItemRename(relativePath: String, kind: MillerItemKind, currentName: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = kind == .folder ? "Rename Folder" : "Rename File"
        alert.informativeText = kind == .folder
            ? "Enter a new name for \(currentName)."
            : "Enter a new name for \(currentName). The current file extension will be preserved."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: currentName)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let newPath = try notesModel.renameWorkspaceItem(relativePath: relativePath, to: field.stringValue)
            guard newPath != relativePath else { return }
            notesModel.reload()
            onWorkspaceItemRenamed(relativePath, newPath, kind)

            if kind == .note {
                navigateToNote(relativePath: newPath, recordHistory: false)
            } else {
                pushEditorContext()
            }

            workspaceTabController.focusContent()
        } catch {
            presentWorkspaceItemOperationError(error)
        }
    }

    private func promptForFinderTags(relativePath: String?, displayName: String) {
        do {
            let currentTags = try notesModel.finderTags(forWorkspaceItem: relativePath)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Finder Tags"
            alert.informativeText = "Edit Finder tags for \(displayName). Separate tags with commas or Return."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")

            let field = NSTokenField()
            field.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
            field.objectValue = currentTags
            field.placeholderString = "Add tags"
            field.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
            alert.accessoryView = field

            guard alert.runModal() == .alertFirstButtonReturn else { return }

            try notesModel.setFinderTags(tokenFieldValues(field), forWorkspaceItem: relativePath)
        } catch {
            presentWorkspaceItemOperationError(error)
        }
    }

    private func tokenFieldValues(_ field: NSTokenField) -> [String] {
        if let values = field.objectValue as? [Any] {
            return values.map { "\($0)" }
        }

        return field.stringValue
            .split(separator: ",")
            .map { String($0) }
    }

    private func displayPath(forFolderRelativePath folderRelativePath: String?) -> String {
        guard let folderRelativePath, !folderRelativePath.isEmpty else {
            return "/"
        }

        return "/\(folderRelativePath)"
    }

    private func duplicateWorkspaceNote(relativePath: String) {
        do {
            let duplicatedPath = try notesModel.duplicateWorkspaceNote(relativePath: relativePath)
            notesModel.reload()
            navigateToNote(relativePath: duplicatedPath)
            workspaceTabController.focusContent()
        } catch {
            presentWorkspaceItemOperationError(error)
        }
    }

    private func confirmMoveWorkspaceItemToTrash(relativePath: String, kind: MillerItemKind, currentName: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = kind == .folder ? "Move Folder to Trash" : "Move File to Trash"
        alert.informativeText = kind == .folder
            ? "Are you sure you want to move \(currentName) and its contents to the Trash?"
            : "Are you sure you want to move \(currentName) to the Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try notesModel.trashWorkspaceItem(relativePath: relativePath)
            notesModel.reload()
            onWorkspaceItemTrashed(relativePath, kind)
            workspaceTabController.focusContent()
        } catch {
            presentWorkspaceItemOperationError(error)
        }
    }

    private func presentWorkspaceItemOperationError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private func handleMillerMove(_ direction: MoveCommandDirection) {
        // A fresh tab has no active row. The first vertical arrow press lands
        // on the natural row (the selected folder, the previewed note, or the
        // first item) instead of skipping past it; horizontal moves fall
        // through so Right from an unselected root column still enters it.
        let columns = orderedMillerColumns
        let depth = max(0, min(state.millerActiveDepth, max(0, columns.count - 1)))
        if selectedMillerItem(in: columns, depth: depth) == nil {
            ensureMillerSelection()
            if direction == .up || direction == .down {
                return
            }
        }

        switch direction {
        case .up:
            moveMillerSelection(delta: -1)
        case .down:
            moveMillerSelection(delta: 1)
        case .left:
            moveMillerOutward()
        case .right:
            enterSelectedMillerFolder()
        default:
            break
        }
    }

    private func prepareMillerSelectionForSearchFocusTransfer() {
        // External/clipboard documents don't participate in Miller column navigation.
        // Bail out early so that applyMillerSelection (→ navigateToFolder) never
        // overwrites state.openedDocument with nil for these tab types.
        switch state.openedDocument {
        case .externalMarkdown, .clipboardMarkdown, .diff:
            return
        case .workspaceNote, nil:
            break
        }

        let columns = orderedMillerColumns
        guard !columns.isEmpty else { return }

        let clampedDepth = max(0, min(state.millerActiveDepth, columns.count - 1))
        if let activeItemPath = state.activeMillerItemPath,
           columns[clampedDepth].contains(where: { $0.relativePath == activeItemPath }) {
            state.millerActiveDepth = clampedDepth
            return
        }

        let targetDepth = max(0, min(state.selectedFolderChain.count, columns.count - 1))
        state.millerActiveDepth = targetDepth

        guard let firstItem = columns[targetDepth].first else {
            return
        }

        applyMillerSelection(item: firstItem, depth: targetDepth)
    }

    private func ensureMillerSelection() {
        let columns = orderedMillerColumns
        guard !columns.isEmpty else { return }

        state.millerActiveDepth = max(0, min(state.millerActiveDepth, columns.count - 1))
        let depth = state.millerActiveDepth
        let items = columns[depth]
        guard !items.isEmpty else { return }

        if let activeItemPath = state.activeMillerItemPath,
           items.contains(where: { $0.relativePath == activeItemPath }) {
            return
        }

        if depth < state.selectedFolderChain.count,
           let folderItem = items.first(where: { $0.relativePath == state.selectedFolderChain[depth] }) {
            applyMillerSelection(item: folderItem, depth: depth)
            return
        }

        if depth == state.selectedFolderChain.count,
           let selectedNotePath = state.selectedNotePath,
           let noteItem = items.first(where: { $0.relativePath == selectedNotePath }) {
            applyMillerSelection(item: noteItem, depth: depth)
            return
        }

        applyMillerSelection(item: items[0], depth: depth)
    }

    private func moveMillerSelection(delta: Int) {
        let columns = orderedMillerColumns
        guard !columns.isEmpty else { return }

        state.millerActiveDepth = max(0, min(state.millerActiveDepth, columns.count - 1))
        let depth = state.millerActiveDepth
        let items = columns[depth]
        guard !items.isEmpty else { return }

        let currentItem = selectedMillerItem(in: columns, depth: depth)
        let currentIndex = currentItem.flatMap { item in items.firstIndex(where: { $0.id == item.id }) } ?? 0

        if delta < 0 && currentIndex == 0 {
            return
        }

        let nextIndex = max(0, min(items.count - 1, currentIndex + delta))
        applyMillerSelection(item: items[nextIndex], depth: depth)
    }

    private func moveMillerOutward() {
        let columns = orderedMillerColumns
        let oldChain = LaunchpadRootColumn.normalized(state.selectedFolderChain)

        // Clamp against the columns that actually exist before stepping out.
        // Reading `millerActiveDepth` raw made left-arrow a silent no-op once the
        // depth outran the chain — which is what happened after landing on a
        // file, since selecting a note shortens the chain to its parent folders.
        let depth = max(0, min(state.millerActiveDepth, max(0, columns.count - 1)))
        guard depth > 0 else { return }

        let newDepth = depth - 1
        // Never truncate past element 0: it names the synthetic root, and
        // dropping it threw the browser back to Workspace from Recent or a
        // capture root instead of just stepping left.
        let newChain = Array(oldChain.prefix(max(1, newDepth)))
        let folderPath = oldChain.indices.contains(newDepth)
            ? oldChain[newDepth]
            : (newChain.last ?? LaunchpadRootColumn.workspacePath)

        state.openedDocument = nil
        state.selectedFolderChain = newChain
        state.selectedNotePath = nil
        state.millerActiveDepth = newDepth
        state.activeMillerItemPath = folderPath
        launchpadMillerSelectedPaths = [folderPath]
        launchpadMillerSelectionAnchor = nil
        clearLaunchpadMillerPreview()
    }

    private func enterSelectedMillerFolder() {
        let columns = orderedMillerColumns
        guard !columns.isEmpty else { return }

        state.millerActiveDepth = max(0, min(state.millerActiveDepth, columns.count - 1))
        let depth = state.millerActiveDepth

        guard let selected = selectedMillerItem(in: columns, depth: depth), selected.kind == .folder else {
            return
        }

        applyMillerSelection(item: selected, depth: depth)
        let updatedColumns = orderedMillerColumns
        let nextDepth = min(depth + 1, updatedColumns.count - 1)
        state.millerActiveDepth = max(0, nextDepth)
        state.activeMillerItemPath = nil
        ensureMillerSelection()
    }

    private func selectedMillerItem(in columns: [[MillerItem]], depth: Int) -> MillerItem? {
        guard columns.indices.contains(depth),
              depth == state.millerActiveDepth,
              let activeItemPath = state.activeMillerItemPath else {
            return nil
        }

        return columns[depth].first(where: { $0.relativePath == activeItemPath })
    }

    private func applyMillerSelection(item: MillerItem, depth: Int) {
        applyMillerSelection(relativePath: item.relativePath, kind: item.kind, depth: depth)
    }

    private func handleMillerSelectionGesture(
        depth: Int,
        row: Int,
        item: MillerItem,
        gesture: MillerSelectionGesture
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        millerDebugLog(
            "Selection",
            "handle begin depth=\(depth) row=\(row) kind=\(item.kind) gesture=\(gesture) path=\(item.relativePath)"
        )
        defer {
            let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            millerDebugLog(
                "Selection",
                "handle end path=\(item.relativePath) elapsedMs=\(String(format: "%.3f", elapsedMilliseconds)) active=\(state.activeMillerItemPath ?? "<nil>") selected=\(effectiveLaunchpadMillerSelectedPaths.sorted())"
            )
        }

        let columns = orderedMillerColumns
        guard columns.indices.contains(depth), columns[depth].indices.contains(row) else { return }
        let columnItems = columns[depth]
        let columnPaths = Set(columnItems.map(\.relativePath))

        var selection = effectiveLaunchpadMillerSelectedPaths.intersection(columnPaths)
        let resolvedAnchor: MillerSelectionAnchor
        if let anchor = launchpadMillerSelectionAnchor,
           anchor.depth == depth,
           columnItems.indices.contains(anchor.row),
           columnItems[anchor.row].relativePath == anchor.relativePath {
            resolvedAnchor = anchor
        } else if state.millerActiveDepth == depth,
                  let activePath = state.activeMillerItemPath,
                  let activeRow = columnItems.firstIndex(where: { $0.relativePath == activePath }) {
            resolvedAnchor = MillerSelectionAnchor(depth: depth, row: activeRow, relativePath: activePath)
        } else {
            resolvedAnchor = MillerSelectionAnchor(depth: depth, row: row, relativePath: item.relativePath)
        }

        switch gesture {
        case .replace:
            launchpadMillerSelectedPaths = [item.relativePath]
            launchpadMillerSelectionAnchor = MillerSelectionAnchor(
                depth: depth,
                row: row,
                relativePath: item.relativePath
            )
            applyMillerSelection(item: item, depth: depth)
            return

        case .toggle:
            if selection.contains(item.relativePath) {
                selection.remove(item.relativePath)
            } else {
                selection.insert(item.relativePath)
            }
            launchpadMillerSelectionAnchor = resolvedAnchor

        case .range:
            let lowerBound = min(resolvedAnchor.row, row)
            let upperBound = max(resolvedAnchor.row, row)
            selection = Set(columnItems[lowerBound...upperBound].map(\.relativePath))
            launchpadMillerSelectionAnchor = resolvedAnchor
        }

        if selection.isEmpty {
            selection = [item.relativePath]
        }
        launchpadMillerSelectedPaths = selection

        if selection.count == 1,
           let selectedPath = selection.first,
           let selectedRow = columnItems.firstIndex(where: { $0.relativePath == selectedPath }) {
            applyMillerSelection(item: columnItems[selectedRow], depth: depth)
            return
        }

        state.openedDocument = nil
        state.selectedNotePath = nil
        state.millerActiveDepth = depth
        state.activeMillerItemPath = selection.contains(item.relativePath)
            ? item.relativePath
            : columnItems.first(where: { selection.contains($0.relativePath) })?.relativePath
        clearLaunchpadMillerPreview()
    }

    private func applyMillerSelection(relativePath: String, kind: MillerItemKind, depth: Int) {
        launchpadMillerSelectedPaths = [relativePath]
        let columns = orderedMillerColumns
        if columns.indices.contains(depth),
           let row = columns[depth].firstIndex(where: { $0.relativePath == relativePath }) {
            launchpadMillerSelectionAnchor = MillerSelectionAnchor(
                depth: depth,
                row: row,
                relativePath: relativePath
            )
        }
        if kind == .folder {
            navigateToFolder(relativePath: relativePath, depth: depth)
            clearLaunchpadMillerPreview()
            return
        }

        selectMillerNote(relativePath: relativePath, depth: depth)
    }

    private func navigateToFolder(relativePath: String, depth: Int) {
        state.openedDocument = nil
        state.millerActiveDepth = depth
        state.activeMillerItemPath = relativePath
        state.selectedNotePath = nil

        // A row in the synthetic column replaces the whole chain: picking a new
        // root discards whatever was selected under the previous one.
        if LaunchpadRootColumn.isSynthetic(relativePath) {
            state.selectedFolderChain = [relativePath]
            return
        }

        let chain = LaunchpadRootColumn.normalized(state.selectedFolderChain)
        state.selectedFolderChain = Array(chain.prefix(max(1, depth))) + [relativePath]
    }

    private func selectMillerFolder(relativePath: String) {
        guard !relativePath.isEmpty else {
            state.openedDocument = nil
            state.selectedNotePath = nil
            state.selectedFolderChain = [LaunchpadRootColumn.workspacePath]
            state.millerActiveDepth = 0
            state.activeMillerItemPath = nil
            launchpadMillerSelectedPaths.removeAll()
            launchpadMillerSelectionAnchor = nil
            clearLaunchpadMillerPreview()
            return
        }

        let chain = folderChain(forFolderPath: relativePath)
        state.openedDocument = nil
        state.selectedNotePath = nil
        state.selectedFolderChain = chain
        state.millerActiveDepth = max(0, chain.count - 1)
        state.activeMillerItemPath = relativePath
        launchpadMillerSelectedPaths = [relativePath]
        launchpadMillerSelectionAnchor = nil
        clearLaunchpadMillerPreview()
    }

    private func selectMillerNote(relativePath: String, depth: Int) {
        guard !relativePath.isEmpty else { return }
        state.openedDocument = nil
        state.selectedNotePath = relativePath
        state.selectedFolderChain = folderChain(for: relativePath)
        state.millerActiveDepth = depth
        state.activeMillerItemPath = relativePath
        scheduleLaunchpadMillerPreview(relativePath: relativePath)
    }

    @discardableResult
    private func showInParentFolder(relativePath: String, selectDocument: Bool) -> Bool {
        guard let documentItem = millerItem(relativePath: relativePath),
              documentItem.kind == .note else {
            return false
        }

        let parentPath = (relativePath as NSString).deletingLastPathComponent
        var folderChain = [LaunchpadRootColumn.workspacePath]
        var accumulatedPath = ""
        for component in parentPath.split(separator: "/") {
            accumulatedPath = accumulatedPath.isEmpty
                ? String(component)
                : "\(accumulatedPath)/\(component)"
            folderChain.append(accumulatedPath)
        }

        state.kind = .launchpad
        state.openedDocument = nil
        state.selectedFolderChain = folderChain

        let columns = orderedMillerColumns
        let depth = max(0, columns.count - 1)
        let items = columns.last ?? []
        let selectedItem = selectDocument
            ? items.first(where: { $0.relativePath == relativePath })
            : nil

        state.millerActiveDepth = depth
        state.activeMillerItemPath = selectedItem?.relativePath
        state.selectedNotePath = selectedItem?.kind == .note ? selectedItem?.relativePath : nil
        launchpadMillerSelectedPaths = Set(selectedItem.map { [$0.relativePath] } ?? [])
        launchpadMillerSelectionAnchor = selectedItem.flatMap { item in
            items.firstIndex(where: { $0.relativePath == item.relativePath }).map {
                MillerSelectionAnchor(depth: depth, row: $0, relativePath: item.relativePath)
            }
        }

        if let selectedItem, selectedItem.kind == .note {
            scheduleLaunchpadMillerPreview(relativePath: selectedItem.relativePath)
        } else {
            clearLaunchpadMillerPreview()
        }

        workspaceTabController.requestMillerHorizontalScroll(to: .revealActive)
        requestLaunchpadMillerFocus()
        return true
    }

    private func clearLaunchpadMillerPreview() {
        launchpadMillerPreview = nil
    }

    private func scheduleLaunchpadMillerPreview(relativePath: String) {
        let title = URL(fileURLWithPath: relativePath).lastPathComponent
        let iconName = millerPreviewIconName(for: relativePath)
        guard let fileURL = notesModel.workspaceURL(for: relativePath),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            clearLaunchpadMillerPreview()
            return
        }

        launchpadMillerPreview = MillerPreviewColumnContent(
            title: title.isEmpty ? "Preview" : title,
            relativePath: relativePath,
            iconName: iconName,
            fileURL: fileURL
        )
        millerDebugLog("QuickLook", "preview scheduled path=\(relativePath) url=\(fileURL.path)")

        // `QLPreviewView` takes first responder as soon as it loads content, which
        // silently killed keyboard navigation: arrow keys stopped reaching the
        // browser the moment the selection landed on a file, and clicking another
        // row did not win it back. Re-assert browser focus once the preview has
        // mounted — a browser should keep the keys unless the user clicks into
        // the preview themselves.
        DispatchQueue.main.async {
            requestLaunchpadMillerFocus()
        }
    }

    private func millerPreviewIconName(for relativePath: String) -> String {
        let ext = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        switch ext {
        case "pdf":
            return "doc.richtext"
        case "csv":
            return "tablecells"
        case "excalidraw":
            return "scribble.variable"
        case "html":
            return "globe"
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "svg":
            return "photo"
        case "md", "markdown", "mdown", "mkd", "org", "txt", "text", "outline":
            return "doc.text"
        default:
            return "doc"
        }
    }

    private func millerItem(relativePath: String) -> MillerItem? {
        for items in notesModel.childrenByFolder.values {
            if let item = items.first(where: { $0.relativePath == relativePath }) {
                return item
            }
        }
        return nil
    }

    private func stageMillerItems(_ relativePaths: [String]) {
        for path in relativePaths where millerItem(relativePath: path) != nil {
            if launchpadMillerShelfPaths.contains(where: { path.hasPrefix($0 + "/") }) {
                continue
            }
            launchpadMillerShelfPaths.removeAll { $0.hasPrefix(path + "/") }
            if !launchpadMillerShelfPaths.contains(path) {
                launchpadMillerShelfPaths.append(path)
            }
        }
    }

    private func pruneMillerTransientPaths() {
        launchpadMillerSelectedPaths = launchpadMillerSelectedPaths.filter {
            millerItem(relativePath: $0) != nil
        }
        launchpadMillerShelfPaths.removeAll { millerItem(relativePath: $0) == nil }
        if let anchor = launchpadMillerSelectionAnchor,
           millerItem(relativePath: anchor.relativePath) == nil {
            launchpadMillerSelectionAnchor = nil
        }
    }

    private func moveMillerItems(_ relativePaths: [String], toFolderRelativePath destinationFolderPath: String) {
        millerDebugLog(
            "Drop",
            "move begin paths=\(relativePaths) destination=\(destinationFolderPath.isEmpty ? "<root>" : destinationFolderPath)"
        )
        let sourceItems = Dictionary(
            uniqueKeysWithValues: relativePaths.compactMap { path in
                millerItem(relativePath: path).map { (path, $0) }
            }
        )

        do {
            let movedPaths = try notesModel.moveWorkspaceItems(
                relativePaths: relativePaths,
                toFolderRelativePath: destinationFolderPath
            )
            notesModel.reload()

            for (oldPath, newPath) in movedPaths.sorted(by: { $0.key < $1.key }) {
                onWorkspaceItemRenamed(oldPath, newPath, sourceItems[oldPath]?.kind ?? .note)
            }

            let resultingPaths = relativePaths.map { movedPaths[$0] ?? $0 }
            launchpadMillerShelfPaths.removeAll { relativePaths.contains($0) }
            launchpadMillerSelectedPaths = Set(resultingPaths)
            state.openedDocument = nil
            state.selectedNotePath = nil
            state.selectedFolderChain = folderChain(forFolderPath: destinationFolderPath)
            state.millerActiveDepth = state.selectedFolderChain.count
            state.activeMillerItemPath = resultingPaths.first

            let destinationColumns = orderedMillerColumns
            let destinationColumn = destinationColumns.indices.contains(state.millerActiveDepth)
                ? destinationColumns[state.millerActiveDepth]
                : []
            if let firstPath = resultingPaths.first,
               let row = destinationColumn.firstIndex(where: { $0.relativePath == firstPath }) {
                launchpadMillerSelectionAnchor = MillerSelectionAnchor(
                    depth: state.millerActiveDepth,
                    row: row,
                    relativePath: firstPath
                )
            } else {
                launchpadMillerSelectionAnchor = nil
            }

            if resultingPaths.count == 1,
               let onlyPath = resultingPaths.first,
               sourceItems[relativePaths[0]]?.kind == .note {
                scheduleLaunchpadMillerPreview(relativePath: onlyPath)
            } else {
                clearLaunchpadMillerPreview()
            }
            requestLaunchpadMillerFocus()
            millerDebugLog("Drop", "move complete mapping=\(movedPaths)")
        } catch {
            millerDebugLog("Drop", "move failed error=\(error.localizedDescription)")
            presentWorkspaceItemOperationError(error)
        }
    }

    private func openMillerItemsInNewTabs(_ relativePaths: [String]) {
        for path in relativePaths where millerItem(relativePath: path)?.kind == .note {
            _ = WorkspaceActionRouter.performOpenDocument(
                .workspaceNote(relativePath: path),
                disposition: .backgroundTab,
                in: nil
            )
        }
    }

    private func revealMillerItemsInFinder(_ relativePaths: [String]) {
        let urls = relativePaths.compactMap { path -> URL? in
            guard let url = notesModel.workspaceURL(for: path),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copyMillerItemPaths(_ relativePaths: [String], absolute: Bool) {
        let values: [String]
        if absolute {
            values = relativePaths.compactMap { notesModel.workspaceURL(for: $0)?.path }
        } else {
            values = relativePaths
        }
        guard !values.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
    }

    private func confirmMoveMillerItemsToTrash(_ relativePaths: [String]) {
        let items = relativePaths.compactMap { millerItem(relativePath: $0) }
        guard !items.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(items.count) Items to Trash"
        alert.informativeText = items.contains(where: { $0.kind == .folder })
            ? "Selected folders and all of their contents will be moved to the Trash."
            : "The selected files will be moved to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            for item in items {
                try notesModel.trashWorkspaceItem(relativePath: item.relativePath)
                onWorkspaceItemTrashed(item.relativePath, item.kind)
            }
            notesModel.reload()
            launchpadMillerSelectedPaths.subtract(relativePaths)
            launchpadMillerShelfPaths.removeAll { relativePaths.contains($0) }
            launchpadMillerSelectionAnchor = nil
            clearLaunchpadMillerPreview()
            requestLaunchpadMillerFocus()
        } catch {
            notesModel.reload()
            presentWorkspaceItemOperationError(error)
        }
    }

    private func navigateToDocument(_ document: WorkspaceOpenedDocument, depth: Int? = nil, recordHistory: Bool = true) {
        clearLaunchpadMillerPreview()
        WorkspaceSessionStore.shared.recordRecentDocument(
            rootURL: notesModel.runtimeConfig.rootURL,
            document: document
        )

        state.navigate(
            to: document,
            millerDepth: depth,
            recordHistory: recordHistory
        )

    }

    private func navigateToNote(relativePath: String, depth: Int? = nil, recordHistory: Bool = true) {
        guard !relativePath.isEmpty else { return }
        navigateToDocument(.workspaceNote(relativePath: relativePath), depth: depth, recordHistory: recordHistory)
    }

    private func shouldOpenInlineLinkInsideWorkspace(relativePath: String) -> Bool {
        let lowercasedPath = relativePath.lowercased()
        return [".md", ".markdown", ".mdown", ".mkd", ".org", ".outline", ".csv", ".html"].contains {
            lowercasedPath.hasSuffix($0)
        }
    }

    private func openInlineWorkspaceFile(relativePath: String) {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }

        if shouldOpenInlineLinkInsideWorkspace(relativePath: trimmedPath) {
            navigateToNote(relativePath: trimmedPath)
            return
        }

        let fileURL = notesModel.runtimeConfig.rootURL.appendingPathComponent(trimmedPath)
        NSWorkspace.shared.open(fileURL)
    }

    private func navigateBackInHistory() {
        guard let previousItem = state.backHistory.popLast() else { return }

        if let currentItem = state.historyCurrentItem,
           currentItem != previousItem {
            state.forwardHistory.append(currentItem)
        }

        navigateToHistoryItem(previousItem)
    }

    private func navigateForwardInHistory() {
        guard let nextItem = state.forwardHistory.popLast() else { return }

        if let currentItem = state.historyCurrentItem,
           currentItem != nextItem {
            state.backHistory.append(currentItem)
        }

        navigateToHistoryItem(nextItem)
    }

    private func navigateToHistoryItem(_ item: WorkspaceHistoryItem) {
        switch item {
        case .workspaceNote, .externalMarkdown:
            guard let document = item.openedDocument else { return }
            navigateToDocument(document, recordHistory: false)
        }
    }

    @discardableResult
    private func prepareTextEditorController() -> EditorWebContentController {
        WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "web.ensureSession.start")
        let existingController = workspaceTabController.existingTextEditorController
        if existingController != nil {
            WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "web.session.controllerReuse")
        } else {
            WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "web.session.create")
        }

        let controller = workspaceTabController.textContent.prepare(
            rootURL: notesModel.runtimeConfig.rootURL,
            onDidAttachToWindow: { _ in
                workspaceTabController.logEditorCommandState("surface.attached")
                restoreContentFocusIfNeeded(reason: "web.session.attach")
            },
            onProcessTermination: {
                guard editorController?.isAttached == true,
                      activeEditorContext?.kind == .text,
                      activePDFURL == nil,
                      activeImageURL == nil,
                      activeCSVURL == nil else {
                    return
                }

                WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "web.processTermination.repushContext")
                pushEditorContext()
            },
            onBridgeReady: {
                WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "web.bridge.ready")
                editorController?.clearContextMarker()
                if activeEditorContext?.kind == .text,
                   activePDFURL == nil,
                   activeImageURL == nil,
                   activeCSVURL == nil {
                    pushEditorContext()
                }
                restoreContentFocusIfNeeded(reason: "web.bridge.ready")
            },
            onEvent: { event, payload in
                if recordPageBackground(event, payload, surface: .text) { return }
                handleEditorEvent(event: event, payload: payload)
            },
            onRequest: { method, params in
                try await handleEditorRequest(method: method, params: params)
            }
        )

        if editorController !== controller {
            editorController = controller
        }

        WorkspaceActivationTraceCenter.shared.mark(
            tabID: tabID,
            event: "web.ensureSession.end",
            details: [
                "bridgeReady": controller.isBridgeReady ? "true" : "false",
                "attached": controller.isAttached ? "true" : "false"
            ]
        )
        return controller
    }

    @discardableResult
    private func preparePreviewController() -> EditorWebContentController {
        let existingController = workspaceTabController.existingPreviewController
        WorkspaceActivationTraceCenter.shared.mark(
            tabID: tabID,
            event: existingController == nil ? "web.preview.create" : "web.preview.controllerReuse"
        )

        let controller = workspaceTabController.previewContent.prepare(
            rootURL: notesModel.runtimeConfig.rootURL,
            onDidAttachToWindow: { _ in
                restoreContentFocusIfNeeded(reason: "web.preview.attach")
            },
            onProcessTermination: {
                guard previewController?.isAttached == true,
                      activeEditorContext.map({ $0.kind == .folder || $0.kind == .unsupported }) == true,
                      activePDFURL == nil,
                      activeImageURL == nil,
                      activeCSVURL == nil else {
                    return
                }

                WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "web.preview.processTermination.repushContext")
                pushEditorContext()
            },
            onBridgeReady: {
                WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "web.preview.ready")
                previewController?.clearContextMarker()
                if activeEditorContext.map({ $0.kind == .folder || $0.kind == .unsupported }) == true,
                   activePDFURL == nil,
                   activeImageURL == nil,
                   activeCSVURL == nil {
                    pushEditorContext()
                }
                restoreContentFocusIfNeeded(reason: "web.preview.ready")
            },
            onEvent: { event, payload in
                if recordPageBackground(event, payload, surface: nil) { return }
                handleEditorEvent(event: event, payload: payload)
            },
            onRequest: { method, params in
                try await handleEditorRequest(method: method, params: params)
            }
        )

        if previewController !== controller {
            previewController = controller
        }

        return controller
    }

    @discardableResult
    private func prepareEPUBController() -> EditorWebContentController {
        let existingController = workspaceTabController.existingEPUBController
        WorkspaceActivationTraceCenter.shared.mark(
            tabID: tabID,
            event: existingController == nil ? "web.epub.create" : "web.epub.controllerReuse"
        )

        let controller = workspaceTabController.epubContent.prepare(
            rootURL: notesModel.runtimeConfig.rootURL,
            onDidAttachToWindow: { _ in
                restoreContentFocusIfNeeded(reason: "web.epub.attach")
            },
            onProcessTermination: {
                guard epubController?.isAttached == true,
                      activeEditorContext?.kind == .epub else { return }
                epubController?.clearContextMarker()
                pushEditorContext()
            },
            onBridgeReady: {
                epubController?.clearContextMarker()
                if activeEditorContext?.kind == .epub {
                    pushEditorContext()
                }
                restoreContentFocusIfNeeded(reason: "web.epub.ready")
            },
            onEvent: { event, payload in
                if recordPageBackground(event, payload, surface: .epub) { return }
                handleEditorEvent(event: event, payload: payload)
            },
            onRequest: { method, params in
                try await handleEditorRequest(method: method, params: params)
            }
        )

        if epubController !== controller {
            epubController = controller
        }
        return controller
    }

    @discardableResult
    private func preparePDFController(
        marker: PDFPreviewContentController.Marker,
        initialScrollRatio: Double?,
        traceDocumentPath: String?
    ) -> PDFPreviewContentController {
        let existingController = workspaceTabController.existingPDFController
        WorkspaceActivationTraceCenter.shared.mark(
            tabID: tabID,
            event: existingController == nil ? "pdf.session.create" : "pdf.session.controllerReuse"
        )
        let controller = workspaceTabController.pdfContent.prepare(
            marker: marker,
            initialScrollRatio: initialScrollRatio,
            traceDocumentPath: traceDocumentPath,
            zoomCommand: pendingPDFZoomCommand,
            navigationCommand: pendingPDFNavigationCommand,
            focusRequestID: pdfFocusRequestID,
            onDidAttachToWindow: { _ in
                restoreContentFocusIfNeeded(reason: "pdf.session.attach")
            },
            onInteraction: {
                adoptLeafContentFocusFromInteraction()
            },
            onScrollChange: { ratio in
                guard let context = activeEditorContext,
                      context.kind == .pdf,
                      case .workspaceNote(let relativePath)? = state.openedDocument,
                      relativePath == context.relativePath else { return }
                WorkspaceSessionStore.shared.recordDocumentScroll(
                    rootURL: notesModel.runtimeConfig.rootURL,
                    relativePath: relativePath,
                    kind: .pdf,
                    verticalRatio: ratio
                )
            },
            onPageInfoChange: { pageInfo in
                WorkspaceActivationTraceCenter.shared.mark(
                    tabID: tabID,
                    event: "pdf.pageInfoChange",
                    details: [
                        "pageCount": String(pageInfo.pageCount),
                        "currentPage": String(pageInfo.currentPageIndex + 1)
                    ]
                )
                if pageInfo.pageCount > 0,
                   let context = activeEditorContext {
                    WorkspaceActivationTraceCenter.shared.finishIfExpected(
                        path: context.relativePath,
                        mode: .pdfPageInfo,
                        event: "pdf.ready.pageInfo",
                        details: [
                            "pageCount": String(pageInfo.pageCount),
                            "currentPage": String(pageInfo.currentPageIndex + 1)
                        ]
                    )
                }
                currentPDFPageInfo = pageInfo
                pendingPDFDisplayedPageIndex = nil
                syncPDFPageFieldFromCurrentPageInfo()
            },
            onOutlineChange: { outlineItems in
                pdfOutlineItems = outlineItems
                if outlineItems.isEmpty {
                    isPDFOutlinePopoverPresented = false
                }
            }
        )
        if pdfController !== controller {
            pdfController = controller
        }
        return controller
    }

    @discardableResult
    private func prepareCSVController(
        marker: CSVPreviewContentController.Marker,
        sourceRelativePath: String?
    ) -> CSVPreviewContentController {
        let existingController = workspaceTabController.existingCSVController
        WorkspaceActivationTraceCenter.shared.mark(
            tabID: tabID,
            event: existingController == nil ? "csv.session.create" : "csv.session.controllerReuse"
        )
        let controller = workspaceTabController.csvContent.prepare(
            marker: marker,
            sourceRelativePath: sourceRelativePath,
            focusRequestID: csvFocusRequestID,
            onDidAttachToWindow: { _ in
                restoreContentFocusIfNeeded(reason: "csv.session.attach")
            },
            onDocumentChange: { snapshot in
                guard let context = activeEditorContext, context.kind == .csv else { return }
                state.liveCachedData = snapshot.data
                state.liveCachedKind = .csv
                state.liveDeletedSnapshot = WorkspaceDeletedDocumentSnapshot(
                    title: state.liveCachedTitle ?? context.title,
                    kind: .csv,
                    relativePath: context.relativePath,
                    textBody: nil,
                    data: snapshot.data,
                    mimeType: "text/csv"
                )
                scheduleCSVSave(path: context.relativePath, snapshot: snapshot)
            },
            onOpenWikilink: { target in
                guard let context = activeEditorContext,
                      context.kind == .csv,
                      let resolvedPath = notesModel.resolveWikilinkTarget(target, from: context.relativePath) else {
                    return
                }
                navigateToNote(relativePath: resolvedPath)
            },
            onOpenWikilinkInNewTab: { target in
                guard let context = activeEditorContext,
                      context.kind == .csv,
                      let resolvedPath = notesModel.resolveWikilinkTarget(target, from: context.relativePath) else {
                    return
                }
                _ = WorkspaceActionRouter.performOpenNoteInNewTab(relativePath: resolvedPath, in: nil)
            },
            wikilinkSuggestionsProvider: { query, sourceRelativePath in
                notesModel.autocompleteWikilinks(query: query, sourceRelativePath: sourceRelativePath)
            }
        )
        if csvController !== controller {
            csvController = controller
        }
        return controller
    }

    @discardableResult
    private func canvasSaveHandler(for document: WorkspaceOpenedDocument?) -> (Data) throws -> Void {
        let isReadOnly = isPaletteDocumentPreviewActive
        return { data in
            guard !isReadOnly, let document else { return }
            switch document {
            case .workspaceNote(let relativePath):
                try notesModel.saveDataNote(relativePath: relativePath, data: data)
                if state.openedDocument == document {
                    state.liveCachedData = data
                    state.liveCachedKind = .canvas
                    state.liveDeletedSnapshot = WorkspaceDeletedDocumentSnapshot(
                        title: state.liveCachedTitle ?? URL(fileURLWithPath: relativePath).lastPathComponent,
                        kind: .canvas,
                        relativePath: relativePath,
                        textBody: nil,
                        data: data,
                        mimeType: "application/vnd.excalidraw+json"
                    )
                }
            case .externalMarkdown(let path):
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            case .clipboardMarkdown, .diff:
                break
            }
        }
    }

    @discardableResult
    private func prepareCanvasController(marker: CanvasDocumentContentController.Marker) -> CanvasDocumentContentController {
        let controller = workspaceTabController.canvasContent.prepare(
            marker: marker,
            focusRequestID: canvasFocusRequestID,
            onDidAttachToWindow: { _ in restoreContentFocusIfNeeded(reason: "canvas.session.attach") },
            onSave: canvasSaveHandler(for: displayedDocument)
        )
        if canvasController !== controller { canvasController = controller }
        return controller
    }

    private func prepareImageController(marker: ImagePreviewContentController.Marker) -> ImagePreviewContentController {
        let existingController = workspaceTabController.existingImageController
        WorkspaceActivationTraceCenter.shared.mark(
            tabID: tabID,
            event: existingController == nil ? "image.session.create" : "image.session.controllerReuse"
        )
        let controller = workspaceTabController.imageContent.prepare(
            marker: marker,
            adjustments: imageAdjustments,
            zoomCommand: pendingImageZoomCommand,
            focusRequestID: imageFocusRequestID,
            onDidAttachToWindow: { _ in
                restoreContentFocusIfNeeded(reason: "image.session.attach")
            }
        )
        if imageController !== controller {
            imageController = controller
        }
        return controller
    }

    @discardableResult
    private func prepareHTMLController(marker: HTMLPreviewContentController.Marker) -> HTMLPreviewContentController {
        let existingController = workspaceTabController.existingHTMLController
        WorkspaceActivationTraceCenter.shared.mark(
            tabID: tabID,
            event: existingController == nil ? "html.session.create" : "html.session.controllerReuse"
        )
        let controller = workspaceTabController.htmlContent.prepare(
            marker: marker,
            focusRequestID: htmlFocusRequestID,
            onDidAttachToWindow: { _ in
                restoreContentFocusIfNeeded(reason: "html.session.attach")
            }
        )
        if htmlController !== controller {
            htmlController = controller
        }
        return controller
    }

    private func handleDocumentNavigatorPresentationChange(_ isPresented: Bool) {
        if isPresented {
            closeDocumentFindBar(restoreFocus: false)
            beginDocumentNavigator()
        } else if documentNavigationSessionOwner == .navigator {
            commitDocumentNavigator()
        }
    }

    private func openDocumentFindBar() {
        guard canOpenDocumentFind else {
            NSSound.beep()
            return
        }

        if isDocumentNavigatorPresented {
            if documentNavigationSessionOwner == .navigator {
                documentNavigationSessionOwner = nil
                sendDocumentNavigatorAction(["kind": "commit"])
            }
            isDocumentNavigatorPresented = false
        }
        if !isDocumentFindBarPresented {
            isDocumentFindBarPresented = true
        }
        documentFindBarFocusRequestID &+= 1

        if documentNavigationSessionOwner != .findBar {
            documentNavigationSessionOwner = .findBar
            sendDocumentNavigatorAction(["kind": "begin"])
        }
        updateDocumentNavigatorSearch(documentNavigatorSearchQuery)
    }

    private func closeDocumentFindBar(restoreFocus: Bool = true) {
        guard isDocumentFindBarPresented else { return }
        isDocumentFindBarPresented = false
        documentNavigatorSearchMatches = []
        documentNavigatorActiveSearchIndex = nil

        if documentNavigationSessionOwner == .findBar {
            documentNavigationSessionOwner = nil
            sendDocumentNavigatorAction(["kind": "commit"])
        }

        if restoreFocus {
            restoreContentFocusIfNeeded(reason: "documentFindBar.close")
        }
    }

    private func moveDocumentFindMatch(by delta: Int) {
        guard !documentNavigatorSearchMatches.isEmpty else { return }
        let count = documentNavigatorSearchMatches.count
        let currentIndex = documentNavigatorActiveSearchIndex.flatMap { $0 >= 0 ? $0 : nil }
            ?? (delta > 0 ? -1 : 0)
        let nextIndex = (currentIndex + delta + count) % count
        documentNavigatorActiveSearchIndex = nextIndex
        previewDocumentNavigatorSearchMatch(documentNavigatorSearchMatches[nextIndex])
    }

    private func beginDocumentNavigator() {
        guard canOpenDocumentNavigator else {
            isDocumentNavigatorPresented = false
            return
        }

        documentNavigationSessionOwner = .navigator
        sendDocumentNavigatorAction(["kind": "begin"])
    }

    private func commitDocumentNavigator() {
        guard documentNavigationSessionOwner == .navigator else {
            isDocumentNavigatorPresented = false
            return
        }

        documentNavigationSessionOwner = nil
        sendDocumentNavigatorAction(["kind": "commit"])
        isDocumentNavigatorPresented = false
        restoreContentFocusIfNeeded(reason: "documentNavigator.commit")
    }

    /// Commit from the inspector column, where the navigator is a persistent
    /// pane rather than a popover: the jump is kept, the column stays open, and
    /// a fresh session begins because the editor ends the old one on commit —
    /// without it the next row click would have no origin to fall back to.
    /// Content focus is left to the editor's own commit handling so the column
    /// is not torn down behind the jump.
    private func commitDocumentNavigatorInColumn() {
        if documentNavigationSessionOwner == .navigator {
            documentNavigationSessionOwner = nil
            sendDocumentNavigatorAction(["kind": "commit"])
        }

        beginDocumentNavigator()
    }

    private func cancelDocumentNavigator() {
        guard documentNavigationSessionOwner == .navigator else {
            isDocumentNavigatorPresented = false
            return
        }

        documentNavigationSessionOwner = nil
        sendDocumentNavigatorAction(["kind": "cancel"])
        isDocumentNavigatorPresented = false
        restoreContentFocusIfNeeded(reason: "documentNavigator.cancel")
    }

    private func updateDocumentNavigatorSearch(_ query: String) {
        documentNavigatorSearchQuery = query
        documentNavigatorActiveSearchIndex = nil
        sendDocumentNavigatorAction([
            "kind": "search",
            "query": query
        ])
    }

    private func previewDocumentNavigatorOutlineItem(_ item: DocumentNavigatorOutlineItem) {
        switch item.destination {
        case .text(let from, _, _):
            sendDocumentNavigatorAction([
                "kind": "jumpToOutlineItem",
                "id": item.id,
                "from": from
            ])
        case .epub(let href, let cfi):
            let path = activeEditorContext?.kind == .epub ? activeEditorContext?.relativePath : nil
            guard let controller = epubController, let path else { return }
            var payload: [String: Any] = ["path": path, "href": href]
            if let cfi { payload["cfi"] = cfi }
            controller.bridge.sendCommand("epubNavigate", payload: payload)
        case .pdf:
            break
        }
    }

    private func previewDocumentNavigatorSearchMatch(_ match: DocumentNavigatorSearchMatch) {
        sendDocumentNavigatorAction([
            "kind": "jumpToSearchMatch",
            "from": match.from,
            "to": match.to
        ])
    }

    private func previewDocumentNavigatorLine(_ line: Int) {
        sendDocumentNavigatorAction([
            "kind": "jumpToLine",
            "line": line
        ])
    }

    private func sendDocumentNavigatorAction(_ action: [String: Any]) {
        guard let controller = activeWebContentController,
              let context = activeEditorContext,
              context.kind == .text else {
            return
        }

        controller.bridge.sendCommand(
            "documentNavigation",
            payload: [
                "path": context.relativePath,
                "action": action
            ]
        )
    }

    private func pushDocumentInspectorAppearance() {
        guard let controller = activeWebContentController,
              let context = activeEditorContext,
              context.kind == .text || context.kind == .epub else {
            isDocumentInspectorPresented = false
            return
        }

        let appearance = effectiveDocumentInspectorAppearance
        controller.bridge.sendCommand(
            "setDocumentAppearance",
            payload: [
                "path": context.relativePath,
                "theme": appearance.settings.theme.rawValue,
                "css": appearance.css,
                "unwrapMarkdownLines": appearance.settings.unwrapMarkdownLines
            ]
        )
    }

    private func resetDocumentInspector() {
        state.documentInspectorSettings = .default
    }

    private var effectiveDocumentInspectorAppearance: DocumentInspectorAppearance {
        documentFrontmatterAppearance?.applied(to: state.documentInspectorSettings)
            ?? DocumentInspectorAppearance(settings: state.documentInspectorSettings)
    }

    private var documentInspectorWordCount: Int {
        guard let activeEditorContext,
              activeEditorContext.kind == .text else {
            return 0
        }

        let body: String
        if let asyncTextContextOverride,
           asyncTextContextOverride.kind == .text,
           asyncTextContextOverride.relativePath == activeEditorContext.relativePath {
            body = asyncTextContextOverride.body
        } else {
            body = activeEditorContext.body
        }
        return DocumentWordCounter.count(in: body)
    }

    private var canUnwrapProseLines: Bool {
        guard let path = activeEditorContext?.relativePath.lowercased() else { return false }
        return [".md", ".markdown", ".mdown", ".mkd", ".org"].contains { path.hasSuffix($0) }
    }

    @discardableResult
    private func updateDocumentFrontmatterAppearance(path: String, body: String) -> Bool {
        guard let context = activeEditorContext,
              context.kind == .text,
              context.relativePath == path else {
            if documentFrontmatterAppearance != nil {
                documentFrontmatterAppearance = nil
                return true
            }
            return false
        }

        let nextAppearance = DocumentFrontmatterAppearance.parse(from: body)
        guard nextAppearance != documentFrontmatterAppearance else {
            return false
        }

        documentFrontmatterAppearance = nextAppearance
        return true
    }

    private func syncDocumentFrontmatterAppearance(for context: EditorSelectionContext) {
        let nextAppearance = context.kind == .text
            ? DocumentFrontmatterAppearance.parse(from: context.body)
            : nil
        if documentFrontmatterAppearance != nextAppearance {
            documentFrontmatterAppearance = nextAppearance
        }
    }

    private func applyDocumentNavigationState(_ payload: [String: Any]) {
        guard let path = payload["path"] as? String,
              let context = activeEditorContext,
              context.kind == .text,
              context.relativePath == path else {
            return
        }

        documentNavigatorOutlineItems = DocumentOutlineItem.textItems(from: payload)
        documentNavigatorActiveOutlineItemID = payload["activeOutlineId"] as? String

        let payloadSearchQuery = payload["searchQuery"] as? String ?? ""
        let shouldAcceptSearchPayload = payloadSearchQuery == documentNavigatorSearchQuery
        if shouldAcceptSearchPayload {
            documentNavigatorSearchQuery = payloadSearchQuery
        }

        if shouldAcceptSearchPayload {
            documentNavigatorSearchMatches = (payload["searchMatches"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String,
                      let text = item["text"] as? String,
                      let preview = item["preview"] as? String,
                      let line = intValue(item["line"]),
                      let from = intValue(item["from"]),
                      let to = intValue(item["to"]) else {
                    return nil
                }

                return DocumentNavigatorSearchMatch(
                    id: id,
                    text: text,
                    preview: preview,
                    line: line,
                    from: from,
                    to: to
                )
            }
            documentNavigatorActiveSearchIndex = intValue(payload["activeSearchIndex"])
        }

        documentNavigatorLineCount = intValue(payload["lineCount"]) ?? documentNavigatorLineCount
    }

    private func applyEPUBNavigationState(_ payload: [String: Any]) {
        guard let path = payload["path"] as? String,
              let context = activeEditorContext,
              context.kind == .epub,
              context.relativePath == path else { return }

        documentNavigatorOutlineItems = (payload["outline"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String,
                  let title = item["title"] as? String,
                  let level = intValue(item["level"]),
                  let href = item["href"] as? String else { return nil }
            return DocumentOutlineItem(
                id: id,
                level: level,
                title: title,
                destination: .epub(href: href, cfi: item["cfi"] as? String)
            )
        }
        documentNavigatorActiveOutlineItemID = payload["activeOutlineId"] as? String
        documentNavigatorLineCount = 0

        guard !isPaletteDocumentPreviewActive,
              case .workspaceNote(let relativePath)? = state.openedDocument,
              relativePath == path,
              let location = payload["location"] as? [String: Any],
              let href = location["href"] as? String else { return }
        let progressionValue = location["progression"]
        let progression = (progressionValue as? NSNumber)?.doubleValue ?? progressionValue as? Double
        WorkspaceSessionStore.shared.recordEPUBLocation(
            rootURL: notesModel.runtimeConfig.rootURL,
            relativePath: relativePath,
            href: href,
            cfi: location["cfi"] as? String,
            progression: progression
        )
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    private func handleEditorEvent(event: String, payload: [String: Any]) {
        switch event {
        case "contentInteraction":
            adoptLeafContentFocusFromInteraction()

        case "diffRefreshRequested":
            guard case .diff? = state.openedDocument else { return }
            invalidateDocumentCacheForLiveRefresh()
            pushEditorContext()

        case "docChange":
            guard !isPaletteDocumentPreviewActive,
                  let path = payload["path"] as? String,
                  let body = payload["body"] as? String,
                  !path.isEmpty
            else {
                return
            }

            state.liveCachedTextBody = body
            state.liveCachedData = Data(body.utf8)
            state.liveCachedKind = .text
            do {
                state.persistedTextSnapshot = PersistedTextDocumentSnapshot(
                    path: path,
                    title: activeEditorContext?.title ?? state.liveCachedTitle ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                    body: body,
                    modifiedDate: activeEditorContext?.modifiedDate,
                    mimeType: activeEditorContext?.mimeType ?? "text/plain",
                    fileSize: Int64(body.lengthOfBytes(using: .utf8)),
                    capturedAt: Date()
                )
            }
            if let activeEditorContext,
               activeEditorContext.kind == .text,
               activeEditorContext.relativePath == path {
                asyncTextContextOverride = EditorSelectionContext(
                    kind: .text,
                    title: activeEditorContext.title,
                    relativePath: activeEditorContext.relativePath,
                    body: body,
                    modifiedDate: activeEditorContext.modifiedDate,
                    mimeType: activeEditorContext.mimeType,
                    fileSize: Int64(body.lengthOfBytes(using: .utf8))
                )
            }
            if case .workspaceNote(let relativePath)? = state.openedDocument,
               relativePath == path {
                state.liveDeletedSnapshot = WorkspaceDeletedDocumentSnapshot(
                    title: state.liveCachedTitle ?? URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent,
                    kind: .text,
                    relativePath: relativePath,
                    textBody: body,
                    data: Data(body.utf8),
                    mimeType: "text/plain"
                )
            }

            if updateDocumentFrontmatterAppearance(path: path, body: body) {
                pushDocumentInspectorAppearance()
            }
            scheduleNoteSave(path: path, body: body)

        case "scrollStateChange":
            guard let kind = payload["kind"] as? String,
                  kind == PersistedDocumentScrollKind.markdown.rawValue,
                  let path = payload["path"] as? String,
                  let ratioValue = payload["ratio"],
                  let ratio = (ratioValue as? NSNumber)?.doubleValue ?? ratioValue as? Double,
                  case .workspaceNote(let relativePath)? = state.openedDocument,
                  relativePath == path
            else {
                return
            }

            // print("[NVModern][ScrollRestore] recordScroll path=\(relativePath) ratio=\(ratio)")
            WorkspaceSessionStore.shared.recordDocumentScroll(
                rootURL: notesModel.runtimeConfig.rootURL,
                relativePath: relativePath,
                kind: .markdown,
                verticalRatio: ratio
            )

        case "documentNavigationState":
            applyDocumentNavigationState(payload)

        case "epubNavigationState":
            applyEPUBNavigationState(payload)

        // case "debugScrollRestore":
        //     print("[NVModern][ScrollRestore] web path=\(payload["path"] as? String ?? "nil") event=\(payload["event"] as? String ?? "nil") requestedRatio=\(String(describing: payload["requestedRatio"])) maxScrollTop=\(String(describing: payload["maxScrollTop"])) attempt=\(String(describing: payload["attempt"])) scrollTop=\(String(describing: payload["scrollTop"]))")

        case "wikilinkOpen":
            guard let navigation = DocumentSurfaceBridgeService.wikilinkNavigation(
                payload: payload,
                notesModel: notesModel
            ) else { return }
            // Shift-click keeps the note beside this one in the side stack.
            if payload["shiftKey"] as? Bool == true,
               SideStackController.isStackable(path: navigation.path) {
                workspaceTabController.sideStack.push(
                    path: navigation.path,
                    focus: SideStackFocus(reference: navigation.reference)
                )
                return
            }
            if !navigation.isSameDocument {
                navigateToNote(relativePath: navigation.path)
            }
            if let reference = navigation.reference {
                sendMarkdownReferenceJump(path: navigation.path, reference: reference)
            }

        case "inlineLinkOpen":
            DocumentSurfaceBridgeService.routeInlineLink(payload: payload) { path in
                openInlineWorkspaceFile(relativePath: path)
            }

        case "jsError":
            let message = payload["message"] as? String ?? "Unknown JS error"
            let source = payload["source"] as? String ?? ""
            let line = payload["line"] as? Int ?? 0
            let column = payload["column"] as? Int ?? 0
            let stack = payload["stack"] as? String ?? ""
            LocalDiagnosticsCenter.shared.log(
                level: .error,
                category: "web.js",
                event: "jsError",
                metadata: [
                    "message": message,
                    "source": source,
                    "line": String(line),
                    "column": String(column),
                    "path": state.openedDocument?.editorPath ?? "",
                    "stack": stack
                ]
            )
            print("[NVModern][WebJS][Error] \(message) @ \(source):\(line):\(column)\n\(stack)")

        case "unhandledRejection":
            let message = payload["message"] as? String ?? "Unhandled rejection"
            let stack = payload["stack"] as? String ?? ""
            LocalDiagnosticsCenter.shared.log(
                level: .error,
                category: "web.js",
                event: "unhandledRejection",
                metadata: [
                    "message": message,
                    "path": state.openedDocument?.editorPath ?? "",
                    "stack": stack
                ]
            )
            print("[NVModern][WebJS][UnhandledRejection] \(message)\n\(stack)")

        case "consoleError":
            let args = payload["args"] as? [String] ?? []
            LocalDiagnosticsCenter.shared.log(
                level: .warning,
                category: "web.js",
                event: "consoleError",
                metadata: [
                    "path": state.openedDocument?.editorPath ?? "",
                    "args": args.joined(separator: " ")
                ]
            )
            print("[NVModern][WebJS][console.error] \(args.joined(separator: " "))")

        case "editorInitError":
            let message = payload["message"] as? String ?? "Editor init failed"
            let stack = payload["stack"] as? String ?? ""
            LocalDiagnosticsCenter.shared.log(
                level: .fault,
                category: "web.editor",
                event: "editorInitError",
                metadata: [
                    "message": message,
                    "path": state.openedDocument?.editorPath ?? "",
                    "stack": stack
                ]
            )
            print("[NVModern][WebJS][EditorInitError] \(message)\n\(stack)")

        case "previewLoadError":
            let kind = payload["kind"] as? String ?? "unknown"
            let path = payload["path"] as? String ?? ""
            LocalDiagnosticsCenter.shared.log(
                level: .warning,
                category: "web.preview",
                event: "previewLoadError",
                metadata: [
                    "kind": kind,
                    "path": path
                ]
            )
            print("[NVModern][WebPreview][LoadError] kind=\(kind) path=\(path)")

        case "csvParseError":
            let path = payload["path"] as? String ?? ""
            let message = payload["message"] as? String ?? "CSV parse/load failed"
            LocalDiagnosticsCenter.shared.log(
                level: .warning,
                category: "web.preview",
                event: "csvParseError",
                metadata: [
                    "path": path,
                    "message": message
                ]
            )
            print("[NVModern][WebPreview][CSVError] path=\(path) message=\(message)")

        case "editorInputLatency":
            let path = payload["path"] as? String ?? state.openedDocument?.editorPath ?? ""
            let key = payload["key"] as? String ?? ""
            let docLength = payload["docLength"] as? Int ?? 0
            let totalLatencyMs = (payload["totalLatencyMs"] as? NSNumber)?.doubleValue ?? 0
            let inputToUpdateMs = (payload["inputToUpdateMs"] as? NSNumber)?.doubleValue ?? 0
            let updateToPaintMs = (payload["updateToPaintMs"] as? NSNumber)?.doubleValue ?? 0
            let activelyEditing = (payload["activelyEditing"] as? Bool) == true ? "true" : "false"
            LocalDiagnosticsCenter.shared.log(
                level: totalLatencyMs >= 40 ? .warning : .info,
                category: "editor.latency",
                event: "inputSample",
                metadata: [
                    "path": path,
                    "key": key,
                    "docLength": String(docLength),
                    "totalLatencyMs": String(format: "%.2f", totalLatencyMs),
                    "inputToUpdateMs": String(format: "%.2f", inputToUpdateMs),
                    "updateToPaintMs": String(format: "%.2f", updateToPaintMs),
                    "activelyEditing": activelyEditing
                ]
            )

        case "editorFirstFrame":
            PerformanceDiagnostics.markNewTab(tabID: tabID, event: "web.editorFirstFrame", metadata: [
                "path": payload["path"] as? String ?? "",
                "kind": payload["kind"] as? String ?? "",
                "bodyLength": String(payload["bodyLength"] as? Int ?? 0)
            ])

        case "contextReceived":
            PerformanceDiagnostics.markNewTab(tabID: tabID, event: "web.contextReceived", metadata: [
                "path": payload["path"] as? String ?? "",
                "kind": payload["kind"] as? String ?? ""
            ])
            consumePendingMarkdownJump()
            WorkspaceActivationTraceCenter.shared.finishIfExpected(
                tabID: tabID,
                mode: .webContextReceived,
                event: "web.contextReceived",
                details: [
                    "path": payload["path"] as? String ?? "",
                    "kind": payload["kind"] as? String ?? ""
                ]
            )
            LocalDiagnosticsCenter.shared.log(
                level: .info,
                category: "web.bridge",
                event: "contextReceived",
                metadata: [
                    "path": payload["path"] as? String ?? "",
                    "kind": payload["kind"] as? String ?? ""
                ]
            )
            print("[NVModern][WebBridge] JS contextReceived payload=\(payload)")

        case "mainScriptLoadError":
            LocalDiagnosticsCenter.shared.log(
                level: .fault,
                category: "web.editor",
                event: "mainScriptLoadError",
                metadata: ["payload": String(describing: payload)]
            )
            print("[NVModern][WebJS] Failed to load main.js payload=\(payload)")

        default:
            LocalDiagnosticsCenter.shared.log(
                level: .warning,
                category: "web.bridge",
                event: "unhandledEvent",
                metadata: [
                    "event": event,
                    "payload": String(describing: payload)
                ]
            )
            print("[NVModern][WebBridge] Unhandled event=\(event) payload=\(payload)")
        }
    }

    private func handleEditorRequest(method: String, params: [String: Any]) async throws -> Any? {
        var writePolicy = DocumentSurfaceBridgeService.WritePolicy()
        writePolicy.isReadOnly = isPaletteDocumentPreviewActive
        if case .handled(let result) = try await workspaceTabController.bridgeService.handleSharedRequest(
            method: method,
            params: params,
            notesModel: notesModel,
            policy: writePolicy
        ) {
            return result
        }

        switch method {
        case "arbor.documentReplace":
            guard let document = params["document"] as? [String: Any],
                  let documentID = document["id"] as? String,
                  let path = document["path"] as? String,
                  let source = document["source"] as? String,
                  let revisionNumber = document["revision"] as? NSNumber,
                  revisionNumber.intValue >= 0
            else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid arbor.documentReplace payload"]
                )
            }

            let requestID = (params["requestId"] as? String)
                ?? (params["requestID"] as? String)
                ?? UUID().uuidString
            let response = await workspaceTabController.arborKernelSupervisor.replaceDocument(
                ArborKernelDocument(
                    id: documentID,
                    path: path,
                    revision: revisionNumber.intValue,
                    source: source
                ),
                requestID: requestID
            )
            let responseData = try JSONEncoder().encode(response)
            return try JSONSerialization.jsonObject(with: responseData)

        case "arbor.queryRun":
            guard let documentID = params["documentId"] as? String,
                  let queryID = params["queryId"] as? String,
                  let revisionNumber = params["revision"] as? NSNumber,
                  revisionNumber.intValue >= 0
            else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid arbor.queryRun payload"]
                )
            }

            let argumentObject = params["arguments"] as? [String: Any] ?? [:]
            guard JSONSerialization.isValidJSONObject(argumentObject) else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid arbor.queryRun arguments"]
                )
            }
            let argumentData = try JSONSerialization.data(withJSONObject: argumentObject)
            let arguments = try JSONDecoder().decode(
                [String: ArborKernelJSONValue].self,
                from: argumentData
            )
            let requestID = (params["requestId"] as? String)
                ?? (params["requestID"] as? String)
                ?? UUID().uuidString
            let response = await workspaceTabController.arborKernelSupervisor.runQuery(
                documentID: documentID,
                revision: revisionNumber.intValue,
                queryID: queryID,
                arguments: arguments,
                requestID: requestID
            )
            let responseData = try JSONEncoder().encode(response)
            return try JSONSerialization.jsonObject(with: responseData)

        case "arbor.viewGet":
            guard let documentID = params["documentId"] as? String,
                  let revisionNumber = params["revision"] as? NSNumber,
                  revisionNumber.intValue >= 0
            else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid arbor.viewGet payload"]
                )
            }

            let argumentObject = params["arguments"] as? [String: Any] ?? [:]
            guard JSONSerialization.isValidJSONObject(argumentObject) else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid arbor.viewGet arguments"]
                )
            }
            let argumentData = try JSONSerialization.data(withJSONObject: argumentObject)
            let arguments = try JSONDecoder().decode(
                [String: ArborKernelJSONValue].self,
                from: argumentData
            )
            let requestID = (params["requestId"] as? String)
                ?? (params["requestID"] as? String)
                ?? UUID().uuidString
            let response = await workspaceTabController.arborKernelSupervisor.getView(
                documentID: documentID,
                revision: revisionNumber.intValue,
                queryID: params["queryId"] as? String,
                arguments: arguments,
                requestID: requestID
            )
            let responseData = try JSONEncoder().encode(response)
            return try JSONSerialization.jsonObject(with: responseData)

        case "arbor.producerRun":
            guard let documentID = params["documentId"] as? String,
                  let producerID = params["producerId"] as? String,
                  let mode = params["mode"] as? String,
                  ["refresh", "append"].contains(mode),
                  let revisionNumber = params["revision"] as? NSNumber,
                  revisionNumber.intValue >= 0
            else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid arbor.producerRun payload"]
                )
            }

            let argumentObject = params["arguments"] as? [String: Any] ?? [:]
            guard JSONSerialization.isValidJSONObject(argumentObject) else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid arbor.producerRun arguments"]
                )
            }
            let argumentData = try JSONSerialization.data(withJSONObject: argumentObject)
            let arguments = try JSONDecoder().decode(
                [String: ArborKernelJSONValue].self,
                from: argumentData
            )
            let requestID = (params["requestId"] as? String)
                ?? (params["requestID"] as? String)
                ?? UUID().uuidString
            var response = await workspaceTabController.arborKernelSupervisor.runProducer(
                documentID: documentID,
                revision: revisionNumber.intValue,
                producerID: producerID,
                mode: mode,
                arguments: arguments,
                requestID: requestID
            )
            if response.status == "effect-request", let effect = response.effect {
                response = await executeArborEffect(effect)
            } else if response.status == "mutation-request", let mutation = response.mutation {
                response = await executeArborMutation(mutation)
            }
            let responseData = try JSONEncoder().encode(response)
            return try JSONSerialization.jsonObject(with: responseData)

        case "arbor.intentApply":
            guard let documentID = params["documentId"] as? String,
                  let resultID = params["resultId"] as? String,
                  let revisionNumber = params["revision"] as? NSNumber,
                  revisionNumber.intValue >= 0,
                  let intentObject = params["intent"] as? [String: Any],
                  intentObject["op"] as? String == "set-text",
                  let text = intentObject["text"] as? String
            else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid arbor.intentApply payload"]
                )
            }
            let requestID = (params["requestId"] as? String)
                ?? (params["requestID"] as? String)
                ?? UUID().uuidString
            var response = await workspaceTabController.arborKernelSupervisor.applyIntent(
                documentID: documentID,
                revision: revisionNumber.intValue,
                resultID: resultID,
                intent: ArborKernelIntent(op: "set-text", text: text),
                requestID: requestID
            )
            if response.ok,
               let expectedSource = response.expectedSource,
               let candidate = response.document,
               let candidateRevision = candidate.revision,
               let candidateSource = candidate.source {
                do {
                    guard let fileURL = notesModel.workspaceURL(for: candidate.path),
                          let rootURL = notesModel.workspaceItemURL(allowingRootRelativePath: nil),
                          fileURL.resolvingSymlinksInPath().path.hasPrefix(
                            rootURL.resolvingSymlinksInPath().path + "/"
                          ),
                          try await WorkspaceFileIO.shared.readText(from: fileURL) == expectedSource
                    else {
                        throw NSError(
                            domain: "NVModern",
                            code: 409,
                            userInfo: [NSLocalizedDescriptionKey: "The source document changed on disk; reload before applying this edit."]
                        )
                    }
                    try await notesModel.saveTextNoteAsync(
                        relativePath: candidate.path,
                        body: candidateSource
                    )
                    let replaced = await workspaceTabController.arborKernelSupervisor.replaceDocument(
                        ArborKernelDocument(
                            id: candidate.id,
                            path: candidate.path,
                            revision: candidateRevision,
                            source: candidateSource
                        ),
                        requestID: "\(requestID):replace"
                    )
                    guard replaced.ok else {
                        throw NSError(
                            domain: "NVModern",
                            code: 502,
                            userInfo: [NSLocalizedDescriptionKey: "The kernel rejected the source-backed replacement."]
                        )
                    }
                } catch {
                    response = .failure(
                        id: requestID,
                        operation: "intent/apply",
                        revision: revisionNumber.intValue,
                        path: response.origin?.path ?? "",
                        code: "ARBOR3405",
                        message: error.localizedDescription
                    )
                }
            }
            response.document = nil
            response.expectedSource = nil
            let responseData = try JSONEncoder().encode(response)
            return try JSONSerialization.jsonObject(with: responseData)

        default:
            throw NSError(
                domain: "NVModern",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Unhandled web request method: \(method)"]
            )
        }
    }

    @MainActor
    private func executeArborEffect(_ effect: ArborKernelEffect) async -> ArborKernelResponse {
        let supervisor = workspaceTabController.arborKernelSupervisor
        let startedAt = ProcessInfo.processInfo.systemUptime
        LocalDiagnosticsCenter.shared.log(
            category: "arbor.effect",
            event: "received",
            metadata: ["effect": arborDiagnosticJSON(effect)]
        )
        // The consent gate is skipped entirely when `capability` decodes as nil,
        // which is indistinguishable at runtime from a granted capability. Log
        // both inputs so a missing prompt can be told apart from a silent
        // decode failure.
        LocalDiagnosticsCenter.shared.log(
            category: "arbor.capability",
            event: "effectGate",
            metadata: [
                "handler": effect.handler,
                "capability": effect.capability.map { "\($0.id) kind=\($0.kind) resource=\($0.resource)" } ?? "nil",
                "alreadyGranted": effect.capability.map { supervisor.hasCapabilityGrant($0.id).description } ?? "n/a"
            ]
        )
        if let capability = effect.capability,
           !supervisor.hasCapabilityGrant(capability.id) {
            let alert = NSAlert()
            alert.messageText = "Allow this Arbor node to perform an effect?"
            alert.informativeText = capability.summary
            alert.addButton(withTitle: "Allow Once")
            alert.addButton(withTitle: "Allow for This Node")
            alert.addButton(withTitle: "Cancel")
            let choice = alert.runModal()
            LocalDiagnosticsCenter.shared.log(
                category: "arbor.effect",
                event: "permissionDecision",
                metadata: [
                    "capability": arborDiagnosticJSON(capability),
                    "choice": choice == .alertFirstButtonReturn
                        ? "allowOnce"
                        : choice == .alertSecondButtonReturn ? "allowForNode" : "cancel",
                    "executionID": effect.executionID
                ]
            )
            if choice == .alertThirdButtonReturn {
                return await supervisor.completeEffect(
                    executionID: effect.executionID,
                    outcome: ArborKernelEffectOutcome(
                        ok: false,
                        value: nil,
                        message: "Effect permission was denied."
                    ),
                    requestID: "\(effect.executionID):denied"
                )
            }
            if choice == .alertSecondButtonReturn {
                supervisor.rememberCapabilityGrant(capability.id)
            }
        }

        do {
            guard let root = notesModel.workspaceItemURL(allowingRootRelativePath: nil) else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "The workspace root is unavailable."]
                )
            }
            LocalDiagnosticsCenter.shared.log(
                category: "arbor.effect",
                event: "executionStarted",
                metadata: [
                    "effect": arborDiagnosticJSON(effect),
                    "workspaceRoot": root.path
                ]
            )
            let value = try await ArborEffectBroker.execute(effect, workspaceRoot: root)
            LocalDiagnosticsCenter.shared.log(
                category: "arbor.effect",
                event: "executionCompleted",
                metadata: [
                    "durationMs": String(format: "%.1f", max(
                        0,
                        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                    )),
                    "executionID": effect.executionID,
                    "value": arborDiagnosticJSON(value)
                ]
            )
            return await supervisor.completeEffect(
                executionID: effect.executionID,
                outcome: ArborKernelEffectOutcome(ok: true, value: value, message: nil),
                requestID: "\(effect.executionID):complete"
            )
        } catch {
            LocalDiagnosticsCenter.shared.log(
                level: .error,
                category: "arbor.effect",
                event: "executionFailed",
                metadata: [
                    "durationMs": String(format: "%.1f", max(
                        0,
                        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                    )),
                    "error": error.localizedDescription,
                    "executionID": effect.executionID
                ]
            )
            return await supervisor.completeEffect(
                executionID: effect.executionID,
                outcome: ArborKernelEffectOutcome(
                    ok: false,
                    value: nil,
                    message: error.localizedDescription
                ),
                requestID: "\(effect.executionID):failed"
            )
        }
    }

    @MainActor
    private func executeArborMutation(_ mutation: ArborKernelMutation) async -> ArborKernelResponse {
        let supervisor = workspaceTabController.arborKernelSupervisor
        let startedAt = ProcessInfo.processInfo.systemUptime
        LocalDiagnosticsCenter.shared.log(
            category: "arbor.mutation",
            event: "received",
            metadata: ["mutation": arborDiagnosticJSON(mutation)]
        )
        let alert = NSAlert()
        alert.messageText = mutation.destructive
            ? "Apply this destructive outline transaction?"
            : "Apply this outline transaction?"
        alert.informativeText = ([mutation.capability.summary] + mutation.summary)
            .joined(separator: "\n")
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        LocalDiagnosticsCenter.shared.log(
            category: "arbor.mutation",
            event: "permissionDecision",
            metadata: [
                "choice": choice == .alertFirstButtonReturn ? "apply" : "cancel",
                "executionID": mutation.executionID
            ]
        )
        guard choice == .alertFirstButtonReturn else {
            return await supervisor.completeMutation(
                executionID: mutation.executionID,
                outcome: ArborKernelEffectOutcome(
                    ok: false,
                    value: nil,
                    message: "Outline transaction was denied."
                ),
                requestID: "\(mutation.executionID):denied"
            )
        }

        do {
            let document = mutation.document
            guard let fileURL = notesModel.workspaceURL(for: document.path),
                  let rootURL = notesModel.workspaceItemURL(allowingRootRelativePath: nil),
                  fileURL.resolvingSymlinksInPath().path.hasPrefix(
                    rootURL.resolvingSymlinksInPath().path + "/"
                  ),
                  try await WorkspaceFileIO.shared.readText(from: fileURL) == mutation.expectedSource
            else {
                throw NSError(
                    domain: "NVModern",
                    code: 409,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The source document changed on disk; reload before applying this transaction."
                    ]
                )
            }
            try await notesModel.saveTextNoteAsync(
                relativePath: document.path,
                body: document.source
            )
            LocalDiagnosticsCenter.shared.log(
                category: "arbor.mutation",
                event: "candidateSaved",
                metadata: [
                    "document": arborDiagnosticJSON(document),
                    "durationMs": String(format: "%.1f", max(
                        0,
                        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                    )),
                    "executionID": mutation.executionID
                ]
            )
            let replaced = await supervisor.replaceDocument(
                document,
                requestID: "\(mutation.executionID):replace"
            )
            guard replaced.ok else {
                try? await notesModel.saveTextNoteAsync(
                    relativePath: document.path,
                    body: mutation.expectedSource
                )
                throw NSError(
                    domain: "NVModern",
                    code: 502,
                    userInfo: [
                        NSLocalizedDescriptionKey: "The kernel rejected the outline transaction."
                    ]
                )
            }
            LocalDiagnosticsCenter.shared.log(
                category: "arbor.mutation",
                event: "candidateAccepted",
                metadata: [
                    "executionID": mutation.executionID,
                    "response": arborDiagnosticJSON(replaced)
                ]
            )
            return await supervisor.completeMutation(
                executionID: mutation.executionID,
                outcome: ArborKernelEffectOutcome(ok: true, value: nil, message: nil),
                requestID: "\(mutation.executionID):complete"
            )
        } catch {
            LocalDiagnosticsCenter.shared.log(
                level: .error,
                category: "arbor.mutation",
                event: "failed",
                metadata: [
                    "durationMs": String(format: "%.1f", max(
                        0,
                        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                    )),
                    "error": error.localizedDescription,
                    "executionID": mutation.executionID
                ]
            )
            return await supervisor.completeMutation(
                executionID: mutation.executionID,
                outcome: ArborKernelEffectOutcome(
                    ok: false,
                    value: nil,
                    message: error.localizedDescription
                ),
                requestID: "\(mutation.executionID):failed"
            )
        }
    }

    private func sendMarkdownReferenceJump(path: String, reference: MarkdownReferenceTarget) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = reference.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, !trimmedQuery.isEmpty else {
            return
        }

        prepareTextEditorController().bridge.sendCommand(
            "jumpToMarkdownReference",
            payload: [
                "id": UUID().uuidString,
                "path": trimmedPath,
                "kind": reference.kind.rawValue,
                "query": trimmedQuery
            ]
        )
    }

    private func consumePendingMarkdownJump() {
        guard let jump = state.pendingMarkdownJump else { return }
        guard let path = state.openedDocument?.editorPath, !path.isEmpty else { return }
        if let heading = jump.heading?.trimmingCharacters(in: .whitespacesAndNewlines), !heading.isEmpty {
            sendMarkdownReferenceJump(
                path: path,
                reference: MarkdownReferenceTarget(kind: .heading, query: heading)
            )
        } else if let line = jump.line, line > 0 {
            prepareTextEditorController().bridge.sendCommand(
                "jumpToMarkdownReference",
                payload: [
                    "id": UUID().uuidString,
                    "path": path,
                    "kind": "line",
                    "query": String(line)
                ]
            )
        }
        state.pendingMarkdownJump = nil
    }

    private func scheduleNoteSave(path: String, body: String) {
        guard let document = state.openedDocument,
              document.editorPath == path else {
            return
        }

        pendingSaveTasks[path]?.cancel()

        pendingSaveTasks[path] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            guard state.openedDocument?.editorPath == path else {
                pendingSaveTasks[path] = nil
                return
            }

            do {
                switch document {
                case .workspaceNote(let relativePath):
                    try await notesModel.saveTextNoteAsync(relativePath: relativePath, body: body)
                    workspaceTabController.sideStack.noteDidSave(path: relativePath, body: body)
                    state.liveCachedTextBody = body
                    state.liveCachedData = Data(body.utf8)
                    state.liveCachedKind = .text
                    state.persistedTextSnapshot = PersistedTextDocumentSnapshot(
                        path: relativePath,
                        title: state.liveCachedTitle ?? URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent,
                        body: body,
                        modifiedDate: nil,
                        mimeType: "text/plain",
                        fileSize: Int64(body.lengthOfBytes(using: .utf8)),
                        capturedAt: Date()
                    )
                    asyncTextContextOverride = EditorSelectionContext(
                        kind: .text,
                        title: state.liveCachedTitle ?? URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent,
                        relativePath: relativePath,
                        body: body,
                        modifiedDate: nil,
                        mimeType: "text/plain",
                        fileSize: Int64(body.lengthOfBytes(using: .utf8))
                    )
                    state.liveDeletedSnapshot = WorkspaceDeletedDocumentSnapshot(
                        title: state.liveCachedTitle ?? URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent,
                        kind: .text,
                        relativePath: relativePath,
                        textBody: body,
                        data: Data(body.utf8),
                        mimeType: "text/plain"
                    )
                    if case .modified(let bannerPath, _) = state.liveBanner?.kind,
                       bannerPath == relativePath {
                        state.liveBanner = nil
                    }
                case .externalMarkdown(let filePath):
                    let url = URL(fileURLWithPath: filePath)
                    try await WorkspaceFileIO.shared.writeText(body, to: url)
                    state.persistedTextSnapshot = PersistedTextDocumentSnapshot(
                        path: filePath,
                        title: URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent,
                        body: body,
                        modifiedDate: nil,
                        mimeType: "text/markdown",
                        fileSize: Int64(body.lengthOfBytes(using: .utf8)),
                        capturedAt: Date()
                    )
                    asyncTextContextOverride = EditorSelectionContext(
                        kind: .text,
                        title: URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent,
                        relativePath: filePath,
                        body: body,
                        modifiedDate: nil,
                        mimeType: "text/markdown",
                        fileSize: Int64(body.lengthOfBytes(using: .utf8))
                    )
                case .clipboardMarkdown:
                    break
                case .diff:
                    break
                }
            } catch {
                LocalDiagnosticsCenter.shared.log(
                    level: .error,
                    category: "editor.save",
                    event: "saveFailed",
                    metadata: [
                        "path": path,
                        "document": String(describing: document),
                        "error": error.localizedDescription
                    ]
                )
                print("[NVModern][Editor] Save failed for \(path): \(error)")
            }

            pendingSaveTasks[path] = nil
        }
    }

    private func scheduleCSVSave(path: String, snapshot: CSVGridSaveSnapshot) {
        guard let document = state.openedDocument,
              document.editorPath == path else {
            return
        }

        pendingSaveTasks[path]?.cancel()

        pendingSaveTasks[path] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            guard state.openedDocument?.editorPath == path else {
                pendingSaveTasks[path] = nil
                return
            }

            do {
                switch document {
                case .workspaceNote(let relativePath):
                    try notesModel.saveDataNote(relativePath: relativePath, data: snapshot.data)
                    state.liveCachedData = snapshot.data
                    state.liveCachedKind = .csv
                    state.liveDeletedSnapshot = WorkspaceDeletedDocumentSnapshot(
                        title: state.liveCachedTitle ?? URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent,
                        kind: .csv,
                        relativePath: relativePath,
                        textBody: nil,
                        data: snapshot.data,
                        mimeType: "text/csv"
                    )
                    if case .modified(let bannerPath, _) = state.liveBanner?.kind,
                       bannerPath == relativePath {
                        state.liveBanner = nil
                    }
                case .externalMarkdown(let filePath):
                    let url = URL(fileURLWithPath: filePath)
                    try snapshot.data.write(to: url, options: .atomic)
                case .clipboardMarkdown, .diff:
                    break
                }
            } catch {
                print("[NVModern][CSV] Save failed for \(path): \(error)")
            }

            pendingSaveTasks[path] = nil
        }
    }

    private func pushEditorContext() {
        let documentToDisplay = displayedDocument
        debugContentLog("pushEditorContext.begin opened=\(state.openedDocument.map { String(describing: $0) } ?? "nil") preview=\(palettePreviewDocument.map { String(describing: $0) } ?? "nil") selectedNote=\(state.selectedNotePath ?? "nil") activeContext=\(activeEditorContext.map { "\($0.kind.rawValue):\($0.relativePath)" } ?? "nil")")
        WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "pushEditorContext.begin")
        defer {
            publishEditorCommandTarget()
            publishLiveSyncObservation()
        }

        pendingPDFZoomCommand = nil
        pendingPDFNavigationCommand = nil
        pendingImageZoomCommand = nil
        cancelPendingTextContextLoadIfNeeded(for: documentToDisplay, reason: "pushEditorContext")

        if let document = documentToDisplay {
            if scheduleAsyncTextContextLoadIfNeeded(for: document) {
                debugContentLog("pushEditorContext.asyncTextLoading document=\(String(describing: document)) context=\(activeEditorContext.map { "\($0.kind.rawValue):\($0.relativePath)" } ?? "nil")")
                if let loadingContext = activeEditorContext,
                   !loadingContext.body.isEmpty {
                    pushWebContext(
                        loadingContext,
                        document: document,
                        isEditable: isDocumentEditable(document, context: loadingContext),
                        allowPreviewURL: false
                    )
                } else if activeEditorContext?.kind == .text {
                    _ = prepareTextEditorController()
                }
                return
            }
            WorkspaceActivationTraceCenter.shared.mark(
                tabID: tabID,
                event: "editorContext.resolve.start",
                details: ["document": String(describing: document)]
            )
            let resolveStart = ProcessInfo.processInfo.systemUptime
            let resolvedContext = editorContext(for: document)
            let resolveDurationMs = (ProcessInfo.processInfo.systemUptime - resolveStart) * 1000
            WorkspaceActivationTraceCenter.shared.mark(
                tabID: tabID,
                event: "editorContext.resolve.end",
                details: [
                    "resolved": resolvedContext == nil ? "false" : "true",
                    "durationMs": String(format: "%.2f", resolveDurationMs)
                ]
            )

            if let context = resolvedContext {
                debugContentLog("pushEditorContext.resolved document=\(String(describing: document)) context=\(context.kind.rawValue):\(context.relativePath)")
                cancelDocumentResolutionRetry()
                WorkspaceActivationTraceCenter.shared.updateTarget(
                    tabID: tabID,
                    path: context.relativePath,
                    kind: context.kind.rawValue
                )

                let previousContext = activeEditorContext
                activeEditorContext = context
                if !isPaletteDocumentPreviewActive {
                    cacheWorkspaceSnapshotIfNeeded(document: document, context: context)
                    onTabPresentationChange(tabPresentation(for: document, context: context))
                }

                if context.kind == .pdf {
                    guard let pdfURL = activePDFURL else {
                        debugContentLog("pushEditorContext.pdfMissingURL context=\(context.relativePath)")
                        WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "pushEditorContext.pdfMissingURL")
                        return
                    }
                    let marker = PDFPreviewContentController.Marker(
                        fileURL: pdfURL,
                        reloadToken: activePreviewReloadToken
                    )
                    let reusesExistingController = workspaceTabController.pdfContent.matches(marker: marker)
                    _ = preparePDFController(
                        marker: marker,
                        initialScrollRatio: activePDFScrollRatio,
                        traceDocumentPath: context.relativePath
                    )
                    let finishMode: WorkspaceActivationTraceCenter.FinishMode = reusesExistingController
                        ? .pdfAttachReady
                        : .pdfPageInfo
                    WorkspaceActivationTraceCenter.shared.expect(tabID: tabID, finishMode: finishMode)
                    WorkspaceActivationTraceCenter.shared.mark(
                        tabID: tabID,
                        event: "pushEditorContext.pdfSelected",
                        details: [
                            "reuse": reusesExistingController ? "true" : "false",
                            "path": context.relativePath
                        ]
                    )
                    return
                }

                if context.kind == .image {
                    WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "pushEditorContext.imageSelected")
                    let isDifferentImage = previousContext?.kind != .image || previousContext?.relativePath != context.relativePath
                    if isDifferentImage {
                        imageAdjustments = .identity
                    }
                    guard let imageURL = activeImageURL else {
                        debugContentLog("pushEditorContext.imageMissingURL context=\(context.relativePath)")
                        WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "pushEditorContext.imageMissingURL")
                        return
                    }
                    _ = prepareImageController(
                        marker: ImagePreviewContentController.Marker(
                            fileURL: imageURL,
                            reloadToken: activePreviewReloadToken
                        )
                    )
                    return
                }

                if context.kind == .csv {
                    guard let csvURL = activeCSVURL else {
                        debugContentLog("pushEditorContext.csvMissingURL context=\(context.relativePath)")
                        WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "pushEditorContext.csvMissingURL")
                        return
                    }
                    let marker = CSVPreviewContentController.Marker(
                        fileURL: csvURL,
                        reloadToken: activePreviewReloadToken
                    )
                    let reusesExistingController = workspaceTabController.csvContent.matches(marker: marker)
                    _ = prepareCSVController(
                        marker: marker,
                        sourceRelativePath: context.relativePath
                    )
                    let finishMode: WorkspaceActivationTraceCenter.FinishMode = reusesExistingController
                        ? .csvAttachReady
                        : .csvDocumentApplied
                    WorkspaceActivationTraceCenter.shared.expect(tabID: tabID, finishMode: finishMode)
                    WorkspaceActivationTraceCenter.shared.mark(
                        tabID: tabID,
                        event: "pushEditorContext.csvSelected",
                        details: [
                            "reuse": reusesExistingController ? "true" : "false",
                            "path": context.relativePath
                        ]
                    )
                    return
                }

                if context.kind == .canvas {
                    guard let canvasURL = activeCanvasURL else { return }
                    _ = prepareCanvasController(
                        marker: CanvasDocumentContentController.Marker(
                            fileURL: canvasURL,
                            reloadToken: activePreviewReloadToken,
                            isReadOnly: isPaletteDocumentPreviewActive
                        )
                    )
                    return
                }

                if context.kind == .html {
                    guard let htmlURL = activeHTMLURL,
                          let readAccessURL = activeHTMLReadAccessURL else {
                        debugContentLog("pushEditorContext.htmlMissingURL context=\(context.relativePath)")
                        WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "pushEditorContext.htmlMissingURL")
                        return
                    }
                    let marker = HTMLPreviewContentController.Marker(
                        fileURL: htmlURL,
                        readAccessURL: readAccessURL,
                        reloadToken: activePreviewReloadToken
                    )
                    let reusesExistingController = workspaceTabController.htmlContent.matches(marker: marker)
                    _ = prepareHTMLController(marker: marker)
                    WorkspaceActivationTraceCenter.shared.mark(
                        tabID: tabID,
                        event: "pushEditorContext.htmlSelected",
                        details: [
                            "reuse": reusesExistingController ? "true" : "false",
                            "path": context.relativePath
                        ]
                    )
                    return
                }

                pushWebContext(
                    context,
                    document: document,
                    isEditable: isDocumentEditable(document, context: context)
                )
                debugContentLog("pushEditorContext.pushedWeb context=\(context.kind.rawValue):\(context.relativePath)")
                return
            }

            let placeholderContext = unresolvedDocumentPlaceholderContext(for: document)
            debugContentLog("pushEditorContext.placeholder document=\(String(describing: document)) context=\(placeholderContext.kind.rawValue):\(placeholderContext.relativePath)")
            WorkspaceActivationTraceCenter.shared.mark(
                tabID: tabID,
                event: "editorContext.resolve.placeholder",
                details: [
                    "document": String(describing: document),
                    "path": placeholderContext.relativePath
                ]
            )
            WorkspaceActivationTraceCenter.shared.updateTarget(
                tabID: tabID,
                path: placeholderContext.relativePath,
                kind: placeholderContext.kind.rawValue
            )
            activeEditorContext = placeholderContext
            if !isPaletteDocumentPreviewActive {
                onTabPresentationChange(document.tabPresentation)
            }
            pushWebContext(
                placeholderContext,
                document: document,
                isEditable: false,
                allowPreviewURL: false
            )
            scheduleDocumentResolutionRetry(for: document)
            return
        }

        cancelDocumentResolutionRetry()
        asyncTextContextOverride = nil
        let folderContext = notesModel.contextForFolder(relativePath: currentMillerFolderPath)
        debugContentLog("pushEditorContext.folder context=\(folderContext.kind.rawValue):\(folderContext.relativePath)")
        WorkspaceActivationTraceCenter.shared.updateTarget(
            tabID: tabID,
            path: folderContext.relativePath,
            kind: folderContext.kind.rawValue
        )
        activeEditorContext = folderContext
        onTabPresentationChange(WorkspaceTabPresentation(title: folderContext.title, icon: "note.text"))
        pushWebContext(
            folderContext,
            document: .clipboardMarkdown(title: folderContext.title, body: folderContext.body),
            isEditable: false,
            titleOverride: "Folder: \(folderContext.title)",
            allowPreviewURL: false
        )
    }

    private func cacheWorkspaceSnapshotIfNeeded(document: WorkspaceOpenedDocument, context: EditorSelectionContext) {
        guard case .workspaceNote(let relativePath) = document else { return }

        state.liveCachedTitle = context.title
        state.liveCachedKind = context.kind

        switch context.kind {
        case .text:
            asyncTextContextOverride = context
            state.liveCachedTextBody = context.body
            state.liveCachedData = Data(context.body.utf8)
            state.persistedTextSnapshot = makePersistedTextSnapshot(document: document, context: context)
            state.liveDeletedSnapshot = WorkspaceDeletedDocumentSnapshot(
                title: context.title,
                kind: .text,
                relativePath: relativePath,
                textBody: context.body,
                data: Data(context.body.utf8),
                mimeType: context.mimeType
            )
        case .csv, .canvas, .epub, .pdf, .image, .html, .unsupported:
            asyncTextContextOverride = nil
            state.persistedTextSnapshot = nil
            WorkspaceActivationTraceCenter.shared.mark(tabID: tabID, event: "workspaceSnapshot.binaryRead.start", details: ["path": relativePath])
            let binaryReadStart = ProcessInfo.processInfo.systemUptime
            let fileData = notesModel.workspaceURL(for: relativePath).flatMap { try? Data(contentsOf: $0) }
            let binaryReadDurationMs = (ProcessInfo.processInfo.systemUptime - binaryReadStart) * 1000
            WorkspaceActivationTraceCenter.shared.mark(
                tabID: tabID,
                event: "workspaceSnapshot.binaryRead.end",
                details: [
                    "path": relativePath,
                    "bytes": fileData.map { String($0.count) } ?? "0",
                    "durationMs": String(format: "%.2f", binaryReadDurationMs)
                ]
            )
            state.liveCachedTextBody = nil
            state.liveCachedData = fileData
            state.liveDeletedSnapshot = WorkspaceDeletedDocumentSnapshot(
                title: context.title,
                kind: context.kind,
                relativePath: relativePath,
                textBody: nil,
                data: fileData,
                mimeType: context.mimeType
            )
        case .folder, .diff:
            state.liveCachedTextBody = nil
            state.liveCachedData = nil
            state.persistedTextSnapshot = nil
            state.liveDeletedSnapshot = nil
        }
    }

    private func substitutionRulesPayload() -> [[String: String]] {
        notesModel.runtimeConfig.substitutions.map { rule in
            [
                "from": rule.from,
                "to": rule.to
            ]
        }
    }

    /// Base theme CSS for a document: its file type's defaults when
    /// `[filetypes.<ext>]` sets them, otherwise the global editor theme.
    private func editorThemeCSSPayload(forPath path: String? = nil) -> String? {
        notesModel.runtimeConfig.editorThemeCSS(forPath: path)
    }

    private func editorContentReloadToken(for context: EditorSelectionContext, isEditable: Bool) -> String {
        let manualReloadToken = String(format: "%.6f", notesModel.lastReloadDate.timeIntervalSinceReferenceDate)

        switch context.kind {
        case .folder:
            return "\(manualReloadToken)|tree=\(notesModel.liveTreeRevision)|local=\(state.liveLocalRefreshRevision)|editable=\(isEditable)"
        case .unsupported, .text, .epub, .pdf, .csv, .canvas, .image, .html, .diff:
            return "\(manualReloadToken)|local=\(state.liveLocalRefreshRevision)|editable=\(isEditable)"
        }
    }

    private func editorContentContextMarker(for context: EditorSelectionContext, isEditable: Bool) -> EditorWebContentController.ContextMarker {
        EditorWebContentController.ContextMarker(
            kind: context.kind.rawValue,
            path: context.relativePath,
            reloadToken: editorContentReloadToken(for: context, isEditable: isEditable),
            isEditable: isEditable
        )
    }

    private func pushWebContext(
        _ context: EditorSelectionContext,
        document: WorkspaceOpenedDocument,
        isEditable: Bool,
        titleOverride: String? = nil,
        allowPreviewURL: Bool = true
    ) {
        syncDocumentFrontmatterAppearance(for: context)
        let controller: EditorWebContentController
        switch context.kind {
        case .text:
            controller = prepareTextEditorController()
        case .epub:
            controller = prepareEPUBController()
        default:
            controller = preparePreviewController()
        }
        let marker = editorContentContextMarker(for: context, isEditable: isEditable)
        let shouldPush = controller.shouldPushContext(marker)
        let appearance = effectiveDocumentInspectorAppearance

        if shouldPush {
            WorkspaceActivationTraceCenter.shared.expect(tabID: tabID, finishMode: .webContextReceived)
            var payload: [String: Any] = [
                "kind": context.kind.rawValue,
                "title": titleOverride ?? context.title,
                "path": context.relativePath,
                "body": context.body,
                "users": notesModel.runtimeConfig.users,
                "substitutionRules": substitutionRulesPayload(),
                "isEditable": isEditable
            ]

            if let userThemeCSS = editorThemeCSSPayload(forPath: context.relativePath) {
                payload["userThemeCSS"] = userThemeCSS
            }
            payload["documentInspectorTheme"] = appearance.settings.theme.rawValue
            payload["documentInspectorCSS"] = appearance.css
            payload["unwrapMarkdownLines"] = appearance.settings.unwrapMarkdownLines

            if let markdownScrollRatio = markdownScrollRatio(for: document, context: context) {
                payload["scrollState"] = [
                    "kind": PersistedDocumentScrollKind.markdown.rawValue,
                    "ratio": markdownScrollRatio
                ]
                // print("[NVModern][ScrollRestore] setContext path=\(context.relativePath) ratio=\(markdownScrollRatio)")
            } else if context.kind == .text {
                // print("[NVModern][ScrollRestore] setContext path=\(context.relativePath) ratio=nil")
            }

            if context.kind == .epub,
               case .workspaceNote(let relativePath) = document,
               let location = WorkspaceSessionStore.shared.epubLocation(
                   rootURL: notesModel.runtimeConfig.rootURL,
                   relativePath: relativePath
               ) {
                var locationPayload: [String: Any] = ["href": location.href]
                if let cfi = location.cfi { locationPayload["cfi"] = cfi }
                if let progression = location.progression { locationPayload["progression"] = progression }
                locationPayload["kind"] = "epub"
                payload["scrollState"] = locationPayload
            }

            if let mimeType = context.mimeType {
                payload["mimeType"] = mimeType
            }

            if let fileSize = context.fileSize {
                payload["fileSize"] = fileSize
            }

            if let diff = context.diff {
                payload["diff"] = [
                    "left": [
                        "path": diff.left.path,
                        "title": diff.left.title,
                        "body": diff.left.body
                    ],
                    "right": [
                        "path": diff.right.path,
                        "title": diff.right.title,
                        "body": diff.right.body
                    ]
                ]
            }

            if allowPreviewURL,
               !context.kind.isEditable,
               context.kind != .folder,
               let previewURL = previewURLString(for: context.relativePath) {
                payload["previewURL"] = previewURL
            }

            WorkspaceActivationTraceCenter.shared.mark(
                tabID: tabID,
                event: "web.setContext.send",
                details: [
                    "bridgeReady": controller.isBridgeReady ? "true" : "false",
                    "path": context.relativePath
                ]
            )
            controller.bridge.sendCommand("setContext", payload: payload)
        } else {
            WorkspaceActivationTraceCenter.shared.expect(tabID: tabID, finishMode: .webAttachReady)
            WorkspaceActivationTraceCenter.shared.mark(
                tabID: tabID,
                event: "web.setContext.skip",
                details: [
                    "bridgeReady": controller.isBridgeReady ? "true" : "false",
                    "attached": controller.isAttached ? "true" : "false",
                    "path": context.relativePath
                ]
            )
            if controller.isBridgeReady && controller.isAttached {
                WorkspaceActivationTraceCenter.shared.finishIfExpected(
                    tabID: tabID,
                    mode: .webAttachReady,
                    event: "web.ready.reusedSession",
                    details: [
                        "bridgeReady": "true",
                        "attached": "true",
                        "path": context.relativePath
                    ]
                )
            }
        }
    }

    /// Retries used to give up after 6 attempts (~4.5s) and leave the
    /// placeholder up forever; rescans now keep a slow cadence going so a
    /// slow iCloud index catches up while the tab is open.
    private static let documentResolutionRetryMaxAttempts = 20

    private func documentResolutionRetryKey(for document: WorkspaceOpenedDocument?) -> String? {
        guard let document else { return nil }

        switch document {
        case .workspaceNote(let relativePath):
            return relativePath
        case .externalMarkdown, .clipboardMarkdown, .diff:
            return nil
        }
    }

    private func cancelDocumentResolutionRetry(resetAttempt: Bool = true) {
        pendingDocumentResolutionRetryTask?.cancel()
        pendingDocumentResolutionRetryTask = nil
        pendingDocumentResolutionRetryKey = nil
        if resetAttempt {
            pendingDocumentResolutionRetryAttempt = 0
        }
    }

    private func scheduleDocumentResolutionRetry(for document: WorkspaceOpenedDocument) {
        guard let retryKey = documentResolutionRetryKey(for: document) else {
            cancelDocumentResolutionRetry()
            return
        }

        if pendingDocumentResolutionRetryKey != retryKey {
            pendingDocumentResolutionRetryTask?.cancel()
            pendingDocumentResolutionRetryTask = nil
            pendingDocumentResolutionRetryKey = retryKey
            pendingDocumentResolutionRetryAttempt = 0
        }

        guard pendingDocumentResolutionRetryAttempt < Self.documentResolutionRetryMaxAttempts else {
            return
        }

        pendingDocumentResolutionRetryAttempt += 1
        let attempt = pendingDocumentResolutionRetryAttempt
        // A placeholder means the file is missing from the scan snapshot, so
        // a fresh scan is the only thing that can resolve it. Ask for one at
        // a throttled cadence; the model serializes scans on a background
        // queue, so requests are cheap to make and never block this thread.
        if [2, 5, 9, 14, 20].contains(attempt) {
            notesModel.scheduleScan(update: nil, reason: "documentResolutionRetry")
        }
        pendingDocumentResolutionRetryTask?.cancel()
        pendingDocumentResolutionRetryTask = Task { @MainActor in
            let delaySeconds = min(1.5, 0.25 * Double(attempt))
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard documentResolutionRetryKey(for: displayedDocument) == retryKey else {
                return
            }
            pendingDocumentResolutionRetryTask = nil
            pushEditorContext()
        }
    }

    private func unresolvedDocumentPlaceholderContext(for document: WorkspaceOpenedDocument) -> EditorSelectionContext {
        let relativePath: String
        let title: String
        let body: String

        switch document {
        case .workspaceNote(let notePath):
            relativePath = notePath
            let fileURL = URL(fileURLWithPath: notePath)
            title = fileURL.deletingPathExtension().lastPathComponent
            body = {
                if pendingDocumentResolutionRetryAttempt == 0 {
                    return "Loading document…"
                }
                if pendingDocumentResolutionRetryAttempt >= Self.documentResolutionRetryMaxAttempts {
                    return "Still not in the workspace index. If this file lives in iCloud, it may not be downloaded yet."
                }
                return "Waiting for the workspace index to catch up…"
            }()
        case .externalMarkdown(let filePath):
            relativePath = filePath
            let fileURL = URL(fileURLWithPath: filePath)
            title = fileURL.deletingPathExtension().lastPathComponent
            body = "The selected file could not be loaded."
        case .clipboardMarkdown(let titleValue, let textBody):
            relativePath = document.editorPath
            title = titleValue
            body = textBody
        case .diff(let left, let right):
            relativePath = document.editorPath
            title = "\(left.displayName) ↔ \(right.displayName)"
            body = "The comparison could not be loaded."
        }

        return EditorSelectionContext(
            kind: .unsupported,
            title: title.isEmpty ? "Untitled" : title,
            relativePath: relativePath,
            body: body,
            modifiedDate: nil,
            mimeType: "text/plain",
            fileSize: nil
        )
    }

    private func textContextLoadKey(for document: WorkspaceOpenedDocument?) -> String? {
        guard let document else { return nil }

        switch document {
        case .workspaceNote(let relativePath):
            return "workspace:\(relativePath)"
        case .externalMarkdown(let filePath):
            return "external:\(filePath)"
        case .diff(let left, let right):
            return "diff:\(left.path)\u{1f}\(right.path)"
        case .clipboardMarkdown:
            return nil
        }
    }

    private func cancelPendingTextContextLoadIfNeeded(for document: WorkspaceOpenedDocument?, reason: String) {
        let expectedKey = textContextLoadKey(for: document)
        guard let pendingTextContextLoadTask else {
            pendingTextContextLoadKey = nil
            return
        }

        guard pendingTextContextLoadKey != expectedKey else {
            return
        }

        #if DEBUG
        print("[NVModern][TextLoad] cancelPending reason=\(reason) pending=\(pendingTextContextLoadKey ?? "nil") expected=\(expectedKey ?? "nil") tab=\(tabID)")
        #endif
        pendingTextContextLoadTask.cancel()
        self.pendingTextContextLoadTask = nil
        pendingTextContextLoadKey = nil
    }

    private func makePersistedTextSnapshot(
        document: WorkspaceOpenedDocument,
        context: EditorSelectionContext
    ) -> PersistedTextDocumentSnapshot? {
        guard context.kind == .text,
              !context.body.isEmpty else {
            return nil
        }

        let path: String
        switch document {
        case .workspaceNote(let relativePath):
            path = relativePath
        case .externalMarkdown(let filePath):
            path = filePath
        case .clipboardMarkdown, .diff:
            return nil
        }

        let snapshot = PersistedTextDocumentSnapshot(
            path: path,
            title: context.title,
            body: context.body,
            modifiedDate: context.modifiedDate,
            mimeType: context.mimeType,
            fileSize: context.fileSize,
            capturedAt: Date()
        )
        return snapshot.isWithinSizeLimit ? snapshot : nil
    }

    private func applyPersistedTextSnapshotIfValid(
        _ snapshot: PersistedTextDocumentSnapshot?,
        document: WorkspaceOpenedDocument,
        lightweightContext: EditorSelectionContext
    ) -> Bool {
        guard let snapshot,
              snapshot.isWithinSizeLimit,
              !snapshot.body.isEmpty,
              snapshot.path == document.editorPath,
              snapshot.path == lightweightContext.relativePath else {
            return false
        }

        if let snapshotFileSize = snapshot.fileSize,
           let currentFileSize = lightweightContext.fileSize,
           snapshotFileSize != currentFileSize {
            #if DEBUG
            print("[NVModern][TextSnapshot] reject path=\(snapshot.path) reason=fileSize snapshot=\(snapshotFileSize) current=\(currentFileSize)")
            #endif
            return false
        }

        if let snapshotModifiedDate = snapshot.modifiedDate,
           let currentModifiedDate = lightweightContext.modifiedDate,
           abs(snapshotModifiedDate.timeIntervalSince(currentModifiedDate)) > 1 {
            #if DEBUG
            print("[NVModern][TextSnapshot] reject path=\(snapshot.path) reason=modifiedDate")
            #endif
            return false
        }

        let context = EditorSelectionContext(
            kind: .text,
            title: snapshot.title.isEmpty ? lightweightContext.title : snapshot.title,
            relativePath: lightweightContext.relativePath,
            body: snapshot.body,
            modifiedDate: lightweightContext.modifiedDate ?? snapshot.modifiedDate,
            mimeType: snapshot.mimeType ?? lightweightContext.mimeType,
            fileSize: lightweightContext.fileSize ?? snapshot.fileSize
        )
        asyncTextContextOverride = context
        activeEditorContext = context
        state.liveCachedTitle = context.title
        state.liveCachedKind = .text
        state.liveCachedTextBody = context.body
        state.liveCachedData = Data(context.body.utf8)
        state.persistedTextSnapshot = makePersistedTextSnapshot(document: document, context: context)
        #if DEBUG
        print("[NVModern][TextSnapshot] hydrate path=\(snapshot.path) bytes=\(snapshot.body.lengthOfBytes(using: .utf8))")
        #endif
        return true
    }

    nonisolated private static func readTextForDetachedContext(from url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        if let unicode = String(data: data, encoding: .unicode) {
            return unicode
        }

        return String(data: data, encoding: .ascii) ?? ""
    }

    private func scheduleWorkspaceTextRefresh(
        loadKey: String,
        document: WorkspaceOpenedDocument,
        relativePath: String,
        loadDescriptor: TextContextLoadDescriptor
    ) {
        let expectedPath = relativePath
        pendingTextContextLoadKey = loadKey
        #if DEBUG
        print("[NVModern][TextLoad] detachedStart key=\(loadKey) tab=\(tabID) fileSize=\(loadDescriptor.fileSize.map(String.init) ?? "nil")")
        #endif
        let detachedLoadTask = Task.detached(priority: .userInitiated) { () -> EditorSelectionContext? in
            let loadStart = ProcessInfo.processInfo.systemUptime
            #if DEBUG
            print("[NVModern][TextLoad] detachedReadStart key=\(loadKey) path=\(loadDescriptor.fileURL.path)")
            #endif
            let body = Self.readTextForDetachedContext(from: loadDescriptor.fileURL)
            let loadDurationMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
            #if DEBUG
            print("[NVModern][TextLoad] detachedReadEnd key=\(loadKey) bytes=\(body.lengthOfBytes(using: .utf8)) durationMs=\(String(format: "%.2f", loadDurationMs))")
            #endif
            return EditorSelectionContext(
                kind: .text,
                title: loadDescriptor.title,
                relativePath: loadDescriptor.relativePath,
                body: body,
                modifiedDate: loadDescriptor.modifiedDate,
                mimeType: loadDescriptor.mimeType,
                fileSize: loadDescriptor.fileSize
            )
        }
        pendingTextContextLoadTask = Task { @MainActor in
            let resolvedContext = await detachedLoadTask.value
            guard !Task.isCancelled else { return }
            guard case .workspaceNote(let openRelativePath)? = displayedDocument,
                  openRelativePath == expectedPath,
                  let resolvedContext else {
                if pendingTextContextLoadKey == loadKey {
                    pendingTextContextLoadTask = nil
                    pendingTextContextLoadKey = nil
                }
                #if DEBUG
                print("[NVModern][TextLoad] abandon key=\(loadKey) tab=\(tabID) displayed=\(displayedDocument.map { String(describing: $0) } ?? "nil") resolved=\(resolvedContext == nil ? "false" : "true")")
                #endif
                return
            }

            asyncTextContextOverride = resolvedContext
            pendingTextContextLoadTask = nil
            pendingTextContextLoadKey = nil
            editorController?.clearContextMarker()
            #if DEBUG
            print("[NVModern][TextLoad] complete key=\(loadKey) tab=\(tabID) bytes=\(resolvedContext.body.lengthOfBytes(using: .utf8))")
            #endif
            if !isPaletteDocumentPreviewActive {
                cacheWorkspaceSnapshotIfNeeded(document: document, context: resolvedContext)
            }
            pushEditorContext()
        }
    }

    private func scheduleAsyncTextContextLoadIfNeeded(for document: WorkspaceOpenedDocument) -> Bool {
        switch document {
        case .workspaceNote(let relativePath):
            let loadKey = "workspace:\(relativePath)"
            if let override = asyncTextContextOverride,
               override.relativePath == relativePath,
               override.kind == .text {
                cancelDocumentResolutionRetry()
                return false
            }

            if let snapshot = state.liveDeletedSnapshot,
               snapshot.relativePath == relativePath {
                return false
            }

            guard let lightweightContext = notesModel.lightweightContextForNote(relativePath: relativePath),
                  lightweightContext.kind == .text else {
                asyncTextContextOverride = nil
                return false
            }

            cancelDocumentResolutionRetry()
            if pendingTextContextLoadTask != nil, pendingTextContextLoadKey == loadKey {
                return true
            }
            guard let loadDescriptor = notesModel.textContextLoadDescriptorForNote(relativePath: relativePath) else {
                asyncTextContextOverride = nil
                return false
            }
            if !isPaletteDocumentPreviewActive,
               applyPersistedTextSnapshotIfValid(
                state.persistedTextSnapshot,
                document: document,
                lightweightContext: lightweightContext
            ) {
                scheduleWorkspaceTextRefresh(
                    loadKey: loadKey,
                    document: document,
                    relativePath: relativePath,
                    loadDescriptor: loadDescriptor
                )
                return false
            }

            asyncTextContextOverride = nil
            let loadingContext = EditorSelectionContext(
                kind: .text,
                title: lightweightContext.title,
                relativePath: lightweightContext.relativePath,
                body: "",
                modifiedDate: lightweightContext.modifiedDate,
                mimeType: lightweightContext.mimeType,
                fileSize: lightweightContext.fileSize
            )
            activeEditorContext = loadingContext
            if !isPaletteDocumentPreviewActive {
                onTabPresentationChange(tabPresentation(for: document, context: loadingContext))
            }

            scheduleWorkspaceTextRefresh(
                loadKey: loadKey,
                document: document,
                relativePath: relativePath,
                loadDescriptor: loadDescriptor
            )
            return true

        case .externalMarkdown(let filePath):
            let loadKey = "external:\(filePath)"
            if let override = asyncTextContextOverride,
               override.relativePath == filePath,
               override.kind == .text {
                cancelDocumentResolutionRetry()
                return false
            }

            let url = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                asyncTextContextOverride = nil
                return false
            }
            guard Self.externalPreviewDescriptor(for: url).kind == .text else {
                asyncTextContextOverride = nil
                return false
            }

            cancelDocumentResolutionRetry()
            asyncTextContextOverride = nil
            if pendingTextContextLoadTask != nil, pendingTextContextLoadKey == loadKey {
                return true
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
            let loadingContext = EditorSelectionContext(
                kind: .text,
                title: url.deletingPathExtension().lastPathComponent,
                relativePath: filePath,
                body: "",
                modifiedDate: nil,
                mimeType: "text/markdown",
                fileSize: fileSize
            )
            activeEditorContext = loadingContext
            if !isPaletteDocumentPreviewActive {
                onTabPresentationChange(tabPresentation(for: document, context: loadingContext))
            }

            pendingTextContextLoadKey = loadKey
            #if DEBUG
            print("[NVModern][TextLoad] detachedStart key=\(loadKey) tab=\(tabID) fileSize=\(fileSize.map(String.init) ?? "nil")")
            #endif
            let detachedLoadTask = Task.detached(priority: .userInitiated) { () -> String in
                let loadStart = ProcessInfo.processInfo.systemUptime
                #if DEBUG
                print("[NVModern][TextLoad] detachedReadStart key=\(loadKey) path=\(url.path)")
                #endif
                let body = Self.readTextForDetachedContext(from: url)
                let loadDurationMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
                #if DEBUG
                print("[NVModern][TextLoad] detachedReadEnd key=\(loadKey) bytes=\(body.lengthOfBytes(using: .utf8)) durationMs=\(String(format: "%.2f", loadDurationMs))")
                #endif
                return body
            }
            pendingTextContextLoadTask = Task { @MainActor in
                let body = await detachedLoadTask.value
                guard !Task.isCancelled else { return }
                guard case .externalMarkdown(let openPath)? = displayedDocument,
                      openPath == filePath else {
                    if pendingTextContextLoadKey == loadKey {
                        pendingTextContextLoadTask = nil
                        pendingTextContextLoadKey = nil
                    }
                    #if DEBUG
                    print("[NVModern][TextLoad] abandon key=\(loadKey) tab=\(tabID) displayed=\(displayedDocument.map { String(describing: $0) } ?? "nil")")
                    #endif
                    return
                }

                asyncTextContextOverride = EditorSelectionContext(
                    kind: .text,
                    title: url.deletingPathExtension().lastPathComponent,
                    relativePath: filePath,
                    body: body,
                    modifiedDate: nil,
                    mimeType: "text/markdown",
                    fileSize: fileSize
                )
                pendingTextContextLoadTask = nil
                pendingTextContextLoadKey = nil
                editorController?.clearContextMarker()
                #if DEBUG
                print("[NVModern][TextLoad] complete key=\(loadKey) tab=\(tabID) bytes=\(body.lengthOfBytes(using: .utf8))")
                #endif
                pushEditorContext()
            }
            return true

        case .diff(let left, let right):
            let loadKey = "diff:\(left.path)\u{1f}\(right.path)"
            if let override = asyncTextContextOverride,
               override.relativePath == document.editorPath,
               override.kind == .diff,
               override.diff != nil {
                cancelDocumentResolutionRetry()
                return false
            }

            cancelDocumentResolutionRetry()
            if pendingTextContextLoadTask != nil, pendingTextContextLoadKey == loadKey {
                return true
            }

            asyncTextContextOverride = nil
            let loadingContext = EditorSelectionContext(
                kind: .diff,
                title: document.tabPresentation.title,
                relativePath: document.editorPath,
                body: "Loading comparison…",
                modifiedDate: nil,
                mimeType: "application/x-nvmodern-diff",
                fileSize: nil
            )
            activeEditorContext = loadingContext
            if !isPaletteDocumentPreviewActive {
                onTabPresentationChange(document.tabPresentation)
            }

            let rootURL = notesModel.runtimeConfig.rootURL
            let leftURL = left.fileURL(rootURL: rootURL)
            let rightURL = right.fileURL(rootURL: rootURL)
            pendingTextContextLoadKey = loadKey
            let expectedDocument = document
            let detachedLoadTask = Task.detached(priority: .userInitiated) { () -> EditorSelectionContext in
                let leftBody = Self.readTextForDetachedContext(from: leftURL)
                let rightBody = Self.readTextForDetachedContext(from: rightURL)
                return EditorSelectionContext(
                    kind: .diff,
                    title: expectedDocument.tabPresentation.title,
                    relativePath: expectedDocument.editorPath,
                    body: "",
                    modifiedDate: nil,
                    mimeType: "application/x-nvmodern-diff",
                    fileSize: Int64(leftBody.lengthOfBytes(using: .utf8) + rightBody.lengthOfBytes(using: .utf8)),
                    diff: EditorDiffContext(
                        left: EditorDiffFileContext(path: left.path, title: left.displayName, body: leftBody),
                        right: EditorDiffFileContext(path: right.path, title: right.displayName, body: rightBody)
                    )
                )
            }
            pendingTextContextLoadTask = Task { @MainActor in
                let resolvedContext = await detachedLoadTask.value
                guard !Task.isCancelled else { return }
                guard displayedDocument == expectedDocument else {
                    if pendingTextContextLoadKey == loadKey {
                        pendingTextContextLoadTask = nil
                        pendingTextContextLoadKey = nil
                    }
                    return
                }

                asyncTextContextOverride = resolvedContext
                pendingTextContextLoadTask = nil
                pendingTextContextLoadKey = nil
                previewController?.clearContextMarker()
                pushEditorContext()
            }
            return true

        case .clipboardMarkdown:
            return false
        }
    }

    private func editorContext(for document: WorkspaceOpenedDocument) -> EditorSelectionContext? {
        switch document {
        case .workspaceNote(let relativePath):
            if let asyncTextContextOverride,
               asyncTextContextOverride.relativePath == relativePath,
               asyncTextContextOverride.kind == .text {
                return asyncTextContextOverride
            }

            if let context = notesModel.contextForNote(relativePath: relativePath) {
                return context
            }
            if let snapshot = state.liveDeletedSnapshot,
               snapshot.relativePath == relativePath {
                switch snapshot.kind {
                case .text:
                    return EditorSelectionContext(
                        kind: .text,
                        title: snapshot.title,
                        relativePath: snapshot.relativePath,
                        body: snapshot.textBody ?? "",
                        modifiedDate: nil,
                        mimeType: snapshot.mimeType,
                        fileSize: snapshot.data.map { Int64($0.count) } ?? snapshot.textBody.map { Int64($0.lengthOfBytes(using: .utf8)) }
                    )
                case .csv:
                    return EditorSelectionContext(
                        kind: .csv,
                        title: snapshot.title,
                        relativePath: snapshot.relativePath,
                        body: "",
                        modifiedDate: nil,
                        mimeType: snapshot.mimeType ?? "text/csv",
                        fileSize: snapshot.data.map { Int64($0.count) }
                    )
                case .canvas:
                    return EditorSelectionContext(
                        kind: .canvas,
                        title: snapshot.title,
                        relativePath: snapshot.relativePath,
                        body: "",
                        modifiedDate: nil,
                        mimeType: snapshot.mimeType ?? "application/vnd.excalidraw+json",
                        fileSize: snapshot.data.map { Int64($0.count) }
                    )
                case .pdf:
                    return EditorSelectionContext(
                        kind: .pdf,
                        title: snapshot.title,
                        relativePath: snapshot.relativePath,
                        body: "",
                        modifiedDate: nil,
                        mimeType: snapshot.mimeType ?? "application/pdf",
                        fileSize: snapshot.data.map { Int64($0.count) }
                    )
                case .image:
                    return EditorSelectionContext(
                        kind: .image,
                        title: snapshot.title,
                        relativePath: snapshot.relativePath,
                        body: "",
                        modifiedDate: nil,
                        mimeType: snapshot.mimeType,
                        fileSize: snapshot.data.map { Int64($0.count) }
                    )
                case .html:
                    return EditorSelectionContext(
                        kind: .html,
                        title: snapshot.title,
                        relativePath: snapshot.relativePath,
                        body: "",
                        modifiedDate: nil,
                        mimeType: snapshot.mimeType ?? "text/html",
                        fileSize: snapshot.data.map { Int64($0.count) }
                    )
                case .epub:
                    return EditorSelectionContext(
                        kind: .epub,
                        title: snapshot.title,
                        relativePath: snapshot.relativePath,
                        body: "",
                        modifiedDate: nil,
                        mimeType: snapshot.mimeType ?? "application/epub+zip",
                        fileSize: snapshot.data.map { Int64($0.count) }
                    )
                case .unsupported:
                    return EditorSelectionContext(
                        kind: .unsupported,
                        title: snapshot.title,
                        relativePath: snapshot.relativePath,
                        body: "Preview unavailable for this file type yet.",
                        modifiedDate: nil,
                        mimeType: snapshot.mimeType,
                        fileSize: snapshot.data.map { Int64($0.count) }
                    )
                case .folder, .diff:
                    return nil
                }
            }
            return nil

        case .externalMarkdown(let filePath):
            if let asyncTextContextOverride,
               asyncTextContextOverride.relativePath == filePath,
               asyncTextContextOverride.kind == .text {
                return asyncTextContextOverride
            }

            let url = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
            let preview = Self.externalPreviewDescriptor(for: url)
            let body = preview.kind == .text
                ? (loadTextFile(at: url) ?? "")
                : (preview.kind == .unsupported ? "Preview unavailable for this file type yet." : "")
            return EditorSelectionContext(
                kind: preview.kind,
                title: url.deletingPathExtension().lastPathComponent,
                relativePath: url.path,
                body: body,
                modifiedDate: nil,
                mimeType: preview.mimeType,
                fileSize: fileSize
            )

        case .clipboardMarkdown(let title, let body):
            return EditorSelectionContext(
                kind: .text,
                title: title,
                relativePath: document.editorPath,
                body: body,
                modifiedDate: nil,
                mimeType: "text/markdown",
                fileSize: Int64(body.lengthOfBytes(using: .utf8))
            )


        case .diff:
            if let asyncTextContextOverride,
               asyncTextContextOverride.relativePath == document.editorPath,
               asyncTextContextOverride.kind == .diff {
                return asyncTextContextOverride
            }
            return nil
        }
    }

    private func tabPresentation(for document: WorkspaceOpenedDocument, context: EditorSelectionContext) -> WorkspaceTabPresentation {
        switch document {
        case .workspaceNote:
            let fileName = URL(fileURLWithPath: context.relativePath).lastPathComponent
            let icon: String

            switch context.kind {
            case .pdf:
                icon = "doc.richtext"
            case .csv:
                icon = "tablecells"
            case .canvas:
                icon = "scribble.variable"
            case .image:
                icon = "photo"
            case .html:
                icon = "globe"
            case .epub:
                icon = "book.closed"
            case .diff:
                icon = "arrow.left.arrow.right"
            case .text, .folder:
                icon = "doc.text"
            case .unsupported:
                icon = "doc"
            }

            return WorkspaceTabPresentation(
                title: fileName.isEmpty ? context.title : fileName,
                icon: icon
            )
        case .externalMarkdown, .clipboardMarkdown, .diff:
            return document.tabPresentation
        }
    }

    private func isDocumentEditable(_ document: WorkspaceOpenedDocument, context: EditorSelectionContext) -> Bool {
        guard !isPaletteDocumentPreviewActive else { return false }

        switch document {
        case .workspaceNote, .externalMarkdown:
            return context.kind.isEditable
        case .clipboardMarkdown, .diff:
            return false
        }
    }

    private func loadTextFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        if let unicode = String(data: data, encoding: .unicode) {
            return unicode
        }

        return String(data: data, encoding: .ascii)
    }

    private static func externalPreviewDescriptor(for url: URL) -> (kind: EditorSelectionContext.Kind, mimeType: String?) {
        let ext = url.pathExtension.lowercased()

        if ext == "csv" {
            return (.csv, "text/csv")
        }

        if ext == "excalidraw" {
            return (.canvas, "application/vnd.excalidraw+json")
        }

        if ext == "pdf" {
            return (.pdf, "application/pdf")
        }

        if ext == "epub" {
            return (.epub, "application/epub+zip")
        }

        if ext == "html" {
            return (.html, "text/html")
        }

        if isExternalTextFile(url) {
            let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "text/plain"
            return (.text, mimeType)
        }

        if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "svg"].contains(ext) {
            return (.image, UTType(filenameExtension: ext)?.preferredMIMEType ?? fallbackExternalMimeType(forExtension: ext))
        }

        if let utType = UTType(filenameExtension: ext) {
            if utType.conforms(to: .pdf) {
                return (.pdf, utType.preferredMIMEType ?? "application/pdf")
            }

            if utType.conforms(to: .image) {
                return (.image, utType.preferredMIMEType ?? fallbackExternalMimeType(forExtension: ext))
            }

            if utType.conforms(to: .commaSeparatedText) {
                return (.csv, utType.preferredMIMEType ?? "text/csv")
            }

            if utType.conforms(to: .text) {
                return (.text, utType.preferredMIMEType ?? "text/plain")
            }
        }

        return (.unsupported, fallbackExternalMimeType(forExtension: ext))
    }

    private static func isExternalTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty {
            return true
        }
        if ["md", "markdown", "txt", "text", "mdown", "mkd", "org", "outline", "json", "toml", "yaml", "yml", "xml", "css", "js", "ts", "tsx", "jsx", "swift", "py", "rb", "go", "rs", "c", "h", "m", "mm", "cpp", "hpp", "java", "sh", "zsh", "bash"].contains(ext) {
            return true
        }
        return UTType(filenameExtension: ext)?.conforms(to: .text) == true
    }

    private static func fallbackExternalMimeType(forExtension ext: String) -> String {
        switch ext {
        case "csv":
            return "text/csv"
        case "pdf":
            return "application/pdf"
        case "html":
            return "text/html"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "bmp":
            return "image/bmp"
        case "tif", "tiff":
            return "image/tiff"
        case "svg":
            return "image/svg+xml"
        default:
            return "application/octet-stream"
        }
    }

    private func previewURLString(for relativePath: String) -> String? {
        guard !relativePath.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = PreviewFileSchemeHandler.scheme
        components.host = "preview"
        components.queryItems = [URLQueryItem(name: "path", value: relativePath)]
        return components.string
    }

    private func markdownScrollRatio(for document: WorkspaceOpenedDocument, context: EditorSelectionContext) -> Double? {
        guard case .workspaceNote(let relativePath) = document else {
            return nil
        }

        let lowercasedPath = context.relativePath.lowercased()
        let isMarkdown = [".md", ".markdown", ".mdown", ".mkd"].contains { lowercasedPath.hasSuffix($0) }
        guard isMarkdown else { return nil }

        return WorkspaceSessionStore.shared.documentScrollRatio(
            rootURL: notesModel.runtimeConfig.rootURL,
            relativePath: relativePath,
            kind: .markdown
        )
    }

    private func folderChain(for notePath: String) -> [String] {
        var chain: [String] = []
        let components = notePath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return rootedChain([]) }

        var current = ""
        for component in components.dropLast() {
            current = current.isEmpty ? component : "\(current)/\(component)"
            chain.append(current)
        }

        return rootedChain(chain)
    }

    private func folderChain(forFolderPath folderPath: String) -> [String] {
        var chain: [String] = []
        let components = folderPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return rootedChain([]) }

        var current = ""
        for component in components {
            current = current.isEmpty ? component : "\(current)/\(component)"
            chain.append(current)
        }

        return rootedChain(chain)
    }

    // MARK: — launchpad root column

    /// Chain element 0, i.e. which synthetic root row is selected.
    private var currentRootSourcePath: String {
        LaunchpadRootColumn.normalized(state.selectedFolderChain)[0]
    }

    private var currentRootSource: LaunchpadRootSource {
        LaunchpadRootColumn.source(for: currentRootSourcePath)
    }

    /// Prefixes a real folder chain with the active synthetic root, dropping the
    /// entries that the root already stands for.
    ///
    /// Under a capture source, column 1 already lists that folder's children, so
    /// the folder itself must not also appear as a chain entry — otherwise the
    /// same column would be produced twice.
    private func rootedChain(_ realChain: [String]) -> [String] {
        let head = currentRootSourcePath
        guard let rootFolder = LaunchpadRootColumn.rootFolderPath(
            for: LaunchpadRootColumn.source(for: head)
        ) else {
            return [head]
        }

        guard !rootFolder.isEmpty else { return [head] + realChain }
        return [head] + realChain.filter { $0.hasPrefix(rootFolder + "/") }
    }

    /// The real folder that new notes and folders should be created in.
    ///
    /// `selectedFolderChain.last` is no longer safe for this: it is the synthetic
    /// root path whenever nothing below the root column is selected.
    private var currentMillerFolderPath: String? {
        if let last = state.selectedFolderChain.last,
           !LaunchpadRootColumn.isSynthetic(last) {
            return last
        }

        guard let rootFolder = LaunchpadRootColumn.rootFolderPath(
            for: currentRootSource
        ), !rootFolder.isEmpty else {
            return nil
        }
        return rootFolder
    }

    /// Recent notes as browser rows, for the Recent root row's column.
    private var launchpadRecentMillerItems: [MillerItem] {
        launchpadRecents.map { item in
            MillerItem(
                relativePath: item.relativePath,
                name: (item.relativePath as NSString).lastPathComponent,
                kind: .note,
                modifiedDate: nil
            )
        }
    }
}

private struct ContextRibbonButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.space2) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.TextStyle.secondary)
                Text(label)
                    .font(DesignTokens.Typography.secondary)
                    .foregroundStyle(DesignTokens.TextStyle.secondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.space3)
            .padding(.vertical, DesignTokens.Spacing.space1)
            .background(
                Capsule()
                    .fill(isHovering ? DesignTokens.Surface.overlay : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(DesignTokens.TextStyle.tertiary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
    }
}

private struct ContextRibbonDocumentButton: View {
    let title: String
    let relativePath: String
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(isCurrent ? DesignTokens.Typography.secondary.weight(.semibold) : DesignTokens.Typography.secondary)
                .foregroundStyle(isCurrent ? Color.white : DesignTokens.TextStyle.primary)
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.Spacing.space3)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(relativePath)
    }

    private var backgroundColor: Color {
        if isCurrent { return DesignTokens.Surface.activeSelection }
        if isHovering { return DesignTokens.Surface.overlay }
        return Color.clear
    }
}

private struct FocusRegionBridgeView: NSViewRepresentable {
    var onResolve: (_ focusAnchorView: NSView, _ regionView: NSView) -> Void

    func makeNSView(context: Context) -> FocusRegionResponderView {
        let view = FocusRegionResponderView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view, view)
        }
        return view
    }

    func updateNSView(_ nsView: FocusRegionResponderView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView, nsView)
        }
    }
}

private final class FocusRegionResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct PDFOutlinePopoverView: View {
    let items: [PDFOutlineItem]
    var onSelectPage: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    PDFOutlinePopoverRow(item: item, depth: 0, onSelectPage: onSelectPage)
                }
            }
            .padding(8)
        }
        .frame(minWidth: 260, idealWidth: 320, maxWidth: 380, minHeight: 180, idealHeight: 300, maxHeight: 420)
    }
}

private struct PDFOutlinePopoverRow: View {
    let item: PDFOutlineItem
    let depth: Int
    var onSelectPage: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if let pageIndex = item.pageIndex {
                    onSelectPage(pageIndex)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(item.title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 8)

                    if let pageLabel = item.pageLabel {
                        Text(pageLabel)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(depth) * 14)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.pageIndex == nil)

            ForEach(item.children) { child in
                PDFOutlinePopoverRow(item: child, depth: depth + 1, onSelectPage: onSelectPage)
            }
        }
    }
}

private struct PDFArrowKeyMonitor: NSViewRepresentable {
    var isActive: Bool
    var onPrevious: () -> Void
    var onNext: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive, onPrevious: onPrevious, onNext: onNext)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostWindow = view.window
        context.coordinator.installMonitorIfNeeded()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostWindow = nsView.window
        context.coordinator.isActive = isActive
        context.coordinator.onPrevious = onPrevious
        context.coordinator.onNext = onNext
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var hostWindow: NSWindow?
        var isActive: Bool
        var onPrevious: () -> Void
        var onNext: () -> Void
        private var monitor: Any?

        init(isActive: Bool, onPrevious: @escaping () -> Void, onNext: @escaping () -> Void) {
            self.isActive = isActive
            self.onPrevious = onPrevious
            self.onNext = onNext
        }

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard isActive else { return event }
                guard WindowEventRouting.shouldHandleLocalEvent(event, in: hostWindow) else { return event }

                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let meaningfulFlags = flags.subtracting([.function, .numericPad])
                guard meaningfulFlags.isEmpty else { return event }

                switch event.keyCode {
                case 123, 126:
                    onPrevious()
                    return nil
                case 124, 125:
                    onNext()
                    return nil
                default:
                    return event
                }
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}


private struct NativePreviewZoomKeyMonitor: NSViewRepresentable {
    var isActive: Bool
    var onZoomIn: () -> Void
    var onZoomOut: () -> Void
    var onReset: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive, onZoomIn: onZoomIn, onZoomOut: onZoomOut, onReset: onReset)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostWindow = view.window
        context.coordinator.installMonitorIfNeeded()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostWindow = nsView.window
        context.coordinator.isActive = isActive
        context.coordinator.onZoomIn = onZoomIn
        context.coordinator.onZoomOut = onZoomOut
        context.coordinator.onReset = onReset
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var hostWindow: NSWindow?
        var isActive: Bool
        var onZoomIn: () -> Void
        var onZoomOut: () -> Void
        var onReset: () -> Void
        private var monitor: Any?

        init(isActive: Bool, onZoomIn: @escaping () -> Void, onZoomOut: @escaping () -> Void, onReset: @escaping () -> Void) {
            self.isActive = isActive
            self.onZoomIn = onZoomIn
            self.onZoomOut = onZoomOut
            self.onReset = onReset
        }

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard isActive else { return event }
                guard WindowEventRouting.shouldHandleLocalEvent(event, in: hostWindow) else { return event }

                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.contains(.command),
                      !flags.contains(.option),
                      !flags.contains(.control),
                      !flags.contains(.function)
                else {
                    return event
                }

                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                switch key {
                case "=", "+":
                    onZoomIn()
                    return nil
                case "-", "_":
                    onZoomOut()
                    return nil
                case "0":
                    onReset()
                    return nil
                default:
                    switch event.keyCode {
                    case 69: // numpad +
                        onZoomIn()
                        return nil
                    case 78: // numpad -
                        onZoomOut()
                        return nil
                    case 82: // numpad 0
                        onReset()
                        return nil
                    default:
                        return event
                    }
                }
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

private struct PaletteDocumentPreviewOverlay: View {
    let title: String
    let accentColor: Color

    var body: some View {
        ZStack(alignment: .top) {
            accentColor.opacity(0.055)

            HStack(spacing: DesignTokens.Spacing.space3) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 11, weight: .semibold))

                Text("Preview")
                    .font(DesignTokens.Typography.bodySemibold)

                Text(title)
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1)
                    .foregroundStyle(DesignTokens.TextStyle.secondary)

                Divider()
                    .frame(height: 12)

                Text("⇥ hide")
                    .font(DesignTokens.Typography.captionMono)
                    .foregroundStyle(DesignTokens.TextStyle.secondary)
            }
            .foregroundStyle(accentColor)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(accentColor.opacity(0.42), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
            .padding(.top, 12)
            .padding(.horizontal, 16)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct EmptyPaneView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No Open Tabs")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
