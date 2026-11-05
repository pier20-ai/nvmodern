import AppKit

struct DocumentDatePickerRequest {
    let isoDate: String?
    let startTime: String?
    let endTime: String?
}

struct DocumentDatePickerResult {
    let isoDate: String
    let startTime: String?
    let endTime: String?

    var payload: [String: Any] {
        var payload: [String: Any] = ["isoDate": isoDate]
        if let startTime { payload["startTime"] = startTime }
        if let endTime { payload["endTime"] = endTime }
        return payload
    }
}

/// Destination of a resolved wikilink activation, shared by every document
/// surface. `isSameDocument` means the link targets a reference inside the
/// document that raised the event, so the surface should jump in place rather
/// than navigate.
struct WikilinkNavigation {
    let path: String
    let reference: MarkdownReferenceTarget?
    let isSameDocument: Bool
}

/// Bridge handling shared by every document surface in a tab (the primary
/// editor and the child pane). A handler added here works identically in both
/// surfaces; surface-specific behavior stays with the surface that owns it.
@MainActor
final class DocumentSurfaceBridgeService {
    /// Write permissions of the surface issuing a request.
    struct WritePolicy {
        /// Read-only presentation, e.g. palette document previews.
        var isReadOnly = false
        /// Surfaces without a workspace-backed document cannot
        /// write transclusions or attachments.
        var allowsWorkspaceWrites = true

        static let editable = WritePolicy()
    }

    enum RequestOutcome {
        case handled(Any?)
        case unhandled
    }

    private enum InlineLinkRoute {
        case external(URL)
        case absoluteFile(URL)
        case workspace(String)
    }

    let arborKernelSupervisor: ArborKernelSupervisor

    /// Presents the native date picker for `date.pick`. Installed by the tab
    /// shell, which owns the sheet presentation; both surfaces share it.
    var presentDatePicker: ((DocumentDatePickerRequest) async -> DocumentDatePickerResult?)?

    init(arborKernelSupervisor: ArborKernelSupervisor) {
        self.arborKernelSupervisor = arborKernelSupervisor
    }

