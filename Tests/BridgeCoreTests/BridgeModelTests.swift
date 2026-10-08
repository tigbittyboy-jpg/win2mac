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
        XCTAssertFalse(model.canCreateBottle, "Unsaved declarations must not permit creation")
        model.saveRuntimeSettings()
        try await waitForOperation(model)
        XCTAssertTrue(model.canCreateBottle)
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
        var bytes = [UInt8](repeating: 0, count: 90)
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
}
#endif
