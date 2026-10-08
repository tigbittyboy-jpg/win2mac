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
}
#endif
