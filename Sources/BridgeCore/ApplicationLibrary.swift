import Foundation

public protocol ApplicationLibraryStoring: Sendable {
    func load() async throws -> LibrarySnapshot
    func save(_ snapshot: LibrarySnapshot) async throws
}

public actor ApplicationLibrary: ApplicationLibraryStoring {
    private let file: URL
    public init(file: URL = BridgePaths.library) { self.file = file }

    public func load() throws -> LibrarySnapshot {
        guard FileManager.default.fileExists(atPath: file.path) else { return LibrarySnapshot() }
        do {
            let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: file))
            try validate(snapshot)
            return snapshot
        } catch { throw BridgeError.persistence("Cannot read library; the original file was preserved. \(error.localizedDescription)") }
    }
    public func save(_ snapshot: LibrarySnapshot) throws {
        try validate(snapshot)
        // Refuse to overwrite a store that became corrupt after the UI loaded it.
        if FileManager.default.fileExists(atPath: file.path) { _ = try load() }
        do {
            let parent = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { throw BridgeError.persistence("Cannot save library: \(error.localizedDescription)") }
    }
    private func validate(_ snapshot: LibrarySnapshot) throws {
        guard snapshot.schemaVersion == 1 else { throw BridgeError.persistence("Unsupported library schema version.") }
        let runtimeIDs = Set(snapshot.runtimes.map(\.id)), bottleIDs = Set(snapshot.bottles.map(\.id))
        guard runtimeIDs.count == snapshot.runtimes.count,
              bottleIDs.count == snapshot.bottles.count,
              Set(snapshot.applications.map(\.id)).count == snapshot.applications.count else {
            throw BridgeError.persistence("Duplicate library identifiers.")
        }
        guard snapshot.bottles.allSatisfy({ runtimeIDs.contains($0.runtimeID) }),
              snapshot.applications.allSatisfy({ $0.bottleID.map { bottleIDs.contains($0) } ?? true }) else {
            throw BridgeError.persistence("Library contains missing runtime or bottle associations.")
        }
        let urls = snapshot.applications.map(\.executable) + snapshot.runtimes.map(\.executable) + snapshot.bottles.map(\.prefix)
        guard urls.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }) else {
            throw BridgeError.persistence("Library paths must be absolute local file URLs.")
        }
        let prefixes = snapshot.bottles.map { $0.prefix.resolvingSymlinksInPath().standardizedFileURL.path }
        for i in prefixes.indices {
            for j in prefixes.indices where i < j {
                if prefixes[i] == prefixes[j] || prefixes[i].hasPrefix(prefixes[j] + "/") || prefixes[j].hasPrefix(prefixes[i] + "/") {
                    throw BridgeError.persistence("Bottle paths must be distinct and must not contain one another.")
                }
            }
        }
    }
}
