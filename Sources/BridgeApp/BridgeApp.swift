import SwiftUI
import Foundation
import BridgeCore

@main
struct BridgeApp: App {
    @StateObject private var model = BridgeModel()
    init() {
        if CommandLine.arguments.contains("--bridge-self-check") {
            // Exercise app/framework loading without launching UI or external software.
            let graphics = GraphicsManager()
            guard graphics.capabilities().contains(where: { $0.configurable }), HostCapabilities.current.isMacOS else {
                exit(EXIT_FAILURE)
            }
            print("Bridge startup check passed; no Wine runtime or Windows executable was launched.")
            exit(EXIT_SUCCESS)
        }
    }
    var body: some Scene {
        WindowGroup("Bridge") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 650)
                .task { await model.load() }
        }
        .defaultSize(width: 1100, height: 760)
    }
}
