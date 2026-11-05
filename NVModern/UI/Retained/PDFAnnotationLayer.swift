import AppKit
import CryptoKit
import PDFKit

/// Annotations over a PDF, the native counterpart of the web editor's
/// annotation layer (`WebEditor/src/lib/plugins/annotations.ts`). It speaks the
/// same request protocol (`op` add/remove/list/reveal/answer/ask) and keeps the
/// same annotation shape, so the action and MCP layers don't care which surface
/// a document is on.
///
/// Marks are PDFKit annotations added to the in-memory document only; nvModern
/// never writes PDFs, so nothing reaches the file. Annotation specs persist per
/// file in Application Support.
@MainActor
final class PDFAnnotationLayer: NSObject {
    // MARK: Model

    struct Spec: Codable, Equatable {
        var id: String
        var label: String
        var style: String
        var color: String
        var author: String
        var quote: String
        var prefix: String?
        var suffix: String?
        var occurrence: Int?
        var note: String?
        var answer: String?
        var answeredBy: String?
        var answerStale: Bool?
    }

    private struct Placed {
        var spec: Spec
        var selection: PDFSelection?
    }

    private enum NotesMode {
        case margin
        case inline
    }

    static let styles = ["highlight", "underline", "box"]
    static let colors = ["yellow", "blue", "green", "pink", "purple", "orange", "red"]
    private static let marginMinimumWidth: CGFloat = 820
    private static let noteWidth: CGFloat = 260
    private static let columnReserve: CGFloat = 300
    private static let noteGap: CGFloat = 8
    private static let anchorContextLength = 32

    private weak var container: PDFAnnotationContainerView?
    private weak var pdfView: ZoomablePDFView?
    private let column = PDFAnnotationNotesView()
    private var document: PDFDocument?
    private var fileURL: URL?
    private var index: PDFTextIndex?
    private var joinedIndex: PDFTextIndex?
    private var items: [Placed] = []
    private let marks = PDFAnnotationMarksView()
    private var cards: [String: PDFAnnotationNoteCard] = [:]
    private var focusedId: String?
    private var mode: NotesMode?
    private var observers: [NSObjectProtocol] = []
    private var popover: NSPopover?

    // MARK: Hosting

