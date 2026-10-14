import Foundation

public enum ExecutionEnvironmentPolicy {
    // Runtime-controlled graphics must not leak from the launcher's parent process.
    // Ordinary provider environment (PATH, locale, etc.) remains available.
    public static let managedKeys = ["WINEPREFIX", "WINEARCH", "WINELOADER", "WINESERVER", "WINEDLLPATH", "WINEDLLOVERRIDES", "WINE_D3D_CONFIG", "DXVK_LOG_LEVEL", "DXVK_LOG_PATH", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH"]
    public static func validate(overrides: [String: String]) throws {
        guard overrides.keys.allSatisfy({ !managedKeys.contains($0) && $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }),
              overrides.values.allSatisfy({ !$0.contains("\0") }) else {
            throw BridgeError.unsupported("Invalid environment override. Prefix, architecture, loader and graphics variables are managed by Win2Mac.")
        }
    }
    public static func effectiveBottle(application: ApplicationEntry, bottle: Bottle) throws -> Bottle {
        var effective = bottle
        if let selected = application.graphicsOverride {
            // DLL installations are shared prefix state, never a per-game override.
            guard selected != .dxvkMoltenVK || bottle.graphics == .dxvkMoltenVK else {
                throw BridgeError.unsupported("DXVK needs a separately approved installation in a dedicated environment.")
            }
            guard bottle.graphics != .dxvkMoltenVK || selected == .dxvkMoltenVK else {
                throw BridgeError.unsupported("Restore shared DXVK files or use a dedicated environment before changing this game's graphics.")
            }
            effective.graphics = selected
        }
        return effective
    }
    public static func environment(application: ApplicationEntry, bottle: Bottle,
                                   graphics: any GraphicsManaging = GraphicsManager()) throws -> [String: String] {
        var result = application.environment ?? [:]
        try validate(overrides: result)
        let effective = try effectiveBottle(application: application, bottle: bottle)
        result.merge(try graphics.environment(for: effective.graphics)) { _, managed in managed }
        result["WINEPREFIX"] = try PrefixPolicy.canonical(bottle.prefix).path
        return result
    }
}

public enum RuntimeProvider: String, Codable, CaseIterable, Sendable {
    case genericWine, crossOver, gamePortingToolkit
    public var documentation: URL {
        switch self {
        case .genericWine: URL(string: "https://github.com/Gcenx/macOS_Wine_builds")!
        case .crossOver: URL(string: "https://www.codeweavers.com/crossover")!
        case .gamePortingToolkit: URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
        }
    }
    public var integrationNote: String {
        switch self {
        case .genericWine: "User-installed provider-documented Wine CLI only; verify the provider's macOS, WoW64 and graphics requirements. Wine LGPL and each distribution's component terms apply."
        case .crossOver: "Commercial provider product; no redistribution or private-binary adapter is supplied. Use its supported application and license."
        case .gamePortingToolkit: "Apple evaluation/provider terms apply; no redistribution or generic-prefix integration is supplied."
        }
    }
}

public struct RuntimeIdentity: Codable, Equatable, Sendable {
    public let sha256: String
    public let recordedAt: Date
    public let scope: String
    public init(sha256: String, recordedAt: Date = Date()) {
        self.sha256 = sha256; self.recordedAt = recordedAt
        scope = "Primary executable only; wrapper payloads and adjacent libraries are not authenticated."
    }
}

public enum RuntimeIntegrity {
    public static func record(_ runtime: WineRuntime) throws -> WineRuntime {
        var result = runtime
        result.identity = RuntimeIdentity(sha256: try FileIntegrity.sha256(runtime.executable))
        return result
    }
    public static func validate(_ runtime: WineRuntime) throws {
        if let identity = runtime.identity {
            guard identity.sha256 == (try FileIntegrity.sha256(runtime.executable)) else {
                throw BridgeError.invalidRuntime("The recorded engine executable changed. Keep the existing environment; add the updated engine as a separate runtime and review it before switching.")
            }
        }
    }
}
