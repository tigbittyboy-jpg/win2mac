import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BridgeCore

struct ContentView: View {
    @ObservedObject var model: BridgeModel
    @AppStorage("bridge.appearance") private var appearance = "Dark"
    @AppStorage("bridge.library.grid") private var grid = true
    @AppStorage("bridge.library.sort") private var sortValue = LibrarySort.name.rawValue
    @State private var search = ""
    @State private var favoritesOnly = false
    @State private var showConsole = false
    @State private var showDetails = false
    @State private var showApplicationSettings = false
    @State private var settingsTab = "General"
    @State private var rename = ""
    @State private var dropTarget = false
    @State private var showCompatibilityRecord = false
    @State private var observedLaunch: VerificationOutcome = .notTested
    @State private var observedRendering: VerificationOutcome = .notTested
    @State private var observedInput: VerificationOutcome = .notTested
    @State private var observedAudio: VerificationOutcome = .notTested
    @State private var observedStability: VerificationOutcome = .notTested
    @State private var observationNotes = ""
    private var entries: [ApplicationEntry] {
        LibraryQuery.filter(model.snapshot.applications.filter { model.section != .applications || $0.steamAppID == nil }, search: search, favoritesOnly: favoritesOnly,
            sort: LibrarySort(rawValue: sortValue) ?? .name)
    }
    var body: some View {
        NavigationSplitView {
            List(NavigationSection.allCases, selection: $model.section) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationTitle("Win2Mac")
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch model.section ?? .home {
                    case .home: homeView
                    case .library, .applications: libraryView
                    case .steam: steamView
                    case .diagnostics: diagnosticsView
                    case .compatibility: compatibilityView
                    case .settings: settingsView
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.busy {
                    HStack { ProgressView().controlSize(.small); Text(model.stage); Spacer(); Button("Stop") { model.stop() } }
                        .padding().background(.bar)
                }
                if showConsole { Divider(); consoleView }
            }
            .navigationTitle(model.section?.rawValue ?? "Home")
            .toolbar { Button { showConsole.toggle() } label: { Label("Technical Output", systemImage: "terminal") } }
        }
        .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
            guard model.canEdit, let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [model] data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in model.importExecutable(url) }
            }
            return true
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 16).stroke(.tint, lineWidth: 3).padding().allowsHitTesting(false) } }
        .sheet(item: $model.pendingApproval) { approval in
            VStack(alignment: .leading, spacing: 16) {
                Text(approval.title).font(.title2.bold())
                ScrollView { Text(approval.details).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Text(approval.changesFiles ? "Use trusted libraries documented for your engine. Importing files does not verify game compatibility." : "Approve only software and engines you trust. Windows programs can access your files and network. A Wine environment is not a security sandbox.")
                    .foregroundStyle(.secondary)
                if case .launch = approval.operation {
                    Toggle("Remember approval for this unchanged app, engine and configuration", isOn: $model.rememberApproval)
                }
                HStack { Spacer(); Button("Cancel") { model.pendingApproval = nil }.keyboardShortcut(.cancelAction)
                    Button(approval.actionTitle) { model.approve(approval) }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 640, height: 460)
        }
        .sheet(isPresented: $showCompatibilityRecord) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Record observed compatibility").font(.title2.bold())
                Text("Record only what you tested on this Mac. A process exit is not proof of rendering, input, audio or stability. Steam records identify the client; the game's executable architecture remains unverified.").foregroundStyle(.secondary)
                observationPicker("Launch", selection: $observedLaunch)
                observationPicker("Rendering", selection: $observedRendering)
                observationPicker("Input", selection: $observedInput)
                observationPicker("Audio", selection: $observedAudio)
                observationPicker("Stability", selection: $observedStability)
                TextField("Known issues and test duration", text: $observationNotes)
                HStack {
                    Button("Cancel") { showCompatibilityRecord = false }; Spacer()
                    Button("Save Observations") {
                        model.recordCompatibility(launch: observedLaunch, rendering: observedRendering, input: observedInput, audio: observedAudio, stability: observedStability, notes: observationNotes)
                        showCompatibilityRecord = false
                    }.disabled(!model.canEdit)
                }
            }.padding(24).frame(width: 580)
        }
        .sheet(item: $model.pendingRemoval) { bottle in
            VStack(alignment: .leading, spacing: 16) {
                Text(bottle.managed ? "Delete environment and its data?" : "Remove environment association?").font(.title2)
                Text(bottle.prefix.path).textSelection(.enabled)
                Text(bottle.managed ? "This permanently deletes everything inside this Bridge-owned environment. Close its Windows applications first." : "Files in this external environment will remain on disk.")
                HStack { Spacer(); Button("Cancel") { model.pendingRemoval = nil }
                    Button(bottle.managed ? "Delete" : "Remove", role: .destructive) { model.removeBottle(bottle) } }
            }.padding(24).frame(width: 560)
        }
        .sheet(isPresented: $showDetails) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Technical Details").font(.title2)
                ScrollView { Text(model.diagnosis?.technicalDetails ?? model.errorMessage ?? model.diagnosticsText)
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                HStack { Button("Export Diagnostics") { model.exportDiagnostics() }; Spacer(); Button("Done") { showDetails = false } }
            }.padding(24).frame(width: 700, height: 450)
        }
        .sheet(isPresented: $showApplicationSettings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Application Settings").font(.title2.bold())
                HStack { TextField("Application name", text: $rename); Button("Rename") { model.renameSelectedApplication(rename) } }
                HStack { Button("Change Icon…") { model.chooseIcon() }; Button("Change Executable…") { model.changeExecutable() } }
                if let app = model.selectedApplication {
                    Toggle("This executable is an installer", isOn: Binding(get: { app.isInstaller == true }, set: { value in model.editSelected { $0.isInstaller = value } }))
                }
                applicationSettings
                HStack { Button("Remove Library Entry", role: .destructive) { model.removeSelectedApplication(); showApplicationSettings = false }; Spacer(); Button("Done") { showApplicationSettings = false } }
            }.padding(24).frame(width: 800, height: 650)
        }
        .alert(model.diagnosis?.title ?? "Win2Mac", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Technical Details") { showDetails = true }
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.diagnosis?.guidance ?? model.errorMessage ?? "") }
    }
    private var homeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your Windows apps. On your Mac.").font(.largeTitle.bold())
                    Text("Choose an EXE. Win2Mac checks your engine and prepares a dedicated Windows environment.").foregroundStyle(.secondary)
                    Button("Run Windows App", systemImage: "play.fill") { model.selectEXE() }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canEdit).keyboardShortcut("o")
                    Text("Or drop an EXE anywhere in this window.").font(.caption).foregroundStyle(.secondary)
                }
                if model.snapshot.runtimes.isEmpty || !model.snapshot.runtimes.contains(where: { $0.supportsWindowsX64 && $0.architecture != .unknown }) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Set up a compatibility engine", systemImage: "sparkles").font(.headline)
                            Text("Win2Mac uses a Wine engine installed by you. Choose it, check its documented Windows support, and approve a version check.")
                            Button("Start Setup") { model.section = .compatibility }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                HStack { Text("Recently launched").font(.title2.bold()); Spacer(); Button("View Library") { model.section = .library } }
                let recent = LibraryQuery.filter(model.snapshot.applications, search: "", favoritesOnly: false, sort: .recent).filter { $0.lastLaunchedAt != nil }
                if recent.isEmpty { Text("Your recent applications will appear here.").foregroundStyle(.secondary) }
                else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) { ForEach(Array(recent.prefix(6))) { app in appCard(app) } } }
                if !model.loaded { Label("Library has not loaded. Existing files have been preserved.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }.padding(32)
        }
    }
    private var libraryView: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("Search applications", text: $search)
                    Button { model.selectEXE() } label: { Label("Add", systemImage: "plus") }.disabled(!model.canEdit)
                }
                HStack {
                    Toggle("Favorites", isOn: $favoritesOnly).toggleStyle(.button)
                    Picker("Sort", selection: $sortValue) { ForEach(LibrarySort.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }.labelsHidden()
                    Spacer()
                    Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }.accessibilityLabel(grid ? "Show list" : "Show grid")
                }
                if entries.isEmpty { ContentUnavailableView("No applications", systemImage: "square.grid.2x2", description: Text("Add a Windows EXE, or change your search.")) }
                else if grid {
                    ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 16) { ForEach(entries) { app in appCard(app) } } }
                } else {
                    List(entries, selection: Binding(get: { model.selectedApplicationID }, set: { model.selectApplication($0) })) { app in
                        HStack { appIcon(app, size: 32); VStack(alignment: .leading) { Text(app.name).font(.headline); Text(status(app)).font(.caption).foregroundStyle(.secondary) }; Spacer(); if app.favorite == true { Image(systemName: "star.fill").foregroundStyle(.yellow) } }.tag(app.id)
                    }
                }
            }.padding(20).frame(minWidth: 350)
            ScrollView { applicationDetails.padding(24) }.frame(minWidth: 320, idealWidth: 380)
        }
    }
    private func appIcon(_ app: ApplicationEntry, size: CGFloat) -> some View {
        let icon = app.customIcon.flatMap { NSImage(contentsOf: $0) } ?? NSWorkspace.shared.icon(forFile: app.executable.path)
        return Image(nsImage: icon).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
    private func status(_ app: ApplicationEntry) -> String {
        if app.lastFailure != nil && (app.lastLaunchedAt ?? .distantFuture) > (app.compatibilityRecords?.last?.date ?? .distantPast) { return "Last launch needs attention" }
        if let record = app.compatibilityRecords?.last { return "Observed " + record.status.rawValue.lowercased() + " · " + record.date.formatted(date: .abbreviated, time: .omitted) }
        if app.lastFailure != nil { return "Last launch needs attention" }
        if app.isInstaller == true { return "Installer · choose launch target after setup" }
        if let code = app.lastExitCode { return code == 0 ? "Last process exited normally · unverified" : "Last launch needs attention" }
        return app.bottleID == nil ? "Environment prepared on first launch" : "Configured · compatibility unverified"
    }
    private func appCard(_ app: ApplicationEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { appIcon(app, size: 48); Spacer(); Button { model.toggleFavorite(app.id) } label: { Image(systemName: app.favorite == true ? "star.fill" : "star") }.buttonStyle(.plain).accessibilityLabel(app.favorite == true ? "Remove favorite" : "Favorite") }
            Button(app.name) { model.selectApplication(app.id); model.section = .library }.font(.headline).buttonStyle(.plain)
            Text(status(app)).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height: 32, alignment: .top)
            Button(app.isInstaller == true ? "Run Installer" : "Play", systemImage: "play.fill") { model.selectApplication(app.id); model.requestLaunch() }.disabled(!model.canEdit)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(model.selectedApplicationID == app.id ? Color.accentColor : Color.secondary.opacity(0.2)))
            .contentShape(Rectangle()).onTapGesture { model.selectApplication(app.id) }
    }
    @ViewBuilder private var applicationDetails: some View {
        if let app = model.selectedApplication {
            VStack(alignment: .leading, spacing: 20) {
                if let art = app.customIcon.flatMap({ NSImage(contentsOf: $0) }) {
                    Image(nsImage: art).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                } else { appIcon(app, size: 72) }
                Text(app.name).font(.title.bold())
                Text(status(app)).foregroundStyle(.secondary)
                Button(app.isInstaller == true ? "Run Installer" : "Play", systemImage: "play.fill") { model.requestLaunch() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canEdit)
                HStack { Button("Settings", systemImage: "slider.horizontal.3") { rename = app.name; showApplicationSettings = true }; Button("Folder", systemImage: "folder") { model.openApplicationFolder() } }
                if app.lastLog != nil { Button("View Launch Log", systemImage: "doc.text") { model.openLaunchLog() } }
                Button("Export Compatibility Matrix…") { model.exportCompatibilityMatrix() }
                Button("Record Compatibility…") { showCompatibilityRecord = true }
                    .disabled(!model.canEdit || app.bottleID == nil)
                if let record = app.compatibilityRecords?.last {
                    Text("Observed on \(record.os) · \(record.graphics.displayName)").font(.caption).foregroundStyle(.secondary)
                    Text(record.notes).font(.caption)
                }
                Divider()
                LabeledContent("Launch attempts", value: String(app.launchCount ?? 0))
                if let lastRun = app.launchHistory?.last {
                    Text("Last process: " + lastRun.state.rawValue).font(.caption)
                    if let seconds = lastRun.elapsedSeconds { LabeledContent("Process duration", value: String(format: "%.1f seconds", seconds)) }
                }
                DisclosureGroup("Process history") {
                    ForEach((app.launchHistory ?? []).reversed()) { run in
                        VStack(alignment: .leading) {
                            Text(run.startedAt.formatted() + " · " + run.state.rawValue).font(.caption)
                            Text(run.diagnosis?.guidance ?? "Process result only; rendering and game functionality need observation.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let date = app.lastLaunchedAt { LabeledContent("Last launched", value: date.formatted(date: .abbreviated, time: .shortened)) }
                if let info = app.inspection { LabeledContent("Executable", value: info.summary) }
                if let bottle = model.snapshot.bottles.first(where: { $0.id == app.bottleID }), let runtime = model.snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) {
                    LabeledContent("Engine", value: runtime.version ?? runtime.name)
                } else { Text("Win2Mac will select a configured compatible engine.").font(.caption).foregroundStyle(.secondary) }
                Text(app.executable.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if model.installerBottleID == app.bottleID {
                    GroupBox("Choose installed launch target") {
                        VStack(alignment: .leading) {
                            if model.installedTargets.isEmpty { Text("No new target was found. Use Add to select the installed EXE.") }
                            ForEach(model.installedTargets) { target in Button(target.executable.lastPathComponent) { model.importInstalledTarget(target) }.help(target.executable.path) }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else { ContentUnavailableView("Choose an application", systemImage: "cursorarrow.click") }
    }
    private var compatibilityView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Check your setup").font(.largeTitle.bold())
                Text("Win2Mac runs natively on Apple Silicon. Your Wine engine provides Windows execution and graphics translation.").foregroundStyle(.secondary)
                GroupBox("1 · Select an installed Wine engine") { runtimeSelection.padding(12) }
                GroupBox("2 · Verify readiness") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(HostCapabilities.current.isAppleSilicon ? "Native Apple Silicon frontend" : "macOS frontend", systemImage: "desktopcomputer")
                        Label(HostCapabilities.current.rosettaInstalled ? "Rosetta runtime detected" : "Rosetta not detected · required for Intel engines", systemImage: "cpu")
                        Text("A successful version check verifies the command, not game compatibility. Windows ARM64/ARM64EC engines and proprietary integrations are not available in this build.").font(.caption).foregroundStyle(.secondary)
                        Button("Continue to Home") { model.section = .home }.disabled(!model.selectedRuntimeConfigured || model.selectedRuntime?.version == nil)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                Link("Wine engine setup instructions", destination: URL(string: "https://github.com/tigbittyboy-jpg/win2mac/blob/main/docs/RUNTIME_SETUP.md")!)
            }.padding(32)
        }
    }
    private var settingsView: some View {
        VStack(alignment: .leading) {
            Picker("Settings", selection: $settingsTab) { ForEach(["General", "Engines", "Environments", "Diagnostics"], id: \.self) { Text($0) } }.pickerStyle(.segmented).padding()
            switch settingsTab {
            case "Engines": runtimeView
            case "Environments": bottlesView
            case "Diagnostics":
                VStack { HStack { Button("Export Diagnostics…") { model.exportDiagnostics() }; Button("Open Logs Folder") { NSWorkspace.shared.open(BridgePaths.dataDirectory.appendingPathComponent("Logs")) }; Spacer() }
                    diagnosticsView
                    List(model.snapshot.repairs ?? [], id: \.date) { record in VStack(alignment: .leading) { Text(record.date.formatted()); Text(record.outcome).font(.caption) } }
                }.padding()
            default:
                Form {
                    Picker("Appearance", selection: $appearance) { Text("System").tag("System"); Text("Light").tag("Light"); Text("Dark").tag("Dark") }
                    Toggle("Show library as a grid", isOn: $grid)
                    Text("Win2Mac selects a configured compatible engine automatically for new apps. Each app keeps its own environment and saved launch settings. First execution requires approval. You can remember approval for an unchanged app and engine to launch with one click.").foregroundStyle(.secondary)
                    Text("Logs are saved locally in Application Support/Bridge/Logs. Removing a library entry never deletes its application or environment.").foregroundStyle(.secondary)
                }.padding(24)
            }
        }
    }
    private var applicationSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let app = model.selectedApplication {
                    Text(app.executable.path).font(.caption).textSelection(.enabled)
                    Picker("Windows environment", selection: Binding(get: { model.selectedApplication?.bottleID }, set: { model.associateSelectedApplication($0) })) {
                        Text("Automatic on first launch").tag(Optional<UUID>.none)
                        ForEach(model.snapshot.bottles) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(!model.canEdit)
                    if let bottle = model.snapshot.bottles.first(where: { $0.id == app.bottleID }) {
                        Picker("This game's graphics", selection: Binding(get: { model.selectedApplication?.graphicsOverride }, set: { model.setApplicationGraphics($0) })) {
                            Text("Use environment configuration").tag(Optional<GraphicsBackend>.none)
                            Text("Runtime default").tag(Optional(GraphicsBackend.runtimeDefault))
                            Text("WineD3D Vulkan (experimental)").tag(Optional(GraphicsBackend.wineD3DVulkan))
                            if bottle.graphics == .dxvkMoltenVK { Text("Installed DXVK").tag(Optional(GraphicsBackend.dxvkMoltenVK)) }
                        }.disabled(!model.canEdit)
                        Button("Review Observed Graphics Recommendation") { model.reviewGraphicsRecommendation() }.disabled(!model.canEdit)
                        if let recommendation = model.graphicsRecommendation {
                            Text(recommendation.reason).font(.caption)
                            if recommendation.evidenceRecordID != nil {
                                Button("Use " + recommendation.backend.displayName) { model.setApplicationGraphics(recommendation.backend) }.disabled(!model.canEdit)
                            }
                        }
                        Text("Default recommendation: retain the known-working configuration. Native DLL changes affect the whole environment; use Settings → Environments for reviewed DXVK changes.").font(.caption)
                        if app.steamAppID == nil { Button("Reset to Fresh Environment…") { model.requestFreshEnvironment() }.disabled(!model.canEdit) }
                        DisclosureGroup("Windows prerequisites") { dependencyControls }
                    }
                    Text("Arguments · one argument per line").font(.headline)
                    TextEditor(text: $model.argumentsText).font(.system(.body, design: .monospaced)).frame(height: 90).border(Color.secondary.opacity(0.2))
                    TextField("Working directory · empty uses EXE folder", text: $model.workingDirectoryText)
                    Text("Environment overrides · NAME=value, one per line").font(.caption)
                    TextEditor(text: $model.environmentText).font(.system(.body, design: .monospaced)).frame(height: 60).border(Color.secondary.opacity(0.2))
                    Text("Prefix, architecture, loader and graphics variables are controlled by Bridge.").font(.caption).foregroundStyle(.secondary)
                    Button("Save Launch Settings") { model.saveArguments() }.disabled(!model.canEdit)
                }
            }
        }
    }
    private var runtimePicker: some View {
        Picker("Runtime", selection: $model.selectedRuntimeID) {
            Text("Select runtime").tag(nil as UUID?)
            ForEach(model.snapshot.runtimes) { runtime in Text(runtime.name + " — " + runtime.executable.path).tag(Optional(runtime.id)) }
        }.disabled(!model.canEdit)
    }
    private func graphicsPicker(_ bottle: Bottle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Graphics", selection: Binding(get: {
                model.snapshot.bottles.first(where: { $0.id == bottle.id })?.graphics ?? bottle.graphics
            }, set: { model.setBottleGraphics($0, bottleID: bottle.id) })) {
                ForEach(GraphicsManager().capabilities().filter { $0.configurable && ($0.backend != .dxvkMoltenVK || DXVKInstaller.hasInstallation(bottle)) }, id: \.backend) { capability in
                    Text(capability.backend.displayName).tag(capability.backend)
                }
                if !GraphicsManager().capabilities().contains(where: { $0.backend == bottle.graphics && $0.configurable && ($0.backend != .dxvkMoltenVK || DXVKInstaller.hasInstallation(bottle)) }) {
                    Text(bottle.graphics.displayName).tag(bottle.graphics)
                }
            }.disabled(!model.canEdit || DXVKInstaller.hasInstallation(bottle))
            if DXVKInstaller.hasInstallation(bottle) {
                Text("DXVK import/backups present. Restore original DLLs before changing graphics backends.").font(.caption)
                Button("Restore Original Direct3D DLLs…") { model.requestDXVKRestore(bottle) }.disabled(!model.canEdit)
            } else {
                Button("Import macOS DXVK x64 Libraries…") { model.importDXVK(bottle) }.disabled(!model.canEdit)
            }
            Link("DirectX 11 setup and supported package layout", destination: URL(string: "https://github.com/tigbittyboy-jpg/win2mac/blob/main/docs/DXVK_SETUP.md")!).font(.caption)
            if bottle.graphics == .wineD3DVulkan {
                Text("Requires Wine's Vulkan renderer and compatible Vulkan/Metal support in your installed runtime. Experimental; game compatibility is not guaranteed. Applies to all applications using this bottle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var runtimeSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Choose Wine Executable…") { model.chooseRuntime() }
                Button("Scan Installed Runtimes") { model.discoverRuntimes() }
            }.disabled(!model.canEdit)
            if model.snapshot.runtimes.isEmpty {
                Text("No Wine runtime added").font(.headline)
                Text("Bottle creation requires a separately installed Wine-compatible runtime. If you have one, choose its Wine executable above. Otherwise, install a runtime that supports Windows x64 on Apple Silicon, then scan or select it here.")
                Link("Runtime setup instructions", destination: URL(string: "https://github.com/tigbittyboy-jpg/win2mac/blob/main/docs/RUNTIME_SETUP.md")!)
                Link("Wine macOS builds and provider instructions", destination: URL(string: "https://github.com/Gcenx/macOS_Wine_builds")!)
            } else {
                runtimePicker
            }
            if let runtime = model.selectedRuntime {
                Text(runtime.executable.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Picker("Provider-documented architecture", selection: $model.runtimeArchitecture) {
                    ForEach(RuntimeArchitecture.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.disabled(!model.canEdit)
                Text("For wrappers, choose the architecture of the launched Wine engine. Inspection does not prove Windows x64 support.").font(.caption)
                Toggle("My runtime provider documents Windows x64 execution on this Mac", isOn: $model.runtimeSupportsX64).disabled(!model.canEdit)
                Toggle("My runtime provider documents Windows x86 (32-bit/WoW64) execution on this Mac", isOn: $model.runtimeSupportsX86).disabled(!model.canEdit)
                Text("32-bit EXEs require a compatible WoW64 runtime in a win64 bottle. Win2Mac’s manual DXVK import supports x64 games only.").font(.caption)
                HStack {
                    Button("Save Runtime Settings") { model.saveRuntimeSettings() }
                    Button("Probe Version…") { model.requestProbe() }
                }.disabled(!model.canEdit)
                if !model.selectedRuntimeConfigured {
                    Text("Confirm the runtime's architecture and Windows x64 support, then save settings to enable bottle creation.")
                        .font(.callout)
                }
                Picker("Runtime provider", selection: $model.runtimeProvider) {
                    ForEach(RuntimeProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.disabled(!model.canEdit)
                Text(model.runtimeProvider.integrationNote).font(.caption).foregroundStyle(.secondary)
                Link("Provider requirements and license", destination: model.runtimeProvider.documentation)
                Text("Last version: \(runtime.version ?? "not probed")").font(.caption)
                if let identity = runtime.identity {
                    Text("Recorded executable SHA-256: \(identity.sha256)").font(.caption.monospaced()).textSelection(.enabled)
                    Text(identity.scope).font(.caption).foregroundStyle(.secondary)
                }
                Button("Register Changed Engine as Separate Revision") { model.registerRuntimeRevision() }.disabled(!model.canEdit)
                Text("Existing environment associations are never switched automatically. Keep the previous provider installation to make runtime rollback possible.").font(.caption)
            }
        }
    }
    private var runtimeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("User-installed Wine runtimes").font(.title2)
                Text("Win2Mac does not bundle or download compatibility engines. Select the executable or wrapper documented by your runtime provider.")
                runtimeSelection
                Text("Intel engines require Rosetta 2 on Apple Silicon. Native ARM64 engines need their own supported x64 translation path. Some engines require a newer macOS than Bridge's macOS 14 minimum.")
                Link("Apple's Rosetta instructions", destination: URL(string: "https://support.apple.com/en-us/102527")!)
                Spacer()
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var bottlesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Isolated Wine prefixes").font(.title2)
                Text("Prefixes organize settings and installed files. They are not security sandboxes.")
                runtimeSelection
                Divider()
                TextField("Bottle name", text: $model.bottleName).disabled(!model.canEdit)
                HStack {
                    TextField("Absolute prefix directory", text: $model.prefixPath).disabled(!model.canEdit)
                    Button("Choose Parent…") { model.choosePrefixLocation() }.disabled(!model.canEdit)
                }
                HStack {
                    Button("Create Bottle…") { model.requestCreateBottle() }.disabled(!model.canCreateBottle)
                    Button("Use Existing Prefix…") { model.associateExistingPrefix() }
                        .disabled(!model.canEdit || model.selectedRuntime == nil)
                }
                Text("Creation needs a new directory and executes wineboot with approval. Existing prefixes must contain drive_c and system.reg. Optional graphics imports below require separate approval.").font(.caption)
                Divider()
                ForEach(model.snapshot.bottles) { bottle in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(bottle.name).font(.headline)
                            Text(bottle.prefix.path).font(.caption).textSelection(.enabled)
                            Text(bottle.managed ? "Bridge-managed" : "External — association only").font(.caption).foregroundStyle(.secondary)
                            Text("Requested Windows version: " + (bottle.requestedWindowsVersion?.rawValue ?? "Provider default")).font(.caption)
                            Menu("Change Windows Version…") {
                                ForEach(WindowsVersion.allCases, id: \.self) { version in
                                    Button(version.rawValue) { model.requestWindowsVersion(version, bottle: bottle) }
                                }
                            }.disabled(!model.canEdit || !bottle.managed)
                            graphicsPicker(bottle)
                        }
                        Spacer()
                        Menu("Recovery") {
                            Button("Backup…") { model.requestBackup(bottle) }
                            Button("Duplicate…") { model.requestDuplicate(bottle) }
                            Button("Load Backups") { model.refreshBackups(bottle) }
                            ForEach(model.environmentBackups[bottle.id] ?? []) { backup in
                                Button("Restore " + backup.createdAt.formatted()) { model.requestRestore(backup, bottle: bottle) }
                            }
                        }.disabled(!model.canEdit || !bottle.managed)
                        Button("Repair…") { model.requestRepair(bottle) }.disabled(!model.canEdit || !bottle.managed)
                        Button(bottle.managed ? "Delete…" : "Remove…", role: .destructive) { model.pendingRemoval = bottle }.disabled(!model.canEdit)
                    }.padding(.vertical, 6)
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var diagnosticsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.largeTitle.bold())
            let host = HostInventory.current
            Text("\(host.processArchitecture) · \(host.logicalProcessorCount) logical CPUs · \(host.physicalMemoryBytes / 1_073_741_824) GiB RAM").foregroundStyle(.secondary)
            Text(host.hardwareModel).font(.caption)
            Text(host.operatingSystem).font(.caption)
            Text(host.graphicsMeasurement).font(.caption).foregroundStyle(.secondary)
            if let diagnosis = model.diagnosis {
                GroupBox(diagnosis.title) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Confidence: " + diagnosis.confidence.rawValue).font(.headline)
                        Text(diagnosis.guidance)
                        ForEach(Array(diagnosis.evidence.enumerated()), id: \.offset) { _, line in Text(line).font(.caption.monospaced()).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(model.snapshot.applications.filter { $0.lastDiagnosis != nil }) { app in
                if let failure = app.lastDiagnosis {
                    GroupBox(app.name + " · " + failure.title) {
                        Text(failure.guidance + "\nConfidence: " + failure.confidence.rawValue).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("Review output before sharing: path redaction cannot remove every secret.").font(.caption)
            HStack {
                Button("Refresh") { model.refreshDiagnostics() }
                Button("Copy Report") { model.copyDiagnostics() }
            }
            ScrollView { Text(model.diagnosticsText).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding()
    }
    private func observationPicker(_ name: String, selection: Binding<VerificationOutcome>) -> some View {
        Picker(name, selection: selection) {
            ForEach(VerificationOutcome.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }
    private var dependencyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let info = model.selectedApplication?.inspection {
                ForEach(DependencyManager.suggestions(for: info), id: \.component) { suggestion in
                    Text(suggestion.component.rawValue + ": " + suggestion.explanation).font(.caption)
                }
            }
            Picker("Component", selection: $model.dependencyComponent) {
                ForEach(WindowsDependency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Link("Official Microsoft installer and requirements", destination: model.dependencyComponent.documentation)
            Picker("Dependency payload architecture", selection: $model.dependencyArchitecture) {
                Text("Windows x64").tag(WindowsMachine.x64)
                Text("Windows x86").tag(WindowsMachine.x86)
            }
            Text("A bootstrap installer's architecture does not determine its payload. Choose the component edition required by your game.").font(.caption)
            TextField("Publisher-reported version", text: $model.dependencyVersion)
            Text("Select an official installer for the required architecture. For DirectX, extract the official package and choose DXSETUP.exe; keep its adjacent installation files. Confirm your Wine provider supports the component. Back up first; all apps sharing this environment may be affected.").font(.caption)
            Toggle("I reviewed the previous uncertain outcome and want to retry", isOn: $model.retryDependency)
            HStack {
                Button("Select Installer and Review…") { model.requestDependencyInstall() }.disabled(!model.canEdit || model.dependencyVersion.isEmpty)
                Button("Read Installation Records") { model.refreshDependencies() }.disabled(!model.canEdit)
            }
            ForEach(model.dependencyRecords) { record in
                Text(record.component.rawValue + " · " + record.state.rawValue + " · " + record.details).font(.caption).textSelection(.enabled)
            }
        }.padding(.vertical, 8)
    }
    private var steamView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Windows Steam").font(.largeTitle.bold())
                Text("Use a dedicated shared environment for Steam authentication and its installed games. Each imported game keeps its arguments and requested graphics. A running Steam client may ignore a new process environment; close it before changing graphics. DRM, anti-cheat and game support depend on the publisher and engine.").foregroundStyle(.secondary)
                Picker("Steam environment", selection: $model.steamBottleID) {
                    Text("Choose an initialized environment").tag(Optional<UUID>.none)
                    ForEach(model.snapshot.bottles) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(!model.canEdit)
                HStack {
                    Button("Create Environment…") { model.section = .settings; settingsTab = "Environments" }
                    Button("Detect Steam and Games") { model.refreshSteam() }.disabled(!model.canEdit || model.steamBottleID == nil)
                }
                Link("Download official Windows Steam from Valve", destination: SteamManager.installerURL)
                Toggle("I reviewed an uncertain Steam installation and want to retry", isOn: $model.retrySteamInstallation)
                Button("Install Downloaded Steam…") { model.requestSteamInstall() }.disabled(!model.canEdit || model.steamBottleID == nil)
                if model.steamClient != nil { Button("Launch Steam…") { model.launchSteamClient() }.buttonStyle(.borderedProminent).disabled(!model.canEdit) }
                ForEach(Array(model.steamWarnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).foregroundStyle(.orange) }
                if model.steamGames.isEmpty { Text("Detected installed games appear here after a scan. An installation is not a compatibility result.").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) {
                    ForEach(model.steamGames) { game in
                        VStack(alignment: .leading, spacing: 12) {
                            if let art = game.artwork.flatMap({ NSImage(contentsOf: $0) }) { Image(nsImage: art).resizable().scaledToFit().frame(height: 140) }
                            Text(game.name).font(.headline)
                            Text("Installed · AppID " + game.appID).font(.caption).foregroundStyle(.secondary)
                            Button("Add to Library") { model.importSteamGame(game) }.disabled(!model.canEdit)
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.padding(32)
        }
    }
    private var consoleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Process Output").font(.headline)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Stop") { model.stop() }.disabled(!model.busy)
                Button("Clear") { model.clearConsole() }
            }
            ScrollView {
                Text(model.console).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 150)
        }.padding()
    }
}
