import AppKit

final class CSVGridNativePreviewContainerView: NSView, NSTextFieldDelegate, NSSearchFieldDelegate {
    var sourceRelativePath: String?
    var onDocumentChange: ((CSVGridSaveSnapshot) -> Void)?
    var onOpenWikilink: ((String) -> Void)?
    var onOpenWikilinkInNewTab: ((String) -> Void)?
    var wikilinkSuggestionsProvider: ((String, String?) -> [WikilinkAutocompleteSuggestion])?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var undoManager: UndoManager? {
        gridUndoManager
    }

    private let headerHeight: CGFloat = 28
    private let rowHeight: CGFloat = 28
    private let minimumColumnWidth: CGFloat = 110
    private let maximumColumnWidth: CGFloat = 320
    private let minimumVisibleRows: Int = 500
    private let minimumVisibleColumns: Int = 26
    private let extraVisibleRows: Int = 200
    private let extraVisibleColumns: Int = 20

    private let formulaBarHeight: CGFloat = 44
    private let isTopChromeEnabled = true
    private let isFormulaFieldEnabled = true
    private let isDebugLoggingEnabled = false
    private let topChromeView = CSVGridTopChromeView()
    private let topChromeCornerLabel = CSVGridPassthroughLabel(string: "#")
    private let topChromeActiveCellPillView = CSVGridPassthroughView()
    private let topChromeActiveCellPillLabel = CSVGridPassthroughLabel(string: "")
    private let topChromeFormulaSymbolLabel = CSVGridPassthroughLabel(string: "ƒx")
    private let topChromeFormulaResultLabel = CSVGridPassthroughLabel(string: "")
    private var topChromeHeaderLabels: [Int: CSVGridPassthroughLabel] = [:]
    private let filterField = NSSearchField(string: "")
    private let columnInsertionIndicatorView = NSView()
    private let rowInsertionIndicatorView = NSView()
    private let rowHeaderView = CSVGridRowHeaderView()
    private let scrollView = NSScrollView()
    private let canvasView = CSVGridBodyCanvasView()
    private let editorView = CSVGridCellEditorView()
    private let formulaField = NSTextField(string: "")
    private let completionView = CSVGridCompletionOverlayView()
    private let progressIndicator = NSProgressIndicator()
    private let placeholderField = NSTextField(wrappingLabelWithString: "")

    private var rowHeaderWidthConstraint: NSLayoutConstraint?
    private var topChromeHeightConstraint: NSLayoutConstraint?

