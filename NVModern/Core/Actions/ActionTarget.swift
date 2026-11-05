import Foundation

/// Transport-facing target selectors.
///
/// The public action API should never depend on ephemeral AppKit identifiers like
/// `NSWindow.windowNumber`. This model keeps the transport stable while allowing the
/// app to resolve selectors to live windows, workspaces, tabs, documents, or future
/// content nodes.
struct ActionTarget: Codable, Hashable, Sendable {
    var app: AppSelector?
    var window: WindowSelector?
    var workspace: WorkspaceSelector?
    var tab: TabSelector?
    var project: ProjectSelector?
    var document: DocumentSelector?
    var content: ContentSelector?

    init(
        app: AppSelector? = nil,
        window: WindowSelector? = nil,
        workspace: WorkspaceSelector? = nil,
        tab: TabSelector? = nil,
        project: ProjectSelector? = nil,
        document: DocumentSelector? = nil,
        content: ContentSelector? = nil
    ) {
        self.app = app
        self.window = window
        self.workspace = workspace
        self.tab = tab
        self.project = project
        self.document = document
        self.content = content
    }

    static let automatic = ActionTarget()

    enum AppSelector: String, Codable, CaseIterable, Hashable, Sendable {
        case current
    }

    enum WindowSelector: Hashable, Sendable {
        case frontmost
        case identifier(String)
    }

    enum WorkspaceSelector: Hashable, Sendable {
        case frontmost
        case identifier(String)
    }

    enum TabSelector: Hashable, Sendable {
        case selected
        case identifier(String)
    }

    enum ProjectSelector: Hashable, Sendable {
        case active
        case rootPath(String)
        case named(String)
    }

    enum DocumentSelector: Hashable, Sendable {
        case current
        case relativePath(String)
        case absolutePath(String)
    }

    enum ContentSelector: Hashable, Sendable {
        case currentDocument
        case address(ActionContentAddress)
        case selector(ActionContentSelector)
    }
}

extension ActionTarget.WindowSelector: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case identifier
    }

    private enum Kind: String, Codable {
        case frontmost
        case identifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .frontmost:
            self = .frontmost
        case .identifier:
            self = .identifier(try container.decode(String.self, forKey: .identifier))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .frontmost:
            try container.encode(Kind.frontmost, forKey: .kind)
        case .identifier(let identifier):
            try container.encode(Kind.identifier, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        }
    }
}

extension ActionTarget.WorkspaceSelector: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case identifier
    }

    private enum Kind: String, Codable {
        case frontmost
        case identifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .frontmost:
            self = .frontmost
        case .identifier:
            self = .identifier(try container.decode(String.self, forKey: .identifier))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .frontmost:
            try container.encode(Kind.frontmost, forKey: .kind)
        case .identifier(let identifier):
            try container.encode(Kind.identifier, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        }
    }
}

extension ActionTarget.TabSelector: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case identifier
    }

    private enum Kind: String, Codable {
        case selected
        case identifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .selected:
            self = .selected
        case .identifier:
            self = .identifier(try container.decode(String.self, forKey: .identifier))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selected:
            try container.encode(Kind.selected, forKey: .kind)
        case .identifier(let identifier):
            try container.encode(Kind.identifier, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        }
    }
}

extension ActionTarget.ProjectSelector: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case active
        case rootPath
        case named
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .active:
            self = .active
        case .rootPath:
            self = .rootPath(try container.decode(String.self, forKey: .value))
        case .named:
            self = .named(try container.decode(String.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .active:
            try container.encode(Kind.active, forKey: .kind)
        case .rootPath(let path):
            try container.encode(Kind.rootPath, forKey: .kind)
            try container.encode(path, forKey: .value)
        case .named(let name):
            try container.encode(Kind.named, forKey: .kind)
            try container.encode(name, forKey: .value)
        }
    }
}

extension ActionTarget.DocumentSelector: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
    }

    private enum Kind: String, Codable {
        case current
        case relativePath
        case absolutePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .current:
            self = .current
        case .relativePath:
            self = .relativePath(try container.decode(String.self, forKey: .path))
        case .absolutePath:
            self = .absolutePath(try container.decode(String.self, forKey: .path))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .current:
            try container.encode(Kind.current, forKey: .kind)
        case .relativePath(let path):
            try container.encode(Kind.relativePath, forKey: .kind)
            try container.encode(path, forKey: .path)
        case .absolutePath(let path):
            try container.encode(Kind.absolutePath, forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}

extension ActionTarget.ContentSelector: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case address
        case selector
    }

    private enum Kind: String, Codable {
        case currentDocument
        case address
        case selector
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .currentDocument:
            self = .currentDocument
        case .address:
            self = .address(try container.decode(ActionContentAddress.self, forKey: .address))
        case .selector:
            self = .selector(try container.decode(ActionContentSelector.self, forKey: .selector))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .currentDocument:
            try container.encode(Kind.currentDocument, forKey: .kind)
        case .address(let address):
            try container.encode(Kind.address, forKey: .kind)
            try container.encode(address, forKey: .address)
        case .selector(let selector):
            try container.encode(Kind.selector, forKey: .kind)
            try container.encode(selector, forKey: .selector)
        }
    }
}

struct ActionResolvedTarget: Hashable, Sendable {
    var appID: String?
    var windowID: String?
    var workspaceID: String?
    var tabID: String?
    var projectRootPath: String?
    var documentPath: String?
    var contentAddress: ActionContentAddress?

    static let unresolved = ActionResolvedTarget()
}
