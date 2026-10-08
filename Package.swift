// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.library(name: "BridgeCore", targets: ["BridgeCore"])]
var targets: [Target] = [
    .target(name: "BridgeCore"),
    .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"])
]
#if os(macOS)
products.append(.executable(name: "Bridge", targets: ["BridgeApp"]))
targets.append(.executableTarget(name: "BridgeApp", dependencies: ["BridgeCore"]))
#endif

let package = Package(
    name: "Bridge", platforms: [.macOS(.v14)],
    products: products, targets: targets, swiftLanguageModes: [.v6]
)
