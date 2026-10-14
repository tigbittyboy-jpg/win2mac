import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import BridgeCore

enum NavigationSection: String, CaseIterable, Identifiable {
    case home = "Home", library = "Library", steam = "Steam", applications = "Applications", compatibility = "Compatibility", diagnostics = "Diagnostics", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house"
        case .library: "square.grid.2x2"
        case .steam: "gamecontroller"
        case .applications: "app.dashed"
        case .diagnostics: "stethoscope"
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
        case dependency(DependencyInstaller, Bottle, WineRuntime, retry: Bool)
        case installSteam(SteamInstaller, Bottle, WineRuntime, retry: Bool)
        case backup(Bottle)
        case restoreBackup(EnvironmentBackup, Bottle)
        case duplicate(Bottle, URL)
        case resetApplication(ApplicationEntry, WineRuntime, URL)
        case windowsVersion(WindowsVersion, Bottle, WineRuntime)
    }
    let id = UUID()
    let operation: Operation
    var fingerprint: String? = nil
    var changesFiles: Bool {
        switch operation { case .installDXVK, .restoreDXVK, .backup, .restoreBackup, .duplicate: true; default: false }
    }
    var title: String { changesFiles ? "Approve environment file changes" : "Approve software execution" }
    var actionTitle: String { changesFiles ? "Approve Changes" : "Approve and Run" }
    var details: String {
        switch operation {
        case .probe(let runtime):
            return "Run runtime version probe:\n\(runtime.executable.path)\nArgument: --version"
        case .createBottle(let name, let prefix, let runtime):
            return "Initialize bottle ‘\(name)’ using:\n\(runtime.executable.path)\nArguments: wineboot, -u\nPrefix: \(prefix.path)"
        case .prepare(let app, let runtime, let prefix):
            return "Prepare and launch ‘\(app.name)’:\nApplication: \(app.executable.path)\nEngine: \(runtime.executable.path)\nEnvironment: \(prefix.path)\nWin2Mac may initialize this dedicated win64 environment, or perform one wineboot update if it is incomplete and Bridge-owned, then run the application. Data is retained; other game environments will not be changed."
        case .repair(let bottle, let runtime):
            return "Update the Bridge-owned environment ‘\(bottle.name)’ using wineboot -u:\n\(runtime.executable.path)\n\(bottle.prefix.path)\nExisting data is retained. Close all Wine applications using this environment first. This verifies environment structure, not game compatibility."
        case .launch(let app, let bottle, let runtime):
            let overrides = (try? ExecutionEnvironmentPolicy.environment(application: app, bottle: bottle)) ?? [:]
            let settings = overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            return "Launch ‘\(app.name)’:\n\(app.executable.path)\nRuntime: \(runtime.executable.path)\nPrefix: \(bottle.prefix.path)\nGraphics: \(bottle.graphics.displayName)\nWorking directory: \(app.workingDirectory?.path ?? app.executable.deletingLastPathComponent().path)\n\(settings.isEmpty ? "Uses runtime graphics settings" : settings)\nAdditional arguments: \(app.arguments.joined(separator: " | "))"
        case .installDXVK(let package, let bottle):
            return "Import user-provided macOS DXVK x64 libraries into ‘\(bottle.name)’:\nSource: \(package.source.path)\nPrefix: \(bottle.prefix.path)\nFiles: d3d11.dll, d3d10core.dll (\(package.byteCount) bytes captured for this approval)\nExisting files are backed up inside .bridge-dxvk. DXGI is unchanged. No Wine or DLL is executed during import. Publisher authenticity is not verified; use a package you trust whose provider supports your runtime. Close all Wine programs using this bottle first."
        case .dependency(let installer, let bottle, let runtime, let retry):
            return "Install \(installer.component.rawValue) (version supplied by you: \(installer.requestedVersion)) into ‘\(bottle.name)’:\nEngine: \(runtime.executable.path)\nCaptured installer: \(installer.capturedFile.path)\nSHA-256: \(installer.sha256)\nInstaller architecture: \(installer.info.machine.rawValue)\nRequested dependency payload: \(installer.targetArchitecture.rawValue)\nArguments: \(installer.arguments.joined(separator: " | "))\nPrefix: \(bottle.prefix.path)\nThis runs the reviewed local installer and may change registry/DLLs for every app sharing this environment. Obtain it from Microsoft; the checksum binds approval bytes, not publisher authenticity. Back up the environment first. \(retry ? "You explicitly requested a retry of an uncertain previous installation." : "Uncertain prior installs will block automatic retries.")"
        case .installSteam(let installer, let bottle, let runtime, let retry):
            return "Run the captured official Windows Steam installer:\n\(installer.capturedFile.path)\nSHA-256: \(installer.sha256)\nEngine: \(runtime.executable.path)\nEnvironment: \(bottle.prefix.path)\nObtain SteamSetup.exe from Valve. Sign in normally inside Windows Steam. No credentials are collected by Win2Mac. Network access and Wine support are required; authentication and game compatibility are unverified. \(retry ? "You explicitly requested a retry after reviewing the previous uncertain outcome." : "Uncertain prior outcomes block retries.")"
        case .backup(let bottle):
            return "Create an offline verified backup of ‘\(bottle.name)’:\n\(bottle.prefix.path)\nClose all Wine and Steam processes first, including processes opened outside Win2Mac. Symlinks are preserved, not traversed. Backups contain private game files and saves and need sufficient disk space."
        case .restoreBackup(let backup, let bottle):
            return "Restore ‘\(bottle.name)’ from \(backup.createdAt.formatted()):\n\(bottle.prefix.path)\nClose every Wine process using it. The current environment is moved to a retained sibling directory, including saves; no current data is deleted. All applications sharing this environment are affected. The engine remains associated by ID; this does not roll back externally updated engine files."
        case .duplicate(let bottle, let destination):
            return "Duplicate ‘\(bottle.name)’ to:\n\(destination.path)\nClose all Wine processes first. The original stays intact. Imported DXVK must be restored first. Installed applications may contain absolute paths; duplication is not proof they will run."
        case .resetApplication(let app, let runtime, let prefix):
            return "Prepare a fresh environment for ‘\(app.name)’ using \(runtime.executable.path):\n\(prefix.path)\nOnly this app's association is changed. The previous environment, game saves and installed files are retained. No dependency/graphics settings are automatically copied. For a Steam game, use Steam environment controls instead."
        case .windowsVersion(let version, let bottle, let runtime):
            return "Request \(version.rawValue) for ‘\(bottle.name)’:\n\(runtime.executable.path)\nArguments: winecfg | -v | \(version.wineValue)\nPrefix: \(bottle.prefix.path)\nThis changes Wine registry configuration for every application using this environment. Back up first and close Wine. It does not install Windows or provide unsupported Windows APIs."
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
    @Published private(set) var graphicsRecommendation: GraphicsRecommendation?
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
    @Published private(set) var runtimeReadiness = false
    @Published var runtimeProvider: RuntimeProvider = .genericWine
    @Published var retrySteamInstallation = false
    @Published var steamBottleID: UUID?
    @Published private(set) var steamGames: [SteamGame] = []
    @Published private(set) var steamWarnings: [String] = []
    @Published private(set) var steamClient: URL?
    @Published var dependencyComponent: WindowsDependency = .visualC2015To2022
    @Published var dependencyVersion = ""
    @Published var dependencyArchitecture: WindowsMachine = .x64
    @Published var retryDependency = false
    @Published private(set) var dependencyRecords: [DependencyRecord] = []
    @Published private(set) var environmentBackups: [UUID: [EnvironmentBackup]] = [:]
    private let dependencies: any DependencyManaging
    private let steam: any SteamManaging
    private let recovery: any EnvironmentRecovering
    private let configuration: any EnvironmentConfiguring
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
         logsDirectory: URL = BridgePaths.dataDirectory.appendingPathComponent("Logs"),
         dependencies: (any DependencyManaging)? = nil,
         steam: (any SteamManaging)? = nil,
         recovery: (any EnvironmentRecovering)? = nil,
         configuration: (any EnvironmentConfiguring)? = nil) {
        self.environmentsDirectory = environmentsDirectory; self.logsDirectory = logsDirectory
        self.library = library; self.runtimes = runtimes; self.bottles = bottles
        let resolvedLauncher = launcher ?? LaunchService(runtimes: runtimes, bottles: bottles)
        self.launcher = resolvedLauncher
        self.diagnostics = diagnostics
        self.graphicsInstaller = graphicsInstaller ?? DXVKInstaller(bottles: bottles)
        self.dependencies = dependencies ?? DependencyManager(runtimes: runtimes, bottles: bottles)
        self.steam = steam ?? SteamManager(launcher: resolvedLauncher)
        self.recovery = recovery ?? EnvironmentRecovery(bottles: bottles)
        self.configuration = configuration ?? EnvironmentConfigurationManager(runtimes: runtimes, bottles: bottles)
    }
    var selectedApplication: ApplicationEntry? { snapshot.applications.first { $0.id == selectedApplicationID } }
    var selectedRuntime: WineRuntime? { snapshot.runtimes.first { $0.id == selectedRuntimeID } }
    var canEdit: Bool { loaded && !busy }
    var selectedRuntimeConfigured: Bool {
        guard let runtime = selectedRuntime else { return false }
        return BackendCapabilities(runtime: runtime).supportsStandardPrefixes && runtimeReadiness
    }
    var canCreateBottle: Bool { canEdit && selectedRuntimeConfigured }
    func load() async {
        guard !loadAttempted else { return }; loadAttempted = true
        do {
            snapshot = try await library.load()
            let recovered = LaunchRecovery.markInterrupted(snapshot)
            if recovered != snapshot { try await save(recovered) }
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
        graphicsRecommendation = nil
        argumentsText = selectedApplication?.arguments.joined(separator: "\n") ?? ""
        workingDirectoryText = selectedApplication?.workingDirectory?.path ?? ""
        environmentText = (selectedApplication?.environment ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
    private func syncRuntimeFields() {
        runtimeArchitecture = selectedRuntime?.architecture ?? .unknown
        runtimeSupportsX64 = selectedRuntime?.supportsWindowsX64 ?? false
        runtimeSupportsX86 = selectedRuntime?.supportsWindowsX86 == true
        runtimeProvider = selectedRuntime?.provider ?? .genericWine
        runtimeReadiness = selectedRuntime.map { (try? runtimes.validate($0, forLaunch: true)) != nil } ?? false
    }
    private func save(_ next: LibrarySnapshot) async throws {
        let previousRuntime = selectedRuntime
        try await library.save(next); snapshot = next
        if selectedRuntime != previousRuntime { syncRuntimeFields() }
        refreshDiagnostics()
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard canEdit else { return }
        busy = true; diagnosis = nil; errorMessage = nil
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
            if let existing = self.snapshot.applications.first(where: { $0.executable == url && $0.steamAppID == nil }) {
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
            next.applications[index].steamAppID = nil; next.applications[index].steamClient = nil; next.applications[index].executionConsent = nil
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
    private static func elapsedSeconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let value = start.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    func exportCompatibilityMatrix() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Win2Mac-compatibility-matrix.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot.applications.flatMap { $0.compatibilityRecords ?? [] }.map(CompatibilityMatrixRow.init)).write(to: url, options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }
    func exportDiagnostics() {
        refreshDiagnostics()
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Win2Mac-diagnostics.txt"
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
            try ExecutionEnvironmentPolicy.validate(overrides: environment)
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
        if found.isEmpty { appendConsole(.init(stream: .stdout, text: "No installed Wine runtime found in common paths. Choose your provider's Wine executable, or install a compatible Wine runtime first. Win2Mac includes no Wine engine.\n")) }
    }
    func saveRuntimeSettings() {
        guard let id = selectedRuntimeID else { return }
        let architecture = runtimeArchitecture, x64 = runtimeSupportsX64, x86 = runtimeSupportsX86, provider = runtimeProvider
        perform {
            var next = self.snapshot
            if let index = next.runtimes.firstIndex(where: { $0.id == id }) {
                try RuntimeIntegrity.validate(next.runtimes[index])
                next.runtimes[index] = try RuntimeIntegrity.record(next.runtimes[index])
                next.runtimes[index].provider = provider
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
        guard app.steamAppID == nil else { errorMessage = "This Steam game needs its installed Steam environment. Scan and import it again from Steam; a fresh generic environment cannot contain its client or authenticated installation."; return }
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
                "prefix": bottle.prefix.path, "graphics": (try ExecutionEnvironmentPolicy.effectiveBottle(application: app, bottle: bottle)).graphics.rawValue,
                "steamAppID": app.steamAppID ?? "", "steamClient": app.steamClient?.path ?? "",
                "workingDirectory": app.workingDirectory?.path ?? app.executable.deletingLastPathComponent().path,
                "architecture": runtime.architecture.rawValue,
                "windowsVersion": bottle.requestedWindowsVersion?.rawValue ?? "provider default",
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
    private func repairOwnedEnvironment(_ bottle: Bottle, runtime: WineRuntime) async throws -> Bottle {
        stage = "Repairing Windows environment"
        var next = snapshot
        next.repairs = Array(((next.repairs ?? []) + [RepairRecord(bottleID: bottle.id, outcome: "Attempting one approved environment update")]).suffix(100))
        try await save(next)
        do {
            let repaired = try await bottles.repair(bottle, runtime: runtime, approved: true, output: outputHandler)
            next = snapshot
            next.repairs = Array(((next.repairs ?? []) + [RepairRecord(bottleID: bottle.id, outcome: "Environment structure verified; application compatibility unverified")]).suffix(100))
            try await save(next); return repaired
        } catch {
            next = snapshot
            next.repairs = Array(((next.repairs ?? []) + [RepairRecord(bottleID: bottle.id, outcome: "Failed: " + error.localizedDescription)]).suffix(100))
            try await save(next); throw error
        }
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
        log.append(.init(stream: .stdout, text: "Win2Mac launch: \(app.name)\nEngine: \(runtime.executable.path)\nEXE: \(app.executable.path)\nEnvironment: \(bottle.prefix.path)\n"))
        let effective = try ExecutionEnvironmentPolicy.effectiveBottle(application: app, bottle: bottle)
        let run = LaunchHistoryRecord(runtime: runtime, bottle: bottle, graphics: effective.graphics, log: log.url)
        let start = ContinuousClock.now
        var next = snapshot
        if let index = next.applications.firstIndex(where: { $0.id == app.id }) {
            next.applications[index].launchHistory = Array(((next.applications[index].launchHistory ?? []) + [run]).suffix(100))
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
            if let index = failed.applications.firstIndex(where: { $0.id == app.id }) {
                let diagnosis = LaunchDiagnosis.classify(error: error)
                failed.applications[index].lastFailure = error.localizedDescription; failed.applications[index].lastDiagnosis = diagnosis
                if let position = failed.applications[index].launchHistory?.firstIndex(where: { $0.id == run.id }) {
                    failed.applications[index].launchHistory?[position].state = error is CancellationError ? .cancelled : .failed
                    failed.applications[index].launchHistory?[position].diagnosis = diagnosis
                    failed.applications[index].launchHistory?[position].elapsedSeconds = Self.elapsedSeconds(since: start)
                }
            }
            try await save(failed); throw error
        }
        lastResult = result
        log.append(.init(stream: .stdout, text: "\nProcess exited with code \(result.exitCode) (signalled: \(result.wasSignalled)).\n"))
        try log.finish(); activeLog = nil
        next = snapshot
        if let index = next.applications.firstIndex(where: { $0.id == app.id }) { next.applications[index].lastExitCode = result.exitCode
            let failed = result.exitCode != 0 || result.wasSignalled
            next.applications[index].lastDiagnosis = failed ? LaunchDiagnosis.classify(result: result) : nil
            next.applications[index].lastFailure = failed ? next.applications[index].lastDiagnosis?.title : nil
            if let position = next.applications[index].launchHistory?.firstIndex(where: { $0.id == run.id }) {
                next.applications[index].launchHistory?[position].state = failed ? .failed : .completed
                next.applications[index].launchHistory?[position].elapsedSeconds = Self.elapsedSeconds(since: start)
                next.applications[index].launchHistory?[position].exitCode = result.exitCode
                next.applications[index].launchHistory?[position].wasSignalled = result.wasSignalled
                next.applications[index].launchHistory?[position].diagnosis = next.applications[index].lastDiagnosis
            }
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
            case .dependency(let installer, let bottle, let runtime, let retry):
                self.stage = "Installing selected prerequisite"
                let record = try await self.dependencies.install(installer, bottle: bottle, runtime: runtime, approved: true, retryUncertain: retry, output: self.outputHandler)
                self.dependencyRecords = try await self.dependencies.records(in: bottle)
                self.appendConsole(.init(stream: .stdout, text: record.details + "\n"))
                if record.state != .filePresenceVerified { throw BridgeError.process(record.details) }
            case .installSteam(let installer, let bottle, let runtime, let retry):
                self.stage = "Installing Windows Steam"
                let scan = try await self.steam.install(installer, bottle: bottle, runtime: runtime, approved: true, retryUncertain: retry, output: self.outputHandler)
                self.steamBottleID = bottle.id; self.steamGames = scan.games; self.steamClient = scan.client; self.steamWarnings = scan.warnings
            case .backup(let bottle):
                self.stage = "Verifying environment backup"
                _ = try await self.recovery.backup(bottle, applications: self.snapshot.applications.filter { $0.bottleID == bottle.id }, approved: true)
                self.environmentBackups[bottle.id] = try await self.recovery.backups(for: bottle)
            case .restoreBackup(let backup, let bottle):
                self.stage = "Restoring environment; retaining current files"
                let updated = try await self.recovery.restore(backup, bottle: bottle, approved: true)
                try await self.saveGraphicsBottle(updated)
                var next = self.snapshot
                for index in next.applications.indices where next.applications[index].bottleID == bottle.id {
                    if let settings = backup.configurations?.first(where: { $0.applicationID == next.applications[index].id }) {
                        next.applications[index] = try settings.restoring(next.applications[index])
                    }
                    next.applications[index].executionConsent = nil
                }
                try await self.save(next)
            case .windowsVersion(let version, let bottle, let runtime):
                self.stage = "Requesting Wine Windows version"
                let updated = try await self.configuration.setWindowsVersion(version, bottle: bottle, runtime: runtime, approved: true, output: self.outputHandler)
                try await self.saveGraphicsBottle(updated)
            case .duplicate(let bottle, let destination):
                self.stage = "Duplicating offline environment"
                let copy = try await self.recovery.duplicate(bottle, destination: destination, name: bottle.name + " Copy", approved: true)
                var next = self.snapshot; next.bottles.append(copy); try await self.save(next)
            case .resetApplication(var app, let runtime, let prefix):
                self.stage = "Preparing fresh environment; retaining prior data"
                let bottle = try await self.bottles.create(name: app.name + " Fresh", prefix: prefix, runtime: runtime, approved: true, output: self.outputHandler)
                var next = self.snapshot; next.bottles.append(bottle)
                app.bottleID = bottle.id; app.graphicsOverride = nil; app.executionConsent = nil
                if let index = next.applications.firstIndex(where: { $0.id == app.id }) { next.applications[index] = app }
                try await self.save(next)
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
                _ = try await self.repairOwnedEnvironment(bottle, runtime: runtime)
            case .prepare(var app, let runtime, let prefix):
                self.stage = "Preparing Windows environment"
                let info = try ExecutableInspector.inspect(app.executable)
                _ = try CompatibilityRouter(runtimes: self.runtimes).select(info: info, installed: [runtime])
                let bottle: Bottle
                if FileManager.default.fileExists(atPath: prefix.path) {
                    let owner = try PrefixPolicy.ownedBottle(at: prefix, runtimeID: runtime.id)
                    if (try? PrefixPolicy.validateWin64(prefix)) != nil { bottle = owner }
                    else { bottle = try await self.repairOwnedEnvironment(owner, runtime: runtime) }
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
    func registerRuntimeRevision() {
        guard let old = selectedRuntime else { return }
        perform {
            var revision = try self.runtimes.inspect(old.executable)
            revision.name = old.name + " (new revision)"; revision.provider = old.provider
            revision.architecture = old.architecture; revision.supportsWindowsX64 = old.supportsWindowsX64
            revision.supportsWindowsX86 = old.supportsWindowsX86
            revision = try RuntimeIntegrity.record(revision)
            var next = self.snapshot; next.runtimes.append(revision)
            try await self.save(next); self.selectedRuntimeID = revision.id
        }
    }
    func refreshSteam() {
        guard let bottle = snapshot.bottles.first(where: { $0.id == steamBottleID }) else { return }
        perform {
            self.steamGames = []; self.steamClient = nil; self.steamWarnings = []
            let scan = try await self.steam.scan(bottle)
            self.steamClient = scan.client; self.steamGames = scan.games; self.steamWarnings = scan.warnings
        }
    }
    func requestSteamInstall() {
        guard canEdit, let bottle = snapshot.bottles.first(where: { $0.id == steamBottleID }),
              let runtime = snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) else { return }
        let panel = NSOpenPanel(); panel.title = "Select official SteamSetup.exe from Valve"
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let retry = retrySteamInstallation
        perform {
            let installer = try await self.steam.inspectInstaller(file)
            self.pendingApproval = ExecutionApproval(operation: .installSteam(installer, bottle, runtime, retry: retry))
        }
    }
    func launchSteamClient() {
        guard let bottle = snapshot.bottles.first(where: { $0.id == steamBottleID }), let client = steamClient else { return }
        perform {
            let existing = self.snapshot.applications.first { $0.executable == client && $0.steamAppID == nil }
            var next = self.snapshot
            let entry = existing ?? ApplicationEntry(name: "Windows Steam", executable: client, bottleID: bottle.id)
            if existing == nil { next.applications.append(entry); try await self.save(next) }
            self.selectApplication(entry.id)
            guard let runtime = self.snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) else { return }
            self.pendingApproval = ExecutionApproval(operation: .launch(entry, bottle, runtime))
        }
        section = .applications
    }
    func importSteamGame(_ game: SteamGame) {
        guard let bottleID = steamBottleID, let client = steamClient else { return }
        perform {
            if let existing = self.snapshot.applications.first(where: { $0.steamAppID == game.appID && $0.bottleID == bottleID }) {
                self.selectApplication(existing.id); self.section = .library; return
            }
            var entry = ApplicationEntry(name: game.name, executable: client, bottleID: bottleID)
            entry.steamAppID = game.appID; entry.steamClient = client; entry.customIcon = game.artwork
            var next = self.snapshot; next.applications.append(entry)
            try await self.save(next); self.selectApplication(entry.id); self.section = .library
        }
    }
    func reviewGraphicsRecommendation() {
        guard let app = selectedApplication, let bottle = snapshot.bottles.first(where: { $0.id == app.bottleID }),
              let runtime = snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) else { return }
        perform {
            let digest = try await Task.detached {
                try RuntimeIntegrity.validate(runtime)
                return try FileIntegrity.sha256(app.executable)
            }.value
            self.graphicsRecommendation = GraphicsRecommender.recommend(application: app, bottle: bottle, runtime: runtime, executableSHA256: digest)
        }
    }
    func setApplicationGraphics(_ backend: GraphicsBackend?) {
        guard let app = selectedApplication, let bottle = snapshot.bottles.first(where: { $0.id == app.bottleID }) else { return }
        perform {
            var updated = app; updated.graphicsOverride = backend; updated.executionConsent = nil
            _ = try ExecutionEnvironmentPolicy.environment(application: updated, bottle: bottle)
            var next = self.snapshot
            if let index = next.applications.firstIndex(where: { $0.id == app.id }) { next.applications[index] = updated }
            try await self.save(next)
        }
    }
    func refreshDependencies() {
        guard let bottle = snapshot.bottles.first(where: { $0.id == selectedApplication?.bottleID }) else { return }
        perform { self.dependencyRecords = try await self.dependencies.records(in: bottle) }
    }
    func requestDependencyInstall() {
        guard canEdit, let bottle = snapshot.bottles.first(where: { $0.id == selectedApplication?.bottleID }),
              let runtime = snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) else { return }
        let panel = NSOpenPanel(); panel.title = "Select the official Microsoft installer (extracted DXSETUP.exe for DirectX)"
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let component = dependencyComponent, version = dependencyVersion, retry = retryDependency, target = dependencyArchitecture
        perform {
            let installer = try await self.dependencies.inspect(installer: file, component: component, version: version, target: target)
            self.pendingApproval = ExecutionApproval(operation: .dependency(installer, bottle, runtime, retry: retry))
        }
    }
    func requestWindowsVersion(_ version: WindowsVersion, bottle: Bottle) {
        guard canEdit, let runtime = snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) else { return }
        pendingApproval = ExecutionApproval(operation: .windowsVersion(version, bottle, runtime))
    }
    func requestBackup(_ bottle: Bottle) {
        guard canEdit else { return }; pendingApproval = ExecutionApproval(operation: .backup(bottle))
    }
    func refreshBackups(_ bottle: Bottle) {
        perform { self.environmentBackups[bottle.id] = try await self.recovery.backups(for: bottle) }
    }
    func requestRestore(_ backup: EnvironmentBackup, bottle: Bottle) {
        guard canEdit else { return }; pendingApproval = ExecutionApproval(operation: .restoreBackup(backup, bottle))
    }
    func requestDuplicate(_ bottle: Bottle) {
        guard canEdit else { return }
        let destination = environmentsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        pendingApproval = ExecutionApproval(operation: .duplicate(bottle, destination))
    }
    func requestFreshEnvironment() {
        guard canEdit, let app = selectedApplication, app.steamAppID == nil,
              let bottle = snapshot.bottles.first(where: { $0.id == app.bottleID }),
              let runtime = snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) else { return }
        pendingApproval = ExecutionApproval(operation: .resetApplication(app, runtime, environmentsDirectory.appendingPathComponent(UUID().uuidString)))
    }
    func recordCompatibility(launch: VerificationOutcome, rendering: VerificationOutcome,
                             input: VerificationOutcome, audio: VerificationOutcome, stability: VerificationOutcome, notes: String) {
        guard let app = selectedApplication, let bottle = snapshot.bottles.first(where: { $0.id == app.bottleID }),
              let runtime = snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) else { return }
        perform {
            let digest = try await Task.detached { try FileIntegrity.sha256(app.executable) }.value
            let effective = try ExecutionEnvironmentPolicy.effectiveBottle(application: app, bottle: bottle)
            let record = CompatibilityRecord(applicationName: app.name, executableSHA256: digest,
                architecture: app.steamAppID == nil ? try ExecutableInspector.inspect(app.executable).machine : .unknown,
                runtime: runtime, graphics: effective.graphics, os: ProcessInfo.processInfo.operatingSystemVersionString,
                launch: launch, rendering: rendering, input: input, audio: audio, stability: stability, notes: notes)
            var next = self.snapshot
            if let index = next.applications.firstIndex(where: { $0.id == app.id }) {
                next.applications[index].compatibilityRecords = Array(((next.applications[index].compatibilityRecords ?? []) + [record]).suffix(100))
            }
            try await self.save(next)
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
