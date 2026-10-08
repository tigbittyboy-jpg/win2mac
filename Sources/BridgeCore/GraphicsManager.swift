import Foundation

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case runtimeDefault, wineD3DVulkan, wineD3D, dxvkMoltenVK, d3dMetal

    public var displayName: String {
        switch self {
        case .runtimeDefault: "Runtime default"
        case .wineD3DVulkan: "WineD3D Vulkan (experimental)"
        case .wineD3D: "WineD3D (provider configuration required)"
        case .dxvkMoltenVK: "DXVK / MoltenVK (provider configuration required)"
        case .d3dMetal: "Direct3D / Metal (provider configuration required)"
        }
    }
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
            .init(backend: .wineD3DVulkan, description: "Request WineD3D's built-in Vulkan renderer; requires engine and Vulkan/Metal support",
                  configurable: true, distributionNote: "Experimental runtime setting only; no libraries installed or bundled."),
            .init(backend: .wineD3D, description: "WineD3D; API/driver support depends on the engine",
                  configurable: false, distributionNote: "Wine licensing applies; no components bundled."),
            .init(backend: .dxvkMoltenVK, description: "Direct3D to Vulkan to Metal; engine-specific requirements",
                  configurable: false, distributionNote: "Review DXVK/MoltenVK licenses and runtime compatibility."),
            .init(backend: .d3dMetal, description: "Provider-supported Direct3D to Metal translation",
                  configurable: false, distributionNote: "Apple/provider terms apply; not redistributed by Bridge.")
        ]
    }
    public func environment(for backend: GraphicsBackend) throws -> [String: String] {
        switch backend {
        case .runtimeDefault:
            return [:]
        case .wineD3DVulkan:
            // Wine documents WINE_D3D_CONFIG and this renderer value in
            // dlls/wined3d/wined3d_main.c. It affects the approved child only;
            // no registry edits, DLL overrides, or graphics downloads occur.
            return ["WINE_D3D_CONFIG": "renderer=vulkan"]
        default:
            throw BridgeError.unsupported("This graphics backend requires a provider-specific integration. Bridge installs no translation libraries.")
        }
    }
}
