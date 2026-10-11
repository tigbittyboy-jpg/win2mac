import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import BridgeCore

enum NavigationSection: String, CaseIterable, Identifiable {
    case home = "Home", library = "Library", compatibility = "Compatibility", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house"
        case .library: "square.grid.2x2"
        case .compatibility: "checkmark.shield"
        case .settings: "gearshape"
        }
    }
}

struct ExecutionApproval: Identifiable {
    enum Operation {
        case probe(WineRuntime)
        case createBottle(name: String, prefix: URL, runtime: WineRuntime)
        case launch(ApplicationEntry, Bottle, WineRuntime)
        case prepare(ApplicationEntry, WineRuntime, URL)
        case repair(Bottle, WineRuntime)
        case installDXVK(DXVKPackage, Bottle)
        case restoreDXVK(Bottle)
    }
    let id = UUID()
    let operation: Operation
    var fingerprint: String? = nil
    var changesFiles: Bool {
        switch operation { case .installDXVK, .restoreDXVK: true; default: false }
    }
    var title: String { changesFiles ? "Approve graphics file changes" : "Approve software execution" }
    var actionTitle: String { changesFiles ? "Approve Changes" : "Approve and Run" }
    var details: String {
        switch operation {
        case .probe(let runtime):
            return "Run runtime version probe:\n\(runtime.executable.path)\nArgument: --version"
        case .createBottle(let name, let prefix, let runtime):
            return "Initialize bottle ‘\(name)’ using:\n\(runtime.executable.path)\nArguments: wineboot, -u\nPrefix: \(prefix.path)"
        case .prepare(let app, let runtime, let prefix):
            return "Prepare and launch ‘\(app.name)’:\nApplication: \(app.executable.path)\nEngine: \(runtime.executable.path)\nEnvironment: \(prefix.path)\nBridge may initialize this new, dedicated win64 environment using wineboot -u, then run the application. Existing game environments will not be changed."
        case .repair(let bottle, let runtime):
            return "Update the Bridge-owned environment ‘\(bottle.name)’ using wineboot -u:\n\(runtime.executable.path)\n\(bottle.prefix.path)\nExisting data is retained. Close all Wine applications using this environment first. This verifies environment structure, not game compatibility."
        case .launch(let app, let bottle, let runtime):
            var overrides = app.environment ?? [:]
            overrides.merge((try? GraphicsManager().environment(for: bottle.graphics)) ?? [:]) { _, managed in managed }
            let settings = overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            return "Launch ‘\(app.name)’:\n\(app.executable.path)\nRuntime: \(runtime.executable.path)\nPrefix: \(bottle.prefix.path)\nGraphics: \(bottle.graphics.displayName)\nWorking directory: \(app.workingDirectory?.path ?? app.executable.deletingLastPathComponent().path)\n\(settings.isEmpty ? "Uses runtime graphics settings" : settings)\nAdditional arguments: \(app.arguments.joined(separator: " | "))"
        case .installDXVK(let package, let bottle):
            return "Import user-provided macOS DXVK x64 libraries into ‘\(bottle.name)’:\nSource: \(package.source.path)\nPrefix: \(bottle.prefix.path)\nFiles: d3d11.dll, d3d10core.dll (\(package.byteCount) bytes captured for this approval)\nExisting files are backed up inside .bridge-dxvk. DXGI is unchanged. No Wine or DLL is executed during import. Publisher authenticity is not verified; use a package you trust whose provider supports your runtime. Close all Wine programs using this bottle first."
        case .restoreDXVK(let bottle):
            return "Restore original d3d11.dll and d3d10core.dll in:\n\(bottle.prefix.path)\nThis removes the imported replacements and restores the recorded prior graphics selection. No software is executed. Modified imported DLLs or incomplete backup records prevent automatic restoration. Close all Wine programs using this bottle first."
        }
    }
}

