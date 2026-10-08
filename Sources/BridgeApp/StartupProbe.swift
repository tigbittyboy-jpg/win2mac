import AppKit
import Foundation

/// Release verification only: creates the normal SwiftUI window and loads an
/// fresh library and passively discovers installed paths. Never probes or
/// launches a Wine runtime or EXE.
@MainActor
enum StartupProbe {
    static var reportURL: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--bridge-ui-smoke-test"),
              arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }
    private static var started = false

    static func checkWindow(model: BridgeModel) async {
        guard let report = reportURL, !started else { return }
        started = true
        for _ in 0..<100 {
            if let window = NSApplication.shared.windows.first(where: {
                $0.isVisible && $0.contentView != nil && $0.frame.width >= 900 && $0.frame.height >= 650
            }) {
                finish(report: report, success: model.loaded && model.errorMessage == nil,
                       windowVisible: window.isVisible)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        finish(report: report, success: false, windowVisible: false)
    }

    private static func finish(report: URL, success: Bool, windowVisible: Bool) {
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "success": success, "windowVisible": windowVisible,
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "runtimeExecuted": false
            ], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: report, options: .atomic)
            print("Bridge full-window startup check: \(success ? "passed" : "failed")")
        } catch {
            FileHandle.standardError.write(Data("Cannot write Bridge startup report.\n".utf8))
            exit(EXIT_FAILURE)
        }
        if success { NSApplication.shared.terminate(nil) }
        else { exit(EXIT_FAILURE) }
    }
}
