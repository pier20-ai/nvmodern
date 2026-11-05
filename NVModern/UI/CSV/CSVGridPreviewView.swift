import SwiftUI

struct CSVGridPreviewView: NSViewRepresentable {
    let fileURL: URL
    let sourceRelativePath: String?
    var reloadToken: String
    var focusRequestID: Int = 0
    var onDocumentChange: ((CSVGridSaveSnapshot) -> Void)?
    var onOpenWikilink: ((String) -> Void)?
    var onOpenWikilinkInNewTab: ((String) -> Void)?
    var wikilinkSuggestionsProvider: ((String, String?) -> [WikilinkAutocompleteSuggestion])?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CSVGridNativePreviewContainerView {
        let view = CSVGridNativePreviewContainerView(frame: .zero)
        view.sourceRelativePath = sourceRelativePath
        view.onDocumentChange = onDocumentChange
        view.onOpenWikilink = onOpenWikilink
        view.onOpenWikilinkInNewTab = onOpenWikilinkInNewTab
        view.wikilinkSuggestionsProvider = wikilinkSuggestionsProvider
        context.coordinator.load(fileURL: fileURL, reloadToken: reloadToken, into: view)
        return view
    }

    func updateNSView(_ nsView: CSVGridNativePreviewContainerView, context: Context) {
        nsView.sourceRelativePath = sourceRelativePath
        nsView.onDocumentChange = onDocumentChange
        nsView.onOpenWikilink = onOpenWikilink
        nsView.onOpenWikilinkInNewTab = onOpenWikilinkInNewTab
        nsView.wikilinkSuggestionsProvider = wikilinkSuggestionsProvider
        context.coordinator.load(fileURL: fileURL, reloadToken: reloadToken, into: nsView)

        if focusRequestID != context.coordinator.lastHandledFocusRequestID {
            nsView.focusContent()
            context.coordinator.lastHandledFocusRequestID = focusRequestID
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CSVGridNativePreviewContainerView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    final class Coordinator {
        private let loadQueue = DispatchQueue(label: "nvmodern.csv-grid.load", qos: .userInitiated)
        private var loadedURL: URL?
        private var loadedReloadToken: String?
        private var latestLoadID: Int = 0
        var lastHandledFocusRequestID: Int = 0

        func load(fileURL: URL, reloadToken: String, into view: CSVGridNativePreviewContainerView) {
            guard loadedURL != fileURL || loadedReloadToken != reloadToken else {
                return
            }

            loadedURL = fileURL
            loadedReloadToken = reloadToken
            latestLoadID += 1
            let loadID = latestLoadID
            view.setLoading(fileURL: fileURL)

            loadQueue.async {
                let result: Result<CSVGridDocument, Error>
                do {
                    result = .success(try CSVGridDocument.load(from: fileURL))
                } catch {
                    result = .failure(error)
                }

                DispatchQueue.main.async {
                    guard loadID == self.latestLoadID,
                          self.loadedURL == fileURL,
                          self.loadedReloadToken == reloadToken else {
                        return
                    }

                    switch result {
                    case .success(let document):
                        view.apply(document: document)
                    case .failure(let error):
                        view.setError(message: error.localizedDescription)
                    }
                }
            }
        }
    }
}
