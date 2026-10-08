import Foundation

public enum BridgeError: Error, LocalizedError, Sendable, Equatable {
    case approvalRequired, invalidRuntime(String), invalidExecutable(String), invalidPrefix(String)
    case unsupported(String), persistence(String), process(String), busy

    public var errorDescription: String? {
        switch self {
        case .approvalRequired: "Explicit approval is required before executing software."
        case .invalidRuntime(let reason), .invalidExecutable(let reason), .invalidPrefix(let reason),
             .unsupported(let reason), .persistence(let reason), .process(let reason): reason
        case .busy: "Another operation is using this launcher. Wait for it to finish."
        }
    }
}

public enum RuntimeArchitecture: String, Codable, CaseIterable, Sendable {
    case x86_64, arm64, universal, unknown
}

public struct WineRuntime: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var executable: URL
    public var architecture: RuntimeArchitecture
    public var supportsWindowsX64: Bool
    public var version: String?

    public init(id: UUID = UUID(), name: String, executable: URL,
                architecture: RuntimeArchitecture = .unknown, supportsWindowsX64: Bool = false,
                version: String? = nil) {
        self.id = id; self.name = name; self.executable = executable
        self.architecture = architecture; self.supportsWindowsX64 = supportsWindowsX64
        self.version = version
    }
}

public struct Bottle: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var prefix: URL
    public var runtimeID: UUID
    public var managed: Bool
    public var graphics: GraphicsBackend

    public init(id: UUID = UUID(), name: String, prefix: URL, runtimeID: UUID,
                managed: Bool = false, graphics: GraphicsBackend = .runtimeDefault) {
        self.id = id; self.name = name; self.prefix = prefix; self.runtimeID = runtimeID
        self.managed = managed; self.graphics = graphics
    }
}

public struct ApplicationEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var executable: URL
    public var bottleID: UUID?
    public var arguments: [String]
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, executable: URL, bottleID: UUID? = nil,
                arguments: [String] = [], addedAt: Date = Date()) {
        self.id = id; self.name = name; self.executable = executable; self.bottleID = bottleID
        self.arguments = arguments; self.addedAt = addedAt
    }
}

public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var applications: [ApplicationEntry] = []
    public var runtimes: [WineRuntime] = []
    public var bottles: [Bottle] = []
    public init() {}
}

public struct HostCapabilities: Sendable {
    public var isMacOS: Bool
    public var isAppleSilicon: Bool
    public var rosettaInstalled: Bool

    public init(isMacOS: Bool, isAppleSilicon: Bool, rosettaInstalled: Bool) {
        self.isMacOS = isMacOS; self.isAppleSilicon = isAppleSilicon
        self.rosettaInstalled = rosettaInstalled
    }

    public static var current: Self {
        #if os(macOS)
        let mac = true
        #else
        let mac = false
        #endif
        #if arch(arm64)
        let arm = true
        #else
        let arm = false
        #endif
        return Self(isMacOS: mac, isAppleSilicon: mac && arm,
                    rosettaInstalled: FileManager.default.fileExists(
                        atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime"))
    }
}

public enum BridgePaths {
    public static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bridge", isDirectory: true)
    }
    public static var library: URL { dataDirectory.appendingPathComponent("library.json") }
    public static var bottles: URL { dataDirectory.appendingPathComponent("Bottles", isDirectory: true) }
}
