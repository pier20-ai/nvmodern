import AppKit
import UniformTypeIdentifiers

/// The New Note sheet: a standard `NSSavePanel` with a Note / Canvas switch
/// as its accessory. Collapsed, it is a name field and a Where pop-up; its
/// disclosure button expands it into the full browser, and AppKit remembers
/// which of the two the user last chose.
///
/// The panel only picks a URL. The caller creates the file, so notes inside
/// the workspace still go through the notes model and live sync.
@MainActor
final class NewNotePanel: NSObject {
    enum Kind: Int {
        case note
        case canvas
    }

    struct Result {
        let url: URL
        let kind: Kind
    }

    private let panel = NSSavePanel()
    private var kind: Kind = .note

    /// Presents the panel as a sheet on `window` (or as a free-standing panel
    /// without one), starting in `directoryURL`. `completion` runs only when
    /// the user confirms; the panel has already asked before replacing an
    /// existing file.
    static func present(
        in window: NSWindow?,
        directoryURL: URL,
        completion: @escaping (Result) -> Void
    ) {
        let controller = NewNotePanel()
        controller.configure(directoryURL: directoryURL)
        // The completion handler keeps the controller, and with it the
        // accessory's action target, alive until the panel closes.
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = controller.panel.url else { return }
            completion(Result(url: url.standardizedFileURL, kind: controller.kind))
        }
        if let window {
            controller.panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            controller.panel.begin(completionHandler: handler)
        }
    }

    private func configure(directoryURL: URL) {
        panel.title = "New Note"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Name:"
        panel.nameFieldStringValue = "Untitled"
        panel.directoryURL = directoryURL
        panel.canCreateDirectories = true
        panel.showsTagField = false
        // Org users rename `.md` to `.org`; keep the extension visible and
        // accept it without the "use .md instead?" prompt.
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false
        panel.allowsOtherFileTypes = true
        panel.accessoryView = makeAccessoryView()
        applyKind()
    }

    private func makeAccessoryView() -> NSView {
        let control = NSSegmentedControl(
            labels: ["Note", "Canvas"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(kindChanged(_:))
        )
        control.selectedSegment = Kind.note.rawValue

        let label = NSTextField(labelWithString: "Type:")
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        stack.setFrameSize(stack.fittingSize)
        return stack
    }

    @objc private func kindChanged(_ sender: NSSegmentedControl) {
        kind = Kind(rawValue: sender.selectedSegment) ?? .note
        applyKind()
    }

    /// The first allowed type sets the extension the panel appends and swaps
    /// in when the kind changes.
    private func applyKind() {
        switch kind {
        case .note:
            panel.allowedContentTypes = [
                Self.type(identifier: "net.daringfireball.markdown", filenameExtension: "md"),
                Self.type(identifier: nil, filenameExtension: "org"),
                .plainText
            ].compactMap { $0 }
        case .canvas:
            panel.allowedContentTypes = [
                Self.type(identifier: "com.nvmodern.excalidraw", filenameExtension: "excalidraw")
            ].compactMap { $0 }
        }
    }

    private static func type(identifier: String?, filenameExtension: String) -> UTType? {
        if let identifier, let type = UTType(identifier) {
            return type
        }
        return UTType(filenameExtension: filenameExtension)
    }
}