    func install(container: PDFAnnotationContainerView, pdfView: ZoomablePDFView) {
        self.container = container
        self.pdfView = pdfView
        column.isHidden = true
        container.addSubview(marks)
        container.addSubview(column)
        marks.onBadgeClick = { [weak self] id in
            guard let self else { return }
            self.setFocus(self.focusedId == id ? nil : id)
        }
        container.onLayout = { [weak self] in self?.layoutContainer() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.layoutNotes()
        })
        observers.append(center.addObserver(forName: .PDFViewDocumentChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.observeScrolling()
            self?.layoutNotes()
        })
        observeScrolling()
    }

    func uninstall() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        popover?.close()
    }

    private var scrollObserver: NSObjectProtocol?

    private func observeScrolling() {
        guard let clipView = pdfView?.firstDescendant(ofType: NSScrollView.self)?.contentView else { return }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.layoutNotes()
        }
    }

    /// Re-places stored annotations whenever a document (re)loads.
    func documentDidLoad(_ document: PDFDocument?, fileURL: URL) {
        self.document = document
        self.fileURL = fileURL
        index = document.map { PDFTextIndex(document: $0, joinsHyphenatedWords: false) }
        joinedIndex = document.map { PDFTextIndex(document: $0, joinsHyphenatedWords: true) }
        focusedId = nil
        items = PDFAnnotationStore.load(for: fileURL).map { Placed(spec: $0, selection: anchor($0)) }
        redrawAll()
        syncCards()
        layoutContainer()
        observeScrolling()
    }

    // MARK: Requests

    /// Handles one request from the action layer; nil while no document is loaded.
    func handle(_ request: [String: ActionValue]) -> ActionValue? {
        guard document != nil, let fileURL else { return nil }
        let op = request["op"]?.stringValue ?? ""
        var response: [String: ActionValue] = ["path": .string(fileURL.path), "op": .string(op)]

        switch op {
        case "add":
            let inputs = request["annotations"]?.arrayValue?.compactMap(\.objectValue) ?? []
            let replace = request["replace"]
            let results = add(inputs, replace: replace)
            response["results"] = .array(results)
            if let reveal = request["reveal"] {
                let target = reveal.stringValue ?? (reveal.boolValue == true ? firstPlacedID(results) : nil)
                response["revealed"] = .bool(target.map(revealAnnotation) ?? false)
            }
        case "remove":
            response["removed"] = .int(remove(
                ids: request["ids"]?.arrayValue?.compactMap(\.stringValue),
                labels: request["labels"]?.arrayValue?.compactMap(\.stringValue),
                author: request["author"]?.stringValue
            ))
        case "reveal":
            response["revealed"] = .bool(request["target"]?.stringValue.map(revealAnnotation) ?? false)
        case "answer":
            let target = request["target"]?.stringValue ?? ""
            let answered = answer(target, text: request["answer"]?.stringValue ?? "", by: request["answeredBy"]?.stringValue)
            response["answered"] = .bool(answered)
            if answered, request["reveal"]?.boolValue != false { _ = revealAnnotation(target) }
        case "list":
            let author = request["author"]?.stringValue
            let unansweredOnly = request["unansweredOnly"]?.boolValue == true
            response["annotations"] = .array(items.filter { item in
                (author == nil || item.spec.author == author) &&
                    (!unansweredOnly || item.spec.answer == nil || item.spec.answerStale == true)
            }.map(snapshot))
        case "ask":
            response["performed"] = .bool(beginAsk())
        default:
            response["error"] = .string("unknown annotation op: \(op)")
        }
        return .object(response)
    }

    private func firstPlacedID(_ results: [ActionValue]) -> String? {
        for result in results {
            guard let object = result.objectValue else { continue }
            let status = object["status"]?.stringValue ?? ""
            if status == "anchored" || status == "ambiguous" { return object["id"]?.stringValue }
        }
        return nil
    }

    private func add(_ inputs: [[String: ActionValue]], replace: ActionValue?) -> [ActionValue] {
        if replace?.boolValue == true {
            items.removeAll()
        } else if let author = replace?.stringValue {
            items.removeAll { $0.spec.author == author }
        }

        var results: [ActionValue] = []
        var assigned: [String] = []
        for (offset, input) in inputs.enumerated() {
            guard let quote = input["quote"]?.stringValue,
                  !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                results.append(["id": .null, "label": .null, "status": "invalid", "message": "quote is required"])
                continue
            }
            let spec = makeSpec(input, quote: quote, assigned: assigned, offset: offset)
            assigned.append(spec.label)
            items.removeAll { $0.spec.id == spec.id }
            guard let match = find(spec) else {
                results.append(["id": .string(spec.id), "label": .string(spec.label), "status": "notFound",
                                "message": "quote not found in the document"])
                continue
            }
            items.append(Placed(spec: spec, selection: match.selection))
            let ambiguous = match.candidates > 1 && spec.prefix == nil && spec.suffix == nil && spec.occurrence == nil
            var result: [String: ActionValue] = [
                "id": .string(spec.id),
                "label": .string(spec.label),
                "status": .string(ambiguous ? "ambiguous" : "anchored"),
                "candidates": .int(match.candidates)
            ]
            if let page = firstPageNumber(match.selection) { result["page"] = .int(page) }
            if ambiguous {
                result["message"] = "quote repeats; marked the first match. Pass prefix, suffix, or occurrence."
            }
            results.append(.object(result))
        }
        sortItems()
        commit()
        return results
    }

    private func makeSpec(_ input: [String: ActionValue], quote: String, assigned: [String], offset: Int) -> Spec {
        let author = input["author"]?.stringValue == "user" ? "user" : "agent"
        let label = Self.labelText(input["label"]).flatMap { $0.isEmpty ? nil : $0 } ?? nextLabel(author: author, assigned: assigned)
        let style = input["style"]?.stringValue.flatMap { Self.styles.contains($0) ? $0 : nil } ?? "highlight"
        let color = input["color"]?.stringValue.flatMap { Self.colors.contains($0) ? $0 : nil } ?? defaultColor(label, offset)
        let id = input["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "\(author):\(label)"
        return Spec(
            id: id,
            label: label,
            style: style,
            color: color,
            author: author,
            quote: quote,
            prefix: input["prefix"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            suffix: input["suffix"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            occurrence: input["occurrence"].flatMap(Self.intValue),
            note: input["note"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            answer: input["answer"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            answeredBy: input["answeredBy"]?.stringValue,
            answerStale: input["answerStale"]?.boolValue == true ? true : nil
        )
    }

    private static func labelText(_ value: ActionValue?) -> String? {
        switch value {
        case .string(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .int(let number): return String(number)
        default: return nil
        }
    }

    private static func intValue(_ value: ActionValue) -> Int? {
        switch value {
        case .int(let number): return number
        case .double(let number): return Int(number)
        default: return nil
        }
    }

    private func nextLabel(author: String, assigned: [String]) -> String {
        let labels = items.filter { $0.spec.author == author }.map(\.spec.label) + assigned
        let highest = labels.compactMap { Int($0.hasPrefix("Q") ? String($0.dropFirst()) : $0) }.max() ?? 0
        return author == "user" ? "Q\(highest + 1)" : String(highest + 1)
    }

    private func defaultColor(_ label: String, _ offset: Int) -> String {
        let digits = label.drop { !$0.isNumber }
        let index = Int(digits).map { $0 - 1 } ?? offset
        return Self.colors[max(0, index) % Self.colors.count]
    }

    private func remove(ids: [String]?, labels: [String]?, author: String?) -> Int {
        let before = items.count
        items.removeAll { item in
            (ids.map { $0.contains(item.spec.id) } ?? true) &&
                (labels.map { $0.contains(item.spec.label) } ?? true) &&
                (author.map { $0 == item.spec.author } ?? true)
        }
        let removed = before - items.count
        if removed > 0 { commit() }
        return removed
    }

    private func item(_ idOrLabel: String) -> Int? {
        items.firstIndex { $0.spec.id == idOrLabel } ?? items.firstIndex { $0.spec.label == idOrLabel }
    }

    private func answer(_ idOrLabel: String, text: String, by: String?) -> Bool {
        guard let position = item(idOrLabel) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        items[position].spec.answer = trimmed.isEmpty ? nil : text
        items[position].spec.answeredBy = trimmed.isEmpty ? nil : by
        items[position].spec.answerStale = nil
        commit()
        return true
    }

    /// Same rule as the text editor: an answered question that changes keeps
    /// its answer, marked stale, and goes back to the agent.
    private func editNote(_ id: String, text: String) {
        guard let position = item(id) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (items[position].spec.note ?? "") else { return }
        items[position].spec.note = trimmed.isEmpty ? nil : trimmed
        if items[position].spec.answer != nil { items[position].spec.answerStale = true }
        commit()
    }

    private func snapshot(_ item: Placed) -> ActionValue {
        var result: [String: ActionValue] = [
            "id": .string(item.spec.id),
            "label": .string(item.spec.label),
            "style": .string(item.spec.style),
            "color": .string(item.spec.color),
            "author": .string(item.spec.author),
            "quote": .string(item.spec.quote),
            "detached": .bool(item.selection == nil),
            "text": item.selection?.string.map { .string($0) } ?? .null,
            "line": .null,
            "endLine": .null
        ]
        if let note = item.spec.note { result["note"] = .string(note) }
        if let answer = item.spec.answer { result["answer"] = .string(answer) }
        if let by = item.spec.answeredBy { result["answeredBy"] = .string(by) }
        if item.spec.answerStale == true { result["answerStale"] = .bool(true) }
        if let selection = item.selection {
            let pages = selection.pages.compactMap { document?.index(for: $0) }
            if let first = pages.min() { result["page"] = .int(first + 1) }
            if let last = pages.max() { result["endPage"] = .int(last + 1) }
        }
        return .object(result)
    }

    private func firstPageNumber(_ selection: PDFSelection) -> Int? {
        selection.pages.compactMap { document?.index(for: $0) }.min().map { $0 + 1 }
    }

    private func sortItems() {
        func key(_ item: Placed) -> (Int, CGFloat) {
            guard let selection = item.selection, let page = selection.pages.first, let document else {
                return (Int.max, 0)
            }
            return (document.index(for: page), -selection.bounds(for: page).maxY)
        }
        items.sort { key($0) < key($1) }
    }

    private func find(_ spec: Spec) -> PDFTextIndex.Match? {
        index?.find(spec) ?? joinedIndex?.find(spec)
    }

    private func anchor(_ spec: Spec) -> PDFSelection? {
        find(spec)?.selection
    }

    /// Persist, redraw, and re-place notes after any change to the annotations.
    private func commit() {
        if let fileURL { PDFAnnotationStore.save(items.map(\.spec), for: fileURL) }
        if let focusedId, item(focusedId) == nil { self.focusedId = nil }
        redrawAll()
        syncCards()
        layoutContainer()
    }

    // MARK: Drawing

    private static func nsColor(_ name: String) -> NSColor {
        switch name {
        case "blue": return .systemBlue
        case "green": return .systemGreen
        case "pink": return .systemPink
        case "purple": return .systemPurple
        case "orange": return .systemOrange
        case "red": return .systemRed
        default: return .systemYellow
        }
    }

    /// Marks are drawn in an overlay above the PDF rather than as PDF
    /// annotations: in dark mode the page content is inverted and desaturated,
    /// which would turn every mark grey.
    private func redrawAll() {
        layoutMarks()
    }

    private func layoutMarks() {
        guard let pdfView else { return }
        marks.frame = pdfView.frame
        let visible = pdfView.bounds
        var drawnMarks: [PDFAnnotationMarksView.Mark] = []
        var badges: [PDFAnnotationMarksView.Badge] = []

        for item in items {
            guard let selection = item.selection else { continue }
            var rects: [NSRect] = []
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let bounds = line.bounds(for: page)
                    guard bounds.width > 0, bounds.height > 0 else { continue }
                    let inView = pdfView.convert(bounds, from: page)
                    guard inView.intersects(visible.insetBy(dx: 0, dy: -200)) || rects.isEmpty else { continue }
                    rects.append(marks.convert(inView, from: pdfView))
                }
            }
            guard let first = rects.first else { continue }
            let color = Self.nsColor(item.spec.color)
            drawnMarks.append(.init(rects: rects, style: item.spec.style, color: color, focused: item.spec.id == focusedId))
            badges.append(.init(id: item.spec.id, label: item.spec.label, color: color, anchor: first))
        }
        marks.update(marks: drawnMarks, badges: badges)
    }

    private func setFocus(_ id: String?) {
        guard focusedId != id else { return }
        focusedId = id
        syncCards()
        layoutNotes()
    }

    private func revealAnnotation(_ idOrLabel: String) -> Bool {
        guard let position = item(idOrLabel), let selection = items[position].selection else { return false }
        pdfView?.go(to: selection)
        setFocus(items[position].spec.id)
        return true
    }

    // MARK: Notes

    private var noteItems: [Placed] {
        items.filter { item in
            item.selection != nil &&
                !((item.spec.note ?? "").isEmpty && (item.spec.answer ?? "").isEmpty)
        }
    }

    private func syncCards() {
        let notes = noteItems
        let ids = Set(notes.map(\.spec.id))
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
        }
        for item in notes {
            let card = cards[item.spec.id] ?? {
                let card = PDFAnnotationNoteCard(width: Self.noteWidth)
                card.onRemove = { [weak self] id in _ = self?.remove(ids: [id], labels: nil, author: nil) }
                card.onEdit = { [weak self] id in self?.beginEdit(id) }
                card.onSelect = { [weak self] id in
                    guard let self else { return }
                    self.setFocus(self.focusedId == id ? nil : id)
                }
                column.addSubview(card)
                cards[item.spec.id] = card
                return card
            }()
            card.configure(
                id: item.spec.id,
                label: item.spec.label,
                color: Self.nsColor(item.spec.color),
                note: item.spec.note ?? "",
                answer: item.spec.answer,
                answeredBy: item.spec.answeredBy,
                answerStale: item.spec.answerStale == true,
                isReader: item.spec.author == "user",
                focused: item.spec.id == focusedId
            )
        }
    }

    /// Sizes the PDF and the notes column: beside the page when there's room
    /// for both, otherwise the PDF keeps the width and notes open on demand.
    func layoutContainer() {
        guard let container, let pdfView else { return }
        let bounds = container.bounds
        let hasNotes = !noteItems.isEmpty
        let nextMode: NotesMode? = hasNotes ? (bounds.width >= Self.marginMinimumWidth ? .margin : .inline) : nil
        mode = nextMode

        let pdfFrame: NSRect
        switch nextMode {
        case .margin:
            pdfFrame = NSRect(x: 0, y: 0, width: bounds.width - Self.columnReserve, height: bounds.height)
            column.frame = NSRect(x: pdfFrame.maxX, y: 0, width: Self.columnReserve, height: bounds.height)
            column.passesClicksThrough = false
        case .inline, nil:
            pdfFrame = bounds
            column.frame = bounds
            column.passesClicksThrough = true
        }
        if pdfView.frame != pdfFrame { pdfView.frame = pdfFrame }
        column.isHidden = nextMode == nil
        container.addSubview(marks, positioned: .above, relativeTo: pdfView)
        container.addSubview(column, positioned: .above, relativeTo: marks)
        layoutNotes()
    }

    private func layoutNotes() {
        layoutMarks()
        guard let pdfView, let mode, !column.isHidden else { return }

        func lineRect(_ selection: PDFSelection, last: Bool) -> NSRect? {
            let lines = selection.selectionsByLine()
            guard let line = last ? lines.last : lines.first, let page = line.pages.first else { return nil }
            let inView = pdfView.convert(line.bounds(for: page), from: page)
            return column.convert(inView, from: pdfView)
        }

        switch mode {
        case .margin:
            var placements: [(card: PDFAnnotationNoteCard, top: CGFloat)] = []
            for item in noteItems {
                guard let card = cards[item.spec.id], let selection = item.selection,
                      let rect = lineRect(selection, last: false) else { continue }
                card.isHidden = false
                placements.append((card, rect.minY))
            }
            placements.sort { $0.top < $1.top }
            var floor = -CGFloat.greatestFiniteMagnitude
            for placement in placements {
                let size = placement.card.fittingSize(width: Self.noteWidth)
                let top = max(placement.top, floor)
                placement.card.frame = NSRect(x: 20, y: top, width: Self.noteWidth, height: size.height)
                floor = top + size.height + Self.noteGap
            }
        case .inline:
            let width = min(column.bounds.width - 48, 520)
            for item in noteItems {
                guard let card = cards[item.spec.id] else { continue }
                guard item.spec.id == focusedId, let selection = item.selection,
                      let rect = lineRect(selection, last: true) else {
                    card.isHidden = true
                    continue
                }
                let size = card.fittingSize(width: width)
                card.isHidden = false
                card.frame = NSRect(x: max(24, min(rect.minX, column.bounds.width - width - 24)), y: rect.maxY + 6,
                                    width: width, height: size.height)
            }
        }
    }

    // MARK: Asking

    /// Opens the question box for the PDF's text selection.
    func beginAsk() -> Bool {
        guard let pdfView, let selection = pdfView.currentSelection,
              let quote = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty
        else {
            NSSound.beep()
            return false
        }
        var input: [String: ActionValue] = ["quote": .string(quote), "author": "user"]
        if let context = surroundingText(selection) {
            input["prefix"] = .string(context.prefix)
            input["suffix"] = .string(context.suffix)
        }
        showComposer(at: selection, initial: "", editing: false) { [weak self] text in
            guard let self else { return }
            var input = input
            if !text.isEmpty { input["note"] = .string(text) }
            let spec = self.makeSpec(input, quote: quote, assigned: [], offset: self.items.count)
            self.items.removeAll { $0.spec.id == spec.id }
            // The reader's selection is the anchor; the quote and context re-find it later.
            self.items.append(Placed(spec: spec, selection: selection))
            self.sortItems()
            self.commit()
            self.pdfView?.clearSelection()
        }
        return true
    }

    private func beginEdit(_ id: String) {
        guard let position = item(id), let selection = items[position].selection else { return }
        showComposer(at: selection, initial: items[position].spec.note ?? "", editing: true) { [weak self] text in
            self?.editNote(id, text: text)
        }
    }

    private func surroundingText(_ selection: PDFSelection) -> (prefix: String, suffix: String)? {
        guard let first = selection.pages.first, let last = selection.pages.last,
              let firstText = first.string as NSString?, let lastText = last.string as NSString?
        else { return nil }
        let start = selection.range(at: 0, on: first)
        let end = selection.range(at: selection.numberOfTextRanges(on: last) - 1, on: last)
        guard start.location != NSNotFound, end.location != NSNotFound else { return nil }
        let prefixStart = max(0, start.location - Self.anchorContextLength)
        let suffixEnd = min(lastText.length, NSMaxRange(end) + Self.anchorContextLength)
        return (
            firstText.substring(with: NSRange(location: prefixStart, length: start.location - prefixStart)),
            lastText.substring(with: NSRange(location: NSMaxRange(end), length: suffixEnd - NSMaxRange(end)))
        )
    }

    private func showComposer(at selection: PDFSelection, initial: String, editing: Bool, save: @escaping (String) -> Void) {
        guard let pdfView, let page = selection.selectionsByLine().last?.pages.first ?? selection.pages.first else { return }
        let lines = selection.selectionsByLine()
        let bounds = (lines.last ?? selection).bounds(for: page)
        let anchor = pdfView.convert(bounds, from: page)

        popover?.close()
        let composer = PDFAnnotationComposerController(initial: initial, editing: editing)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = composer
        composer.onSubmit = { [weak popover] text in
            popover?.close()
            save(text)
        }
        composer.onCancel = { [weak popover] in popover?.close() }
        self.popover = popover
        popover.show(relativeTo: anchor, of: pdfView, preferredEdge: .minY)
    }
}

// MARK: - Text index

/// The document's text with whitespace collapsed, compatibility forms folded
/// (ligatures) and soft hyphens dropped, mapped back to page character
/// positions. Quotes are normalised the same way, so a passage copied from
/// extracted text still anchors. A second index rejoins words hyphenated at a
/// line end ("para- graph"; PDFKit often turns the break into a space), tried
/// when the text as written has no match.
@MainActor
struct PDFTextIndex {
    struct Match {
        let selection: PDFSelection
        let candidates: Int
    }

    private struct Location {
        let page: Int
        let start: Int
        let end: Int
    }

    private let document: PDFDocument
    private let text: NSString
    private let map: [Location]

    let joinsHyphenatedWords: Bool

    init(document: PDFDocument, joinsHyphenatedWords: Bool) {
        self.document = document
        self.joinsHyphenatedWords = joinsHyphenatedWords
        var units: [unichar] = []
        var map: [Location] = []
        var pendingSpace: Location?
        var pendingHyphen: Location?
        var spaceSinceHyphen = false

        func append(_ string: String, at location: Location) {
            for unit in string.utf16 {
                units.append(unit)
                map.append(location)
            }
        }

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex), let pageText = page.string else { continue }
            let nsText = pageText as NSString
            nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length), options: .byComposedCharacterSequences) { substring, range, _, _ in
                guard let substring else { return }
                let location = Location(page: pageIndex, start: range.location, end: NSMaxRange(range))
                if substring.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                    if pendingSpace == nil { pendingSpace = location }
                    spaceSinceHyphen = true
                    return
                }
                if substring == "\u{00AD}" { return }
                if let hyphen = pendingHyphen {
                    pendingHyphen = nil
                    if spaceSinceHyphen, substring.first?.isLetter == true {
                        pendingSpace = nil
                    } else {
                        append("-", at: hyphen)
                    }
                }
                if let space = pendingSpace {
                    if !units.isEmpty { append(" ", at: space) }
                    pendingSpace = nil
                }
                let previousIsLetter = units.last.flatMap { Unicode.Scalar($0) }.map { CharacterSet.letters.contains($0) } ?? false
                if joinsHyphenatedWords, previousIsLetter, substring == "-" || substring == "\u{2010}" {
                    pendingHyphen = location
                    spaceSinceHyphen = false
                    return
                }
                append(substring.precomposedStringWithCompatibilityMapping, at: location)
            }
            // A page break is a line break for a hyphen ending the page.
            if pendingHyphen != nil { spaceSinceHyphen = true }
            if pendingSpace == nil {
                pendingSpace = Location(page: pageIndex, start: nsText.length, end: nsText.length)
            }
        }
        if let hyphen = pendingHyphen { append("-", at: hyphen) }

        self.text = NSString(characters: units, length: units.count)
        self.map = map
    }

    static func normalize(_ string: String, joinsHyphenatedWords: Bool) -> String {
        var result = ""
        var pendingSpace = false
        var pendingHyphen = false
        var spaceSinceHyphen = false
        for character in string {
            let scalars = String(character).unicodeScalars
            if scalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                pendingSpace = true
                spaceSinceHyphen = true
                continue
            }
            if character == "\u{00AD}" { continue }
            if pendingHyphen {
                pendingHyphen = false
                if spaceSinceHyphen, character.isLetter {
                    pendingSpace = false
                } else {
                    result += "-"
                }
            }
            if pendingSpace, !result.isEmpty { result += " " }
            pendingSpace = false
            if joinsHyphenatedWords, result.last?.isLetter == true, character == "-" || character == "\u{2010}" {
                pendingHyphen = true
                spaceSinceHyphen = false
                continue
            }
            result += String(character).precomposedStringWithCompatibilityMapping
        }
        if pendingHyphen { result += "-" }
        return result
    }

    func find(_ spec: PDFAnnotationLayer.Spec) -> Match? {
        let quote = normalize(spec.quote)
        guard !quote.isEmpty else { return nil }
        var ranges = occurrences(of: quote, options: [])
        if ranges.isEmpty { ranges = occurrences(of: quote, options: .caseInsensitive) }
        guard let first = ranges.first else { return nil }

        var chosen = first
        if let occurrence = spec.occurrence, occurrence >= 1, occurrence <= ranges.count {
            chosen = ranges[occurrence - 1]
        } else if ranges.count > 1, spec.prefix != nil || spec.suffix != nil {
            chosen = ranges.max { score($0, spec) < score($1, spec) } ?? first
        }
        guard let selection = selection(for: chosen) else { return nil }
        return Match(selection: selection, candidates: ranges.count)
    }

    private func normalize(_ string: String) -> String {
        Self.normalize(string, joinsHyphenatedWords: joinsHyphenatedWords)
    }

    private func occurrences(of quote: String, options: NSString.CompareOptions) -> [NSRange] {
        var ranges: [NSRange] = []
        var searchFrom = 0
        while searchFrom < text.length {
            let found = text.range(of: quote, options: options, range: NSRange(location: searchFrom, length: text.length - searchFrom))
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            searchFrom = found.location + 1
        }
        return ranges
    }

    private func score(_ range: NSRange, _ spec: PDFAnnotationLayer.Spec) -> Int {
        var score = 0
        if let prefix = spec.prefix.map(normalize), !prefix.isEmpty {
            let start = max(0, range.location - prefix.count - 8)
            let before = text.substring(with: NSRange(location: start, length: range.location - start))
                .trimmingCharacters(in: .whitespaces)
            if before.hasSuffix(prefix.trimmingCharacters(in: .whitespaces)) { score += 2 }
            else if before.hasSuffix(String(prefix.suffix(12)).trimmingCharacters(in: .whitespaces)) { score += 1 }
        }
        if let suffix = spec.suffix.map(normalize), !suffix.isEmpty {
            let end = NSMaxRange(range)
            let after = text.substring(with: NSRange(location: end, length: min(text.length - end, suffix.count + 8)))
                .trimmingCharacters(in: .whitespaces)
            if after.hasPrefix(suffix.trimmingCharacters(in: .whitespaces)) { score += 2 }
            else if after.hasPrefix(String(suffix.prefix(12)).trimmingCharacters(in: .whitespaces)) { score += 1 }
        }
        return score
    }

    private func selection(for range: NSRange) -> PDFSelection? {
        guard range.length > 0, NSMaxRange(range) <= map.count else { return nil }
        let start = map[range.location]
        let end = map[NSMaxRange(range) - 1]
        guard let startPage = document.page(at: start.page), let endPage = document.page(at: end.page) else { return nil }
        return document.selection(from: startPage, atCharacterIndex: start.start, to: endPage, atCharacterIndex: max(start.start, end.end - 1))
    }
}

