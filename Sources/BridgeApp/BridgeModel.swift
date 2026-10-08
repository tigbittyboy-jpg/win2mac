import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BridgeCore

enum NavigationSection: String, CaseIterable, Identifiable {
    case library = "Library", runtimes = "Runtimes", bottles = "Bottles", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .library: "square.grid.2x2"
        case .runtimes: "cpu"
        case .bottles: "shippingbox"
        case .diagnostics: "stethoscope"
        }
    }
}

struct ExecutionApproval: Identifiable {
    enum Operation {
        case probe(WineRuntime)
        case createBottle(name: String, prefix: URL, runtime: WineRuntime)
        case launch(ApplicationEntry, Bottle, WineRuntime)
    }
    let id = UUID()
    let operation: Operation
    var details: String {
        switch operation {
        case .probe(let runtime):
            return "Run runtime version probe:\n\(runtime.executable.path)\nArgument: --version"
        case .createBottle(let name, let prefix, let runtime):
            return "Initialize bottle ‘\(name)’ using:\n\(runtime.executable.path)\nArguments: wineboot, -u\nPrefix: \(prefix.path)"
        case .launch(let app, let bottle, let runtime):
            let overrides = (try? GraphicsManager().environment(for: bottle.graphics)) ?? [:]
            let settings = overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            return "Launch ‘\(app.name)’:\n\(app.executable.path)\nRuntime: \(runtime.executable.path)\nPrefix: \(bottle.prefix.path)\nGraphics: \(bottle.graphics.displayName)\n\(settings.isEmpty ? "Uses runtime graphics settings" : settings)\nAdditional arguments: \(app.arguments.joined(separator: " | "))"
        }
    }
}

@MainActor
final class BridgeModel: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published var section: NavigationSection? = .library
    @Published var selectedApplicationID: UUID?
    @Published var selectedRuntimeID: UUID? { didSet { syncRuntimeFields() } }
    @Published var runtimeArchitecture: RuntimeArchitecture = .unknown
    @Published var runtimeSupportsX64 = false
    @Published var bottleName = "My Bottle"
    @Published var prefixPath = BridgePaths.bottles.appendingPathComponent("My Bottle").path
    @Published var argumentsText = ""
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

    init(library: any ApplicationLibraryStoring = ApplicationLibrary(),
         runtimes: any RuntimeManaging = RuntimeManager(),
         bottles: any BottleManaging = BottleManager(),
         launcher: (any LaunchServing)? = nil,
         diagnostics: any DiagnosticsCollecting = DiagnosticsService()) {
        self.library = library; self.runtimes = runtimes; self.bottles = bottles
        self.launcher = launcher ?? LaunchService(runtimes: runtimes, bottles: bottles)
        self.diagnostics = diagnostics
    }
    var selectedApplication: ApplicationEntry? { snapshot.applications.first { $0.id == selectedApplicationID } }
    var selectedRuntime: WineRuntime? { snapshot.runtimes.first { $0.id == selectedRuntimeID } }
    var canEdit: Bool { loaded && !busy }
    var selectedRuntimeConfigured: Bool {
        guard let runtime = selectedRuntime else { return false }
        return runtime.architecture != .unknown && runtime.supportsWindowsX64
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
    }
    private func syncRuntimeFields() {
        runtimeArchitecture = selectedRuntime?.architecture ?? .unknown
        runtimeSupportsX64 = selectedRuntime?.supportsWindowsX64 ?? false
    }
    private func save(_ next: LibrarySnapshot) async throws {
        try await library.save(next); snapshot = next; refreshDiagnostics()
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard canEdit else { return }
        busy = true
        operationTask = Task {
            defer { busy = false; operationTask = nil; refreshDiagnostics() }
            do { try await operation() }
            catch is CancellationError { appendConsole(.init(stream: .stderr, text: "Operation stopped. Wine child processes may still be running.\n")) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    private var outputHandler: OutputHandler {
        { [weak self] event in Task { @MainActor [weak self] in self?.appendConsole(event) } }
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
        let panel = NSOpenPanel(); panel.title = "Select a Windows x64 EXE"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            try ExecutableValidator.validateX64(url)
            let app = ApplicationEntry(name: url.deletingPathExtension().lastPathComponent, executable: url)
            var next = self.snapshot; next.applications.append(app)
            try await self.save(next); self.selectApplication(app.id)
        }
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
        perform {
            var next = self.snapshot
            if let index = next.applications.firstIndex(where: { $0.id == id }) { next.applications[index].arguments = args }
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
        let architecture = runtimeArchitecture, x64 = runtimeSupportsX64
        perform {
            var next = self.snapshot
            if let index = next.runtimes.firstIndex(where: { $0.id == id }) {
                next.runtimes[index].architecture = architecture; next.runtimes[index].supportsWindowsX64 = x64
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
            let bottle = Bottle(name: url.lastPathComponent, prefix: try PrefixPolicy.canonical(url), runtimeID: runtime.id)
            var next = self.snapshot; next.bottles.append(bottle)
            try await self.save(next)
        }
    }
    func requestLaunch() {
        guard canEdit, let app = selectedApplication else { return }
        guard let bottle = snapshot.bottles.first(where: { $0.id == app.bottleID }),
              let runtime = snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) else {
            errorMessage = "Associate this application with a configured bottle first."; return
        }
        pendingApproval = ExecutionApproval(operation: .launch(app, bottle, runtime))
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
    func approve(_ request: ExecutionApproval) {
        pendingApproval = nil
        perform {
            self.console = ""; self.lastResult = nil
            switch request.operation {
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
            case .launch(let app, let bottle, let runtime):
                let result = try await self.launcher.launch(app, bottle: bottle, runtime: runtime, approved: true, output: self.outputHandler)
                self.lastResult = result
                self.appendConsole(.init(stream: .stdout, text: "\nProcess exited with code \(result.exitCode)\(result.wasSignalled ? " (signal)" : "").\n"))
                if result.exitCode != 0 || result.wasSignalled {
                    throw BridgeError.process("Launch finished with exit \(result.exitCode). Inspect the console and diagnostics.")
                }
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