    private var scrollBoundsObserver: NSObjectProtocol?
    private var document = CSVGridDocument(
        mode: .plainCSV,
        columns: [],
        rows: [],
        encoding: .utf8,
        newlineStyle: .lf,
        hasUTF8BOM: false,
        frontmatterStyle: nil,
        preservedFrontmatterLines: [],
        statusColors: [:]
    )
    private var columnWidths: [CGFloat] = []
    private var columnOffsets: [CGFloat] = []
    private var selection: CSVNativeGridSelection?
    private var dragAnchor: CSVNativeGridCellAddress?
    private var editingCell: CSVNativeGridCellAddress?
    private var formulaBarTargetCell: CSVNativeGridCellAddress?
    private var contextMenuCell: CSVNativeGridCellAddress?
    private var contextMenuLinkTarget: String?
    private var contextMenuColumn: Int?
    private var contextMenuRow: Int?
    private var pendingDeleteColumnIndex: Int?
    private var pendingDeleteRowIndex: Int?
    private var headerDragState: CSVGridHeaderDragState?
    private let gridUndoManager = UndoManager()
    private var isApplyingLoadedDocument = false
    private var isLoadingDocument = false
    private var currentErrorMessage: String?
    private var suppressFormulaBarCommitOnEndEditing = false
    private var isUpdatingFormulaField = false
    private var filteredDocumentRowIndices: [Int] = []
    private var formulaComputationCache: [CSVNativeGridCellAddress: CSVGridFormulaComputedValue] = [:]
    private var completionContext: CSVGridCompletionContext?
    private var debugBodyDrawLogCount = 0
    private var debugRowHeaderDrawLogCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
        }
    }

    override func layout() {
        super.layout()
        updateCanvasFrame()
        updateTopChromeFormulaSubviews()
        updateTopChromeStaticHeaderSubviews()
        updateEditorFrameIfNeeded()
        updateCompletionFrameIfNeeded()
        updateFilterFieldFrame()
        updateFormulaFieldFrame()
        updateDragIndicators()
        invalidateCursorRects()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
        topChromeView.needsDisplay = true
        rowHeaderView.needsDisplay = true
    }

    func setLoading(fileURL: URL) {
        isLoadingDocument = true
        currentErrorMessage = nil
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        let fileName = fileURL.lastPathComponent.isEmpty ? fileURL.path : fileURL.lastPathComponent
        placeholderField.stringValue = "Loading \(fileName)…"
        placeholderField.isHidden = false
        updateChromeVisibility()
    }

    func setError(message: String) {
        isLoadingDocument = false
        currentErrorMessage = message
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        placeholderField.stringValue = message
        placeholderField.isHidden = false
        updateChromeVisibility()
    }

    func focusContent() {
        guard let window else { return }

        if window.firstResponder === editorView.textView {
            return
        }

        if editingCell != nil {
            window.makeFirstResponder(editorView.textView)
            return
        }

        if formulaField.currentEditor() != nil || filterField.currentEditor() != nil {
            return
        }

        window.makeFirstResponder(canvasView)
    }

    func apply(document: CSVGridDocument) {
        isApplyingLoadedDocument = true
        isLoadingDocument = false
        currentErrorMessage = nil
        debugBodyDrawLogCount = 0
        debugRowHeaderDrawLogCount = 0
        endEditing(commit: false)
        resetFilterState()
        self.document = document
        formulaComputationCache.removeAll()
        completionContext = nil
        rebuildColumnMetrics()
        debugLog("apply(document:) after rebuildColumnMetrics")
        let firstCell = CSVNativeGridCellAddress(row: 0, column: 0)
        selection = CSVNativeGridSelection(anchor: firstCell, focus: firstCell)
        dragAnchor = selection?.anchor
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        placeholderField.stringValue = ""
        placeholderField.isHidden = true
        updateHeaderMetrics()
        updateCanvasFrame()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateChromeVisibility()
        invalidateGridDisplay()
        updateFormulaBar()
        debugLog("apply(document:) complete")
        isApplyingLoadedDocument = false
    }

    private var isFilterActive: Bool {
        !filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate var displayedRowCount: Int {
        if isFilterActive {
            return filteredDocumentRowIndices.count
        }
        return max(minimumVisibleRows, document.rowCount + extraVisibleRows)
    }

    fileprivate var displayedColumnCount: Int {
        max(minimumVisibleColumns, document.columnCount + extraVisibleColumns)
    }

    fileprivate var totalColumnWidth: CGFloat {
        columnWidths.reduce(0, +)
    }

    fileprivate func cellRect(for address: CSVNativeGridCellAddress) -> NSRect {
        guard columnOffsets.indices.contains(address.column), columnWidths.indices.contains(address.column) else {
            return .zero
        }
        return NSRect(
            x: columnOffsets[address.column],
            y: CGFloat(address.row) * rowHeight,
            width: columnWidths[address.column],
            height: rowHeight
        )
    }

    fileprivate func visibleColumnRange(in rect: NSRect) -> ClosedRange<Int>? {
        guard !columnWidths.isEmpty else { return nil }
        let lower = max(0, indexOfColumn(atX: rect.minX))
        let upper = max(0, indexOfColumn(atX: max(rect.minX, rect.maxX - 1)))
        let overscannedLower = max(0, lower - 1)
        let overscannedUpper = min(displayedColumnCount - 1, upper + 1)
        return overscannedLower...overscannedUpper
    }

    fileprivate func visibleRowRange(in rect: NSRect) -> ClosedRange<Int>? {
        guard displayedRowCount > 0 else { return nil }
        let lower = max(0, Int(floor(rect.minY / rowHeight)) - 2)
        let upper = min(displayedRowCount - 1, Int(floor(max(rect.minY, rect.maxY - 1) / rowHeight)) + 2)
        guard lower <= upper else { return nil }
        return lower...upper
    }

    fileprivate func selectionRect() -> NSRect? {
        guard let selection,
              let topLeft = clampedCellAddress(selection.topLeft),
              let bottomRight = clampedCellAddress(selection.bottomRight) else {
            return nil
        }
        return cellRect(for: topLeft).union(cellRect(for: bottomRight)).insetBy(dx: 1, dy: 1)
    }

    fileprivate func activeCellRect() -> NSRect? {
        guard let activeCell = activeCell else { return nil }
        return cellRect(for: activeCell).insetBy(dx: 1, dy: 1)
    }

    fileprivate var activeCell: CSVNativeGridCellAddress? {
        clampedCellAddress(selection?.focus)
    }

    fileprivate func isCellSelected(_ address: CSVNativeGridCellAddress) -> Bool {
        selection?.contains(address) ?? false
    }

    fileprivate func display(for address: CSVNativeGridCellAddress) -> CSVNativeGridCellDisplay {
        let rawValue = documentValue(atDisplayRow: address.row, column: address.column)
        let computed: String
        switch computedValue(for: address) {
        case .evaluating:
            return .text("…")
        case .value(let value):
            computed = value
        case .error(let message):
            return .text("⚠︎ \(message)")
        }

        let format = document.columns.indices.contains(address.column) ? document.columns[address.column].format?.lowercased() : nil

        if format == "status" {
            return .status(title: computed.isEmpty ? "—" : computed, color: statusColor(for: computed))
        }

        if format == "tags" {
            let tags = parseTags(from: computed)
            return .tags(tags.isEmpty ? ["—"] : tags)
        }

        if let target = wikilinkTarget(from: computed) {
            return .link(title: displayTitle(forWikilinkTarget: target), target: target)
        }

        return .text(rawValue == computed ? rawValue : computed)
    }

    fileprivate func headerTitle(forColumn column: Int) -> String {
        if document.columns.indices.contains(column) {
            let title = document.columns[column].title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        return spreadsheetColumnLabel(for: column)
    }

    fileprivate func rowLabel(for row: Int) -> String {
        if let documentRow = documentRowIndex(forDisplayRow: row) {
            return "\(documentRow + 1)"
        }
        return "\(row + 1)"
    }

    fileprivate func spreadsheetColumnLabel(for index: Int) -> String {
        var index = index
        var result = ""
        repeat {
            result = String(UnicodeScalar(65 + (index % 26))!) + result
            index = index / 26 - 1
        } while index >= 0
        return result
    }

    fileprivate func scrollOrigin() -> CGPoint {
        scrollView.contentView.bounds.origin
    }

    private func debugLog(_ event: String) {
        guard isDebugLoggingEnabled else { return }
        let path = sourceRelativePath ?? "<external>"
        let filter = filterField.stringValue.replacingOccurrences(of: "\n", with: "\\n")
        let selectionSummary: String
        if let selection {
            selectionSummary = "anchor=(\(selection.anchor.row),\(selection.anchor.column)) focus=(\(selection.focus.row),\(selection.focus.column))"
        } else {
            selectionSummary = "nil"
        }
        print("[NVModern][CSVGridDebug] \(event) path=\(path) documentRows=\(document.rowCount) documentCols=\(document.columnCount) displayedRows=\(displayedRowCount) displayedCols=\(displayedColumnCount) filter='\(filter)' filteredRows=\(filteredDocumentRowIndices.count) selection=\(selectionSummary) bounds=\(NSStringFromRect(bounds)) scrollBounds=\(NSStringFromRect(scrollView.contentView.bounds)) canvasFrame=\(NSStringFromRect(canvasView.frame)) topHidden=\(topChromeView.isHidden) scrollHidden=\(scrollView.isHidden)")
    }

    private func documentRowIndex(forDisplayRow row: Int) -> Int? {
        guard row >= 0 else { return nil }
        if isFilterActive {
            guard filteredDocumentRowIndices.indices.contains(row) else { return nil }
            return filteredDocumentRowIndices[row]
        }
        return row
    }

    private func displayRowIndex(forDocumentRow row: Int) -> Int? {
        guard row >= 0 else { return nil }
        if isFilterActive {
            return filteredDocumentRowIndices.firstIndex(of: row)
        }
        return row
    }

    private func documentValue(atDisplayRow row: Int, column: Int) -> String {
        guard let documentRow = documentRowIndex(forDisplayRow: row) else { return "" }
        return document.value(atDisplayRow: documentRow, column: column)
    }

    private func setDocumentValue(_ value: String, atDisplayRow row: Int, column: Int) {
        if let documentRow = documentRowIndex(forDisplayRow: row) {
            document.setValue(value, atDisplayRow: documentRow, column: column)
        } else if !isFilterActive {
            document.setValue(value, atDisplayRow: row, column: column)
        }
    }

    private func resetFilterState() {
        if let editor = filterField.currentEditor() as? NSTextView {
            editor.string = ""
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        }
        filterField.abortEditing()
        filterField.stringValue = ""
        filteredDocumentRowIndices = []
        debugLog("resetFilterState")
    }

    private func rebuildFilteredRows() {
        guard isFilterActive else {
            filteredDocumentRowIndices = []
            debugLog("rebuildFilteredRows inactive filter")
            return
        }

        let query = filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filteredDocumentRowIndices = document.rows.enumerated().compactMap { index, row in
            let matches = row.contains { $0.lowercased().contains(query) }
            return matches ? index : nil
        }
        debugLog("rebuildFilteredRows active filter query='\(query)'")
    }

    private func reconcileSelectionAfterFilterOrDataChange(preferredDocumentRow: Int? = nil, preferredColumn: Int? = nil) {
        let documentRow = preferredDocumentRow ?? activeCell.flatMap { documentRowIndex(forDisplayRow: $0.row) }
        let column = min(max(0, preferredColumn ?? activeCell?.column ?? 0), max(0, displayedColumnCount - 1))

        if displayedRowCount <= 0 || displayedColumnCount <= 0 {
            selection = nil
            dragAnchor = nil
            editingCell = nil
            return
        }

        if let documentRow,
           let displayRow = displayRowIndex(forDocumentRow: documentRow) {
            let cell = CSVNativeGridCellAddress(row: displayRow, column: column)
            selection = CSVNativeGridSelection(anchor: cell, focus: cell)
            dragAnchor = cell
            if let editingCell {
                let editingDocumentRow = documentRowIndex(forDisplayRow: editingCell.row) ?? editingCell.row
                if let editingDisplayRow = displayRowIndex(forDocumentRow: editingDocumentRow) {
                    self.editingCell = CSVNativeGridCellAddress(row: editingDisplayRow, column: editingCell.column)
                } else {
                    self.editingCell = nil
                }
            }
            return
        }

        let firstCell = CSVNativeGridCellAddress(row: 0, column: column)
        selection = CSVNativeGridSelection(anchor: firstCell, focus: firstCell)
        dragAnchor = firstCell
        editingCell = nil
    }

    private func applyFilter() {
        debugLog("applyFilter begin")
        endEditing(commit: true)
        let preferredDocumentRow = activeCell.flatMap { documentRowIndex(forDisplayRow: $0.row) }
        let preferredColumn = activeCell?.column
        rebuildFilteredRows()
        reconcileSelectionAfterFilterOrDataChange(preferredDocumentRow: preferredDocumentRow, preferredColumn: preferredColumn)
        formulaComputationCache.removeAll()
        updateHeaderMetrics()
        updateCanvasFrame()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        invalidateGridDisplay()
        updateFormulaBar()
        debugLog("applyFilter complete")
    }

    private func computedValue(for address: CSVNativeGridCellAddress) -> CSVGridFormulaComputedValue {
        if let cached = formulaComputationCache[address] {
            switch cached {
            case .evaluating:
                return .error("Circular formula reference")
            case .value, .error:
                return cached
            }
        }

        let rawValue = documentValue(atDisplayRow: address.row, column: address.column)
        guard let expression = CSVGridFormula.expression(from: rawValue) else {
            let result: CSVGridFormulaComputedValue = .value(rawValue)
            formulaComputationCache[address] = result
            return result
        }

        formulaComputationCache[address] = .evaluating
        let bindings = CSVGridFormula.columnBindings(columns: document.columns)
        let referencedColumns = CSVGridFormula.referencedColumns(in: expression, bindings: bindings)
        var rowObject: [String: Any] = [:]
        var globals: [String: Any] = [:]

        for binding in bindings where referencedColumns.contains(binding.column) {
            if binding.column == address.column {
                let result: CSVGridFormulaComputedValue = .error("Circular formula reference")
                formulaComputationCache[address] = result
                return result
            }

            switch computedValue(for: CSVNativeGridCellAddress(row: address.row, column: binding.column)) {
            case .evaluating:
                let result: CSVGridFormulaComputedValue = .error("Circular formula reference")
                formulaComputationCache[address] = result
                return result
            case .value(let value):
                let primitive = CSVGridFormula.primitive(from: value)
                rowObject[binding.title] = primitive
                globals[binding.alias] = primitive
            case .error(let message):
                let result: CSVGridFormulaComputedValue = .error("\(binding.title): \(message)")
                formulaComputationCache[address] = result
                return result
            }
        }

        do {
            let value = try CSVGridFormulaEngine.evaluate(expression: expression, row: rowObject, globals: globals)
            let result: CSVGridFormulaComputedValue = .value(value)
            formulaComputationCache[address] = result
            return result
        } catch {
            let result: CSVGridFormulaComputedValue = .error(error.localizedDescription)
            formulaComputationCache[address] = result
            return result
        }
    }

    fileprivate func hitTarget(at point: NSPoint) -> CSVNativeGridHitTarget {
        guard displayedColumnCount > 0,
              displayedRowCount > 0,
              point.x >= 0,
              point.y >= 0 else {
            return .background
        }

        let row = Int(floor(point.y / rowHeight))
        guard row >= 0, row < displayedRowCount else {
            return .background
        }

        let column = indexOfColumn(atX: point.x)
        guard column >= 0, column < displayedColumnCount else {
            return .background
        }

        let address = CSVNativeGridCellAddress(row: row, column: column)
        switch display(for: address) {
        case .link(_, let target):
            return .link(address, target)
        default:
            return .cell(address)
        }
    }

    fileprivate func drawBody(dirtyRect: NSRect) {
        if debugBodyDrawLogCount < 6 {
            let rowRangeDescription = visibleRowRange(in: dirtyRect).map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil"
            let columnRangeDescription = visibleColumnRange(in: dirtyRect).map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil"
            debugLog("drawBody dirtyRect=\(NSStringFromRect(dirtyRect)) visibleRows=\(rowRangeDescription) visibleCols=\(columnRangeDescription)")
            debugBodyDrawLogCount += 1
        }

        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        if let selectionRect = selectionRect(), selectionRect.intersects(dirtyRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            selectionRect.fill()

            NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke()
            let path = NSBezierPath(rect: selectionRect)
            path.lineWidth = 1
            path.stroke()
        }

        guard let rowRange = visibleRowRange(in: dirtyRect),
              let columnRange = visibleColumnRange(in: dirtyRect) else {
            drawGridLines(in: dirtyRect, rowRange: nil, columnRange: nil)
            return
        }

        for row in rowRange {
            for column in columnRange {
                let address = CSVNativeGridCellAddress(row: row, column: column)
                drawCell(display(for: address), in: cellRect(for: address), selected: isCellSelected(address))
            }
        }

        drawGridLines(in: dirtyRect, rowRange: rowRange, columnRange: columnRange)

        if editingCell == nil,
           let activeRect = activeCellRect(), activeRect.intersects(dirtyRect) {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: activeRect)
            path.lineWidth = 2
            path.stroke()
        }
    }

    fileprivate func drawRowHeaders(dirtyRect: NSRect) {
        if debugRowHeaderDrawLogCount < 4 {
            let scrollY = scrollOrigin().y
            let visibleRect = NSRect(x: 0, y: scrollY + dirtyRect.minY, width: dirtyRect.width, height: dirtyRect.height)
            let rangeDescription = visibleRowRange(in: visibleRect).map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil"
            debugLog("drawRowHeaders dirtyRect=\(NSStringFromRect(dirtyRect)) visibleRows=\(rangeDescription)")
            debugRowHeaderDrawLogCount += 1
        }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (isDark ? NSColor(calibratedWhite: 0.18, alpha: 1) : NSColor.windowBackgroundColor).setFill()
        dirtyRect.fill()

        guard displayedRowCount > 0 else { return }

        let scrollY = scrollOrigin().y
        let visibleRect = NSRect(x: 0, y: scrollY + dirtyRect.minY, width: dirtyRect.width, height: dirtyRect.height)
        guard let range = visibleRowRange(in: visibleRect) else { return }

        for row in range {
            let rect = NSRect(
                x: 0,
                y: CGFloat(row) * rowHeight - scrollY,
                width: rowHeaderWidth,
                height: rowHeight
            )
            let isSelected = selection?.rowRange.contains(row) ?? false
            drawHeaderCell(title: rowLabel(for: row), in: rect, selected: isSelected, alignment: .right)
        }

        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let rule = NSBezierPath()
        rule.lineWidth = 1
        rule.move(to: NSPoint(x: rowHeaderWidth - 0.5, y: dirtyRect.minY))
        rule.line(to: NSPoint(x: rowHeaderWidth - 0.5, y: dirtyRect.maxY))
        rule.stroke()
    }

    private func drawFormulaChrome(in rect: NSRect, isDark: Bool) {
        let activeLabel = activeCell.map { "\(spreadsheetColumnLabel(for: $0.column))\($0.row + 1)" } ?? "—"
        let (resultText, resultColor) = formulaResultPresentation(isDark: isDark)
        let labelColor = isDark ? NSColor.white : NSColor.controlAccentColor
        let symbolColor = isDark ? NSColor(calibratedWhite: 0.76, alpha: 1) : NSColor.tertiaryLabelColor

        let pillRect = NSRect(x: 10, y: floor(rect.midY - 11), width: 56, height: 22)
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 7, yRadius: 7)
        NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.22 : 0.12).setFill()
        pillPath.fill()
        NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.40 : 0.22).setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()
        drawSimpleText(activeLabel, in: pillRect.insetBy(dx: 8, dy: 3), color: labelColor, font: .monospacedSystemFont(ofSize: 11, weight: .semibold), alignment: .center)

        drawSimpleText("ƒx", in: NSRect(x: 76, y: floor(rect.midY - 8), width: 24, height: 16), color: symbolColor, font: .systemFont(ofSize: 12, weight: .semibold), alignment: .center)

        let resultWidth: CGFloat = min(220, max(40, measuredWidth(for: resultText, font: .systemFont(ofSize: 11)) + 8))
        drawSimpleText(resultText, in: NSRect(x: rect.maxX - resultWidth - 10, y: floor(rect.midY - 8), width: resultWidth, height: 16), color: resultColor, font: .systemFont(ofSize: 11), alignment: .right)
    }

    private func drawHeaderChrome(in rect: NSRect, isDark: Bool) {
        drawHeaderCell(title: "#", in: NSRect(x: 0, y: rect.minY, width: rowHeaderWidth, height: headerHeight), selected: false, alignment: .center)

        let scrollX = scrollOrigin().x
        let visibleRect = NSRect(x: scrollX, y: 0, width: bounds.width - rowHeaderWidth, height: headerHeight)
        guard let range = visibleColumnRange(in: visibleRect) else { return }

        for column in range {
            let cellRect = NSRect(
                x: rowHeaderWidth + columnOffsets[column] - scrollX,
                y: rect.minY,
                width: columnWidths[column],
                height: headerHeight
            )
            let isSelected = selection?.columnRange.contains(column) ?? false
            drawHeaderCell(title: headerTitle(forColumn: column), in: cellRect, selected: isSelected, alignment: .left)
        }
    }

    private func headerColumn(at point: NSPoint) -> Int? {
        guard point.y >= formulaBarHeight,
              point.y <= formulaBarHeight + headerHeight,
              point.x >= rowHeaderWidth,
              displayedColumnCount > 0 else {
            return nil
        }
        let contentX = point.x - rowHeaderWidth + scrollOrigin().x
        let column = indexOfColumn(atX: contentX)
        return (0..<displayedColumnCount).contains(column) ? column : nil
    }

    private func gutterRow(at point: NSPoint) -> Int? {
        guard point.x >= 0, point.x <= rowHeaderWidth, displayedRowCount > 0 else { return nil }
        let contentY = point.y + scrollOrigin().y
        let row = Int(floor(contentY / rowHeight))
        return (0..<displayedRowCount).contains(row) ? row : nil
    }

    private func columnInsertionIndex(for point: NSPoint) -> Int {
        let contentX = max(0, point.x - rowHeaderWidth + scrollOrigin().x)
        for column in 0..<displayedColumnCount {
            let midpoint = columnOffsets[column] + columnWidths[column] / 2
            if contentX < midpoint {
                return column
            }
        }
        return displayedColumnCount
    }

    private func rowInsertionIndex(for point: NSPoint) -> Int {
        let contentY = max(0, point.y + scrollOrigin().y)
        let insertionIndex = Int(floor((contentY + rowHeight / 2) / rowHeight))
        return min(document.rowCount, max(0, insertionIndex))
    }

    private func selectColumn(_ column: Int) {
        guard displayedRowCount > 0, displayedColumnCount > 0 else { return }
        let top = CSVNativeGridCellAddress(row: 0, column: column)
        let bottom = CSVNativeGridCellAddress(row: displayedRowCount - 1, column: column)
        selection = CSVNativeGridSelection(anchor: top, focus: bottom)
        dragAnchor = top
        invalidateGridDisplay()
    }

    private func selectRow(_ row: Int) {
        guard displayedRowCount > 0, displayedColumnCount > 0 else { return }
        let leading = CSVNativeGridCellAddress(row: row, column: 0)
        let trailing = CSVNativeGridCellAddress(row: row, column: displayedColumnCount - 1)
        selection = CSVNativeGridSelection(anchor: leading, focus: trailing)
        dragAnchor = leading
        invalidateGridDisplay()
    }

    private func updateDragIndicators() {
        columnInsertionIndicatorView.isHidden = true
        rowInsertionIndicatorView.isHidden = true

        guard let headerDragState else { return }
        switch headerDragState {
        case .column(_, let insertionIndex):
            let scrollX = scrollOrigin().x
            let contentX: CGFloat
            if insertionIndex <= 0 {
                contentX = 0
            } else if insertionIndex >= displayedColumnCount {
                contentX = totalColumnWidth
            } else {
                contentX = columnOffsets[insertionIndex]
            }
            let x = rowHeaderWidth + contentX - scrollX - 1
            columnInsertionIndicatorView.frame = NSRect(x: x, y: formulaBarHeight, width: 2, height: max(0, bounds.height - formulaBarHeight))
            columnInsertionIndicatorView.isHidden = false
        case .row(_, _, let insertionIndex):
            let scrollY = scrollOrigin().y
            let clampedInsertionIndex = min(max(0, insertionIndex), document.rowCount)
            let contentY = CGFloat(clampedInsertionIndex) * rowHeight
            let y = topChromeHeight + contentY - scrollY - 1
            rowInsertionIndicatorView.frame = NSRect(x: 0, y: y, width: bounds.width, height: 2)
            rowInsertionIndicatorView.isHidden = false
        }
    }

    private func clearHeaderDragState() {
        headerDragState = nil
        updateDragIndicators()
    }

    fileprivate func handleTopChromeMouseDown(event: NSEvent, in view: CSVGridTopChromeView) {
        window?.makeFirstResponder(canvasView)
        let point = view.convert(event.locationInWindow, from: nil)
        guard let column = headerColumn(at: point) else {
            clearHeaderDragState()
            return
        }
        commitPendingEditIfNeeded()
        selectColumn(column)
        headerDragState = .column(sourceColumn: column, insertionIndex: column)
        updateDragIndicators()
    }

    fileprivate func handleTopChromeMouseDragged(event: NSEvent, in view: CSVGridTopChromeView) {
        guard case .column(let sourceColumn, _) = headerDragState else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        headerDragState = .column(sourceColumn: sourceColumn, insertionIndex: columnInsertionIndex(for: point))
        updateDragIndicators()
    }

    fileprivate func handleTopChromeMouseUp(event: NSEvent, in view: CSVGridTopChromeView) {
        defer { clearHeaderDragState() }
        guard case .column(let sourceColumn, let insertionIndex) = headerDragState else { return }
        performMoveColumn(from: sourceColumn, to: insertionIndex)
    }

    fileprivate func topChromeMenu(for event: NSEvent, in view: CSVGridTopChromeView) -> NSMenu? {
        let point = view.convert(event.locationInWindow, from: nil)
        guard let column = headerColumn(at: point) else { return nil }
        contextMenuColumn = column
        selectColumn(column)

        let menu = NSMenu(title: "Column")
        menu.addItem(makeMenuItem(title: "Edit Header…", action: #selector(renameHeaderFromMenu(_:))))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Insert Column Left", action: #selector(insertColumnLeftFromMenu(_:))))
        menu.addItem(makeMenuItem(title: "Insert Column Right", action: #selector(insertColumnRightFromMenu(_:))))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Delete Column…", action: #selector(deleteColumnFromMenu(_:))))
        return menu
    }

    fileprivate func handleRowHeaderMouseDown(event: NSEvent, in view: CSVGridRowHeaderView) {
        window?.makeFirstResponder(canvasView)
        let point = view.convert(event.locationInWindow, from: nil)
        guard let row = gutterRow(at: point) else {
            clearHeaderDragState()
            return
        }
        commitPendingEditIfNeeded()
        selectRow(row)
        guard !isFilterActive else {
            clearHeaderDragState()
            return
        }
        let documentRow = documentRowIndex(forDisplayRow: row) ?? row
        headerDragState = .row(sourceDisplayRow: row, sourceDocumentRow: documentRow, insertionIndex: row)
        updateDragIndicators()
    }

    fileprivate func handleRowHeaderMouseDragged(event: NSEvent, in view: CSVGridRowHeaderView) {
        guard case .row(let sourceDisplayRow, let sourceDocumentRow, _) = headerDragState else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        headerDragState = .row(sourceDisplayRow: sourceDisplayRow, sourceDocumentRow: sourceDocumentRow, insertionIndex: rowInsertionIndex(for: point))
        updateDragIndicators()
    }

    fileprivate func handleRowHeaderMouseUp(event: NSEvent, in view: CSVGridRowHeaderView) {
        defer { clearHeaderDragState() }
        guard case .row(_, let sourceDocumentRow, let insertionIndex) = headerDragState else { return }
        guard !isFilterActive else { return }
        performMoveRow(fromDocumentRow: sourceDocumentRow, toDisplayInsertionIndex: insertionIndex)
    }

    fileprivate func rowHeaderMenu(for event: NSEvent, in view: CSVGridRowHeaderView) -> NSMenu? {
        let point = view.convert(event.locationInWindow, from: nil)
        guard let row = gutterRow(at: point) else { return nil }
        contextMenuRow = documentRowIndex(forDisplayRow: row) ?? row
        selectRow(row)

        let menu = NSMenu(title: "Row")
        menu.addItem(makeMenuItem(title: "Insert Row Above", action: #selector(insertRowAboveFromMenu(_:))))
        menu.addItem(makeMenuItem(title: "Insert Row Below", action: #selector(insertRowBelowFromMenu(_:))))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Delete Row…", action: #selector(deleteRowFromMenu(_:))))
        return menu
    }

    fileprivate func handleMouseDown(event: NSEvent, in view: CSVGridBodyCanvasView) {
        window?.makeFirstResponder(view)
        let point = view.convert(event.locationInWindow, from: nil)
        let hit = hitTarget(at: point)
        guard let clickedCell = hit.cellAddress else {
            commitPendingEditIfNeeded()
            return
        }

        commitPendingEditIfNeeded()

        if event.modifierFlags.contains(.command), case .link(_, let target) = hit {
            onOpenWikilinkInNewTab?(target)
            return
        }

        if event.modifierFlags.contains(.shift), let anchor = selection?.anchor ?? activeCell {
            selection = CSVNativeGridSelection(anchor: anchor, focus: clickedCell)
        } else {
            selection = CSVNativeGridSelection(anchor: clickedCell, focus: clickedCell)
        }
        dragAnchor = selection?.anchor
        invalidateGridDisplay()

        if case .link(_, let target) = hit, !event.modifierFlags.contains(.shift), event.clickCount == 1 {
            onOpenWikilinkInNewTab?(target)
            return
        }

        if event.clickCount >= 2 {
            beginEditing(cell: clickedCell, selectAll: true)
        }
    }

    fileprivate func handleMouseDragged(event: NSEvent, in view: CSVGridBodyCanvasView) {
        guard let anchor = dragAnchor else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        guard let cell = hitTarget(at: point).cellAddress else { return }
        selection = CSVNativeGridSelection(anchor: anchor, focus: cell)
        invalidateGridDisplay()
        scrollCellToVisible(cell)
    }

    fileprivate func handleMouseMoved(event: NSEvent, in view: CSVGridBodyCanvasView) {
        let point = view.convert(event.locationInWindow, from: nil)
        updateCursor(for: hitTarget(at: point))
    }

    fileprivate func handleMouseExited() {
        NSCursor.arrow.set()
    }

    fileprivate func handleCursorUpdate(event: NSEvent, in view: CSVGridBodyCanvasView) {
        let point = view.convert(event.locationInWindow, from: nil)
        updateCursor(for: hitTarget(at: point))
    }

    fileprivate func handleKeyDown(event: NSEvent, in view: CSVGridBodyCanvasView) -> Bool {
        guard displayedColumnCount > 0 else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command),
           let characters = event.charactersIgnoringModifiers?.lowercased() {
            if characters == "z" {
                if modifiers.contains(.shift) {
                    redo(nil)
                } else {
                    undo(nil)
                }
                return true
            }
            if characters == "y" {
                redo(nil)
                return true
            }
        }

        let extendsSelection = modifiers.contains(.shift)
        let hasUnsupportedModifiers = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)

        if !hasUnsupportedModifiers {
            switch event.keyCode {
            case 123:
                moveSelection(.left, extending: extendsSelection)
                return true
            case 124:
                moveSelection(.right, extending: extendsSelection)
                return true
            case 125:
                moveSelection(.down, extending: extendsSelection)
                return true
            case 126:
                moveSelection(.up, extending: extendsSelection)
                return true
            case 48:
                moveSelection(extendsSelection ? .tabBackward : .tabForward, extending: false)
                return true
            case 36, 76:
                beginEditingSelectedCell(selectAll: true)
                return true
            case 51, 117:
                clearSelectionContents()
                return true
            case 122:
                beginEditingSelectedCell(selectAll: true)
                return true
            default:
                break
            }
        }

        if let seed = typingSeed(from: event) {
            beginEditingSelectedCell(replacingWith: seed, selectAll: false)
            return true
        }

        return false
    }

    fileprivate func menu(for event: NSEvent, in view: CSVGridBodyCanvasView) -> NSMenu? {
        let point = view.convert(event.locationInWindow, from: nil)
        let hit = hitTarget(at: point)
        guard let cell = hit.cellAddress else { return nil }

        commitPendingEditIfNeeded()
        selection = CSVNativeGridSelection(anchor: cell, focus: cell)
        contextMenuCell = cell
        if case .link(_, let target) = hit {
            contextMenuLinkTarget = target
        } else {
            contextMenuLinkTarget = nil
        }
        invalidateGridDisplay()

        let menu = NSMenu(title: "CSV")
        if contextMenuLinkTarget != nil {
            menu.addItem(makeMenuItem(title: "Open Link", action: #selector(openContextMenuLink(_:))))
            menu.addItem(makeMenuItem(title: "Open Link in New Tab", action: #selector(openContextMenuLinkInNewTab(_:))))
            menu.addItem(.separator())
        }
        menu.addItem(makeMenuItem(title: "Copy", action: #selector(copyFromMenu(_:))))
        menu.addItem(makeMenuItem(title: "Paste", action: #selector(pasteFromMenu(_:))))
        menu.addItem(makeMenuItem(title: "Clear", action: #selector(clearFromMenu(_:))))
        return menu
    }

    fileprivate func copySelection() {
        guard let selection else { return }
        let matrix = selection.rowRange.map { row in
            selection.columnRange.map { column in
                documentValue(atDisplayRow: row, column: column)
            }
        }
        let tsv = matrix.map { CSVGridTransferCodec.serializeRow($0, delimiter: "\t") }.joined(separator: "\n")
        let csv = matrix.map { CSVGridTransferCodec.serializeRow($0, delimiter: ",") }.joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tsv, forType: .string)
        pasteboard.setString(tsv, forType: NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text"))
        pasteboard.setString(csv, forType: NSPasteboard.PasteboardType("public.comma-separated-values-text"))
    }

    fileprivate func pasteSelection() {
        guard displayedColumnCount > 0,
              let target = activeCell,
              let text = NSPasteboard.general.string(forType: .string) else {
            return
        }

        let delimiter: Character = text.contains("\t") ? "\t" : ","
        let rows = CSVGridTransferCodec.parseRows(from: text, delimiter: delimiter)
        guard !rows.isEmpty else { return }

        endEditing(commit: true)

        var endCell: CSVNativeGridCellAddress?
        performUndoableMutation(actionName: "Paste") {
            let targetDocumentRow = documentRowIndex(forDisplayRow: target.row) ?? target.row
            let maxColumnCount = rows.map(\.count).max() ?? 0
            document.ensureColumnCount(atLeast: target.column + maxColumnCount)
            rebuildColumnMetrics()

            for (rowOffset, values) in rows.enumerated() {
                for (columnOffset, value) in values.enumerated() {
                    document.setValue(value, atDisplayRow: targetDocumentRow + rowOffset, column: target.column + columnOffset)
                }
            }

            rebuildFilteredRows()
            let anchorRow = displayRowIndex(forDocumentRow: targetDocumentRow) ?? min(target.row, max(0, displayedRowCount - 1))
            let anchorCell = CSVNativeGridCellAddress(row: anchorRow, column: target.column)
            let endDocumentRow = targetDocumentRow + max(0, rows.count - 1)
            let focusRow = displayRowIndex(forDocumentRow: endDocumentRow) ?? anchorRow
            let resolvedEndCell = CSVNativeGridCellAddress(
                row: focusRow,
                column: target.column + max(0, maxColumnCount - 1)
            )
            selection = CSVNativeGridSelection(anchor: anchorCell, focus: resolvedEndCell)
            dragAnchor = anchorCell
            updateHeaderMetrics()
            updateCanvasFrame()
            invalidateGridDisplay()
            endCell = resolvedEndCell
        }

        if let endCell {
            scrollCellToVisible(endCell)
        }
    }

    fileprivate func clearSelectionContents() {
        guard let selection else { return }
        endEditing(commit: false)

        var didChange = false
        for row in selection.rowRange {
            for column in selection.columnRange {
                if !documentValue(atDisplayRow: row, column: column).isEmpty {
                    didChange = true
                    break
                }
            }
            if didChange { break }
        }

        guard didChange else { return }
        performUndoableMutation(actionName: "Clear") {
            for row in selection.rowRange {
                for column in selection.columnRange {
                    setDocumentValue("", atDisplayRow: row, column: column)
                }
            }
            rebuildFilteredRows()
            reconcileSelectionAfterFilterOrDataChange()
            invalidateGridDisplay()
        }
    }

    fileprivate func cutSelection() {
        copySelection()
        clearSelectionContents()
    }

    fileprivate func selectAllCells() {
        guard displayedColumnCount > 0, displayedRowCount > 0 else { return }
        let topLeft = CSVNativeGridCellAddress(row: 0, column: 0)
        let bottomRight = CSVNativeGridCellAddress(row: displayedRowCount - 1, column: displayedColumnCount - 1)
        selection = CSVNativeGridSelection(anchor: topLeft, focus: bottomRight)
        invalidateGridDisplay()
    }

    private var rowHeaderWidth: CGFloat {
        let digits = max(2, String(max(1, displayedRowCount)).count)
        return max(44, CGFloat(digits) * 9 + 22)
    }

    private var topChromeHeight: CGFloat {
        isTopChromeEnabled ? (formulaBarHeight + headerHeight) : 0
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.masksToBounds = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        topChromeView.owner = self
        rowHeaderView.owner = self
        canvasView.owner = self

        topChromeView.translatesAutoresizingMaskIntoConstraints = false
        topChromeView.wantsLayer = true
        topChromeCornerLabel.translatesAutoresizingMaskIntoConstraints = true
        topChromeCornerLabel.font = .systemFont(ofSize: 18, weight: .bold)
        topChromeCornerLabel.textColor = .black
        topChromeCornerLabel.alignment = .center

        topChromeActiveCellPillView.translatesAutoresizingMaskIntoConstraints = true
        topChromeActiveCellPillView.wantsLayer = true
        topChromeActiveCellPillLabel.translatesAutoresizingMaskIntoConstraints = true
        topChromeActiveCellPillLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        topChromeActiveCellPillLabel.alignment = .center
        topChromeFormulaSymbolLabel.translatesAutoresizingMaskIntoConstraints = true
        topChromeFormulaSymbolLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        topChromeFormulaSymbolLabel.alignment = .center
        topChromeFormulaResultLabel.translatesAutoresizingMaskIntoConstraints = true
        topChromeFormulaResultLabel.font = .systemFont(ofSize: 11)
        topChromeFormulaResultLabel.alignment = .right
        (topChromeFormulaResultLabel.cell as? NSTextFieldCell)?.lineBreakMode = .byTruncatingTail

        formulaField.translatesAutoresizingMaskIntoConstraints = true
        formulaField.isHidden = !isFormulaFieldEnabled
        formulaField.font = .systemFont(ofSize: 13)
        formulaField.isBordered = false
        formulaField.drawsBackground = false
        formulaField.backgroundColor = .clear
        formulaField.focusRingType = .none
        formulaField.delegate = self
        formulaField.placeholderString = "Enter raw cell value or {{ formula }}"

        filterField.translatesAutoresizingMaskIntoConstraints = true
        filterField.font = .systemFont(ofSize: 12)
        filterField.focusRingType = .none
        filterField.sendsSearchStringImmediately = true
        filterField.sendsWholeSearchString = false
        filterField.delegate = self
        filterField.placeholderString = "Filter rows"

        for indicatorView in [columnInsertionIndicatorView, rowInsertionIndicatorView] {
            indicatorView.translatesAutoresizingMaskIntoConstraints = true
            indicatorView.wantsLayer = true
            indicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            indicatorView.isHidden = true
        }

        completionView.translatesAutoresizingMaskIntoConstraints = true
        completionView.isHidden = true
        completionView.onChoose = { [weak self] item in
            self?.acceptCompletion(item)
        }

        rowHeaderView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.translatesAutoresizingMaskIntoConstraints = false

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView = CSVGridPinnedClipView()
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = canvasView

        let clipView = scrollView.contentView
        clipView.wantsLayer = true
        clipView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        clipView.addSubview(editorView)
        editorView.frame = .zero

        editorView.isHidden = true
        editorView.onCommit = { [weak self] value, navigation in
            self?.commitEditorValue(value, navigation: navigation)
        }
        editorView.onCancel = { [weak self] in
            self?.endEditing(commit: false)
            if let canvasView = self?.canvasView {
                self?.window?.makeFirstResponder(canvasView)
            }
        }
        editorView.onTextChange = { [weak self] in
            self?.updateEditorCompletion()
        }
        editorView.completionCommandHandler = { [weak self] selector in
            self?.handleEditorCompletionCommand(selector) ?? false
        }

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.isHidden = true

        placeholderField.alignment = .center
        placeholderField.maximumNumberOfLines = 0
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.font = .systemFont(ofSize: 13)
        placeholderField.isBordered = false
        placeholderField.drawsBackground = false
        placeholderField.backgroundColor = .clear
        placeholderField.isEditable = false
        placeholderField.isSelectable = false

        topChromeView.addSubview(formulaField)
        topChromeView.addSubview(filterField)
        topChromeView.addSubview(topChromeCornerLabel)
        topChromeActiveCellPillView.addSubview(topChromeActiveCellPillLabel)
        topChromeView.addSubview(topChromeActiveCellPillView)
        topChromeView.addSubview(topChromeFormulaSymbolLabel)
        topChromeView.addSubview(topChromeFormulaResultLabel)

        addSubview(rowHeaderView)
        addSubview(scrollView)
        addSubview(topChromeView)
        addSubview(columnInsertionIndicatorView)
        addSubview(rowInsertionIndicatorView)
        addSubview(completionView)
        addSubview(progressIndicator)
        addSubview(placeholderField)

        let rowWidth = rowHeaderWidth
        rowHeaderWidthConstraint = rowHeaderView.widthAnchor.constraint(equalToConstant: rowWidth)
        topChromeHeightConstraint = topChromeView.heightAnchor.constraint(equalToConstant: topChromeHeight)

        NSLayoutConstraint.activate([
            rowHeaderWidthConstraint!,
            topChromeHeightConstraint!,

            topChromeView.topAnchor.constraint(equalTo: topAnchor),
            topChromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            topChromeView.trailingAnchor.constraint(equalTo: trailingAnchor),

            rowHeaderView.topAnchor.constraint(equalTo: topChromeView.bottomAnchor),
            rowHeaderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowHeaderView.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: topChromeView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rowHeaderView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            progressIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),

            placeholderField.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 12),
            placeholderField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            placeholderField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])

        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.topChromeView.needsDisplay = true
            self?.rowHeaderView.needsDisplay = true
            self?.updateTopChromeFormulaSubviews()
            self?.updateTopChromeStaticHeaderSubviews()
            self?.updateEditorFrameIfNeeded()
            self?.updateCompletionFrameIfNeeded()
            self?.updateFilterFieldFrame()
            self?.updateFormulaFieldFrame()
            self?.updateDragIndicators()
            self?.invalidateCursorRects()
        }

        applyResolvedAppearance()
        updateChromeVisibility()
        updateFormulaFieldFrame()
    }

    private func applyResolvedAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        topChromeView.layer?.backgroundColor = (isDark ? NSColor(calibratedWhite: 0.18, alpha: 1) : NSColor.windowBackgroundColor).cgColor
        formulaField.textColor = isDark ? .white : .labelColor
        formulaField.backgroundColor = .clear
        formulaField.isHidden = !isFormulaFieldEnabled
        filterField.textColor = isDark ? .white : .labelColor
        topChromeCornerLabel.textColor = isDark ? .white : .black
        topChromeActiveCellPillLabel.textColor = isDark ? .white : .controlAccentColor
        topChromeFormulaSymbolLabel.textColor = isDark ? NSColor(calibratedWhite: 0.76, alpha: 1) : .tertiaryLabelColor
        topChromeFormulaResultLabel.textColor = isDark ? NSColor(calibratedWhite: 0.80, alpha: 1) : .secondaryLabelColor
        for label in topChromeHeaderLabels.values {
            label.textColor = isDark ? .white : .black
        }
        updateTopChromeFormulaSubviews()
        topChromeView.needsDisplay = true
        rowHeaderView.needsDisplay = true
        completionView.needsDisplay = true
    }

    private func rebuildColumnMetrics() {
        columnWidths = (0..<displayedColumnCount).map { index in
            let title = document.columns.indices.contains(index) ? document.columns[index].title : spreadsheetColumnLabel(for: index)
            let format = document.columns.indices.contains(index) ? document.columns[index].format : nil
            return preferredWidth(forColumnAt: index, title: title, format: format)
        }

        columnOffsets = []
        columnOffsets.reserveCapacity(columnWidths.count)
        var x: CGFloat = 0
        for width in columnWidths {
            columnOffsets.append(x)
            x += width
        }
    }

    private func updateHeaderMetrics() {
        let width = rowHeaderWidth
        rowHeaderWidthConstraint?.constant = width
        topChromeHeightConstraint?.constant = topChromeHeight
        topChromeView.needsDisplay = true
        rowHeaderView.needsDisplay = true
        updateTopChromeFormulaSubviews()
        updateTopChromeStaticHeaderSubviews()
        updateFilterFieldFrame()
        updateFormulaFieldFrame()
    }

    private func updateCanvasFrame() {
        let minimumWidth = scrollView.contentSize.width
        let minimumHeight = scrollView.contentSize.height
        let width = max(totalColumnWidth, minimumWidth)
        let height = max(CGFloat(displayedRowCount) * rowHeight, minimumHeight)
        canvasView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        canvasView.needsDisplay = true
        debugLog("updateCanvasFrame")
    }

    private func updateTopChromeFormulaSubviews() {
        guard isTopChromeEnabled, !topChromeView.isHidden else {
            topChromeActiveCellPillView.isHidden = true
            topChromeFormulaSymbolLabel.isHidden = true
            topChromeFormulaResultLabel.isHidden = true
            return
        }

        let label = activeCellLabel()
        topChromeActiveCellPillLabel.stringValue = label
        let pillWidth = max(56, measuredWidth(for: label, font: .monospacedSystemFont(ofSize: 11, weight: .semibold)) + 16)
        let pillHeight: CGFloat = 22
        let pillY = floor((formulaBarHeight - pillHeight) / 2)
        topChromeActiveCellPillView.frame = NSRect(x: 10, y: pillY, width: pillWidth, height: pillHeight)
        topChromeActiveCellPillView.layer?.cornerRadius = 7
        topChromeActiveCellPillView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        topChromeActiveCellPillView.layer?.borderWidth = 1
        topChromeActiveCellPillView.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        topChromeActiveCellPillLabel.frame = NSRect(x: 8, y: 3, width: pillWidth - 16, height: pillHeight - 6)
        topChromeActiveCellPillView.isHidden = false

        topChromeFormulaSymbolLabel.frame = NSRect(x: 76, y: floor((formulaBarHeight - 16) / 2), width: 24, height: 16)
        topChromeFormulaSymbolLabel.isHidden = false

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let (resultText, resultColor) = formulaResultPresentation(isDark: isDark)
        topChromeFormulaResultLabel.stringValue = resultText
        topChromeFormulaResultLabel.textColor = resultColor
        let filterWidth: CGFloat = 180
        let resultWidth = min(160, max(40, measuredWidth(for: resultText, font: .systemFont(ofSize: 11)) + 8))
        let resultX = max(110, topChromeView.bounds.width - filterWidth - resultWidth - 20)
        topChromeFormulaResultLabel.frame = NSRect(
            x: resultX,
            y: floor((formulaBarHeight - 16) / 2),
            width: resultWidth,
            height: 16
        )
        topChromeFormulaResultLabel.isHidden = false
    }

    private func updateTopChromeStaticHeaderSubviews() {
        guard isTopChromeEnabled, !topChromeView.isHidden else {
            topChromeCornerLabel.isHidden = true
            for label in topChromeHeaderLabels.values {
                label.isHidden = true
            }
            return
        }

        topChromeCornerLabel.isHidden = false
        topChromeCornerLabel.frame = NSRect(x: 0, y: formulaBarHeight, width: rowHeaderWidth, height: headerHeight)

        let scrollX = scrollOrigin().x
        let visibleWidth = max(0, topChromeView.bounds.width - rowHeaderWidth)
        let visibleRect = NSRect(x: scrollX, y: 0, width: visibleWidth, height: headerHeight)
        guard let range = visibleColumnRange(in: visibleRect) else {
            for label in topChromeHeaderLabels.values {
                label.isHidden = true
            }
            return
        }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let visibleColumns = Set(range)

        for column in range {
            let label: NSTextField
            if let existing = topChromeHeaderLabels[column] {
                label = existing
            } else {
                let created = CSVGridPassthroughLabel(string: "")
                created.font = .systemFont(ofSize: 12, weight: .semibold)
                created.alignment = .left
                (created.cell as? NSTextFieldCell)?.lineBreakMode = .byTruncatingTail
                created.translatesAutoresizingMaskIntoConstraints = true
                topChromeView.addSubview(created)
                topChromeHeaderLabels[column] = created
                label = created
            }

            label.stringValue = headerTitle(forColumn: column)
            label.textColor = isDark ? .white : .black
            label.frame = NSRect(
                x: rowHeaderWidth + columnOffsets[column] - scrollX + 8,
                y: formulaBarHeight + 6,
                width: max(0, columnWidths[column] - 16),
                height: max(0, headerHeight - 12)
            )
            label.isHidden = false
        }

        for (column, label) in topChromeHeaderLabels where !visibleColumns.contains(column) {
            label.isHidden = true
        }
    }

    private func updateChromeVisibility() {
        let showsGrid = !isLoadingDocument && currentErrorMessage == nil
        let showsTopChrome = showsGrid && isTopChromeEnabled
        topChromeView.isHidden = !showsTopChrome
        formulaField.isHidden = !(showsTopChrome && isFormulaFieldEnabled)
        filterField.isHidden = !showsTopChrome
        updateTopChromeFormulaSubviews()
        updateTopChromeStaticHeaderSubviews()
        updateFilterFieldFrame()
        rowHeaderView.isHidden = !showsGrid
        scrollView.isHidden = !showsGrid
        if !showsGrid {
            completionView.isHidden = true
        }
        invalidateCursorRects()
        debugLog("updateChromeVisibility showsGrid=\(showsGrid) showsTopChrome=\(showsTopChrome)")
    }

    private func invalidateGridDisplay() {
        formulaComputationCache.removeAll()
        canvasView.needsDisplay = true
        topChromeView.needsDisplay = true
        rowHeaderView.needsDisplay = true
        invalidateCursorRects()
        updateTopChromeFormulaSubviews()
        updateFormulaBar()
        debugLog("invalidateGridDisplay")
    }

    private func invalidateCursorRects() {
        guard let window else { return }
        window.invalidateCursorRects(for: topChromeView)
        window.invalidateCursorRects(for: rowHeaderView)
        window.invalidateCursorRects(for: canvasView)
        if !editorView.isHidden {
            window.invalidateCursorRects(for: editorView)
        }
    }

    private func drawGridLines(in dirtyRect: NSRect, rowRange: ClosedRange<Int>?, columnRange: ClosedRange<Int>?) {
        let stroke = NSColor.separatorColor.withAlphaComponent(0.18)
        stroke.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1

        if let rowRange {
            for row in rowRange {
                let y = CGFloat(row + 1) * rowHeight - 0.5
                path.move(to: NSPoint(x: dirtyRect.minX, y: y))
                path.line(to: NSPoint(x: dirtyRect.maxX, y: y))
            }
        }

        if let columnRange {
            for column in columnRange {
                let x = columnOffsets[column] + columnWidths[column] - 0.5
                path.move(to: NSPoint(x: x, y: dirtyRect.minY))
                path.line(to: NSPoint(x: x, y: dirtyRect.maxY))
            }
        }

        path.stroke()
    }

    private func drawCell(_ display: CSVNativeGridCellDisplay, in rect: NSRect, selected: Bool) {
        let contentRect = rect.insetBy(dx: 8, dy: 4)

        switch display {
        case .text(let text):
            drawText(displayText(for: text), in: contentRect, color: .labelColor)
        case .link(let title, _):
            drawText(title, in: contentRect, color: .linkColor, underline: true)
        case .status(let title, let color):
            drawPill(text: title, backgroundColor: color, textColor: .white, in: contentRect)
        case .tags(let tags):
            drawTagList(tags, in: contentRect)
        }

        if selected, let activeCell, activeCellRect()?.intersects(rect) == false {
            _ = activeCell
        }
    }

    private func drawHeaderCell(title: String, in rect: NSRect, selected: Bool, alignment: NSTextAlignment) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let baseBackground = isDark ? NSColor(calibratedWhite: 0.18, alpha: 1) : NSColor.windowBackgroundColor
        baseBackground.setFill()
        rect.fill()

        if selected {
            NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.18 : 0.09).setFill()
            rect.fill()
        }

        let insetX: CGFloat = alignment == .right ? 6 : 8
        let textRect = rect.insetBy(dx: insetX, dy: 6)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let foreground = isDark ? NSColor.white : NSColor.labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: foreground,
            .paragraphStyle: style
        ]
        NSAttributedString(string: title, attributes: attributes).draw(in: textRect)

        NSColor.separatorColor.withAlphaComponent(isDark ? 0.40 : 0.25).setStroke()
        let verticalRule = NSBezierPath()
        verticalRule.lineWidth = 1
        verticalRule.move(to: NSPoint(x: rect.maxX - 0.5, y: rect.minY))
        verticalRule.line(to: NSPoint(x: rect.maxX - 0.5, y: rect.maxY))
        verticalRule.stroke()
    }

    private func drawPill(text: String, backgroundColor: NSColor, textColor: NSColor, in rect: NSRect) {
        let display = displayText(for: text)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: textColor
        ]
        let attributed = NSAttributedString(string: display, attributes: attributes)
        let size = attributed.size()
        let pillRect = NSRect(
            x: rect.minX,
            y: floor(rect.midY - (size.height + 4) / 2),
            width: min(rect.width, size.width + 16),
            height: size.height + 4
        )
        let path = NSBezierPath(roundedRect: pillRect, xRadius: 10, yRadius: 10)
        backgroundColor.setFill()
        path.fill()
        let textRect = pillRect.insetBy(dx: 8, dy: 2)
        attributed.draw(in: textRect)
    }

    private func drawTagList(_ tags: [String], in rect: NSRect) {
        let visibleTags = Array(tags.prefix(4))
        var x = rect.minX

        for (index, tag) in visibleTags.enumerated() {
            let isOverflow = index == 3 && tags.count > visibleTags.count
            let label = isOverflow ? "+\(tags.count - visibleTags.count + 1)" : tag
            let background = isOverflow
                ? NSColor.quaternaryLabelColor.withAlphaComponent(0.18)
                : NSColor.controlAccentColor.withAlphaComponent(0.16)
            let foreground = isOverflow ? NSColor.secondaryLabelColor : NSColor.labelColor
            let chipSize = chipSize(for: label)
            let chipRect = NSRect(x: x, y: floor(rect.midY - chipSize.height / 2), width: min(rect.maxX - x, chipSize.width), height: chipSize.height)
            guard chipRect.width > 12 else { break }
            let path = NSBezierPath(roundedRect: chipRect, xRadius: 9, yRadius: 9)
            background.setFill()
            path.fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: foreground
            ]
            NSAttributedString(string: label, attributes: attributes).draw(in: chipRect.insetBy(dx: 8, dy: 2))
            x += chipRect.width + 4
            if x >= rect.maxX { break }
        }
    }

    private func chipSize(for label: String) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ]
        let size = NSAttributedString(string: label, attributes: attributes).size()
        return NSSize(width: min(120, size.width + 16), height: size.height + 4)
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, underline: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: color,
            .paragraphStyle: style,
            .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let measured = attributed.boundingRect(with: NSSize(width: rect.width, height: rect.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let drawRect = NSRect(
            x: rect.minX,
            y: floor(rect.midY - measured.height / 2),
            width: rect.width,
            height: max(rect.height, measured.height)
        )
        attributed.draw(in: drawRect)
    }

    private func preferredWidth(forColumnAt index: Int, title: String, format: String?) -> CGFloat {
        var maxLength = max(6, title.count)
        for row in 0..<min(document.rowCount, 40) {
            let raw = document.value(atDisplayRow: row, column: index)
            if format?.lowercased() == "status" {
                maxLength = max(maxLength, min((raw.isEmpty ? "—" : raw).count + 4, 18))
            } else if format?.lowercased() == "tags" {
                let tagPreview = parseTags(from: raw).prefix(3).joined(separator: ", ")
                maxLength = max(maxLength, min(tagPreview.count, 28))
            } else if let target = wikilinkTarget(from: raw) {
                maxLength = max(maxLength, min(displayTitle(forWikilinkTarget: target).count, 28))
            } else {
                maxLength = max(maxLength, min(displayText(for: raw).count, 36))
            }
            if raw.contains("\n") {
                maxLength = max(maxLength, 24)
            }
        }

        if format?.lowercased() == "status" {
            return 140
        }
        if format?.lowercased() == "tags" {
            return 180
        }

        return min(max(minimumColumnWidth, CGFloat(maxLength) * 7 + 24), maximumColumnWidth)
    }

    private func statusColor(for rawValue: String) -> NSColor {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hex = document.statusColors[key] ?? document.statusColors[rawValue] ?? document.statusColors[rawValue.lowercased()],
           let color = NSColor(nativeCSVHex: hex) {
            return color
        }
        switch key {
        case "todo": return .systemOrange
        case "doing", "in-progress", "wip": return .systemBlue
        case "done": return .systemGreen
        case "blocked", "cancelled": return .systemRed
        default: return .systemGray
        }
    }

    private func parseTags(from rawValue: String) -> [String] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains(",") {
            return trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private func displayText(for rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "\r\n", with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\r", with: " ⏎ ")
    }

    private func wikilinkTarget(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[["), trimmed.hasSuffix("]]"), trimmed.count > 4 else {
            return nil
        }
        return String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayTitle(forWikilinkTarget target: String) -> String {
        let fileName = URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
        let display = fileName.isEmpty ? target : fileName
        return "\(display) ↗"
    }

    private func indexOfColumn(atX x: CGFloat) -> Int {
        guard !columnOffsets.isEmpty else { return -1 }
        var lower = 0
        var upper = columnOffsets.count - 1
        while lower <= upper {
            let mid = (lower + upper) / 2
            let start = columnOffsets[mid]
            let end = start + columnWidths[mid]
            if x < start {
                upper = mid - 1
            } else if x >= end {
                lower = mid + 1
            } else {
                return mid
            }
        }
        return min(max(upper, 0), columnOffsets.count - 1)
    }

    private func clampedCellAddress(_ address: CSVNativeGridCellAddress?) -> CSVNativeGridCellAddress? {
        guard let address,
              displayedColumnCount > 0,
              displayedRowCount > 0 else {
            return nil
        }
        return CSVNativeGridCellAddress(
            row: min(max(0, address.row), displayedRowCount - 1),
            column: min(max(0, address.column), displayedColumnCount - 1)
        )
    }

    private func moveSelection(_ movement: CSVNativeGridMovement, extending: Bool) {
        guard let current = activeCell else { return }
        var target = current

        switch movement {
        case .left:
            target.column = max(0, target.column - 1)
        case .right:
            target.column = min(displayedColumnCount - 1, target.column + 1)
        case .up:
            target.row = max(0, target.row - 1)
        case .down:
            target.row = min(displayedRowCount - 1, target.row + 1)
        case .tabForward:
            if target.column < displayedColumnCount - 1 {
                target.column += 1
            } else {
                target.column = 0
                target.row = min(displayedRowCount - 1, target.row + 1)
            }
        case .tabBackward:
            if target.column > 0 {
                target.column -= 1
            } else if target.row > 0 {
                target.row -= 1
                target.column = max(0, displayedColumnCount - 1)
            }
        }

        if target.row == displayedRowCount - 1 && current.row == displayedRowCount - 1 && movement == .tabForward && current.column == displayedColumnCount - 1 {
            target.row = displayedRowCount - 1
            target.column = 0
        }

        hideCompletion()
        if extending, let anchor = selection?.anchor {
            selection = CSVNativeGridSelection(anchor: anchor, focus: target)
        } else {
            selection = CSVNativeGridSelection(anchor: target, focus: target)
        }
        invalidateGridDisplay()
        scrollCellToVisible(target)
    }

    private func beginEditingSelectedCell(replacingWith replacementText: String? = nil, selectAll: Bool = true) {
        guard let target = activeCell else { return }
        beginEditing(cell: target, replacingWith: replacementText, selectAll: selectAll)
    }

    private func beginEditing(cell: CSVNativeGridCellAddress, replacingWith replacementText: String? = nil, selectAll: Bool = true) {
        guard let clamped = clampedCellAddress(cell) else { return }
        selection = CSVNativeGridSelection(anchor: clamped, focus: clamped)
        editingCell = clamped
        scrollCellToVisible(clamped)
        invalidateGridDisplay()
        updateEditorFrameIfNeeded()

        let value = replacementText ?? documentValue(atDisplayRow: clamped.row, column: clamped.column)
        editorView.beginEditing(
            text: value,
            selectAll: replacementText == nil && selectAll,
            replacementTextWasProvided: replacementText != nil
        )
        window?.makeFirstResponder(editorView.textView)
        updateEditorCompletion()
    }

    private func commitPendingEditIfNeeded() {
        guard editingCell != nil else { return }
        endEditing(commit: true)
    }

    private func commitEditorValue(_ value: String, navigation: CSVNativeGridMovement?, targetCell: CSVNativeGridCellAddress? = nil) {
        let target = targetCell ?? editingCell
        guard let target else { return }
        let targetDocumentRow = documentRowIndex(forDisplayRow: target.row) ?? target.row
        let previousValue = document.value(atDisplayRow: targetDocumentRow, column: target.column)

        var focusCell = CSVNativeGridCellAddress(row: target.row, column: target.column)
        let applyCommit = {
            self.document.setValue(value, atDisplayRow: targetDocumentRow, column: target.column)
            if targetCell == nil {
                self.endEditing(commit: false)
            } else {
                self.hideCompletion()
            }

            self.rebuildFilteredRows()
            if target.column >= self.columnWidths.count {
                self.rebuildColumnMetrics()
                self.updateHeaderMetrics()
                self.updateCanvasFrame()
            }

            let focusRow = self.displayRowIndex(forDocumentRow: targetDocumentRow) ?? min(target.row, max(0, self.displayedRowCount - 1))
            focusCell = CSVNativeGridCellAddress(row: focusRow, column: target.column)
            self.selection = CSVNativeGridSelection(anchor: focusCell, focus: focusCell)
            self.dragAnchor = focusCell
            self.invalidateGridDisplay()
        }

        if previousValue != value {
            performUndoableMutation(actionName: "Edit Cell") {
                applyCommit()
            }
        } else {
            applyCommit()
        }

        if let navigation {
            moveSelection(navigation, extending: false)
        } else {
            scrollCellToVisible(focusCell)
        }
    }

    private func endEditing(commit: Bool) {
        guard editingCell != nil else {
            editorView.endEditingSession()
            return
        }

        let currentValue = editorView.currentText
        let currentCell = editingCell
        editingCell = nil
        hideCompletion()
        editorView.endEditingSession()
        if commit, let currentCell {
            let currentDocumentRow = documentRowIndex(forDisplayRow: currentCell.row) ?? currentCell.row
            let previousValue = document.value(atDisplayRow: currentDocumentRow, column: currentCell.column)
            if previousValue != currentValue {
                performUndoableMutation(actionName: "Edit Cell") {
                    document.setValue(currentValue, atDisplayRow: currentDocumentRow, column: currentCell.column)
                    rebuildFilteredRows()
                    reconcileSelectionAfterFilterOrDataChange(preferredDocumentRow: currentDocumentRow, preferredColumn: currentCell.column)
                    invalidateGridDisplay()
                }
                updateEditorFrameIfNeeded()
                return
            }
        }
        updateEditorFrameIfNeeded()
        invalidateGridDisplay()
    }

    private func updateEditorFrameIfNeeded() {
        guard let editingCell else {
            editorView.endEditingSession()
            editorView.isHidden = true
            invalidateCursorRects()
            return
        }

        let clipView = scrollView.contentView

        let origin = clipView.bounds.origin
        let cellRect = self.cellRect(for: editingCell)
        var frame = cellRect.offsetBy(dx: -origin.x, dy: -origin.y)
        frame = frame.insetBy(dx: 1, dy: 1)
        frame.size.height = max(rowHeight - 2, frame.height)
        editorView.isHidden = false
        editorView.frame = frame
        editorView.layoutSubtreeIfNeeded()
        invalidateCursorRects()
    }

    private func scrollCellToVisible(_ address: CSVNativeGridCellAddress) {
        canvasView.scrollToVisible(cellRect(for: address))
    }

    private func updateCursor(for hit: CSVNativeGridHitTarget) {
        switch hit {
        case .background:
            NSCursor.arrow.set()
        case .cell:
            NSCursor.csvGridCell.set()
        case .link:
            NSCursor.pointingHand.set()
        }
    }

    private func activeCellLabel() -> String {
        guard let activeCell else { return "—" }
        let documentRow = documentRowIndex(forDisplayRow: activeCell.row) ?? activeCell.row
        return "\(spreadsheetColumnLabel(for: activeCell.column))\(documentRow + 1)"
    }

    private func formulaResultPresentation(isDark: Bool) -> (String, NSColor) {
        guard let activeCell else {
            return ("", isDark ? NSColor(calibratedWhite: 0.80, alpha: 1) : .secondaryLabelColor)
        }

        let rawValue = documentValue(atDisplayRow: activeCell.row, column: activeCell.column)
        let columnTitle = headerTitle(forColumn: activeCell.column)

        if CSVGridFormula.expression(from: rawValue) != nil {
            switch computedValue(for: activeCell) {
            case .evaluating:
                return ("…", isDark ? NSColor(calibratedWhite: 0.80, alpha: 1) : .secondaryLabelColor)
            case .value(let value):
                return (value.isEmpty ? "Result" : "→ \(displayText(for: value))", isDark ? NSColor(calibratedWhite: 0.80, alpha: 1) : .secondaryLabelColor)
            case .error(let message):
                return ("⚠︎ \(message)", .systemRed)
            }
        }

        return (columnTitle, isDark ? NSColor(calibratedWhite: 0.76, alpha: 1) : .tertiaryLabelColor)
    }

    private func updateFilterFieldFrame() {
        guard !topChromeView.isHidden else { return }
        let filterWidth: CGFloat = 180
        filterField.frame = NSRect(
            x: max(110, topChromeView.bounds.width - filterWidth - 10),
            y: 10,
            width: filterWidth,
            height: 24
        )
    }

    private func updateFormulaFieldFrame() {
        guard isFormulaFieldEnabled, !topChromeView.isHidden else { return }
        let resultText = formulaResultPresentation(isDark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua).0
        let resultWidth: CGFloat = min(160, max(40, measuredWidth(for: resultText, font: .systemFont(ofSize: 11)) + 8))
        let fieldX: CGFloat = 102
        let filterWidth: CGFloat = 180
        let fieldRightInset = filterWidth + resultWidth + 34
        let fieldWidth = max(80, topChromeView.bounds.width - fieldX - fieldRightInset)
        formulaField.frame = NSRect(x: fieldX, y: 14, width: fieldWidth, height: 16)
    }

    private func measuredWidth(for text: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private func drawSimpleText(_ text: String, in rect: NSRect, color: NSColor, font: NSFont, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        NSAttributedString(string: text, attributes: attributes).draw(in: rect)
    }

    private func updateFormulaBar() {
        guard isFormulaFieldEnabled else {
            isUpdatingFormulaField = true
            formulaField.stringValue = ""
            isUpdatingFormulaField = false
            updateTopChromeFormulaSubviews()
            topChromeView.needsDisplay = true
            return
        }

        guard let activeCell else {
            isUpdatingFormulaField = true
            formulaField.stringValue = ""
            isUpdatingFormulaField = false
            topChromeView.needsDisplay = true
            updateFormulaFieldFrame()
            return
        }

        let rawValue = documentValue(atDisplayRow: activeCell.row, column: activeCell.column)
        guard formulaField.currentEditor() == nil else {
            topChromeView.needsDisplay = true
            updateFormulaFieldFrame()
            return
        }
        isUpdatingFormulaField = true
        formulaField.stringValue = rawValue
        isUpdatingFormulaField = false
        topChromeView.needsDisplay = true
        updateFormulaFieldFrame()
    }

    private func commitFormulaBarEdit(navigation: CSVNativeGridMovement? = nil) {
        guard let target = formulaBarTargetCell ?? activeCell else { return }
        formulaBarTargetCell = nil
        hideCompletion()
        commitEditorValue(formulaField.stringValue, navigation: navigation, targetCell: target)
        updateFormulaBar()
    }

    private func updateCompletionsForCurrentResponder() {
        if formulaField.currentEditor() != nil {
            updateFormulaFieldCompletion()
        } else if window?.firstResponder === editorView.textView {
            updateEditorCompletion()
        } else {
            hideCompletion()
        }
    }

    private func updateFormulaFieldCompletion() {
        guard let editor = formulaField.currentEditor() as? NSTextView,
              let activeCell else {
            hideCompletion()
            return
        }
        let format = document.columns.indices.contains(activeCell.column) ? document.columns[activeCell.column].format : nil
        updateCompletion(text: formulaField.stringValue, selectedRange: editor.selectedRange(), anchorView: formulaField, cell: activeCell, columnFormat: format, target: .formulaBar)
    }

    private func updateEditorCompletion() {
        guard let editingCell else {
            hideCompletion()
            return
        }
        let format = document.columns.indices.contains(editingCell.column) ? document.columns[editingCell.column].format : nil
        updateCompletion(text: editorView.currentText, selectedRange: editorView.textView.selectedRange(), anchorView: editorView, cell: editingCell, columnFormat: format, target: .cellEditor)
    }

    private func updateCompletion(text: String, selectedRange: NSRange, anchorView: NSView, cell: CSVNativeGridCellAddress, columnFormat: String?, target: CSVGridCompletionTarget) {
        guard let request = completionRequest(for: text, selectedRange: selectedRange, columnFormat: columnFormat) else {
            hideCompletion()
            return
        }

        let items = completionItems(for: request)
        guard !items.isEmpty else {
            hideCompletion()
            return
        }

        completionContext = CSVGridCompletionContext(target: target, items: items, selectedIndex: 0, replacementRange: request.replacementRange, appendSuffix: request.appendSuffix)
        completionView.items = items
        completionView.selectedIndex = 0
        completionView.isHidden = false
        let anchorRect = convert(anchorView.bounds, from: anchorView)
        completionView.anchorRect = anchorRect
        updateCompletionFrameIfNeeded()
    }

    private func updateCompletionFrameIfNeeded() {
        guard let completionContext, !completionView.isHidden else { return }
        let anchorRect = completionView.anchorRect
        let maxWidth: CGFloat = min(max(280, anchorRect.width), 420)
        let preferredHeight = min(CGFloat(completionContext.items.count) * 24 + 8, 220)
        let x = max(8, min(bounds.width - maxWidth - 8, anchorRect.minX))
        let y = min(bounds.height - preferredHeight - 8, anchorRect.maxY + 4)
        completionView.frame = NSRect(x: x, y: y, width: maxWidth, height: preferredHeight)
    }

    private func hideCompletion() {
        completionContext = nil
        completionView.isHidden = true
    }

    private func moveCompletionSelection(delta: Int) {
        guard var completionContext, !completionContext.items.isEmpty else { return }
        let count = completionContext.items.count
        completionContext.selectedIndex = max(0, min(count - 1, completionContext.selectedIndex + delta))
        self.completionContext = completionContext
        completionView.selectedIndex = completionContext.selectedIndex
    }

    private func acceptSelectedCompletion() {
        guard let completionContext,
              completionContext.items.indices.contains(completionContext.selectedIndex) else { return }
        acceptCompletion(completionContext.items[completionContext.selectedIndex])
    }

    private func acceptCompletion(_ item: CSVGridCompletionItem) {
        guard let completionContext else { return }
        switch completionContext.target {
        case .formulaBar:
            applyCompletion(item, to: formulaField, replacementRange: completionContext.replacementRange, appendSuffix: completionContext.appendSuffix)
            hideCompletion()
            commitFormulaBarEdit()
            suppressFormulaBarCommitOnEndEditing = true
            window?.makeFirstResponder(canvasView)
        case .cellEditor:
            editorView.applyCompletion(item, replacementRange: completionContext.replacementRange, appendSuffix: completionContext.appendSuffix)
            hideCompletion()
            commitEditorValue(editorView.currentText, navigation: nil)
            window?.makeFirstResponder(canvasView)
        }
    }

    private func applyCompletion(_ item: CSVGridCompletionItem, to field: NSTextField, replacementRange: NSRange, appendSuffix: String?) {
        let nsText = field.stringValue as NSString
        let suffix = appendSuffix ?? ""
        let replacement = item.insertText + suffix
        let updated = nsText.replacingCharacters(in: replacementRange, with: replacement)
        field.stringValue = updated
        if let editor = field.currentEditor() as? NSTextView {
            let caret = replacementRange.location + (replacement as NSString).length
            editor.string = updated
            editor.setSelectedRange(NSRange(location: caret, length: 0))
        }
    }

    private func completionRequest(for text: String, selectedRange: NSRange, columnFormat: String?) -> CSVGridCompletionRequest? {
        let nsText = text as NSString
        let caret = min(max(0, selectedRange.location), nsText.length)
        let prefix = nsText.substring(to: caret) as NSString

        let wikilinkOpen = prefix.range(of: "[[", options: .backwards)
        if wikilinkOpen.location != NSNotFound {
            let queryStart = wikilinkOpen.location + wikilinkOpen.length
            let trailingPrefix = prefix.substring(from: queryStart)
            if !trailingPrefix.contains("]]" ) {
                let fullSuffix = nsText.substring(from: queryStart)
                return CSVGridCompletionRequest(
                    kind: .wikilink,
                    query: trailingPrefix,
                    replacementRange: NSRange(location: queryStart, length: caret - queryStart),
                    appendSuffix: fullSuffix.contains("]]" ) ? nil : "]]"
                )
            }
        }

        let formulaOpen = prefix.range(of: "{{", options: .backwards)
        if formulaOpen.location != NSNotFound {
            let queryStart = formulaOpen.location + formulaOpen.length
            let trailingPrefix = prefix.substring(from: queryStart)
            if !trailingPrefix.contains("}}") {
                let fullSuffix = nsText.substring(from: queryStart)
                return CSVGridCompletionRequest(
                    kind: .formula,
                    query: trailingPrefix.trimmingCharacters(in: .whitespaces),
                    replacementRange: NSRange(location: queryStart, length: caret - queryStart),
                    appendSuffix: fullSuffix.contains("}}") ? nil : "}}"
                )
            }
        }

        if columnFormat?.lowercased() == "status" {
            let query = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultStatuses = ["todo", "doing", "done", "blocked", "cancelled"]
            let normalizedStatuses = Set((defaultStatuses + document.statusColors.keys).map { $0.lowercased() })
            if !query.isEmpty, normalizedStatuses.contains(query.lowercased()) {
                return nil
            }
            return CSVGridCompletionRequest(
                kind: .status,
                query: query,
                replacementRange: NSRange(location: 0, length: caret),
                appendSuffix: nil
            )
        }

        return nil
    }

    private func completionItems(for request: CSVGridCompletionRequest) -> [CSVGridCompletionItem] {
        switch request.kind {
        case .wikilink:
            let suggestions = wikilinkSuggestionsProvider?(request.query, sourceRelativePath) ?? []
            return suggestions.map { CSVGridCompletionItem(label: $0.label, insertText: $0.insertText, detail: $0.detail) }
        case .status:
            let defaults = ["todo", "doing", "done", "blocked", "cancelled"]
            let candidates = Array(Set(defaults + document.statusColors.keys)).sorted()
            let normalized = request.query.lowercased()
            return candidates
                .filter { normalized.isEmpty || $0.lowercased().contains(normalized) }
                .map { CSVGridCompletionItem(label: $0, insertText: $0, detail: "status") }
        case .formula:
            let functions = [
                CSVGridCompletionItem(label: "min", insertText: "min()", detail: "Minimum"),
                CSVGridCompletionItem(label: "max", insertText: "max()", detail: "Maximum"),
                CSVGridCompletionItem(label: "round", insertText: "round()", detail: "Round"),
                CSVGridCompletionItem(label: "concat", insertText: "concat()", detail: "Join strings"),
                CSVGridCompletionItem(label: "coalesce", insertText: "coalesce()", detail: "First non-empty value"),
                CSVGridCompletionItem(label: "iff", insertText: "iff()", detail: "Conditional")
            ]
            let columns = document.columns.map { column in
                CSVGridCompletionItem(label: column.title, insertText: "row[\"\(column.title)\"]", detail: "column")
            }
            let normalized = request.query.lowercased()
            return (functions + columns).filter { normalized.isEmpty || $0.label.lowercased().contains(normalized) }
        }
    }

    private func publishDocumentChange() {
        guard !isApplyingLoadedDocument else { return }
        onDocumentChange?(document.serializedSnapshot())
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field == formulaField else { return }
        formulaBarTargetCell = activeCell
        updateFormulaFieldCompletion()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }

        if field == formulaField {
            guard !isUpdatingFormulaField else { return }
            updateFormulaFieldCompletion()
            return
        }

        if field == filterField {
            debugLog("controlTextDidChange filterField")
            applyFilter()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field == formulaField else { return }
        if suppressFormulaBarCommitOnEndEditing {
            suppressFormulaBarCommitOnEndEditing = false
            return
        }
        guard !isUpdatingFormulaField else { return }
        commitFormulaBarEdit()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control == formulaField else { return false }

        if completionContext != nil {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                moveCompletionSelection(delta: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                moveCompletionSelection(delta: 1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                hideCompletion()
                return true
            default:
                if isCompletionAcceptCommand(commandSelector) {
                    acceptSelectedCompletion()
                    return true
                }
            }
        }

        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            suppressFormulaBarCommitOnEndEditing = true
            commitFormulaBarEdit(navigation: .tabForward)
            window?.makeFirstResponder(canvasView)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            suppressFormulaBarCommitOnEndEditing = true
            commitFormulaBarEdit(navigation: .tabBackward)
            window?.makeFirstResponder(canvasView)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            suppressFormulaBarCommitOnEndEditing = true
            hideCompletion()
            updateFormulaBar()
            window?.makeFirstResponder(canvasView)
            return true
        default:
            if isVerticalCommitCommand(commandSelector) {
                let navigation: CSVNativeGridMovement = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .up : .down
                suppressFormulaBarCommitOnEndEditing = true
                commitFormulaBarEdit(navigation: navigation)
                window?.makeFirstResponder(canvasView)
                return true
            }
            return false
        }
    }

    private func handleEditorCompletionCommand(_ selector: Selector) -> Bool {
        guard completionContext != nil else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveCompletionSelection(delta: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveCompletionSelection(delta: 1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hideCompletion()
            return true
        default:
            if isCompletionAcceptCommand(selector) {
                acceptSelectedCompletion()
                return true
            }
            return false
        }
    }

    private func isCompletionAcceptCommand(_ selector: Selector) -> Bool {
        let command = NSStringFromSelector(selector)
        return command == NSStringFromSelector(#selector(NSResponder.insertTab(_:))) ||
            command == NSStringFromSelector(#selector(NSResponder.insertNewline(_:))) ||
            command == NSStringFromSelector(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))) ||
            command == "insertLineBreak:" ||
            command == "insertParagraphSeparator:"
    }

    private func isVerticalCommitCommand(_ selector: Selector) -> Bool {
        let command = NSStringFromSelector(selector)
        return command == NSStringFromSelector(#selector(NSResponder.insertNewline(_:))) ||
            command == NSStringFromSelector(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))) ||
            command == "insertLineBreak:" ||
            command == "insertParagraphSeparator:"
    }

    private func typingSeed(from event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option),
              let characters = event.characters,
              characters.count == 1,
              let scalar = characters.unicodeScalars.first,
              scalar.value >= 0x20,
              scalar != "\t",
              !CharacterSet.newlines.contains(scalar),
              scalar != "\u{7F}" else {
            return nil
        }
        return characters
    }

    private func clampedSelection(_ selection: CSVNativeGridSelection?) -> CSVNativeGridSelection? {
        guard let selection,
              let anchor = clampedCellAddress(selection.anchor),
              let focus = clampedCellAddress(selection.focus) else {
            return nil
        }
        return CSVNativeGridSelection(anchor: anchor, focus: focus)
    }

    private func captureUndoSnapshot() -> CSVGridUndoSnapshot {
        CSVGridUndoSnapshot(document: document, selection: selection, filterText: filterField.stringValue)
    }

    private func registerUndoRestore(actionName: String, restoreState: CSVGridUndoSnapshot, oppositeState: CSVGridUndoSnapshot) {
        gridUndoManager.registerUndo(withTarget: self) { target in
            target.restoreUndoSnapshot(restoreState)
            target.registerUndoRestore(actionName: actionName, restoreState: oppositeState, oppositeState: restoreState)
        }
        gridUndoManager.setActionName(actionName)
    }

    private func restoreUndoSnapshot(_ snapshot: CSVGridUndoSnapshot) {
        endEditing(commit: false)
        document = snapshot.document
        filterField.stringValue = snapshot.filterText
        rebuildFilteredRows()
        formulaComputationCache.removeAll()
        completionContext = nil
        rebuildColumnMetrics()
        selection = clampedSelection(snapshot.selection)
        dragAnchor = selection?.anchor
        editingCell = nil
        clearHeaderDragState()
        updateHeaderMetrics()
        updateCanvasFrame()
        updateChromeVisibility()
        invalidateGridDisplay()
        updateFormulaBar()
        publishDocumentChange()
    }

    private func performUndoableMutation(actionName: String, mutation: () -> Void) {
        let before = captureUndoSnapshot()
        mutation()
        let after = captureUndoSnapshot()
        registerUndoRestore(actionName: actionName, restoreState: before, oppositeState: after)
        publishDocumentChange()
    }

    @objc func undo(_ sender: Any?) {
        gridUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        gridUndoManager.redo()
    }

    private func promptForHeaderRename(column: Int) {
        let alert = NSAlert()
        alert.messageText = "Edit Header"
        alert.informativeText = "Rename column \(spreadsheetColumnLabel(for: column))."
        alert.alertStyle = .informational
        let field = NSTextField(string: headerTitle(forColumn: column))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newTitle = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        performUndoableMutation(actionName: "Rename Header") {
            document.ensureColumnCount(atLeast: column + 1)
            document.columns[column].title = newTitle.isEmpty ? spreadsheetColumnLabel(for: column) : newTitle
            rebuildColumnMetrics()
            updateHeaderMetrics()
            updateCanvasFrame()
            selectColumn(column)
        }
    }

    private func confirmDeleteColumn(_ column: Int) {
        let alert = NSAlert()
        alert.messageText = "Delete Column?"
        alert.informativeText = "Delete column \(headerTitle(forColumn: column)) and all of its cell values?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performDeleteColumn(at: column)
    }

    private func confirmDeleteRow(_ documentRow: Int) {
        let alert = NSAlert()
        alert.messageText = "Delete Row?"
        alert.informativeText = "Delete row \(documentRow + 1) and all of its cell values?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performDeleteRow(atDocumentRow: documentRow)
    }

    private func performInsertColumn(at column: Int) {
        performUndoableMutation(actionName: "Insert Column") {
            document.insertColumn(at: column)
            rebuildColumnMetrics()
            updateHeaderMetrics()
            updateCanvasFrame()
            selectColumn(min(column, max(0, displayedColumnCount - 1)))
        }
    }

    private func performDeleteColumn(at column: Int) {
        guard document.columns.indices.contains(column) else { return }
        performUndoableMutation(actionName: "Delete Column") {
            _ = document.removeColumn(at: column)
            rebuildColumnMetrics()
            updateHeaderMetrics()
            updateCanvasFrame()
            let targetColumn = max(0, min(column, max(0, displayedColumnCount - 1)))
            selectColumn(targetColumn)
        }
    }

    private func performMoveColumn(from sourceColumn: Int, to insertionIndex: Int) {
        let adjustedDestination = sourceColumn < insertionIndex ? insertionIndex - 1 : insertionIndex
        guard adjustedDestination != sourceColumn,
              adjustedDestination >= 0,
              adjustedDestination <= document.columnCount else { return }
        performUndoableMutation(actionName: "Move Column") {
            document.moveColumn(from: sourceColumn, to: insertionIndex)
            rebuildColumnMetrics()
            updateHeaderMetrics()
            updateCanvasFrame()
            selectColumn(min(max(0, adjustedDestination), max(0, displayedColumnCount - 1)))
        }
    }

    private func performInsertRow(atDocumentRow row: Int) {
        performUndoableMutation(actionName: "Insert Row") {
            document.insertRow(at: row)
            rebuildFilteredRows()
            updateHeaderMetrics()
            updateCanvasFrame()
            let displayRow = displayRowIndex(forDocumentRow: row) ?? min(row, max(0, displayedRowCount - 1))
            selectRow(displayRow)
        }
    }

    private func performDeleteRow(atDocumentRow row: Int) {
        guard row >= 0, row < document.rowCount else { return }
        performUndoableMutation(actionName: "Delete Row") {
            _ = document.removeRow(at: row)
            rebuildFilteredRows()
            updateHeaderMetrics()
            updateCanvasFrame()
            let fallbackDocumentRow = min(row, max(0, document.rowCount - 1))
            let displayRow = displayRowIndex(forDocumentRow: fallbackDocumentRow) ?? min(fallbackDocumentRow, max(0, displayedRowCount - 1))
            selectRow(displayRow)
        }
    }

    private func performMoveRow(fromDocumentRow sourceDocumentRow: Int, toDisplayInsertionIndex insertionIndex: Int) {
        guard !isFilterActive,
              sourceDocumentRow >= 0,
              sourceDocumentRow < document.rowCount else { return }
        let destinationDocumentRow = min(max(0, insertionIndex), document.rowCount)
        let adjustedDestination = sourceDocumentRow < destinationDocumentRow ? destinationDocumentRow - 1 : destinationDocumentRow
        guard adjustedDestination != sourceDocumentRow else { return }
        performUndoableMutation(actionName: "Move Row") {
            document.moveRow(from: sourceDocumentRow, to: destinationDocumentRow)
            rebuildFilteredRows()
            updateHeaderMetrics()
            updateCanvasFrame()
            let displayRow = displayRowIndex(forDocumentRow: adjustedDestination) ?? min(adjustedDestination, max(0, displayedRowCount - 1))
            selectRow(displayRow)
        }
    }

    @objc private func renameHeaderFromMenu(_ sender: Any?) {
        guard let contextMenuColumn else { return }
        promptForHeaderRename(column: contextMenuColumn)
    }

    @objc private func insertColumnLeftFromMenu(_ sender: Any?) {
        guard let contextMenuColumn else { return }
        performInsertColumn(at: contextMenuColumn)
    }

    @objc private func insertColumnRightFromMenu(_ sender: Any?) {
        guard let contextMenuColumn else { return }
        performInsertColumn(at: contextMenuColumn + 1)
    }

    @objc private func deleteColumnFromMenu(_ sender: Any?) {
        guard let contextMenuColumn else { return }
        confirmDeleteColumn(contextMenuColumn)
    }

    @objc private func insertRowAboveFromMenu(_ sender: Any?) {
        guard let contextMenuRow else { return }
        performInsertRow(atDocumentRow: contextMenuRow)
    }

    @objc private func insertRowBelowFromMenu(_ sender: Any?) {
        guard let contextMenuRow else { return }
        performInsertRow(atDocumentRow: contextMenuRow + 1)
    }

    @objc private func deleteRowFromMenu(_ sender: Any?) {
        guard let contextMenuRow else { return }
        confirmDeleteRow(contextMenuRow)
    }

    private func makeMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openContextMenuLink(_ sender: Any?) {
        guard let contextMenuLinkTarget else { return }
        onOpenWikilink?(contextMenuLinkTarget)
    }

    @objc private func openContextMenuLinkInNewTab(_ sender: Any?) {
        guard let contextMenuLinkTarget else { return }
        onOpenWikilinkInNewTab?(contextMenuLinkTarget)
    }

    @objc private func copyFromMenu(_ sender: Any?) {
        copySelection()
    }

    @objc private func pasteFromMenu(_ sender: Any?) {
        pasteSelection()
    }

    @objc private func clearFromMenu(_ sender: Any?) {
        clearSelectionContents()
    }
}

private struct CSVNativeGridCellAddress: Hashable {
    var row: Int
    var column: Int
}

private struct CSVGridUndoSnapshot {
    var document: CSVGridDocument
    var selection: CSVNativeGridSelection?
    var filterText: String
}

private enum CSVGridHeaderDragState {
    case column(sourceColumn: Int, insertionIndex: Int)
    case row(sourceDisplayRow: Int, sourceDocumentRow: Int, insertionIndex: Int)
}

private struct CSVNativeGridSelection: Equatable {
    let anchor: CSVNativeGridCellAddress
    let focus: CSVNativeGridCellAddress

    var rowRange: ClosedRange<Int> {
        min(anchor.row, focus.row)...max(anchor.row, focus.row)
    }

    var columnRange: ClosedRange<Int> {
        min(anchor.column, focus.column)...max(anchor.column, focus.column)
    }

    var topLeft: CSVNativeGridCellAddress {
        CSVNativeGridCellAddress(row: rowRange.lowerBound, column: columnRange.lowerBound)
    }

    var bottomRight: CSVNativeGridCellAddress {
        CSVNativeGridCellAddress(row: rowRange.upperBound, column: columnRange.upperBound)
    }

    func contains(_ address: CSVNativeGridCellAddress) -> Bool {
        rowRange.contains(address.row) && columnRange.contains(address.column)
    }
}

private enum CSVNativeGridMovement {
    case left
    case right
    case up
    case down
    case tabForward
    case tabBackward
}

private enum CSVGridCompletionKind {
    case wikilink
    case status
    case formula
}

private enum CSVGridCompletionTarget {
    case formulaBar
    case cellEditor
}

private struct CSVGridCompletionItem {
    let label: String
    let insertText: String
    let detail: String
}

private struct CSVGridCompletionRequest {
    let kind: CSVGridCompletionKind
    let query: String
    let replacementRange: NSRange
    let appendSuffix: String?
}

private struct CSVGridCompletionContext {
    let target: CSVGridCompletionTarget
    let items: [CSVGridCompletionItem]
    var selectedIndex: Int
    let replacementRange: NSRange
    let appendSuffix: String?
}

private enum CSVNativeGridHitTarget {
    case background
    case cell(CSVNativeGridCellAddress)
    case link(CSVNativeGridCellAddress, String)

    var cellAddress: CSVNativeGridCellAddress? {
        switch self {
        case .cell(let address):
            return address
        case .link(let address, _):
            return address
        case .background:
            return nil
        }
    }
}

private enum CSVNativeGridCellDisplay {
    case text(String)
    case link(title: String, target: String)
    case status(title: String, color: NSColor)
    case tags([String])
}

private final class CSVGridPinnedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        constrained.origin.x = max(0, constrained.origin.x)
        constrained.origin.y = max(0, constrained.origin.y)

        if let documentView {
            let maxX = max(0, documentView.frame.width - proposedBounds.width)
            let maxY = max(0, documentView.frame.height - proposedBounds.height)
            constrained.origin.x = min(constrained.origin.x, maxX)
            constrained.origin.y = min(constrained.origin.y, maxY)
        }

        return constrained
    }

    override func resetCursorRects() {}
}

private class CSVGridPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() {}
}

private final class CSVGridPassthroughLabel: NSTextField {
    init(string: String) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        isSelectable = false
        stringValue = string
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() {}
}

private final class CSVGridTopChromeView: NSView {
    weak var owner: CSVGridNativePreviewContainerView?

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .csvGridCell)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.handleTopChromeMouseDown(event: event, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        owner?.handleTopChromeMouseDragged(event: event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.handleTopChromeMouseUp(event: event, in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.topChromeMenu(for: event, in: self)
    }

    override var undoManager: UndoManager? {
        owner?.undoManager
    }

    @objc func undo(_ sender: Any?) {
        owner?.undo(sender)
    }

    @objc func redo(_ sender: Any?) {
        owner?.redo(sender)
    }
}

private final class CSVGridRowHeaderView: NSView {
    weak var owner: CSVGridNativePreviewContainerView?

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .csvGridCell)
    }

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawRowHeaders(dirtyRect: dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.handleRowHeaderMouseDown(event: event, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        owner?.handleRowHeaderMouseDragged(event: event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.handleRowHeaderMouseUp(event: event, in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.rowHeaderMenu(for: event, in: self)
    }

    override var undoManager: UndoManager? {
        owner?.undoManager
    }

    @objc func undo(_ sender: Any?) {
        owner?.undo(sender)
    }

    @objc func redo(_ sender: Any?) {
        owner?.redo(sender)
    }
}

private final class CSVGridBodyCanvasView: NSView {
    weak var owner: CSVGridNativePreviewContainerView?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { owner?.undoManager }

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawBody(dirtyRect: dirtyRect)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .csvGridCell)

        guard let owner,
              let rowRange = owner.visibleRowRange(in: visibleRect),
              let columnRange = owner.visibleColumnRange(in: visibleRect) else {
            return
        }

        for row in rowRange {
            for column in columnRange {
                let address = CSVNativeGridCellAddress(row: row, column: column)
                guard case .link = owner.display(for: address) else { continue }
                addCursorRect(owner.cellRect(for: address), cursor: .pointingHand)
            }
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) {
        owner?.handleMouseDown(event: event, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        owner?.handleMouseDragged(event: event, in: self)
    }

    override func mouseMoved(with event: NSEvent) {
        owner?.handleMouseMoved(event: event, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        owner?.handleMouseExited()
    }

    override func cursorUpdate(with event: NSEvent) {
        owner?.handleCursorUpdate(event: event, in: self)
    }

    override func keyDown(with event: NSEvent) {
        if owner?.handleKeyDown(event: event, in: self) != true {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(for: event, in: self)
    }

    @objc func copy(_ sender: Any?) {
        owner?.copySelection()
    }

    @objc func cut(_ sender: Any?) {
        owner?.cutSelection()
    }

    @objc func paste(_ sender: Any?) {
        owner?.pasteSelection()
    }

    override func deleteBackward(_ sender: Any?) {
        owner?.clearSelectionContents()
    }

    override func deleteForward(_ sender: Any?) {
        owner?.clearSelectionContents()
    }

    override func selectAll(_ sender: Any?) {
        owner?.selectAllCells()
    }

    @objc func undo(_ sender: Any?) {
        owner?.undo(sender)
    }

    @objc func redo(_ sender: Any?) {
        owner?.redo(sender)
    }
}

private final class CSVGridCompletionOverlayView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var items: [CSVGridCompletionItem] = [] {
        didSet { tableView.reloadData() }
    }
    var selectedIndex: Int = 0 {
        didSet {
            guard items.indices.contains(selectedIndex) else { return }
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
            tableView.reloadData()
        }
    }
    var anchorRect: NSRect = .zero
    var onChoose: ((CSVGridCompletionItem) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("completion")
        let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? CSVGridCompletionRowView) ?? CSVGridCompletionRowView(frame: .zero)
        view.identifier = identifier
        if items.indices.contains(row) {
            view.configure(item: items[row], selected: row == selectedIndex)
        }
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if tableView.selectedRow >= 0 {
            selectedIndex = tableView.selectedRow
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let local = convert(point, to: tableView)
        let row = tableView.row(at: local)
        guard items.indices.contains(row) else { return }
        selectedIndex = row
        onChoose?(items[row])
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.delegate = self
        tableView.dataSource = self
        scrollView.documentView = tableView

        addSubview(scrollView)
    }
}

private final class CSVGridCompletionRowView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(item: CSVGridCompletionItem, selected: Bool) {
        titleField.stringValue = item.label
        detailField.stringValue = item.detail
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
    }

    private func setup() {
        wantsLayer = true
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = .systemFont(ofSize: 10)
        detailField.textColor = .secondaryLabelColor
        addSubview(titleField)
        addSubview(detailField)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detailField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 0),
            detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detailField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }
}

private final class CSVGridCellEditorView: NSView, NSTextViewDelegate {
    let textView: NSTextView
    private let scrollView: NSScrollView
    var onCommit: ((String, CSVNativeGridMovement?) -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: (() -> Void)?
    var completionCommandHandler: ((Selector) -> Bool)?
    private(set) var currentText = ""

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: frameRect.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        textView = NSTextView(frame: .zero, textContainer: container)
        scrollView = NSScrollView(frame: .zero)
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        textView = NSTextView(frame: .zero, textContainer: container)
        scrollView = NSScrollView(frame: .zero)
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        textView.frame = scrollView.bounds.insetBy(dx: 0, dy: 0)
        textView.textContainer?.containerSize = NSSize(width: max(0, scrollView.contentSize.width), height: CGFloat.greatestFiniteMagnitude)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        guard !isHidden else { return }
        super.resetCursorRects()
    }

    func beginEditing(text: String, selectAll: Bool, replacementTextWasProvided: Bool) {
        isHidden = false
        textView.isEditable = true
        textView.isSelectable = true
        currentText = text
        textView.string = text
        if selectAll {
            textView.setSelectedRange(NSRange(location: 0, length: text.utf16.count))
        } else if replacementTextWasProvided {
            let length = text.utf16.count
            textView.setSelectedRange(NSRange(location: length, length: 0))
        }
    }

    func endEditingSession() {
        currentText = textView.string
        textView.isEditable = false
        textView.isSelectable = false
        frame = .zero
        isHidden = true
    }

    func textDidChange(_ notification: Notification) {
        currentText = textView.string
        onTextChange?()
    }

    func applyCompletion(_ item: CSVGridCompletionItem, replacementRange: NSRange, appendSuffix: String?) {
        let suffix = appendSuffix ?? ""
        let replacement = item.insertText + suffix
        let nsText = textView.string as NSString
        let updated = nsText.replacingCharacters(in: replacementRange, with: replacement)
        textView.string = updated
        currentText = updated
        let caret = replacementRange.location + (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        onTextChange?()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if completionCommandHandler?(commandSelector) == true {
            return true
        }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            onCommit?(textView.string, .tabForward)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            onCommit?(textView.string, .tabBackward)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            let command = NSStringFromSelector(commandSelector)
            let isVerticalCommit = command == NSStringFromSelector(#selector(NSResponder.insertNewline(_:))) ||
                command == NSStringFromSelector(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))) ||
                command == "insertLineBreak:" ||
                command == "insertParagraphSeparator:"
            guard isVerticalCommit else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                return false
            }
            let movement: CSVNativeGridMovement = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .up : .down
            onCommit?(textView.string, movement)
            return true
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 4
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 6
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            return shadow
        }()

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.lineFragmentPadding = 4
        textView.delegate = self
        scrollView.documentView = textView

        addSubview(scrollView)
    }
}

private extension NSColor {
    convenience init?(nativeCSVHex: String) {
        let cleaned = nativeCSVHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension NSCursor {
    static let csvGridCell: NSCursor = {
        let size = NSSize(width: 15, height: 15)
        let image = NSImage(size: size)
        image.lockFocus()

        let center = NSPoint(x: floor(size.width / 2), y: floor(size.height / 2))
        let outline = NSBezierPath()
        outline.lineCapStyle = .square
        outline.lineWidth = 5
        outline.move(to: NSPoint(x: center.x, y: 2))
        outline.line(to: NSPoint(x: center.x, y: size.height - 2))
        outline.move(to: NSPoint(x: 2, y: center.y))
        outline.line(to: NSPoint(x: size.width - 2, y: center.y))
        NSColor.white.setStroke()
        outline.stroke()

        let plus = NSBezierPath()
        plus.lineCapStyle = .square
        plus.lineWidth = 3
        plus.move(to: NSPoint(x: center.x, y: 2))
        plus.line(to: NSPoint(x: center.x, y: size.height - 2))
        plus.move(to: NSPoint(x: 2, y: center.y))
        plus.line(to: NSPoint(x: size.width - 2, y: center.y))
        NSColor.black.setStroke()
        plus.stroke()

        image.unlockFocus()
        return NSCursor(image: image, hotSpot: center)
    }()
}

