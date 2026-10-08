import SwiftUI
import BridgeCore

@main
struct BridgeApp: App {
    @StateObject private var model = BridgeModel()
    var body: some Scene {
        WindowGroup("Bridge") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 650)
                .task { await model.load() }
        }
        .defaultSize(width: 1100, height: 760)
    }
}
