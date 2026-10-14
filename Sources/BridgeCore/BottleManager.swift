import Foundation

public protocol BottleManaging: Sendable {
    func create(name: String, prefix: URL, runtime: WineRuntime, approved: Bool,
                output: @escaping OutputHandler) async throws -> Bottle
    func repair(_ bottle: Bottle, runtime: WineRuntime, approved: Bool, output: @escaping OutputHandler) async throws -> Bottle
    func enumerate(_ configured: [Bottle]) async -> [Bottle]
    func configure(_ bottle: Bottle, name: String, graphics: GraphicsBackend) async throws -> Bottle
    func remove(_ bottle: Bottle) async throws
    func acquire(_ bottle: Bottle) async throws
    func release(_ bottle: Bottle) async
}

public extension BottleManaging {
    func repair(_ bottle: Bottle, runtime: WineRuntime, approved: Bool, output: @escaping OutputHandler) async throws -> Bottle {
        throw BridgeError.unsupported("This environment provider does not support repair.")
    }
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
        // A prefix is a directory even before creation. Foundation can infer a
        // different directory hint once it exists; persist a stable URL form.
        return URL(fileURLWithPath: resolved.path, isDirectory: true)
    }
    public static func validateWin64(_ url: URL) throws {
        try validateInitialized(url)
        try validateArchitecture(url)
    }
    public static func validateArchitecture(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: canonical(url).appendingPathComponent("system.reg"))
        defer { try? handle.close() }
        let header = String(decoding: try handle.read(upToCount: 4096) ?? Data(), as: UTF8.self)
        if header.components(separatedBy: .newlines).contains("#arch=win32") {
            throw BridgeError.invalidPrefix("This environment is win32. Bridge's supported WoW64 engines require win64; create a separate environment without changing this one.")
        }
    }
    public static func ownedBottle(at url: URL, runtimeID: UUID) throws -> Bottle {
        let path = try canonical(url)
        let owner = try JSONDecoder().decode(Bottle.self, from: Data(contentsOf: path.appendingPathComponent(".bridge-bottle.json")))
        guard owner.managed, owner.prefix.standardizedFileURL.path == path.path, owner.runtimeID == runtimeID else {
            throw BridgeError.invalidPrefix("Environment ownership or engine does not match. Automatic repair is unavailable.")
        }
        return owner
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
    private let readinessAttempts: Int
    private let readinessInterval: Duration
    private var active: Set<String> = []
    private static let marker = ".bridge-bottle.json"
    public init(executor: any ProcessExecuting = FoundationProcessExecutor(), runtimes: any RuntimeManaging = RuntimeManager(), readinessAttempts: Int = 120, readinessInterval: Duration = .milliseconds(250)) {
        self.executor = executor; self.runtimes = runtimes
        self.readinessAttempts = max(1, min(readinessAttempts, 120)); self.readinessInterval = min(max(readinessInterval, .zero), .milliseconds(250))
    }
    public func create(name: String, prefix: URL, runtime: WineRuntime, approved: Bool,
                       output: @escaping OutputHandler) async throws -> Bottle {
        guard approved else { throw BridgeError.approvalRequired }
        guard BackendCapabilities(runtime: runtime).supportsStandardPrefixes else {
            throw BridgeError.unsupported("This provider cannot use the generic Wine prefix adapter.")
        }
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
                workingDirectory: path, timeout: 120, removingInheritedEnvironment: ExecutionEnvironmentPolicy.managedKeys), output: output)
            guard result.exitCode == 0, !result.wasSignalled else {
                throw BridgeError.invalidPrefix("wineboot failed (exit \(result.exitCode)). Check process output.")
            }
            try await waitUntilInitialized(path)
            return bottle
        } catch {
            // Keep a partial prefix: Wine children may still be running after an error.
            // The user can inspect it; no arbitrary recursive cleanup on failure.
            throw BridgeError.invalidPrefix("Bottle initialization failed. A partial prefix was retained at \(path.path): \(error.localizedDescription)")
        }
    }
    private func waitUntilInitialized(_ path: URL) async throws {
        for attempt in 0..<readinessAttempts {
            try Task.checkCancellation()
            if (try? PrefixPolicy.validateInitialized(path)) != nil {
                try PrefixPolicy.validateWin64(path); return
            }
            if attempt + 1 < readinessAttempts { try await Task.sleep(for: readinessInterval) }
        }
        throw BridgeError.invalidPrefix("Environment initialization did not finish within the readiness window. Files were preserved; wait for Wine to finish or use Repair.")
    }
    public func repair(_ bottle: Bottle, runtime: WineRuntime, approved: Bool, output: @escaping OutputHandler) async throws -> Bottle {
        guard approved else { throw BridgeError.approvalRequired }
        try EnvironmentRecovery.validateNoInterruptedRestore(bottle.prefix)
        guard bottle.runtimeID == runtime.id, bottle.managed,
              try PrefixPolicy.ownedBottle(at: bottle.prefix, runtimeID: runtime.id).id == bottle.id else {
            throw BridgeError.invalidPrefix("Repair requires a matching Bridge-owned environment and engine.")
        }
        guard BackendCapabilities(runtime: runtime).supportsStandardPrefixes else { throw BridgeError.unsupported("Provider-specific repair is unavailable.") }
        try runtimes.validate(runtime, forLaunch: true)
        let path = try PrefixPolicy.canonical(bottle.prefix)
        if FileManager.default.fileExists(atPath: path.appendingPathComponent("system.reg").path) {
            try PrefixPolicy.validateArchitecture(path)
        }
        guard !DXVKInstaller.hasInstallation(bottle) else {
            throw BridgeError.invalidPrefix("Restore imported graphics libraries before repairing this environment.")
        }
        guard !active.contains(path.path) else { throw BridgeError.busy }
        active.insert(path.path); defer { active.remove(path.path) }
        // Exactly one approved update, never change an existing prefix's architecture.
        let result = try await executor.run(.init(executable: runtime.executable, arguments: ["wineboot", "-u"],
            environment: ["WINEPREFIX": path.path], workingDirectory: path, timeout: 120, removingInheritedEnvironment: ExecutionEnvironmentPolicy.managedKeys), output: output)
        guard result.exitCode == 0, !result.wasSignalled else { throw BridgeError.invalidPrefix("Environment repair failed (exit \(result.exitCode)); data was preserved.") }
        try await waitUntilInitialized(path)
        return bottle
    }
    public func enumerate(_ configured: [Bottle]) -> [Bottle] {
        configured.filter { (try? PrefixPolicy.validateInitialized($0.prefix)) != nil }
    }
    public func configure(_ bottle: Bottle, name: String, graphics: GraphicsBackend) throws -> Bottle {
        guard !active.contains(try PrefixPolicy.canonical(bottle.prefix).path) else { throw BridgeError.busy }
        if DXVKInstaller.hasInstallation(bottle), graphics != .dxvkMoltenVK {
            throw BridgeError.invalidPrefix("Restore the imported DXVK DLLs before switching graphics backends.")
        }
        if graphics == .dxvkMoltenVK { try DXVKInstaller.validateInstallation(bottle) }
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
              owner.id == bottle.id, owner.managed, owner.prefix.isFileURL,
              owner.prefix.standardizedFileURL.path == path.path else {
            throw BridgeError.invalidPrefix("Refusing deletion: prefix has no matching Bridge ownership record.")
        }
        try FileManager.default.removeItem(at: path)
    }
    public func acquire(_ bottle: Bottle) throws {
        try PrefixPolicy.validateWin64(bottle.prefix)
        try EnvironmentRecovery.validateNoInterruptedRestore(bottle.prefix)
        let path = try PrefixPolicy.canonical(bottle.prefix).path
        guard !active.contains(path) else { throw BridgeError.busy }
        active.insert(path)
    }
    public func release(_ bottle: Bottle) {
        // Release the leased path even if a caller has removed the prefix.
        active.remove(bottle.prefix.resolvingSymlinksInPath().standardizedFileURL.path)
    }
}
