import Foundation

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case runtimeDefault, wineD3D, dxvkMoltenVK, d3dMetal
}

public struct GraphicsCapability: Sendable {
    public let backend: GraphicsBackend
    public let description: String
    public let configurable: Bool
    public let distributionNote: String
}

public protocol GraphicsManaging: Sendable {
    func capabilities() -> [GraphicsCapability]
    func environment(for backend: GraphicsBackend) throws -> [String: String]
}

public struct GraphicsManager: GraphicsManaging {
    public init() {}
    public func capabilities() -> [GraphicsCapability] {
        [
            .init(backend: .runtimeDefault, description: "Use the runtime's existing graphics configuration",
                  configurable: true, distributionNote: "Bridge supplies no translation libraries."),
            .init(backend: .wineD3D, description: "WineD3D; API/driver support depends on the engine",
                  configurable: false, distributionNote: "Wine licensing applies; no components bundled."),
            .init(backend: .dxvkMoltenVK, description: "Direct3D to Vulkan to Metal; engine-specific requirements",
                  configurable: false, distributionNote: "Review DXVK/MoltenVK licenses and runtime compatibility."),
            .init(backend: .d3dMetal, description: "Provider-supported Direct3D to Metal translation",
                  configurable: false, distributionNote: "Apple/provider terms apply; not redistributed by Bridge.")
        ]
    }
    public func environment(for backend: GraphicsBackend) throws -> [String: String] {
        guard backend == .runtimeDefault else {
            throw BridgeError.unsupported("Phase 1 only supports the runtime's existing graphics configuration.")
        }
        return [:]
    }
}
