import SwiftUI
import Foundation
import BridgeCore

@main
struct BridgeApp: App {
    @StateObject private var model: BridgeModel
    init() {
        if let report = StartupProbe.reportURL {
            // A fresh store exercises normal load/UI without reading user data.
            _model = StateObject(wrappedValue: BridgeModel(library: ApplicationLibrary(
                file: report.deletingLastPathComponent().appendingPathComponent("smoke-library.json"))))
        } else {
            _model = StateObject(wrappedValue: BridgeModel())
        }
        if CommandLine.arguments.contains("--bridge-self-check") {
            // Check native process startup without launching external software.
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
                .task {
                    await model.load()
                    await StartupProbe.checkWindow(model: model)
                }
        }
        .defaultSize(width: 1100, height: 760)
    }
}
