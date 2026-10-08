import Foundation

public protocol BottleManaging: Sendable {
    func create(name: String, prefix: URL, runtime: WineRuntime, approved: Bool,
                output: @escaping OutputHandler) async throws -> Bottle
    func enumerate(_ configured: [Bottle]) async -> [Bottle]
    func configure(_ bottle: Bottle, name: String, graphics: GraphicsBackend) async throws -> Bottle
    func remove(_ bottle: Bottle) async throws
    func acquire(_ bottle: Bottle) async throws
    func release(_ bottle: Bottle) async
}

public enum PrefixPolicy {
    public static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw BridgeError.invalidPrefix("Prefix must be an absolute local directory.") }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard resolved.path != home, resolved.pathComponents.count >= 3,
              !["/Users", "/home", "/tmp", "/Applications", "/Library", "/System", "/usr", "/var", "/opt"].contains(resolved.path) else {
            throw BridgeError.invalidPrefix("Choose a dedicated prefix directory, not a home or system directory.")
        }
        var ancestor = resolved
        while ancestor.path != "/" {
            let metadata = ancestor.appendingPathComponent(".git")
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: metadata.path, isDirectory: &directory)
            let gitDirectory = directory.boolValue && FileManager.default.fileExists(atPath: metadata.appendingPathComponent("HEAD").path)
            let linkedWorktree = exists && !directory.boolValue && ((try? String(contentsOf: metadata, encoding: .utf8))?.hasPrefix("gitdir:") == true)
            if gitDirectory || linkedWorktree {
                throw BridgeError.invalidPrefix("Wine prefixes must be outside source repositories.")
            }
            ancestor.deleteLastPathComponent()
        }
        return resolved
    }
    public static func validateInitialized(_ url: URL) throws {
        let prefix = try canonical(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c").path, isDirectory: &isDirectory),
              isDirectory.boolValue, FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
            throw BridgeError.invalidPrefix("Prefix is not initialized (expected drive_c and system.reg). Create a bottle or select an existing Wine prefix.")
        }
    }
}

public actor BottleManager: BottleManaging {
    private let executor: any ProcessExecuting
    private let runtimes: any RuntimeManaging
    private var active: Set<String> = []
    private static let marker = ".bridge-bottle.json"
    public init(executor: any ProcessExecuting = FoundationProcessExecutor(), runtimes: any RuntimeManaging = RuntimeManager()) {
        self.executor = executor; self.runtimes = runtimes
    }
    public func create(name: String, prefix: URL, runtime: WineRuntime, approved: Bool,
                       output: @escaping OutputHandler) async throws -> Bottle {
        guard approved else { throw BridgeError.approvalRequired }
        try runtimes.validate(runtime, forLaunch: true)
        let path = try PrefixPolicy.canonical(prefix)
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw BridgeError.invalidPrefix("Creation requires a new directory. Select an existing initialized prefix to reuse it.")
        }
        guard !active.contains(path.path) else { throw BridgeError.busy }
        active.insert(path.path); defer { active.remove(path.path) }
        let bottle = Bottle(name: name, prefix: path, runtimeID: runtime.id, managed: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(bottle).write(to: path.appendingPathComponent(Self.marker), options: .atomic)
        do {
            let result = try await executor.run(.init(executable: runtime.executable,
                arguments: ["wineboot", "-u"], environment: ["WINEPREFIX": path.path, "WINEARCH": "win64"],
                workingDirectory: path, timeout: 120), output: output)
            guard result.exitCode == 0, !result.wasSignalled else {
                throw BridgeError.invalidPrefix("wineboot failed (exit \(result.exitCode)). Check process output.")
            }
            try PrefixPolicy.validateInitialized(path)
            return bottle
        } catch {
            // Keep a partial prefix: Wine children may still be running after an error.
            // The user can inspect it; no arbitrary recursive cleanup on failure.
            throw BridgeError.invalidPrefix("Bottle initialization failed. A partial prefix was retained at \(path.path): \(error.localizedDescription)")
        }
    }
    public func enumerate(_ configured: [Bottle]) -> [Bottle] {
        configured.filter { (try? PrefixPolicy.validateInitialized($0.prefix)) != nil }
    }
    public func configure(_ bottle: Bottle, name: String, graphics: GraphicsBackend) throws -> Bottle {
        guard !active.contains(try PrefixPolicy.canonical(bottle.prefix).path) else { throw BridgeError.busy }
        _ = try GraphicsManager().environment(for: graphics)
        var updated = bottle; updated.name = name; updated.graphics = graphics
        return updated
    }
    public func remove(_ bottle: Bottle) throws {
        let path = try PrefixPolicy.canonical(bottle.prefix)
        guard !active.contains(path.path) else { throw BridgeError.busy }
        guard bottle.managed else { throw BridgeError.invalidPrefix("Bridge cannot delete an externally managed prefix.") }
        let marker = path.appendingPathComponent(Self.marker)
        guard let data = try? Data(contentsOf: marker), let owner = try? JSONDecoder().decode(Bottle.self, from: data),
              owner.id == bottle.id, owner.managed, owner.prefix.standardizedFileURL == path else {
            throw BridgeError.invalidPrefix("Refusing deletion: prefix has no matching Bridge ownership record.")
        }
        try FileManager.default.removeItem(at: path)
    }
    public func acquire(_ bottle: Bottle) throws {
        try PrefixPolicy.validateInitialized(bottle.prefix)
        let path = try PrefixPolicy.canonical(bottle.prefix).path
        guard !active.contains(path) else { throw BridgeError.busy }
        active.insert(path)
    }
    public func release(_ bottle: Bottle) {
        // Release the leased path even if a caller has removed the prefix.
        active.remove(bottle.prefix.resolvingSymlinksInPath().standardizedFileURL.path)
    }
}
