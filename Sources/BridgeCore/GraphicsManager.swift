import Foundation

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case runtimeDefault, wineD3DVulkan, wineD3D, dxvkMoltenVK, d3dMetal

    public var displayName: String {
        switch self {
        case .runtimeDefault: "Runtime default"
        case .wineD3DVulkan: "WineD3D Vulkan (experimental)"
        case .wineD3D: "WineD3D (provider configuration required)"
        case .dxvkMoltenVK: "DXVK macOS (DirectX 10/11)"
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
            .init(backend: .dxvkMoltenVK, description: "Manually imported macOS DXVK libraries with Wine's built-in DXGI; requires a compatible runtime",
                  configurable: true, distributionNote: "User supplies libraries; no download or redistribution. Validate the provider's compatibility and license."),
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
        case .dxvkMoltenVK:
            // The macOS fork explicitly uses native d3d11/d3d10core and Wine's
            // built-in DXGI, unlike upstream DXVK. No native dxgi DLL is imported.
            return ["WINEDLLOVERRIDES": "d3d11,d3d10core=n;dxgi=b", "DXVK_LOG_LEVEL": "info", "DXVK_LOG_PATH": "none"]
        default:
            throw BridgeError.unsupported("This graphics backend requires a provider-specific integration. Bridge installs no translation libraries.")
        }
    }
}