// MARK: - Storage

enum PDFAnnotationStore {
    private struct File: Codable {
        var path: String
        var annotations: [PDFAnnotationLayer.Spec]
    }

    private static func url(for documentURL: URL) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let digest = SHA256.hash(data: Data(documentURL.standardizedFileURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return support.appendingPathComponent("nvModern/pdf-annotations/\(name).json")
    }

    static func load(for documentURL: URL) -> [PDFAnnotationLayer.Spec] {
        guard let url = url(for: documentURL), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.annotations
    }

    static func save(_ specs: [PDFAnnotationLayer.Spec], for documentURL: URL) {
        guard let url = url(for: documentURL) else { return }
        if specs.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let file = File(path: documentURL.standardizedFileURL.path, annotations: specs)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Views

/// Holds the PDF and its notes column, letting the annotation layer size them.
final class PDFAnnotationContainerView: NSView {
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onLayout?()
    }
}

/// Draws annotation marks and badges over the PDF. Only badges take clicks,
/// so text selection and scrolling reach the PDF underneath.
final class PDFAnnotationMarksView: NSView {
    struct Mark {
        var rects: [NSRect]
        var style: String
        var color: NSColor
        var focused: Bool
    }

    struct Badge {
        var id: String
        var label: String
        var color: NSColor
        var anchor: NSRect
    }

    var onBadgeClick: ((String) -> Void)?
    private var marks: [Mark] = []
    private var badgeViews: [String: PDFAnnotationBadgeView] = [:]

    override var isFlipped: Bool { true }

    func update(marks: [Mark], badges: [Badge]) {
        self.marks = marks
        needsDisplay = true
        let ids = Set(badges.map(\.id))
        for (id, view) in badgeViews where !ids.contains(id) {
            view.removeFromSuperview()
            badgeViews[id] = nil
        }
        for badge in badges {
            let view = badgeViews[badge.id] ?? {
                let view = PDFAnnotationBadgeView()
                view.onClick = { [weak self] id in self?.onBadgeClick?(id) }
                addSubview(view)
                badgeViews[badge.id] = view
                return view
            }()
            view.configure(id: badge.id, label: badge.label, color: badge.color)
            let size = view.intrinsicContentSize
            // Raised like a footnote marker at the start of the passage: the PDF's
            // text can't move aside for it the way the editor's can.
            view.frame = NSRect(
                x: max(2, badge.anchor.minX - size.width / 2),
                y: badge.anchor.minY - size.height + 3,
                width: size.width,
                height: size.height
            )
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks {
            for rect in mark.rects where rect.intersects(dirtyRect) {
                switch mark.style {
                case "underline":
                    mark.color.setFill()
                    NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: mark.focused ? 2.5 : 1.75).fill()
                case "box":
                    mark.color.setStroke()
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1), xRadius: 2, yRadius: 2)
                    path.lineWidth = mark.focused ? 2 : 1.25
                    path.stroke()
                default:
                    mark.color.withAlphaComponent(mark.focused ? 0.42 : 0.26).setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2).fill()
                }
            }
        }
    }
}