    func handleSharedRequest(
        method: String,
        params: [String: Any],
        notesModel: NotesWorkspaceModel,
        policy: WritePolicy = .editable
    ) async throws -> RequestOutcome {
        switch method {
        case "autocomplete.wikilink":
            let query = (params["query"] as? String) ?? ""
            let sourcePath = params["filePath"] as? String
            let items = notesModel.autocompleteWikilinks(query: query, sourceRelativePath: sourcePath)
                .map { item in
                    [
                        "label": item.label,
                        "insertText": item.insertText,
                        "detail": item.detail
                    ]
                }
            return .handled(["items": items])

        case "transclusion.resolve":
            guard let target = params["target"] as? String,
                  let resolved = notesModel.resolveTransclusion(
                    target: target,
                    sourceRelativePath: params["filePath"] as? String
                  ) else {
                return .handled(nil)
            }
            return .handled([
                "content": resolved.content,
                "kind": resolved.kind as Any,
                "filePath": resolved.relativePath
            ])

        case "transclusion.save":
            guard !policy.isReadOnly else {
                throw NSError(domain: "NVModern", code: 403, userInfo: [NSLocalizedDescriptionKey: "Palette previews are read-only"])
            }
            guard policy.allowsWorkspaceWrites else {
                throw NSError(domain: "NVModern", code: 403, userInfo: [NSLocalizedDescriptionKey: "This document cannot save transclusions"])
            }
            guard let target = params["target"] as? String,
                  let content = params["content"] as? String
            else {
                throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid transclusion save payload"])
            }
            _ = try notesModel.saveTransclusion(
                target: target,
                sourceRelativePath: params["filePath"] as? String,
                content: content
            )
            return .handled(["ok": true])

        case "date.pick":
            guard let presentDatePicker,
                  let result = await presentDatePicker(
                    DocumentDatePickerRequest(
                        isoDate: params["isoDate"] as? String,
                        startTime: params["startTime"] as? String,
                        endTime: params["endTime"] as? String
                    )
                  )
            else {
                return .handled(nil)
            }
            return .handled(result.payload)

        case "image.save":
            guard !policy.isReadOnly else {
                throw NSError(domain: "NVModern", code: 403, userInfo: [NSLocalizedDescriptionKey: "Palette previews are read-only"])
            }
            guard policy.allowsWorkspaceWrites else {
                throw NSError(domain: "NVModern", code: 403, userInfo: [NSLocalizedDescriptionKey: "This document cannot save attachments"])
            }
            guard let base64String = params["data"] as? String,
                  let mimeType = params["mimeType"] as? String,
                  !base64String.isEmpty
            else {
                throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid image.save payload"])
            }
            guard let imageData = Data(base64Encoded: base64String) else {
                throw NSError(domain: "NVModern", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid base64 image data"])
            }

            let ext: String
            switch mimeType.lowercased() {
            case "image/jpeg", "image/jpg": ext = "jpg"
            case "image/gif": ext = "gif"
            case "image/webp": ext = "webp"
            case "image/svg+xml": ext = "svg"
            default: ext = "png"
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let timestamp = formatter.string(from: Date())
            let random = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
            let filename = "\(timestamp)-\(random).\(ext)"

            let attachmentsDir = notesModel.runtimeConfig.rootURL
                .appendingPathComponent(".attachments", isDirectory: true)
            try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
            try imageData.write(to: attachmentsDir.appendingPathComponent(filename))
            print("[NVModern][ImageSave] Saved \(imageData.count) bytes → .attachments/\(filename)")
            return .handled(["path": ".attachments/\(filename)"])

        case "arbor.evaluate":
            guard let path = params["path"] as? String,
                  let source = params["source"] as? String,
                  let revisionNumber = params["revision"] as? NSNumber,
                  revisionNumber.intValue >= 0
            else {
                throw NSError(
                    domain: "NVModern",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid arbor.evaluate payload"]
                )
            }
            let previousDerivedUIDs = params["previousDerivedUIDs"] as? [String] ?? []
            let requestID = (params["requestId"] as? String)
                ?? (params["requestID"] as? String)
                ?? UUID().uuidString
            let response = await arborKernelSupervisor.evaluate(
                document: ArborKernelDocument(
                    path: path,
                    revision: revisionNumber.intValue,
                    source: source
                ),
                previousDerivedUIDs: previousDerivedUIDs,
                requestID: requestID
            )
            let responseData = try JSONEncoder().encode(response)
            return .handled(try JSONSerialization.jsonObject(with: responseData))

        default:
            return .unhandled
        }
    }

    /// Resolves a `wikilinkOpen` payload into a navigation destination, with
    /// Obsidian-style heading/block references handled for both surfaces.
    static func wikilinkNavigation(
        payload: [String: Any],
        notesModel: NotesWorkspaceModel
    ) -> WikilinkNavigation? {
        guard let target = payload["target"] as? String else { return nil }
        let sourcePath = payload["filePath"] as? String
        let parsed = parseObsidianWikilinkTarget(target)

        if let reference = parsed.reference,
           !reference.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if parsed.noteTarget.isEmpty {
                guard let sourcePath = sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sourcePath.isEmpty else {
                    return nil
                }
                return WikilinkNavigation(path: sourcePath, reference: reference, isSameDocument: true)
            }
            guard let destination = notesModel.resolveWikilinkTarget(parsed.noteTarget, from: sourcePath),
                  !destination.isEmpty else {
                return nil
            }
            return WikilinkNavigation(path: destination, reference: reference, isSameDocument: false)
        }

        guard let resolved = notesModel.resolveWikilinkTarget(target, from: sourcePath) else {
            return nil
        }
        return WikilinkNavigation(path: resolved, reference: nil, isSameDocument: false)
    }

    /// Routes an `inlineLinkOpen` payload: external URLs and absolute file
    /// paths open outside the app; workspace-relative paths go back to the
    /// surface, which decides where to show them.
    static func routeInlineLink(
        payload: [String: Any],
        openWorkspacePath: (String) -> Void
    ) {
        guard let route = inlineLinkRoute(payload: payload) else { return }
        switch route {
        case .external(let url), .absoluteFile(let url):
            NSWorkspace.shared.open(url)
        case .workspace(let path):
            openWorkspacePath(path)
        }
    }

    private static func inlineLinkRoute(payload: [String: Any]) -> InlineLinkRoute? {
        if let resolvedPath = (payload["resolvedPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resolvedPath.isEmpty {
            return .workspace(resolvedPath)
        }
        guard let href = (payload["href"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !href.isEmpty
        else {
            return nil
        }
        if let url = URL(string: href), let scheme = url.scheme, !scheme.isEmpty {
            return .external(url)
        }
        if href.hasPrefix("/") {
            return .absoluteFile(URL(fileURLWithPath: href))
        }
        return .workspace(href)
    }
}
