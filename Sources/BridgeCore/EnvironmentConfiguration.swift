import Foundation

public enum WindowsVersion: String, Codable, CaseIterable, Sendable { case windows7, windows10, windows11
    public var wineValue: String { switch self { case .windows7: "win7"; case .windows10: "win10"; case .windows11: "win11" } }
}
public protocol EnvironmentConfiguring: Sendable {
    func setWindowsVersion(_ version: WindowsVersion, bottle: Bottle, runtime: WineRuntime,
                           approved: Bool, output: @escaping OutputHandler) async throws -> Bottle
}
public struct EnvironmentConfigurationManager: EnvironmentConfiguring {
    private let executor: any ProcessExecuting
    private let runtimes: any RuntimeManaging
    private let bottles: any BottleManaging
    public init(executor: any ProcessExecuting = FoundationProcessExecutor(), runtimes: any RuntimeManaging = RuntimeManager(),
                bottles: any BottleManaging = BottleManager()) {
        self.executor = executor; self.runtimes = runtimes; self.bottles = bottles
    }
    public func setWindowsVersion(_ version: WindowsVersion, bottle: Bottle, runtime: WineRuntime,
                                  approved: Bool, output: @escaping OutputHandler) async throws -> Bottle {
        guard approved else { throw BridgeError.approvalRequired }
        guard bottle.managed, bottle.runtimeID == runtime.id,
              try PrefixPolicy.ownedBottle(at: bottle.prefix, runtimeID: runtime.id).id == bottle.id,
              BackendCapabilities(runtime: runtime).supportsStandardPrefixes else {
            throw BridgeError.invalidPrefix("Windows version changes need a matching owned environment and supported engine.")
        }
        try runtimes.validate(runtime, forLaunch: true)
        try await bottles.acquire(bottle)
        do {
            let result = try await executor.run(.init(executable: runtime.executable, arguments: ["winecfg", "-v", version.wineValue],
                environment: ["WINEPREFIX": try PrefixPolicy.canonical(bottle.prefix).path],
                workingDirectory: bottle.prefix, timeout: 60, removingInheritedEnvironment: ExecutionEnvironmentPolicy.managedKeys), output: output)
            guard result.exitCode == 0 && !result.wasSignalled else {
                throw BridgeError.process("Wine rejected the Windows version request (exit \(result.exitCode)). Existing data is retained; inspect the log before retrying.")
            }
            var updated = bottle; updated.requestedWindowsVersion = version
            await bottles.release(bottle); return updated
        } catch { await bottles.release(bottle); throw error }
    }
}

/// Launch configuration checkpoint, separate from launch history and game files.
public struct ApplicationConfiguration: Codable, Equatable, Sendable {
    public let applicationID: UUID
    public let bottleID: UUID
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: URL?
    public let graphicsOverride: GraphicsBackend?
    public init?(_ application: ApplicationEntry) {
        guard let bottleID = application.bottleID else { return nil }
        applicationID = application.id; self.bottleID = bottleID; arguments = application.arguments
        environment = application.environment; workingDirectory = application.workingDirectory; graphicsOverride = application.graphicsOverride
    }
    public func restoring(_ application: ApplicationEntry) throws -> ApplicationEntry {
        guard application.id == applicationID, application.bottleID == bottleID else {
            throw BridgeError.persistence("Saved settings belong to a different application or environment.")
        }
        try ExecutionEnvironmentPolicy.validate(overrides: environment ?? [:])
        var restored = application; restored.arguments = arguments; restored.environment = environment
        restored.workingDirectory = workingDirectory; restored.graphicsOverride = graphicsOverride; restored.executionConsent = nil
        return restored
    }
}