final class PDFAnnotationBadgeView: NSView {
    var onClick: ((String) -> Void)?
    private var id = ""
    private var label = ""
    private var color: NSColor = .systemYellow
    private let font = NSFont.systemFont(ofSize: 9, weight: .bold)

    func configure(id: String, label: String, color: NSColor) {
        guard self.id != id || self.label != label || self.color != color else { return }
        self.id = id
        self.label = label
        self.color = color
        invalidateIntrinsicContentSize()
        needsDisplay = true
        toolTip = "Annotation \(label)"
    }

    override var intrinsicContentSize: NSSize {
        let width = (label as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: max(14, ceil(width) + 9), height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let textColor = color == .systemYellow ? NSColor(white: 0.15, alpha: 1) : NSColor.white
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(id)
    }
}

/// The notes column. In inline mode it overlays the PDF and only its cards take clicks.
final class PDFAnnotationNotesView: NSView {
    var passesClicksThrough = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return passesClicksThrough && hit === self ? nil : hit
    }
}

/// One note: badge and note (or question), then any answer.
final class PDFAnnotationNoteCard: NSView {
    var onRemove: ((String) -> Void)?
    var onEdit: ((String) -> Void)?
    var onSelect: ((String) -> Void)?

    private var id = ""
    private var color: NSColor = .systemYellow
    private var focused = false
    private let badge = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let answerCaption = NSTextField(labelWithString: "")
    private let answerBody = NSTextField(wrappingLabelWithString: "")
    private let editButton = NSButton(title: "✎", target: nil, action: nil)
    private let removeButton = NSButton(title: "×", target: nil, action: nil)
    private let stack = NSStackView()

