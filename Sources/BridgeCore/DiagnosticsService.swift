import Foundation

public protocol DiagnosticsCollecting: Sendable {
    func report(snapshot: LibrarySnapshot, result: ProcessResult?, recentOutput: String) -> String
}

public struct DiagnosticsService: DiagnosticsCollecting {
    private let home: URL
    private let host: HostCapabilities
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, host: HostCapabilities = .current) {
        self.home = home; self.host = host
    }
    public func redact(_ text: String, paths: [URL] = []) -> String {
        var redacted = text
        let known = ([home] + paths).map(\.path).filter { !$0.isEmpty && $0 != "/" }.sorted { $0.count > $1.count }
        for path in known { redacted = redacted.replacingOccurrences(of: path, with: "<private-path>") }
        // Heuristic only: no guarantee arbitrary binary output is safe to share.
        redacted = redacted.replacingOccurrences(of: #"(?<![A-Za-z0-9:])/(?:Users|home|private|tmp|var|Volumes|workspace)/[^\n\r\t\"']+"#,
                                                 with: "<private-path>", options: .regularExpression)
        return redacted
    }
    public func report(snapshot: LibrarySnapshot, result: ProcessResult?, recentOutput: String) -> String {
        let paths = snapshot.applications.map(\.executable) + snapshot.bottles.map(\.prefix) + snapshot.runtimes.map(\.executable)
        let runtimes = snapshot.runtimes.map { "\($0.name): \($0.architecture.rawValue), version: \($0.version ?? "unprobed"), x64 declared: \($0.supportsWindowsX64)" }.joined(separator: "\n")
        let exit = result.map { "\($0.exitCode) (signal: \($0.wasSignalled))" } ?? "No completed launch"
        let graphics = snapshot.bottles.map { "\($0.name): \($0.graphics.displayName)" }.joined(separator: "\n")
        let report = """
        Bridge Phase 1 diagnostics — review before sharing
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        macOS: \(host.isMacOS), Apple Silicon: \(host.isAppleSilicon), Rosetta file present: \(host.rosettaInstalled)
        Applications: \(snapshot.applications.count), bottles: \(snapshot.bottles.count)
        Runtimes (user-reported x64 capability is not a compatibility test):
        \(runtimes)
        Configured bottle graphics (requested settings, not verified capabilities):
        \(graphics)
        Last exit: \(exit)
        Recent console (may contain secrets even after path redaction):
        \(String(recentOutput.suffix(65_536)))
        """
        return redact(report, paths: paths)
    }
}
