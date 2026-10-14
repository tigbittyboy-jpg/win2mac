// The Xcode XCTest target compiles the same BridgeModel source as the app.
// Linux/SwiftPM backend tests do not compile AppKit or the UI model.
#if BRIDGE_MODEL_TESTS
import Foundation
import XCTest
@testable import BridgeCore

final class BridgeModelTests: XCTestCase, @unchecked Sendable {
    @MainActor
    private func waitForOperation(_ model: BridgeModel) async throws {
        for _ in 0..<200 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Model operation did not finish")
    }
    private func fixture() throws -> (root: URL, runtime: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeModelTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = root.appendingPathComponent("wine")
        // An inspected Mach-O header only; this file must never be executed.
        try Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1]).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        var image = [UInt8](repeating: 0, count: 512)
        image[0] = 0x4d; image[1] = 0x5a; image[60] = 64; image[64] = 0x50; image[65] = 0x45
        image[68] = 0x64; image[69] = 0x86; image[70] = 1; image[84] = 240; image[86] = 2
        image[88] = 0x0b; image[89] = 2; image[149] = 2
        try Data(image).write(to: root.appendingPathComponent("Game.exe"))
        return (root, runtime)
    }
    private var host: HostCapabilities { .init(isMacOS: true, isAppleSilicon: true, rosettaInstalled: true) }

    @MainActor
    func testEmptyDiscoveryDoesNotWriteAStoreOrOfferCreation() async throws {
        let sample = try fixture(); defer { try? FileManager.default.removeItem(at: sample.root) }
        let file = sample.root.appendingPathComponent("library.json")
        let executor = MockExecutor()
        let model = BridgeModel(library: ApplicationLibrary(file: file),
            runtimes: RuntimeManager(executor: executor, host: host, discoveryPaths: []))
        await model.load()
        XCTAssertTrue(model.canEdit)
        XCTAssertTrue(model.snapshot.runtimes.isEmpty)
        XCTAssertFalse(model.canCreateBottle)
        XCTAssertNil(model.selectedRuntime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(model.console.contains("install a compatible Wine runtime first"))
        model.requestCreateBottle()
        XCTAssertNil(model.pendingApproval)
        let requests = await executor.requests
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testDiscoveredRuntimeRequiresSavedConfigurationAndApprovalBeforeBottleCreation() async throws {
        let sample = try fixture(); defer { try? FileManager.default.removeItem(at: sample.root) }
        let file = sample.root.appendingPathComponent("library.json")
        let executor = MockExecutor(initializePrefix: true)
        let runtimes = RuntimeManager(executor: executor, host: host, discoveryPaths: [sample.runtime])
        let bottles = BottleManager(executor: executor, runtimes: runtimes)
        let model = BridgeModel(library: ApplicationLibrary(file: file), runtimes: runtimes, bottles: bottles)
        await model.load()
        XCTAssertEqual(model.snapshot.runtimes.count, 1)
        XCTAssertEqual(model.selectedRuntime?.architecture, .x86_64)
        XCTAssertFalse(model.canCreateBottle)
        model.runtimeSupportsX64 = true
        model.runtimeSupportsX86 = true
        XCTAssertFalse(model.canCreateBottle, "Unsaved declarations must not permit creation")
        model.saveRuntimeSettings()
        try await waitForOperation(model)
        XCTAssertTrue(model.canCreateBottle)
        XCTAssertEqual(model.selectedRuntime?.supportsWindowsX86, true)
        model.prefixPath = sample.root.appendingPathComponent("my bottle").path
        model.requestCreateBottle()
        let request = try XCTUnwrap(model.pendingApproval)
        let beforeApproval = await executor.requests
        XCTAssertTrue(beforeApproval.isEmpty)
        model.approve(request)
        try await waitForOperation(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.snapshot.bottles.count, 1)
        let commands = await executor.requests
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.arguments, ["wineboot", "-u"])
        let reloaded = BridgeModel(library: ApplicationLibrary(file: file), runtimes: runtimes, bottles: bottles)
        await reloaded.load()
        XCTAssertEqual(reloaded.snapshot.runtimes.count, 1, "Discovery must not duplicate saved entries")
        XCTAssertEqual(reloaded.selectedRuntime?.id, model.selectedRuntime?.id)
        XCTAssertTrue(reloaded.canCreateBottle, "Discovery must preserve saved compatibility settings")
        XCTAssertEqual(reloaded.snapshot.bottles, model.snapshot.bottles)
        XCTAssertTrue(reloaded.runtimeSupportsX86, "Saved x86 declaration survives discovery/restart")
    }

    @MainActor
    func testCorruptLibraryIsPreservedDespiteRuntimeDiscovery() async throws {
        let sample = try fixture(); defer { try? FileManager.default.removeItem(at: sample.root) }
        let file = sample.root.appendingPathComponent("library.json"), original = Data("corrupt".utf8)
        try original.write(to: file)
        let model = BridgeModel(library: ApplicationLibrary(file: file),
            runtimes: RuntimeManager(host: host, discoveryPaths: [sample.runtime]))
        await model.load()
        XCTAssertFalse(model.canEdit)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    @MainActor
    func testBottleGraphicsPersistsAndApprovalShowsRequestedOverride() async throws {
        let sample = try fixture(); defer { try? FileManager.default.removeItem(at: sample.root) }
        let file = sample.root.appendingPathComponent("library.json")
        let executor = MockExecutor()
        let runtimes = RuntimeManager(executor: executor, host: host, discoveryPaths: [])
        var engine = try runtimes.inspect(sample.runtime); engine.supportsWindowsX64 = true
        let bottle = Bottle(name: "Existing bottle", prefix: sample.root.appendingPathComponent("prefix"), runtimeID: engine.id)
        let app = ApplicationEntry(name: "Game", executable: sample.root.appendingPathComponent("Game.exe"), bottleID: bottle.id)
        var snapshot = LibrarySnapshot(); snapshot.runtimes = [engine]; snapshot.bottles = [bottle]; snapshot.applications = [app]
        let library = ApplicationLibrary(file: file); try await library.save(snapshot)
        let model = BridgeModel(library: library, runtimes: runtimes, bottles: BottleManager(executor: executor, runtimes: runtimes))
        await model.load()
        model.setBottleGraphics(.wineD3DVulkan, bottleID: bottle.id)
        try await waitForOperation(model)
        XCTAssertNil(model.errorMessage)
        let saved = try await ApplicationLibrary(file: file).load()
        XCTAssertEqual(saved.bottles.first?.graphics, .wineD3DVulkan)
        XCTAssertEqual(saved.bottles.first?.prefix, bottle.prefix)
        model.requestLaunch()
        try await waitForOperation(model)
        let approval = try XCTUnwrap(model.pendingApproval)
        XCTAssertTrue(approval.details.contains("WINE_D3D_CONFIG=renderer=vulkan"))
        XCTAssertTrue(approval.details.contains("WineD3D Vulkan (experimental)"))
        let commands = await executor.requests
        XCTAssertTrue(commands.isEmpty, "Saving graphics/requesting approval must not run Wine")
        model.pendingApproval = nil
        model.setBottleGraphics(.runtimeDefault, bottleID: bottle.id)
        try await waitForOperation(model)
        let restored = try await library.load()
        XCTAssertEqual(restored.bottles.first?.graphics, .runtimeDefault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bottle.prefix.path))
    }
    @MainActor
    func testDXVKImportAndRestoreRequireApprovalPersistAndNeverExecuteWine() async throws {
        let sample = try fixture(); defer { try? FileManager.default.removeItem(at: sample.root) }
        let executor = MockExecutor()
        let runtimes = RuntimeManager(executor: executor, host: host, discoveryPaths: [])
        var engine = try runtimes.inspect(sample.runtime); engine.supportsWindowsX64 = true
        let bottle = Bottle(name: "Test", prefix: sample.root.appendingPathComponent("prefix"), runtimeID: engine.id)
        let system = bottle.prefix.appendingPathComponent("drive_c/windows/system32")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try Data().write(to: bottle.prefix.appendingPathComponent("system.reg"))
        let directory = sample.root.appendingPathComponent("x64")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[70] = 1; bytes[84] = 240; bytes[86] = 2; bytes[149] = 2
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes[64] = 0x50; bytes[65] = 0x45; bytes[68] = 0x64; bytes[69] = 0x86
        bytes[87] = 0x20; bytes[88] = 0x0b; bytes[89] = 2
        for name in DXVKInstaller.libraryNames { try Data(bytes).write(to: directory.appendingPathComponent(name)) }
        let app = ApplicationEntry(name: "Game", executable: sample.root.appendingPathComponent("Game.exe"), bottleID: bottle.id)
        var snapshot = LibrarySnapshot(); snapshot.runtimes = [engine]; snapshot.bottles = [bottle]; snapshot.applications = [app]
        let library = ApplicationLibrary(file: sample.root.appendingPathComponent("library.json"))
        try await library.save(snapshot)
        let model = BridgeModel(library: library, runtimes: runtimes, bottles: BottleManager(executor: executor, runtimes: runtimes))
        await model.load()
        model.requestDXVKImport(directory: directory, bottle: bottle)
        let approval = try XCTUnwrap(model.pendingApproval)
        XCTAssertTrue(approval.changesFiles)
        XCTAssertTrue(approval.details.contains("DXGI is unchanged"))
        XCTAssertFalse(DXVKInstaller.hasInstallation(bottle))
        model.approve(approval); try await waitForOperation(model)
        XCTAssertNil(model.errorMessage)
        let saved = try await library.load()
        let installed = try XCTUnwrap(saved.bottles.first)
        XCTAssertEqual(installed.graphics, .dxvkMoltenVK)
        try DXVKInstaller.validateInstallation(installed)
        model.requestLaunch()
        try await waitForOperation(model)
        XCTAssertTrue(try XCTUnwrap(model.pendingApproval).details.contains("WINEDLLOVERRIDES=d3d11,d3d10core=n;dxgi=b"))
        model.pendingApproval = nil
        model.setBottleGraphics(.runtimeDefault, bottleID: bottle.id); try await waitForOperation(model)
        XCTAssertNotNil(model.errorMessage, "Backend cannot change while native DLLs remain installed")
        model.errorMessage = nil
        model.requestDXVKRestore(installed)
        XCTAssertTrue(DXVKInstaller.hasInstallation(installed))
        model.approve(try XCTUnwrap(model.pendingApproval)); try await waitForOperation(model)
        XCTAssertNil(model.errorMessage)
        let restored = try await library.load()
        XCTAssertEqual(restored.bottles.first?.graphics, .runtimeDefault)
        XCTAssertFalse(DXVKInstaller.hasInstallation(installed))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: system.path).isEmpty)
        let commands = await executor.requests; XCTAssertTrue(commands.isEmpty)
    }
    @MainActor
    func testImportAutomaticallyPreparesDedicatedEnvironmentOnlyAfterApproval() async throws {
        let sample = try fixture(); defer { try? FileManager.default.removeItem(at: sample.root) }
        let executor = MockExecutor(initializePrefix: true)
        let runtimes = RuntimeManager(executor: executor, host: host, discoveryPaths: [])
        var engine = try runtimes.inspect(sample.runtime); engine.supportsWindowsX64 = true
        var snapshot = LibrarySnapshot(); snapshot.runtimes = [engine]
        let store = ApplicationLibrary(file: sample.root.appendingPathComponent("library.json")); try await store.save(snapshot)
        let model = BridgeModel(library: store, runtimes: runtimes,
            bottles: BottleManager(executor: executor, runtimes: runtimes),
            launcher: LaunchService(executor: executor, runtimes: runtimes, bottles: BottleManager(runtimes: runtimes)),
            environmentsDirectory: sample.root.appendingPathComponent("Environments"), logsDirectory: sample.root.appendingPathComponent("Logs"))
        await model.load()
        XCTAssertEqual(model.section, .home)
        model.importExecutable(sample.root.appendingPathComponent("Game.exe")); try await waitForOperation(model)
        XCTAssertEqual(model.section, .library); XCTAssertEqual(model.snapshot.applications.count, 1)
        XCTAssertEqual(model.selectedApplication?.inspection?.machine, .x64)
        model.requestLaunch(); try await waitForOperation(model)
        let approval = try XCTUnwrap(model.pendingApproval)
        let before = await executor.requests; XCTAssertTrue(before.isEmpty)
        model.approve(approval); try await waitForOperation(model)
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.snapshot.bottles.count, 1)
        XCTAssertEqual(model.selectedApplication?.launchCount, 1); XCTAssertEqual(model.selectedApplication?.lastExitCode, 0)
        let commands = await executor.requests; XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.first?.arguments, ["wineboot", "-u"])
        XCTAssertEqual(commands.last?.arguments, [sample.root.appendingPathComponent("Game.exe").path])
        let log = try XCTUnwrap(model.selectedApplication?.lastLog)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("Process exited with code 0"))
        let restored = try await store.load(); XCTAssertEqual(restored, model.snapshot)
    }
    @MainActor
    func testRememberedApprovalInvalidatesWhenBinaryChangesAndRemovalPreservesEnvironment() async throws {
        let sample = try fixture(); defer { try? FileManager.default.removeItem(at: sample.root) }
        let executor = MockExecutor(), runtimes = RuntimeManager(executor: executor, host: host, discoveryPaths: [])
        var engine = try runtimes.inspect(sample.runtime); engine.supportsWindowsX64 = true
        let prefix = sample.root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data().write(to: prefix.appendingPathComponent("system.reg"))
        let bottle = Bottle(name: "Existing", prefix: prefix, runtimeID: engine.id)
        let app = ApplicationEntry(name: "Game", executable: sample.root.appendingPathComponent("Game.exe"), bottleID: bottle.id)
        var snapshot = LibrarySnapshot(); snapshot.runtimes = [engine]; snapshot.bottles = [bottle]; snapshot.applications = [app]
        let store = ApplicationLibrary(file: sample.root.appendingPathComponent("library.json")); try await store.save(snapshot)
        let model = BridgeModel(library: store, runtimes: runtimes, bottles: BottleManager(runtimes: runtimes),
            launcher: LaunchService(executor: executor, runtimes: runtimes, bottles: BottleManager(runtimes: runtimes)), logsDirectory: sample.root.appendingPathComponent("Logs"))
        await model.load(); model.requestLaunch(); try await waitForOperation(model)
        let request = try XCTUnwrap(model.pendingApproval); model.rememberApproval = true
        model.approve(request); try await waitForOperation(model)
        XCTAssertNotNil(model.selectedApplication?.executionConsent)
        model.requestLaunch(); try await waitForOperation(model); XCTAssertNil(model.pendingApproval)
        let before = await executor.requests; XCTAssertEqual(before.count, 2)
        var changed = try Data(contentsOf: app.executable); changed.append(1); try changed.write(to: app.executable)
        model.requestLaunch(); try await waitForOperation(model); XCTAssertNotNil(model.pendingApproval)
        let after = await executor.requests; XCTAssertEqual(after.count, 2)
        model.pendingApproval = nil; model.removeSelectedApplication(); try await waitForOperation(model)
        XCTAssertTrue(model.snapshot.applications.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.path))
        XCTAssertEqual(model.snapshot.bottles.count, 1)
    }

    @MainActor
    func testGameGraphicsOverridePreservesOtherAppsAndActualLaunchHistory() async throws {
        let sample = try fixture(); defer { try? FileManager.default.removeItem(at: sample.root) }
        let executor = MockExecutor(), runtimes = RuntimeManager(executor: executor, host: host, discoveryPaths: [])
        var runtime = try runtimes.inspect(sample.runtime); runtime.supportsWindowsX64 = true
        let prefix = sample.root.appendingPathComponent("Environment")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data("#arch=win64".utf8).write(to: prefix.appendingPathComponent("system.reg"))
        let bottle = Bottle(name: "Shared", prefix: prefix, runtimeID: runtime.id)
        let first = ApplicationEntry(name: "First", executable: sample.root.appendingPathComponent("Game.exe"), bottleID: bottle.id)
        let second = ApplicationEntry(name: "Second", executable: first.executable, bottleID: bottle.id)
        var snapshot = LibrarySnapshot(); snapshot.runtimes = [runtime]; snapshot.bottles = [bottle]; snapshot.applications = [first, second]
        let store = ApplicationLibrary(file: sample.root.appendingPathComponent("library.json")); try await store.save(snapshot)
        let manager = BottleManager(executor: executor, runtimes: runtimes)
        let model = BridgeModel(library: store, runtimes: runtimes, bottles: manager,
            launcher: LaunchService(executor: executor, runtimes: runtimes, bottles: manager), logsDirectory: sample.root.appendingPathComponent("Logs"))
        await model.load(); model.selectApplication(first.id)
        model.setApplicationGraphics(.wineD3DVulkan); try await waitForOperation(model)
        XCTAssertEqual(model.snapshot.bottles[0].graphics, .runtimeDefault)
        XCTAssertNil(model.snapshot.applications[1].graphicsOverride)
        model.requestLaunch(); try await waitForOperation(model)
        XCTAssertTrue(try XCTUnwrap(model.pendingApproval).details.contains("WINE_D3D_CONFIG=renderer=vulkan"))
        model.approve(try XCTUnwrap(model.pendingApproval)); try await waitForOperation(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.selectedApplication?.launchHistory?.last?.state, .completed)
        XCTAssertNotNil(model.selectedApplication?.launchHistory?.last?.elapsedSeconds)
        XCTAssertNil(model.selectedApplication?.compatibilityRecords)
        let commands = await executor.requests; XCTAssertEqual(commands.last?.environment["WINE_D3D_CONFIG"], "renderer=vulkan")
    }
    @MainActor
    func testNativeModelRecoversInterruptedHistoryWithoutExecutingAnything() async throws {
        let sample = try fixture(); defer { try? FileManager.default.removeItem(at: sample.root) }
        let executor = MockExecutor(), runtimes = RuntimeManager(executor: executor, host: host, discoveryPaths: [])
        let runtime = try runtimes.inspect(sample.runtime)
        let bottle = Bottle(name: "Existing", prefix: sample.root.appendingPathComponent("Environment"), runtimeID: runtime.id)
        var app = ApplicationEntry(name: "Game", executable: sample.root.appendingPathComponent("Game.exe"), bottleID: bottle.id)
        app.launchHistory = [LaunchHistoryRecord(runtime: runtime, bottle: bottle, graphics: .runtimeDefault, log: sample.root.appendingPathComponent("run.log"))]
        var snapshot = LibrarySnapshot(); snapshot.runtimes = [runtime]; snapshot.bottles = [bottle]; snapshot.applications = [app]
        let store = ApplicationLibrary(file: sample.root.appendingPathComponent("library.json")); try await store.save(snapshot)
        let model = BridgeModel(library: store, runtimes: runtimes)
        await model.load()
        XCTAssertEqual(model.selectedApplication?.launchHistory?.last?.state, .interrupted)
        let saved = try await store.load(); XCTAssertEqual(saved.applications[0].launchHistory?.last?.state, .interrupted)
        let commands = await executor.requests; XCTAssertTrue(commands.isEmpty)
    }

}
#endif