@MainActor
final class BridgeModel: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published var section: NavigationSection? = .home
    @Published var stage = "Ready"
    @Published var rememberApproval = false
    @Published var diagnosis: LaunchDiagnosis?
    @Published var installedTargets: [InstalledTarget] = []
    @Published var installerBottleID: UUID?
    private var activeLog: RunLog?
    private let environmentsDirectory: URL
    private let logsDirectory: URL
    @Published var selectedApplicationID: UUID?
    @Published var selectedRuntimeID: UUID? { didSet { syncRuntimeFields() } }
    @Published var runtimeArchitecture: RuntimeArchitecture = .unknown
    @Published var runtimeSupportsX64 = false
    @Published var runtimeSupportsX86 = false
    @Published var bottleName = "My Bottle"
    @Published var prefixPath = BridgePaths.bottles.appendingPathComponent("My Bottle").path
    @Published var argumentsText = ""
    @Published var workingDirectoryText = ""
    @Published var environmentText = ""
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var console = "Select a runtime and configure a bottle to begin.\n"
    @Published private(set) var diagnosticsText = ""
    @Published var errorMessage: String?
    @Published var pendingApproval: ExecutionApproval?
    @Published var pendingRemoval: Bottle?
    private var loadAttempted = false
    private var lastResult: ProcessResult?
    private var operationTask: Task<Void, Never>?
    private let library: any ApplicationLibraryStoring
    private let runtimes: any RuntimeManaging
    private let bottles: any BottleManaging
    private let launcher: any LaunchServing
    private let diagnostics: any DiagnosticsCollecting
    private let graphicsInstaller: any GraphicsInstalling

    init(library: any ApplicationLibraryStoring = ApplicationLibrary(),
         runtimes: any RuntimeManaging = RuntimeManager(),
         bottles: any BottleManaging = BottleManager(),
         launcher: (any LaunchServing)? = nil,
         diagnostics: any DiagnosticsCollecting = DiagnosticsService(),
         graphicsInstaller: (any GraphicsInstalling)? = nil,
         environmentsDirectory: URL = BridgePaths.bottles,
         logsDirectory: URL = BridgePaths.dataDirectory.appendingPathComponent("Logs")) {
        self.environmentsDirectory = environmentsDirectory; self.logsDirectory = logsDirectory
        self.library = library; self.runtimes = runtimes; self.bottles = bottles
        self.launcher = launcher ?? LaunchService(runtimes: runtimes, bottles: bottles)
        self.diagnostics = diagnostics
        self.graphicsInstaller = graphicsInstaller ?? DXVKInstaller(bottles: bottles)
    }
    var selectedApplication: ApplicationEntry? { snapshot.applications.first { $0.id == selectedApplicationID } }
    var selectedRuntime: WineRuntime? { snapshot.runtimes.first { $0.id == selectedRuntimeID } }
    var canEdit: Bool { loaded && !busy }
    var selectedRuntimeConfigured: Bool {
        guard let runtime = selectedRuntime else { return false }
        return BackendCapabilities(runtime: runtime).supportsStandardPrefixes && (try? runtimes.validate(runtime, forLaunch: true)) != nil
    }
    var canCreateBottle: Bool { canEdit && selectedRuntimeConfigured }
    func load() async {
        guard !loadAttempted else { return }; loadAttempted = true
        do {
            snapshot = try await library.load()
            // Inspect installed files only. Discovery never executes a candidate.
            try await addRuntimes(runtimes.discover())
            loaded = true
            selectedRuntimeID = snapshot.runtimes.first?.id
            selectApplication(snapshot.applications.first?.id)
            refreshDiagnostics()
        } catch { errorMessage = error.localizedDescription }
    }
    func selectApplication(_ id: UUID?) {
        selectedApplicationID = id
        argumentsText = selectedApplication?.arguments.joined(separator: "\n") ?? ""
        workingDirectoryText = selectedApplication?.workingDirectory?.path ?? ""
        environmentText = (selectedApplication?.environment ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
    private func syncRuntimeFields() {
        runtimeArchitecture = selectedRuntime?.architecture ?? .unknown
        runtimeSupportsX64 = selectedRuntime?.supportsWindowsX64 ?? false
        runtimeSupportsX86 = selectedRuntime?.supportsWindowsX86 == true
    }
    private func save(_ next: LibrarySnapshot) async throws {
        try await library.save(next); snapshot = next; refreshDiagnostics()
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard canEdit else { return }
        busy = true
        operationTask = Task {
            defer { if let activeLog { try? activeLog.finish(); self.activeLog = nil }; busy = false; operationTask = nil; if stage != "Finished" { stage = "Ready" }; refreshDiagnostics() }
            do {
                try await operation()
                if let activeLog { try activeLog.finish(); self.activeLog = nil }
            }
            catch is CancellationError { appendConsole(.init(stream: .stderr, text: "Operation stopped. Wine child processes may still be running.\n")) }
            catch {
                if let activeLog { activeLog.append(.init(stream: .stderr, text: error.localizedDescription + "\n")); try? activeLog.finish(); self.activeLog = nil }
                diagnosis = LaunchDiagnosis.classify(error: error)
                errorMessage = error.localizedDescription
            }
        }
    }
    private var outputHandler: OutputHandler {
        let log = activeLog
        return { [weak self] event in
            log?.append(event)
            Task { @MainActor [weak self] in
                if self?.stage == "Launching · awaiting process output" { self?.stage = "Running · compatibility unverified" }
                self?.appendConsole(event)
            }
        }
    }
    private func appendConsole(_ event: ProcessOutput) {
        console += (event.stream == .stderr ? "[stderr] " : "") + event.text
        if console.utf8.count > 65_536 { console = "[Earlier output omitted]\n" + String(console.suffix(16_000)) }
    }
    func stop() { operationTask?.cancel() }
    func clearConsole() { console = ""; refreshDiagnostics() }
    func refreshDiagnostics() {
        diagnosticsText = diagnostics.report(snapshot: snapshot, result: lastResult, recentOutput: console)
    }
    func copyDiagnostics() {
        refreshDiagnostics(); NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsText, forType: .string)
    }
    func selectEXE() {
        guard canEdit else { return }
        let panel = NSOpenPanel(); panel.title = "Run Windows App"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importExecutable(url)
    }
    func importExecutable(_ url: URL) {
        perform {
            self.stage = "Analyzing application"
            let info = try await Task.detached { try ExecutableInspector.inspect(url) }.value
            if let existing = self.snapshot.applications.first(where: { $0.executable == url }) {
                self.selectApplication(existing.id); self.section = .library; return
            }
            var app = ApplicationEntry(name: url.deletingPathExtension().lastPathComponent, executable: url)
            app.inspection = info; app.isInstaller = info.kind == .installerCandidate
            var next = self.snapshot; next.applications.append(app)
            try await self.save(next); self.selectApplication(app.id); self.section = .library
        }
    }
    func renameSelectedApplication(_ name: String) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { return }
        editSelected { $0.name = value }
    }
    func toggleFavorite(_ id: UUID) {
        perform {
            var next = self.snapshot
            if let index = next.applications.firstIndex(where: { $0.id == id }) { next.applications[index].favorite = !(next.applications[index].favorite ?? false) }
            try await self.save(next)
        }
    }
    func editSelected(_ update: @escaping @Sendable (inout ApplicationEntry) -> Void) {
        guard let id = selectedApplicationID else { return }
        perform {
            var next = self.snapshot
            if let index = next.applications.firstIndex(where: { $0.id == id }) { update(&next.applications[index]) }
            try await self.save(next)
        }
    }
    func changeExecutable() {
        guard canEdit else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let info = try ExecutableInspector.inspect(url)
            guard let index = self.snapshot.applications.firstIndex(where: { $0.id == self.selectedApplicationID }) else { return }
            var next = self.snapshot; next.applications[index].executable = url; next.applications[index].inspection = info
            try await self.save(next)
        }
    }
    func chooseIcon() {
        guard canEdit else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .icns]
        guard panel.runModal() == .OK, let source = panel.url, let id = selectedApplicationID else { return }
        perform {
            let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
            guard bytes.count <= 8 * 1024 * 1024, NSImage(data: bytes) != nil else { throw BridgeError.unsupported("Choose an image smaller than 8 MB.") }
            let directory = BridgePaths.dataDirectory.appendingPathComponent("Icons")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(id.uuidString + "." + source.pathExtension)
            try bytes.write(to: destination, options: .atomic)
            var next = self.snapshot
            if let index = next.applications.firstIndex(where: { $0.id == id }) { next.applications[index].customIcon = destination }
            try await self.save(next)
        }
    }
    func openApplicationFolder() {
        if let url = selectedApplication?.executable { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func openLaunchLog() {
        if let url = selectedApplication?.lastLog { NSWorkspace.shared.open(url) }
    }
    func exportDiagnostics() {
        refreshDiagnostics()
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Bridge-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try diagnosticsText.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }
    func removeSelectedApplication() {
        guard let id = selectedApplicationID else { return }
        perform {
            var next = self.snapshot; next.applications.removeAll { $0.id == id }
            try await self.save(next); self.selectApplication(next.applications.first?.id)
        }
    }
    func associateSelectedApplication(_ bottleID: UUID?) {
        guard let id = selectedApplicationID else { return }
        perform {
            var next = self.snapshot
            if let index = next.applications.firstIndex(where: { $0.id == id }) { next.applications[index].bottleID = bottleID }
            try await self.save(next)
        }
    }
    func saveArguments() {
        guard let id = selectedApplicationID else { return }
        let args = argumentsText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let directory = workingDirectoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrides = environmentText
        perform {
            var environment: [String: String] = [:]
            for line in overrides.components(separatedBy: .newlines) where !line.isEmpty {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw BridgeError.unsupported("Enter each environment override as NAME=value.") }
                environment[String(parts[0])] = String(parts[1])
            }
            if !directory.isEmpty {
                var isDirectory: ObjCBool = false
                guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw BridgeError.invalidPrefix("Choose an existing absolute working directory.")
                }
            }
            var next = self.snapshot
            if let index = next.applications.firstIndex(where: { $0.id == id }) {
                next.applications[index].arguments = args
                next.applications[index].workingDirectory = directory.isEmpty ? nil : URL(fileURLWithPath: directory, isDirectory: true)
                next.applications[index].environment = environment
            }
            try await self.save(next)
        }
    }
    func chooseRuntime() {
        guard canEdit else { return }
        let panel = NSOpenPanel(); panel.title = "Select the provider's Wine executable or supported wrapper"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the Wine executable supplied by your installed runtime, rather than a Windows EXE. App bundles can be opened to locate a provider-supported executable."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try await self.addRuntimes([self.runtimes.inspect(url)]) }
    }
    func discoverRuntimes() { perform { try await self.addRuntimes(self.runtimes.discover()) } }
    private func addRuntimes(_ found: [WineRuntime]) async throws {
        var next = snapshot
        for runtime in found where !next.runtimes.contains(where: { $0.executable.resolvingSymlinksInPath() == runtime.executable.resolvingSymlinksInPath() }) {
            next.runtimes.append(runtime)
        }
        if next != snapshot { try await save(next) }
        selectedRuntimeID = next.runtimes.first(where: { $0.executable.resolvingSymlinksInPath() == found.first?.executable.resolvingSymlinksInPath() })?.id ?? selectedRuntimeID
        if found.isEmpty { appendConsole(.init(stream: .stdout, text: "No installed Wine runtime found in common paths. Choose your provider's Wine executable, or install a compatible Wine runtime first. Bridge includes no Wine engine.\n")) }
    }
    func saveRuntimeSettings() {
        guard let id = selectedRuntimeID else { return }
        let architecture = runtimeArchitecture, x64 = runtimeSupportsX64, x86 = runtimeSupportsX86
        perform {
            var next = self.snapshot
            if let index = next.runtimes.firstIndex(where: { $0.id == id }) {
                next.runtimes[index].architecture = architecture; next.runtimes[index].supportsWindowsX64 = x64
                next.runtimes[index].supportsWindowsX86 = x86
            }
            try await self.save(next)
        }
    }
    func requestProbe() {
        guard canEdit, let runtime = selectedRuntime else { return }
        pendingApproval = ExecutionApproval(operation: .probe(runtime))
    }
    func requestCreateBottle() {
        guard canEdit, let runtime = selectedRuntime else { errorMessage = "Select and configure a runtime first."; return }
        do { try runtimes.validate(runtime, forLaunch: true) }
        catch { errorMessage = error.localizedDescription; return }
        guard prefixPath.hasPrefix("/"), !bottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter a bottle name and an absolute prefix path."; return
        }
        pendingApproval = ExecutionApproval(operation: .createBottle(name: bottleName, prefix: URL(fileURLWithPath: prefixPath), runtime: runtime))
    }
    func choosePrefixLocation() {
        guard canEdit else { return }
        let panel = NSOpenPanel(); panel.title = "Choose the parent directory for a new bottle"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefixPath = url.appendingPathComponent(bottleName.isEmpty ? "My Bottle" : bottleName).path
    }
    func associateExistingPrefix() {
        guard canEdit, let runtime = selectedRuntime else { errorMessage = "Select a runtime first."; return }
        let panel = NSOpenPanel(); panel.title = "Select an initialized Wine prefix"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            try PrefixPolicy.validateInitialized(url)
            let canonical = try PrefixPolicy.canonical(url)
            let bottle = (try? PrefixPolicy.ownedBottle(at: url, runtimeID: runtime.id)) ?? Bottle(name: url.lastPathComponent, prefix: canonical, runtimeID: runtime.id)
            var next = self.snapshot; next.bottles.append(bottle)
            try await self.save(next)
        }
    }
    func requestLaunch() {
        guard canEdit, let app = selectedApplication else { return }
        // Existing associations retain their settings. Remembered approval is bound
        // to both binary contents and launch configuration, not just a file path.
        if let bottle = snapshot.bottles.first(where: { $0.id == app.bottleID }),
           let runtime = snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) {
            perform {
                self.stage = "Checking compatibility"
                let fingerprint = try await Self.fingerprint(app: app, bottle: bottle, runtime: runtime)
                if app.executionConsent == fingerprint {
                    try await self.executeLaunch(app, bottle: bottle, runtime: runtime)
                } else {
                    self.rememberApproval = false
                    self.pendingApproval = ExecutionApproval(operation: .launch(app, bottle, runtime), fingerprint: fingerprint)
                }
            }
            return
        }
        do {
            let info = try ExecutableInspector.inspect(app.executable)
            let runtime = try CompatibilityRouter(runtimes: runtimes).select(info: info, installed: snapshot.runtimes, preferred: selectedRuntimeID)
            let prefix = environmentsDirectory.appendingPathComponent(app.id.uuidString, isDirectory: true)
            pendingApproval = ExecutionApproval(operation: .prepare(app, runtime, prefix))
        } catch { diagnosis = LaunchDiagnosis.classify(error: error); errorMessage = error.localizedDescription }
    }
    nonisolated private static func fingerprint(app: ApplicationEntry, bottle: Bottle, runtime: WineRuntime) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var hash = SHA256()
            let configuration: [String: String] = [
                "exe": app.executable.path, "engine": runtime.executable.path,
                "prefix": bottle.prefix.path, "graphics": bottle.graphics.rawValue,
                "workingDirectory": app.workingDirectory?.path ?? app.executable.deletingLastPathComponent().path,
                "architecture": runtime.architecture.rawValue,
                "x64": String(runtime.supportsWindowsX64), "x86": String(runtime.supportsWindowsX86 == true)
            ]
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            hash.update(data: try encoder.encode(configuration)); hash.update(data: try encoder.encode(app.arguments))
            hash.update(data: try encoder.encode(app.environment ?? [:]))
            for url in [app.executable, runtime.executable] {
                let handle = try FileHandle(forReadingFrom: url)
                do {
                    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                        try Task.checkCancellation(); hash.update(data: chunk)
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
                hash.update(data: Data([0]))
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
    func requestRepair(_ bottle: Bottle) {
        guard canEdit, let runtime = snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) else { return }
        pendingApproval = ExecutionApproval(operation: .repair(bottle, runtime))
    }
    func importInstalledTarget(_ target: InstalledTarget) {
        guard let bottleID = installerBottleID else { return }
        perform {
            var app = ApplicationEntry(name: target.executable.deletingPathExtension().lastPathComponent,
                executable: target.executable, bottleID: bottleID)
            app.inspection = target.info
            var next = self.snapshot
            guard !next.applications.contains(where: { $0.executable == app.executable }) else { return }
            next.applications.append(app); try await self.save(next); self.selectApplication(app.id)
            self.installedTargets = []; self.installerBottleID = nil
        }
    }
    private func executeLaunch(_ app: ApplicationEntry, bottle: Bottle, runtime: WineRuntime) async throws {
        let log = try activeLog ?? RunLog(directory: logsDirectory); activeLog = log
        log.append(.init(stream: .stdout, text: "Bridge launch: \(app.name)\nEngine: \(runtime.executable.path)\nEXE: \(app.executable.path)\nEnvironment: \(bottle.prefix.path)\n"))
        var next = snapshot
        if let index = next.applications.firstIndex(where: { $0.id == app.id }) {
            next.applications[index].lastLog = log.url
            next.applications[index].lastLaunchedAt = Date()
            next.applications[index].launchCount = (next.applications[index].launchCount ?? 0) + 1
        }
        try await save(next)
        stage = "Launching"
        let handler = outputHandler
        // LaunchService returns after process exit; no claim that a visible game works.
        stage = "Launching · awaiting process output"
        let result: ProcessResult
        do { result = try await launcher.launch(app, bottle: bottle, runtime: runtime, approved: true, output: handler) }
        catch {
            var failed = snapshot
            if let index = failed.applications.firstIndex(where: { $0.id == app.id }) { failed.applications[index].lastFailure = error.localizedDescription }
            try await save(failed); throw error
        }
        lastResult = result
        log.append(.init(stream: .stdout, text: "\nProcess exited with code \(result.exitCode) (signalled: \(result.wasSignalled)).\n"))
        try log.finish(); activeLog = nil
        next = snapshot
        if let index = next.applications.firstIndex(where: { $0.id == app.id }) { next.applications[index].lastExitCode = result.exitCode
            next.applications[index].lastFailure = result.exitCode == 0 && !result.wasSignalled ? nil : "Application stopped unexpectedly"
        }
        try await save(next); stage = "Finished"
        appendConsole(.init(stream: .stdout, text: "\nProcess exited with code \(result.exitCode).\n"))
        if result.exitCode != 0 || result.wasSignalled {
            diagnosis = LaunchDiagnosis.classify(result: result)
            errorMessage = diagnosis?.title; return
        }
        if app.isInstaller == true {
            stage = "Checking installed applications"
            let known = Set(snapshot.applications.map(\.executable))
            installedTargets = try await Task.detached { try InstalledApplicationScanner.scan(prefix: bottle.prefix, excluding: known) }.value
            installerBottleID = bottle.id; stage = "Finished"
        }
    }
    func setBottleGraphics(_ graphics: GraphicsBackend, bottleID: UUID) {
        perform {
            guard let index = self.snapshot.bottles.firstIndex(where: { $0.id == bottleID }) else {
                throw BridgeError.invalidPrefix("This bottle is no longer in the library.")
            }
            let bottle = self.snapshot.bottles[index]
            let updated = try await self.bottles.configure(bottle, name: bottle.name, graphics: graphics)
            var next = self.snapshot; next.bottles[index] = updated
            try await self.save(next)
        }
    }
    func importDXVK(_ bottle: Bottle) {
        guard canEdit else { return }
        let panel = NSOpenPanel(); panel.title = "Select the extracted macOS DXVK x64 directory"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        requestDXVKImport(directory: url, bottle: bottle)
    }
    func requestDXVKImport(directory: URL, bottle: Bottle) {
        guard canEdit else { return }
        do { pendingApproval = ExecutionApproval(operation: .installDXVK(try graphicsInstaller.inspect(directory), bottle)) }
        catch { errorMessage = error.localizedDescription }
    }
    func requestDXVKRestore(_ bottle: Bottle) {
        guard canEdit else { return }
        pendingApproval = ExecutionApproval(operation: .restoreDXVK(bottle))
    }
    private func saveGraphicsBottle(_ bottle: Bottle) async throws {
        guard let index = snapshot.bottles.firstIndex(where: { $0.id == bottle.id }) else {
            throw BridgeError.invalidPrefix("Bottle no longer exists in the library.")
        }
        var next = snapshot; next.bottles[index] = bottle
        try await save(next)
    }
    func approve(_ request: ExecutionApproval) {
        let remember = rememberApproval
        pendingApproval = nil
        perform {
            self.console = ""; self.lastResult = nil; self.diagnosis = nil
            self.activeLog = try RunLog(directory: self.logsDirectory)
            switch request.operation {
            case .installDXVK(let package, let bottle):
                let updated = try await self.graphicsInstaller.install(package, bottle: bottle, approved: true)
                do { try await self.saveGraphicsBottle(updated) }
                catch {
                    _ = try await self.graphicsInstaller.restore(updated, approved: true)
                    throw error
                }
                self.appendConsole(.init(stream: .stdout, text: "Imported macOS DXVK libraries. No software was executed. Launch approval is still required; rendering compatibility remains untested.\n"))
            case .restoreDXVK(let bottle):
                let updated = try await self.graphicsInstaller.restore(bottle, approved: true)
                try await self.saveGraphicsBottle(updated)
                self.appendConsole(.init(stream: .stdout, text: "Original Direct3D DLLs and prior graphics selection restored. No software was executed.\n"))
            case .probe(let runtime):
                let verified = try await self.runtimes.probe(runtime, approved: true, output: self.outputHandler)
                var next = self.snapshot
                if let index = next.runtimes.firstIndex(where: { $0.id == runtime.id }) { next.runtimes[index] = verified }
                try await self.save(next)
            case .createBottle(let name, let prefix, let runtime):
                // Validate all persisted associations before starting a runtime.
                let candidatePath = try PrefixPolicy.canonical(prefix).path
                guard !self.snapshot.bottles.contains(where: {
                    let existing = $0.prefix.resolvingSymlinksInPath().path
                    return existing == candidatePath || existing.hasPrefix(candidatePath + "/") || candidatePath.hasPrefix(existing + "/")
                }) else { throw BridgeError.invalidPrefix("Bottle directories cannot overlap.") }
                let bottle = try await self.bottles.create(name: name, prefix: prefix, runtime: runtime, approved: true, output: self.outputHandler)
                var next = self.snapshot; next.bottles.append(bottle)
                try await self.save(next)
                self.appendConsole(.init(stream: .stdout, text: "\nBottle initialized. Select it in your application's library entry.\n"))
            case .repair(let bottle, let runtime):
                self.stage = "Repairing Windows environment"
                var next = self.snapshot
                do {
                    _ = try await self.bottles.repair(bottle, runtime: runtime, approved: true, output: self.outputHandler)
                    next.repairs = Array(((next.repairs ?? []) + [RepairRecord(bottleID: bottle.id, outcome: "Environment structure verified; application compatibility unverified")]).suffix(100))
                    try await self.save(next)
                } catch {
                    next.repairs = Array(((next.repairs ?? []) + [RepairRecord(bottleID: bottle.id, outcome: "Failed: " + error.localizedDescription)]).suffix(100))
                    try await self.save(next); throw error
                }
            case .prepare(var app, let runtime, let prefix):
                self.stage = "Preparing Windows environment"
                let info = try ExecutableInspector.inspect(app.executable)
                _ = try CompatibilityRouter(runtimes: self.runtimes).select(info: info, installed: [runtime])
                let bottle: Bottle
                if FileManager.default.fileExists(atPath: prefix.path) {
                    let owner = try PrefixPolicy.ownedBottle(at: prefix, runtimeID: runtime.id)
                    if (try? PrefixPolicy.validateWin64(prefix)) != nil { bottle = owner }
                    else { bottle = try await self.bottles.repair(owner, runtime: runtime, approved: true, output: self.outputHandler) }
                } else {
                    bottle = try await self.bottles.create(name: app.name, prefix: prefix, runtime: runtime, approved: true, output: self.outputHandler)
                }
                app.bottleID = bottle.id
                var next = self.snapshot
                if !next.bottles.contains(where: { $0.id == bottle.id }) { next.bottles.append(bottle) }
                if let index = next.applications.firstIndex(where: { $0.id == app.id }) { next.applications[index] = app }
                try await self.save(next)
                try await self.executeLaunch(app, bottle: bottle, runtime: runtime)
            case .launch(var app, let bottle, let runtime):
                let fingerprint = try await Self.fingerprint(app: app, bottle: bottle, runtime: runtime)
                guard request.fingerprint == nil || request.fingerprint == fingerprint else {
                    throw BridgeError.unsupported("The executable, engine or launch settings changed after approval was requested. Review a new approval before running.")
                }
                if remember {
                    app.executionConsent = fingerprint
                    var next = self.snapshot
                    if let index = next.applications.firstIndex(where: { $0.id == app.id }) { next.applications[index] = app }
                    try await self.save(next)
                }
                try await self.executeLaunch(app, bottle: bottle, runtime: runtime)
            }
        }
    }
    func removeBottle(_ bottle: Bottle) {
        pendingRemoval = nil
        perform {
            if bottle.managed { try await self.bottles.remove(bottle) }
            var next = self.snapshot; next.bottles.removeAll { $0.id == bottle.id }
            for index in next.applications.indices where next.applications[index].bottleID == bottle.id {
                next.applications[index].bottleID = nil
            }
            try await self.save(next)
        }
    }
}
