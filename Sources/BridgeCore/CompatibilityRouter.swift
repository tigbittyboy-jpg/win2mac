import Foundation

public enum BackendFamily: String, Sendable { case wine, crossover, gamePortingToolkit }
public struct BackendCapabilities: Sendable {
    public let family: BackendFamily
    public let architectures: [WindowsMachine]
    public let hostArchitecture: RuntimeArchitecture
    public let graphics: [GraphicsBackend]
    public let requirements: [String]
    public let supportsStandardPrefixes: Bool
    public init(runtime: WineRuntime) {
        let path = runtime.executable.path.lowercased()
        let detected: BackendFamily = path.contains("crossover") ? .crossover :
            (path.contains("game porting toolkit") || path.contains("game-porting-toolkit")) ? .gamePortingToolkit : .wine
        family = runtime.provider.map {
            switch $0 { case .genericWine: .wine; case .crossOver: .crossover; case .gamePortingToolkit: .gamePortingToolkit }
        } ?? detected
        supportsStandardPrefixes = family == .wine && detected == .wine
        architectures = supportsStandardPrefixes ? (runtime.supportsWindowsX64 ? [.x64] : []) +
            (runtime.supportsWindowsX86 == true ? [.x86] : []) : []
        hostArchitecture = runtime.architecture
        graphics = supportsStandardPrefixes ? [.runtimeDefault, .wineD3DVulkan] : []
        requirements = ["Provider-documented Windows execution support", "A supported 64-bit macOS engine"]
    }
}

/// Generic Wine adapter only. Proprietary integrations need their own command/prefix adapter.
public struct CompatibilityRouter: Sendable {
    private let runtimes: any RuntimeManaging
    public init(runtimes: any RuntimeManaging = RuntimeManager()) { self.runtimes = runtimes }
    public func select(info: ExecutableInfo, installed: [WineRuntime], preferred: UUID? = nil) throws -> WineRuntime {
        guard info.machine == .x86 || info.machine == .x64 else {
            throw BridgeError.unsupported("This Windows \(info.machine.rawValue) application has no supported Bridge backend. ARM64 and ARM64EC require a dedicated provider integration; Rosetta does not run Windows apps by itself.")
        }
        var reasons: [String] = []
        let ordered = installed.sorted { a, b in
            if (a.id == preferred) != (b.id == preferred) { return a.id == preferred }
            if (a.architecture == .arm64 || a.architecture == .universal) != (b.architecture == .arm64 || b.architecture == .universal) {
                return a.architecture == .arm64 || a.architecture == .universal
            }
            if (a.version != nil) != (b.version != nil) { return a.version != nil }
            return a.executable.path < b.executable.path
        }
        for runtime in ordered {
            let capabilities = BackendCapabilities(runtime: runtime)
            guard capabilities.supportsStandardPrefixes else { reasons.append("\(runtime.name) needs a provider-specific adapter."); continue }
            guard capabilities.architectures.contains(info.machine) else { reasons.append("\(runtime.name) has no confirmed \(info.machine.rawValue) support."); continue }
            do { try runtimes.validate(runtime, forLaunch: true); return runtime }
            catch { reasons.append(error.localizedDescription) }
        }
        throw BridgeError.invalidRuntime(installed.isEmpty ? "No Windows compatibility engine is installed. Open Compatibility to set one up." :
            "No configured engine can prepare this application. " + reasons.joined(separator: " "))
    }
}
