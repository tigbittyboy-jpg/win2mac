import SwiftUI
import BridgeCore

struct ContentView: View {
    @ObservedObject var model: BridgeModel
    var body: some View {
        NavigationSplitView {
            List(NavigationSection.allCases, selection: $model.section) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationTitle("Bridge")
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch model.section ?? .library {
                    case .library: libraryView
                    case .runtimes: runtimeView
                    case .bottles: bottlesView
                    case .diagnostics: diagnosticsView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                consoleView
            }
            .navigationTitle(model.section?.rawValue ?? "Library")
        }
        .sheet(item: $model.pendingApproval) { approval in
            VStack(alignment: .leading, spacing: 16) {
                Text(approval.title).font(.title2)
                Text(approval.details).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text(approval.changesFiles ? "These libraries will run with your user permissions when you separately approve an application launch. Use a trusted macOS DXVK package documented for your runtime. Importing files is not proof of compatibility." : "This software runs with your user permissions and may access your files and network. A Wine prefix is not a security sandbox. Approve only software and runtimes you trust.")
                HStack {
                    Spacer()
                    Button("Cancel") { model.pendingApproval = nil }.keyboardShortcut(.cancelAction)
                    Button(approval.actionTitle) { model.approve(approval) }
                }
            }.padding(24).frame(width: 620)
        }
        .sheet(item: $model.pendingRemoval) { bottle in
            VStack(alignment: .leading, spacing: 16) {
                Text(bottle.managed ? "Delete bottle and its data?" : "Remove bottle association?").font(.title2)
                Text(bottle.prefix.path).textSelection(.enabled)
                Text(bottle.managed ? "This deletes all applications and files inside this Bridge-owned prefix. Make sure no Wine processes are still using it. This cannot be undone." : "The existing Wine prefix and its files will remain on disk.")
                HStack {
                    Spacer()
                    Button("Cancel") { model.pendingRemoval = nil }.keyboardShortcut(.cancelAction)
                    Button(bottle.managed ? "Delete" : "Remove", role: .destructive) { model.removeBottle(bottle) }
                }
            }.padding(24).frame(width: 560)
        }
        .alert("Bridge", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .overlay(alignment: .top) {
            if !model.loaded {
                Text("Library unavailable. Check the error and preserve library.json before repairing it.")
                    .padding().background(.regularMaterial)
            }
        }
    }
    private var libraryView: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Button("Select EXE", systemImage: "plus") { model.selectEXE() }.disabled(!model.canEdit)
                    Spacer()
                    Button("Remove Entry", systemImage: "minus") { model.removeSelectedApplication() }
                        .disabled(!model.canEdit || model.selectedApplication == nil)
                }.padding()
                List(model.snapshot.applications, selection: Binding(get: { model.selectedApplicationID }, set: { model.selectApplication($0) })) { app in
                    VStack(alignment: .leading) {
                        Text(app.name).font(.headline)
                        Text(app.executable.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }.tag(app.id)
                }
            }.frame(minWidth: 240)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let app = model.selectedApplication {
                        Text(app.name).font(.title2)
                        Text(app.executable.path).font(.caption).textSelection(.enabled)
                        Picker("Bottle", selection: Binding(get: { model.selectedApplication?.bottleID }, set: { model.associateSelectedApplication($0) })) {
                            Text("Select a bottle").tag(nil as UUID?)
                            ForEach(model.snapshot.bottles) { bottle in Text(bottle.name).tag(Optional(bottle.id)) }
                        }.disabled(!model.canEdit)
                        if let bottle = model.snapshot.bottles.first(where: { $0.id == app.bottleID }),
                           let runtime = model.snapshot.runtimes.first(where: { $0.id == bottle.runtimeID }) {
                            Text("Runtime: \(runtime.name) (\(runtime.architecture.rawValue))")
                            Text("Prefix: \(bottle.prefix.path)").font(.caption).textSelection(.enabled)
                            graphicsPicker(bottle)
                        }
                        Text("Arguments — one argument per line; spaces stay inside an argument").font(.caption)
                        TextEditor(text: $model.argumentsText).font(.system(.body, design: .monospaced))
                            .frame(height: 90).border(Color.secondary.opacity(0.3)).disabled(!model.canEdit)
                        Button("Save Arguments") { model.saveArguments() }.disabled(!model.canEdit)
                        Button("Launch", systemImage: "play.fill") { model.requestLaunch() }
                            .buttonStyle(.borderedProminent).disabled(!model.canEdit)
                        Text("Importing an EXE does not run it or copy it. Installers use the selected prefix; add the installed application's EXE separately afterward.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("No application selected", systemImage: "square.grid.2x2", description: Text("Use Select EXE to import a Windows x64 application. Configure a runtime and bottle before launching."))
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 350)
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
                HStack {
                    Button("Save Runtime Settings") { model.saveRuntimeSettings() }
                    Button("Probe Version…") { model.requestProbe() }
                }.disabled(!model.canEdit)
                if !model.selectedRuntimeConfigured {
                    Text("Confirm the runtime's architecture and Windows x64 support, then save settings to enable bottle creation.")
                        .font(.callout)
                }
                Text("Last version: \(runtime.version ?? "not probed")").font(.caption)
            }
        }
    }
    private var runtimeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("User-installed Wine runtimes").font(.title2)
                Text("Bridge does not bundle or download compatibility engines. Select the executable or wrapper documented by your runtime provider.")
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
                            graphicsPicker(bottle)
                        }
                        Spacer()
                        Button(bottle.managed ? "Delete…" : "Remove…", role: .destructive) { model.pendingRemoval = bottle }.disabled(!model.canEdit)
                    }.padding(.vertical, 6)
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var diagnosticsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review output before sharing: path redaction cannot remove every secret.").font(.caption)
            HStack {
                Button("Refresh") { model.refreshDiagnostics() }
                Button("Copy Report") { model.copyDiagnostics() }
            }
            ScrollView { Text(model.diagnosticsText).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding()
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
