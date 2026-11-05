import AppKit
import WebKit

/// Native chrome for the help drawer: one toolbar row (provider, search, close) over a grouped topic list and detail.
@MainActor
final class HelpDrawerController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row {
        case header(String)
        case topic(HelpTopic)
    }

    static let cornerRadius: CGFloat = 18
    var onInsert: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let providers: [HelpProvider]
    private let initialProviderID: String?
    private let canInsert: Bool
    private let allowsMultiline: Bool
    private let search = NSSearchField()
    private let providerPicker = NSPopUpButton()
    private let table = NSTableView()
    private let detail = HelpDetailWebController()
    private var rows: [Row] = []
    private var provider: HelpProvider { providers[max(0, providerPicker.indexOfSelectedItem)] }
    private var insertionEnabled: Bool { canInsert && provider.id == initialProviderID }
    private var selectedTopic: HelpTopic? { topic(at: table.selectedRow) }

    init(providers: [HelpProvider], selectedProviderID: String?, canInsert: Bool, allowsMultiline: Bool) {
        self.providers = providers
        self.initialProviderID = selectedProviderID
        self.canInsert = canInsert
        self.allowsMultiline = allowsMultiline
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let body = NSView()
        if #available(macOS 26.0, *) {
            // Clear glass lenses and refracts what is behind it; regular glass would frost it into a flat sheet.
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = body
            view = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.addSubview(body)
            body.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: effect.leadingAnchor), body.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                body.topAnchor.constraint(equalTo: effect.topAnchor), body.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            view = effect
        }
        // The surface fills a transparent borderless panel; clip its backing layer so all four corners stay clear.
        view.wantsLayer = true
        view.layer?.cornerRadius = Self.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 400)
        view.setAccessibilityLabel("nvModern Help")

        providerPicker.addItems(withTitles: providers.map { "Explore \($0.title)" })
        providerPicker.selectItem(at: providers.firstIndex(where: { $0.id == initialProviderID }) ?? 0)
        providerPicker.target = self
        providerPicker.action = #selector(providerChanged)
        providerPicker.controlSize = .large
        providerPicker.setAccessibilityLabel("Help provider")

        search.sendsSearchStringImmediately = true
        search.controlSize = .large
        search.delegate = self
        search.setAccessibilityLabel("Search help")

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close help")!, target: self, action: #selector(closeHelp))
        close.controlSize = .large
        if #available(macOS 26.0, *) {
            close.bezelStyle = .glass
            close.borderShape = .circle
        } else {
            close.bezelStyle = .circular
        }
        close.keyEquivalent = "\u{1b}"
        close.keyEquivalentModifierMask = []
        close.toolTip = "Close (Esc)"

        let header = NSStackView(views: [providerPicker, search, close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        providerPicker.setContentHuggingPriority(.required, for: .horizontal)
        close.setContentHuggingPriority(.required, for: .horizontal)

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("topic")))
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.floatsGroupRows = false
        table.rowSizeStyle = .default
        table.usesAutomaticRowHeights = false
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Help topics")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)

        addChild(detail)
        // Clear glass stays clear around the toolbar; the content well dims what shows through behind text.
        let well = HelpDimmingView()
        let inset: CGFloat = 6
        well.layer?.cornerRadius = Self.cornerRadius - inset
        [header, well].forEach { body.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        [scroll, detail.view].forEach { well.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: body.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -12),
            well.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            well.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: inset),
            well.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -inset),
            well.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -inset),
            scroll.topAnchor.constraint(equalTo: well.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: well.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 250),
            detail.view.topAnchor.constraint(equalTo: well.topAnchor, constant: 6),
            detail.view.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 6),
            detail.view.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            detail.view.bottomAnchor.constraint(equalTo: well.bottomAnchor),
        ])
        detail.onInsert = { [weak self] topicID, actionID in
            guard let self, self.insertionEnabled, let topic = self.selectedTopic, topic.id == topicID,
                  let action = topic.insertions.first(where: { $0.id == actionID }),
                  self.allowsMultiline || !action.template.contains("\n") else { return }
            self.onInsert?(action.template)
        }
        detail.onClose = { [weak self] in self?.onClose?() }
        providerPicker.nextKeyView = search
        search.nextKeyView = table
        table.nextKeyView = detail.view
        detail.view.nextKeyView = close
        close.nextKeyView = providerPicker
        providerChanged()
    }

    func focusSearch() { view.window?.makeFirstResponder(search) }
    func invalidate() { detail.invalidate() }
    @objc private func closeHelp() { onClose?() }
    @objc private func providerChanged() {
        search.placeholderString = "Search \(provider.topics.count) \(provider.title) topics"
        refresh()
    }
    func controlTextDidChange(_ obj: Notification) { refresh() }

    private func topic(at row: Int) -> HelpTopic? {
        guard rows.indices.contains(row), case .topic(let topic) = rows[row] else { return nil }
        return topic
    }

    private func refresh() {
        let previous = selectedTopic?.id
        let matches = provider.topics.filter { $0.matches(search.stringValue) }
        let categories = Set(matches.map(\.category)).sorted { a, b in
            if (a == "Constructions") != (b == "Constructions") { return a == "Constructions" }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        rows = categories.flatMap { category -> [Row] in
            [.header(category)] + matches.filter { $0.category == category }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map(Row.topic)
        }
        table.reloadData()
        let target = previous.flatMap { id in rows.indices.first { topic(at: $0)?.id == id } }
            ?? rows.indices.first { topic(at: $0) != nil }
        if let target {
            table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            table.scrollRowToVisible(target)
        } else { table.deselectAll(nil) }
        showSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { topic(at: row) == nil }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { topic(at: row) != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { topic(at: row) == nil ? 28 : 24 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label: NSTextField
        switch rows[row] {
        case .header(let category):
            label = NSTextField(labelWithString: category)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
        case .topic(let topic):
            label = NSTextField(labelWithString: topic.title)
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        label.lineBreakMode = .byTruncatingTail
        cell.textField = label
        cell.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: topic(at: row) == nil ? 3 : 0),
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }
    private func showSelection() {
        detail.show(topic: selectedTopic, providerTitle: provider.title, canInsert: insertionEnabled, allowsMultiline: allowsMultiline)
    }

    /// Arrow keys in search move through topics, skipping category headers.
    private func moveSelection(by delta: Int) {
        var row = table.selectedRow
        repeat { row += delta } while rows.indices.contains(row) && topic(at: row) == nil
        guard rows.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            guard insertionEnabled, let insertion = selectedTopic?.insertions.first,
                  allowsMultiline || !insertion.template.contains("\n") else { return true }
            onInsert?(insertion.template)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default: return false
        }
    }
}

/// Appearance-aware dimming behind the list and detail: darkens in Dark Mode, washes light in Light Mode,
/// so text keeps contrast over whatever the clear glass refracts.
@MainActor
private final class HelpDimmingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.34) : NSColor.white.withAlphaComponent(0.96)).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The detail page renders bundled React on a transparent WebKit surface over native glass.
@MainActor
private final class HelpDetailWebController: NSViewController {
    var onInsert: ((String, String) -> Void)?
    var onClose: (() -> Void)?
    private let bridge = WebEditorBridge()
    private var handler: HelpMessageHandler?
    private var selection: [String: Any] = [:]
    private var webView: WKWebView?

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        let handler = HelpMessageHandler(bridge: bridge)
        self.handler = handler
        configuration.userContentController.add(handler, name: "nvmodern")
        let web = HelpWebView(frame: .zero, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor.clear.cgColor
        web.onAppearanceChange = { [weak self] in self?.sendAppearance() }
        webView = web
        view = web
        bridge.attach(webView: web)
        bridge.onReady = { [weak self] in self?.sendAppearance(); self?.sendSelection() }
        bridge.onEvent = { [weak self] event, payload in
            if event == "help.insert", let topic = payload["topicID"] as? String, let action = payload["actionID"] as? String {
                self?.onInsert?(topic, action)
            } else if event == "help.close" { self?.onClose?() }
        }
        if let url = Bundle.main.url(forResource: "help", withExtension: "html", subdirectory: "WebEditor")
            ?? Bundle.main.url(forResource: "help", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
    func show(topic: HelpTopic?, providerTitle: String, canInsert: Bool, allowsMultiline: Bool) {
        selection = ["providerTitle": providerTitle, "canInsert": canInsert, "allowsMultiline": allowsMultiline]
        if let topic, let data = try? JSONEncoder().encode(topic), let json = try? JSONSerialization.jsonObject(with: data) {
            selection["topic"] = json
        }
        if bridge.isReadyForCommands { sendSelection() }
    }
    private func sendSelection() { bridge.sendCommand("help.showTopic", payload: selection) }
    private func sendAppearance() {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        bridge.sendCommand("setHostAppearance", payload: ["colorScheme": dark ? "dark" : "light"])
    }
    func invalidate() {
        guard let webView else { return }
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nvmodern")
        bridge.detach(webView: webView)
        bridge.onReady = nil
        bridge.onEvent = nil
    }
}

@MainActor
private final class HelpMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var bridge: WebEditorBridge?
    init(bridge: WebEditorBridge) { self.bridge = bridge }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        bridge?.receive(messageBody: message.body)
    }
}

@MainActor
private final class HelpWebView: WKWebView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
