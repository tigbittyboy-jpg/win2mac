import Foundation

public struct InstalledTarget: Identifiable, Equatable, Sendable {
    public var id: URL { executable }
    public let executable: URL
    public let info: ExecutableInfo
}
public enum InstalledApplicationScanner {
    /// Read-only bounded scan of conventional installation folders. Never follows links.
    public static func scan(prefix: URL, excluding known: Set<URL> = []) throws -> [InstalledTarget] {
        let root = try PrefixPolicy.canonical(prefix).appendingPathComponent("drive_c", isDirectory: true)
        let knownPaths = Set(known.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        var targets: [InstalledTarget] = []
        var visited = 0
        for folder in ["Program Files", "Program Files (x86)", "users"] {
            let directory = root.appendingPathComponent(folder)
            guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            guard let iterator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in iterator {
                visited += 1
                if visited > 20_000 || targets.count >= 100 { return targets }
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
                guard values.isDirectory != true, url.pathExtension.lowercased() == "exe", !knownPaths.contains(url.resolvingSymlinksInPath().standardizedFileURL.path),
                      url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                      let info = try? ExecutableInspector.inspect(url), info.kind != .installerCandidate else { continue }
                targets.append(.init(executable: url, info: info))
            }
        }
        return targets.sorted { $0.executable.path < $1.executable.path }
    }
}