    override var isFlipped: Bool { true }

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        wantsLayer = true
        layer?.cornerRadius = 6

        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.drawsBackground = true

        for label in [body, answerBody] {
            label.font = .systemFont(ofSize: 11.5)
            label.isSelectable = true
        }
        answerCaption.font = .systemFont(ofSize: 10, weight: .semibold)
        answerCaption.textColor = .secondaryLabelColor

        let header = NSStackView(views: [badge, body])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 6

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 9, bottom: 8, right: 34)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(answerCaption)
        stack.addArrangedSubview(answerBody)
        stack.setCustomSpacing(8, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor)
        ])

        for (button, action) in [(editButton, #selector(edit)), (removeButton, #selector(remove))] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            addSubview(button)
        }
        editButton.toolTip = "Edit"
        removeButton.toolTip = "Remove"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // swiftlint:disable:next function_parameter_count
    func configure(
        id: String,
        label: String,
        color: NSColor,
        note: String,
        answer: String?,
        answeredBy: String?,
        answerStale: Bool,
        isReader: Bool,
        focused: Bool
    ) {
        self.id = id
        self.color = color
        self.focused = focused
        badge.stringValue = " \(label) "
        badge.textColor = color == .systemYellow ? NSColor(white: 0.15, alpha: 1) : .white
        badge.backgroundColor = color
        body.attributedStringValue = PDFAnnotationNoteCard.render(note, italic: isReader)
        body.isHidden = note.isEmpty
        let author = answeredBy?.isEmpty == false ? answeredBy! : "Reply"
        answerCaption.stringValue = answerStale ? "\(author) · to an earlier version" : author
        answerCaption.isHidden = answer == nil
        answerBody.attributedStringValue = PDFAnnotationNoteCard.render(answer ?? "", italic: false)
        answerBody.isHidden = answer == nil
        answerBody.alphaValue = answerStale ? 0.55 : 1
        answerCaption.alphaValue = answerStale ? 0.55 : 1
        editButton.isHidden = !isReader
        updateBackground()
    }

    func fittingSize(width: CGFloat) -> NSSize {
        let textWidth = width - 9 - 34
        body.preferredMaxLayoutWidth = textWidth - badge.intrinsicContentSize.width - 6
        answerBody.preferredMaxLayoutWidth = textWidth
        frame.size.width = width
        layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height)
        removeButton.frame = NSRect(x: width - 22, y: 4, width: 18, height: 18)
        editButton.frame = NSRect(x: width - 40, y: 4, width: 18, height: 18)
        return NSSize(width: width, height: max(height, 26))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.textBackgroundColor
            let mixed = base.blended(withFraction: focused ? 0.16 : 0.08, of: color) ?? base
            layer?.backgroundColor = mixed.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(id)
    }

    @objc private func edit() { onEdit?(id) }
    @objc private func remove() { onRemove?(id) }

    /// Light Markdown (bold, italic, code) via Foundation's inline parser.
    static func render(_ text: String, italic: Bool) -> NSAttributedString {
        let baseSize: CGFloat = 11.5
        let parsed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font = NSFont.systemFont(ofSize: baseSize, weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
            }
            if intent.contains(.emphasized) || italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            result.append(NSAttributedString(string: piece, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        return result
    }
}

/// The question box: a small text view in a popover. Return saves, Shift-Return
/// adds a line, Escape cancels; saving an empty box keeps a plain highlight.
final class PDFAnnotationComposerController: NSViewController, NSTextViewDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let initial: String
    private let editing: Bool
    private let textView = NSTextView()

    init(initial: String, editing: Bool) {
        self.initial = initial
        self.editing = editing
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 104))
        let title = NSTextField(labelWithString: editing
            ? "Edit your question (empty keeps a plain highlight)"
            : "Ask about this, or press ↵ to just highlight")
        title.font = .systemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 12, y: 80, width: 316, height: 16)

        let scroll = NSScrollView(frame: NSRect(x: 10, y: 28, width: 320, height: 50))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        textView.frame = scroll.bounds
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.drawsBackground = false
        textView.delegate = self
        textView.string = initial
        textView.autoresizingMask = [.width]
        scroll.documentView = textView

        let hint = NSTextField(labelWithString: "↵ save · ⇧↵ new line · esc cancel")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 12, y: 8, width: 316, height: 14)

        root.addSubview(title)
        root.addSubview(scroll)
        root.addSubview(hint)
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?(textView.string.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}

extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}
