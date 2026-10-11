import Foundation

public enum FailureCategory: String, Codable, Sendable {
    case architecture, missingEngine, rosetta, dependency, path, environment, prefix, graphics, permission, crash, unsupportedFormat, unknown
}
public struct LaunchDiagnosis: Equatable, Sendable {
    public let category: FailureCategory
    public let title: String
    public let guidance: String
    public let technicalDetails: String
    public static func classify(error: Error? = nil, result: ProcessResult? = nil) -> Self {
        let details = [error?.localizedDescription, result.map { "Exit \($0.exitCode)\($0.wasSignalled ? " (signal)" : "")\n\($0.stderr)\n\($0.stdout)" }].compactMap { $0 }.joined(separator: "\n")
        let text = details.lowercased()
        let category: FailureCategory
        let title: String, guidance: String
        if text.contains("rosetta") && !text.contains("does not run") {
            category = .rosetta; title = "This engine needs Rosetta 2"; guidance = "Follow Apple's Rosetta installation instructions, then check Compatibility again."
        } else if text.contains("permission denied") || text.contains("operation not permitted") || text.contains("sandbox_extension") {
            category = .permission; title = "macOS blocked access"; guidance = "Check the file's location and macOS permission prompts. Keep macOS security protections enabled."
        } else if text.contains("feature levels") || text.contains("failed to initialize graphics") || text.contains("failed to create swapchain") || text.contains("vk_error") {
            category = .graphics; title = "The graphics backend could not initialize"; guidance = "Check this engine's supported graphics configuration. Installing Windows DirectX alone does not add Metal translation."
        } else if text.contains("import_dll") && (text.contains("not found") || text.contains("failed")) {
            category = .dependency; title = "A Windows dependency is missing"; guidance = "Technical Details identifies the library. Use the application's official installer or a trusted runtime dependency installer in this environment."
        } else if text.contains("environment override") || text.contains("name=value") {
            category = .environment; title = "A launch setting is invalid"; guidance = "Check environment overrides in Application Settings. Bridge controls prefix, architecture and graphics variables."
        } else if text.contains("prefix") || text.contains("wineboot") {
            category = .prefix; title = "The Windows environment could not start"; guidance = "Repair this Bridge-owned environment from Settings. Existing application data will be retained."
        } else if text.contains("architecture") || text.contains("wow64") || text.contains("arm64") {
            category = .architecture; title = "This application needs a different engine"; guidance = "Check Compatibility for an engine with documented support for this Windows architecture."
        } else if text.contains("pe ") || text.contains("executable image") || text.contains("not a windows") {
            category = .unsupportedFormat; title = "This executable could not be inspected"; guidance = "Select an intact Windows EXE. Obtain a fresh copy from its publisher if the file is damaged."
        } else if text.contains("no such file") || text.contains("file not found") || text.contains("readable") {
            category = .path; title = "An application file could not be found"; guidance = "Use Change Executable in the application's settings to select its current location."
        } else if text.contains("engine") || text.contains("runtime") {
            category = .missingEngine; title = "A compatible engine is not ready"; guidance = "Open Compatibility, select an installed engine, confirm its documented capabilities, and save its settings."
        } else if result?.wasSignalled == true || result.map({ $0.exitCode != 0 }) == true {
            category = .crash; title = "The application stopped unexpectedly"; guidance = "The exit code alone does not identify the cause. Open the saved launch log for evidence; Bridge will not repeatedly restart it."
        } else {
            category = .unknown; title = "Bridge could not complete this operation"; guidance = "Open Technical Details or export diagnostics. No application data was automatically deleted."
        }
        return .init(category: category, title: title, guidance: guidance, technicalDetails: details)
    }
}

/// Synchronous ordered writes happen on process pipe workers, never via queued UI tasks.
/// Locks protect the handle; no @unchecked state escapes the lock.
public final class RunLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var writeFailure: String?
    public init(directory: URL = BridgePaths.dataDirectory.appendingPathComponent("Logs")) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BridgeError.persistence("Could not create the launch log.")
        }
        handle = try FileHandle(forWritingTo: url)
    }
    public func append(_ event: ProcessOutput) {
        lock.lock(); defer { lock.unlock() }
        do { try handle?.write(contentsOf: Data("[\(event.stream.rawValue)] \(event.text)".utf8)) }
        catch { writeFailure = error.localizedDescription }
    }
    public func finish() throws {
        lock.lock(); defer { lock.unlock() }
        try handle?.synchronize(); try handle?.close(); handle = nil
        if let writeFailure { throw BridgeError.persistence("Launch log could not be fully saved: \(writeFailure)") }
    }
    deinit { try? handle?.close() }
}

public struct RepairRecord: Codable, Equatable, Sendable {
    public let date: Date
    public let bottleID: UUID
    public let outcome: String
    public init(bottleID: UUID, outcome: String) { date = Date(); self.bottleID = bottleID; self.outcome = outcome }
}

public enum LibrarySort: String, CaseIterable, Sendable { case name = "Name", recent = "Recently launched", added = "Recently added" }
public enum LibraryQuery {
    public static func filter(_ entries: [ApplicationEntry], search: String, favoritesOnly: Bool, sort: LibrarySort) -> [ApplicationEntry] {
        entries.filter { (!favoritesOnly || $0.favorite == true) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted { a, b in
                switch sort {
                case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
                case .recent: return (a.lastLaunchedAt ?? .distantPast) > (b.lastLaunchedAt ?? .distantPast)
                case .added: return a.addedAt > b.addedAt
                }
            }
    }
}
