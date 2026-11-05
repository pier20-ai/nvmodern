import Foundation

@MainActor
enum ActionProjectPathResolver {
    static func resolveRootURL(for target: ActionTarget) -> URL {
        if let runtime = WorkspaceActionRouter.resolveRuntime(target: target) {
            return URL(fileURLWithPath: runtime.projectRootPath, isDirectory: true)
        }

        if let projectSelector = target.project {
            switch projectSelector {
            case .active:
                return NVModernConfigLoader.load().rootURL
            case .rootPath(let path):
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            case .named(let name):
                let config = NVModernConfigLoader.loadAppConfig()
                if let project = config.projects.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    return project.rootURL
                }
            }
        }

        return NVModernConfigLoader.load().rootURL
    }

    static func resolveFileURL(path: String, target: ActionTarget) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: false)
        }

        return resolveRootURL(for: target).appendingPathComponent(expanded, isDirectory: false)
    }
}
