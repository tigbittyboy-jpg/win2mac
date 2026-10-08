import Foundation
import XCTest
@testable import BridgeCore

actor MockExecutor: ProcessExecuting {
    var requests: [ProcessRequest] = []
    var result: ProcessResult
    var failure: BridgeError?
    var initializePrefix: Bool
    init(result: ProcessResult = .init(exitCode: 0, stdout: "wine-9.0"),
         failure: BridgeError? = nil, initializePrefix: Bool = false) {
        self.result = result; self.failure = failure; self.initializePrefix = initializePrefix
    }
    func run(_ request: ProcessRequest, output: @escaping OutputHandler) throws -> ProcessResult {
        requests.append(request)
        if let failure { throw failure }
        if initializePrefix, let prefix = request.environment["WINEPREFIX"] {
            let url = URL(fileURLWithPath: prefix)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
            try Data("WINE REGISTRY Version 2".utf8).write(to: url.appendingPathComponent("system.reg"))
        }
        output(.init(stream: .stdout, text: result.stdout))
        output(.init(stream: .stderr, text: result.stderr))
        return result
    }
}

final class OutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProcessOutput] = []
    func add(_ event: ProcessOutput) { lock.lock(); events.append(event); lock.unlock() }
    func text(_ stream: ProcessOutputStream) -> String {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.stream == stream }.map(\.text).joined()
    }
}

// XCTest owns each instance's setUp/test/tearDown lifecycle. No fixture is shared.
final class BridgeCoreTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private var mac: HostCapabilities { .init(isMacOS: true, isAppleSilicon: true, rosettaInstalled: true) }
    private func runtime(architecture: RuntimeArchitecture = .x86_64) throws -> WineRuntime {
        let url = root.appendingPathComponent("wine runtime")
        // Minimal Mach-O CPU header; never executed by mocked tests.
        try Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return WineRuntime(name: "Test runtime", executable: url, architecture: architecture, supportsWindowsX64: true)
    }
    private func exe(machine: [UInt8] = [0x64, 0x86]) throws -> URL {
        let url = root.appendingPathComponent("Game $(touch hacked); space.exe")
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes[64] = 0x50; bytes[65] = 0x45
        bytes[68] = machine[0]; bytes[69] = machine[1]
        bytes[88] = 0x0b; bytes[89] = 2
        try Data(bytes).write(to: url)
        return url
    }
    private func initializedBottle(runtime: WineRuntime) throws -> Bottle {
        let prefix = root.appendingPathComponent("prefix with spaces")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data().write(to: prefix.appendingPathComponent("system.reg"))
        return Bottle(name: "Test", prefix: prefix, runtimeID: runtime.id)
    }

    func testInspectMachOAndRejectMissingRuntime() throws {
        let engine = try runtime()
        let manager = RuntimeManager(host: mac)
        XCTAssertEqual(try manager.inspect(engine.executable).architecture, .x86_64)
        XCTAssertThrowsError(try manager.inspect(root.appendingPathComponent("missing")))
        try Data([0xcf, 0xfa, 0xed, 0xfe, 12, 0, 0, 1]).write(to: engine.executable)
        XCTAssertEqual(try manager.inspect(engine.executable).architecture, .arm64)
    }
    func testInspectUniversalAndWrapperArchitecture() throws {
        let engine = try runtime()
        var fat = [UInt8](repeating: 0, count: 48)
        fat.replaceSubrange(0..<8, with: [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2])
        fat.replaceSubrange(8..<12, with: [1, 0, 0, 7])
        fat.replaceSubrange(28..<32, with: [1, 0, 0, 12])
        try Data(fat).write(to: engine.executable)
        let manager = RuntimeManager(host: mac)
        XCTAssertEqual(try manager.inspect(engine.executable).architecture, .universal)
        try Data("#!/bin/sh\n".utf8).write(to: engine.executable)
        XCTAssertEqual(try manager.inspect(engine.executable).architecture, .unknown)
    }
    func testRuntimeSymlinkCanBeInspected() throws {
        let engine = try runtime(), link = root.appendingPathComponent("wine-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: engine.executable)
        XCTAssertEqual(try RuntimeManager(host: mac).inspect(link).architecture, .x86_64)
    }
    func testDiscoveryInspectsAndDeduplicatesWithoutExecuting() async throws {
        let engine = try runtime(), link = root.appendingPathComponent("wine-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: engine.executable)
        let executor = MockExecutor()
        let manager = RuntimeManager(executor: executor, host: mac,
            discoveryPaths: [root.appendingPathComponent("missing"), engine.executable, link])
        let found = manager.discover()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.architecture, .x86_64)
        XCTAssertEqual(found.first?.supportsWindowsX64, false)
        let requests = await executor.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testRosettaAndX64DeclarationRequired() throws {
        var engine = try runtime()
        let manager = RuntimeManager(host: .init(isMacOS: true, isAppleSilicon: true, rosettaInstalled: false))
        XCTAssertThrowsError(try manager.validate(engine, forLaunch: true))
        engine.architecture = .arm64; engine.supportsWindowsX64 = false
        XCTAssertThrowsError(try manager.validate(engine, forLaunch: true))
        XCTAssertNoThrow(try manager.validate(engine, forLaunch: false))
        engine.architecture = .unknown
        XCTAssertThrowsError(try manager.validate(engine, forLaunch: false))
        XCTAssertThrowsError(try RuntimeManager(host: .init(isMacOS: false, isAppleSilicon: false, rosettaInstalled: false)).validate(engine, forLaunch: false))
    }
    func testProbeRequiresApprovalAndCapturesVersion() async throws {
        let executor = MockExecutor()
        let manager = RuntimeManager(executor: executor, host: mac)
        let engine = try runtime()
        do { _ = try await manager.probe(engine, approved: false, output: { _ in }); XCTFail("Executed without approval") }
        catch { XCTAssertEqual(error as? BridgeError, .approvalRequired) }
        let before = await executor.requests
        XCTAssertTrue(before.isEmpty)
        let probed = try await manager.probe(engine, approved: true, output: { _ in })
        XCTAssertEqual(probed.version, "wine-9.0")
        let requests = await executor.requests
        XCTAssertEqual(requests.first?.arguments, ["--version"])
        XCTAssertEqual(requests.first?.timeout, 15)
    }
    func testProbeFailureIsNotValidation() async throws {
        let manager = RuntimeManager(executor: MockExecutor(result: .init(exitCode: 1, stderr: "unavailable")), host: mac)
        do { _ = try await manager.probe(try runtime(), approved: true, output: { _ in }); XCTFail("Accepted failed probe") }
        catch { XCTAssertTrue(error is BridgeError) }
    }
    func testPEValidationRejects32BitAndMalformedFiles() throws {
        XCTAssertNoThrow(try ExecutableValidator.validateX64(exe()))
        XCTAssertThrowsError(try ExecutableValidator.validateX64(exe(machine: [0x4c, 0x01])))
        let url = try exe()
        try Data("not an executable".utf8).write(to: url)
        XCTAssertThrowsError(try ExecutableValidator.validateX64(url))
    }
    func testLaunchArgumentsEnvironmentOutputAndNonzeroExit() async throws {
        let engine = try runtime(), bottle = try initializedBottle(runtime: engine)
        let application = ApplicationEntry(name: "Game", executable: try exe(), bottleID: bottle.id,
                                           arguments: ["--name", "a b;$(bad)"])
        let executor = MockExecutor(result: .init(exitCode: 17, stdout: "started\n", stderr: "failed\n"))
        let runtimes = RuntimeManager(executor: executor, host: mac)
        let bottles = BottleManager(executor: executor, runtimes: runtimes)
        let service = LaunchService(executor: executor, runtimes: runtimes, bottles: bottles)
        let output = OutputRecorder()
        let result = try await service.launch(application, bottle: bottle, runtime: engine, approved: true, output: output.add)
        XCTAssertEqual(result.exitCode, 17)
        XCTAssertEqual(output.text(.stdout), "started\n"); XCTAssertEqual(output.text(.stderr), "failed\n")
        let request = await executor.requests.first
        XCTAssertEqual(request?.executable, engine.executable)
        XCTAssertEqual(request?.arguments, [application.executable.path, "--name", "a b;$(bad)"])
        XCTAssertEqual(request?.environment["WINEPREFIX"], bottle.prefix.resolvingSymlinksInPath().path)
        XCTAssertEqual(request?.workingDirectory, application.executable.deletingLastPathComponent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hacked").path))
    }
    func testLaunchRefusesApprovalAndAssociationMismatch() async throws {
        let engine = try runtime(), bottle = try initializedBottle(runtime: engine)
        let executor = MockExecutor(), manager = RuntimeManager(host: mac)
        let service = LaunchService(executor: executor, runtimes: manager)
        let application = ApplicationEntry(name: "Game", executable: try exe())
        do { _ = try await service.launch(application, bottle: bottle, runtime: engine, approved: false, output: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? BridgeError, .approvalRequired) }
        do { _ = try await service.launch(application, bottle: bottle, runtime: engine, approved: true, output: { _ in }); XCTFail() }
        catch { XCTAssertTrue(error is BridgeError) }
        let requests = await executor.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testLaunchFailureReleasesBottleLease() async throws {
        let engine = try runtime(), bottle = try initializedBottle(runtime: engine)
        let executor = MockExecutor(failure: .process("injected launch failure"))
        let runtimes = RuntimeManager(host: mac)
        let bottles = BottleManager(runtimes: runtimes)
        let service = LaunchService(executor: executor, runtimes: runtimes, bottles: bottles)
        let application = ApplicationEntry(name: "Game", executable: try exe(), bottleID: bottle.id)
        do { _ = try await service.launch(application, bottle: bottle, runtime: engine, approved: true, output: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? BridgeError, .process("injected launch failure")) }
        try await bottles.acquire(bottle)
        await bottles.release(bottle)
    }
    func testBottleCreationAndSafeRemoval() async throws {
        let engine = try runtime()
        let executor = MockExecutor(initializePrefix: true)
        let manager = BottleManager(executor: executor, runtimes: RuntimeManager(host: mac))
        let path = root.appendingPathComponent("managed prefix")
        do { _ = try await manager.create(name: "Bottle", prefix: path, runtime: engine, approved: false, output: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? BridgeError, .approvalRequired) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let bottle = try await manager.create(name: "Bottle", prefix: path, runtime: engine, approved: true, output: { _ in })
        let request = await executor.requests.first
        XCTAssertEqual(request?.arguments, ["wineboot", "-u"])
        XCTAssertEqual(request?.environment["WINEARCH"], "win64")
        let found = await manager.enumerate([bottle])
        XCTAssertEqual(found, [bottle])
        try await manager.acquire(bottle)
        do { try await manager.remove(bottle); XCTFail("Removed active bottle") }
        catch { XCTAssertEqual(error as? BridgeError, .busy) }
        await manager.release(bottle)
        var forged = bottle; forged.id = UUID()
        do { try await manager.remove(forged); XCTFail("Removed unowned bottle") } catch { XCTAssertTrue(error is BridgeError) }
        try await manager.remove(bottle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testFailedInitializationRetainsPartialPrefix() async throws {
        let engine = try runtime(), path = root.appendingPathComponent("failed prefix")
        let manager = BottleManager(executor: MockExecutor(result: .init(exitCode: 2)), runtimes: RuntimeManager(host: mac))
        do { _ = try await manager.create(name: "Bad", prefix: path, runtime: engine, approved: true, output: { _ in }); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("partial prefix")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent(".bridge-bottle.json").path))
    }
    func testOwnedRemovalChecksPathWithoutDependingOnURLDirectoryHint() async throws {
        let engine = try runtime()
        let manager = BottleManager(executor: MockExecutor(initializePrefix: true), runtimes: RuntimeManager(host: mac))
        let bottle = try await manager.create(name: "Owned", prefix: root.appendingPathComponent("owned"),
            runtime: engine, approved: true, output: { _ in })
        let marker = bottle.prefix.appendingPathComponent(".bridge-bottle.json")
        var owner = bottle
        owner.prefix = root.appendingPathComponent("different directory", isDirectory: true)
        try JSONEncoder().encode(owner).write(to: marker)
        do { try await manager.remove(bottle); XCTFail("Accepted a marker for another path") }
        catch { XCTAssertTrue(error is BridgeError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bottle.prefix.path))
        owner.prefix = URL(fileURLWithPath: bottle.prefix.path, isDirectory: false)
        try JSONEncoder().encode(owner).write(to: marker)
        try await manager.remove(bottle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bottle.prefix.path))
    }
    func testExternalPrefixAndRepositoryDeletionRefused() async throws {
        let engine = try runtime(), bottle = try initializedBottle(runtime: engine)
        let manager = BottleManager()
        do { try await manager.remove(bottle); XCTFail() } catch { XCTAssertTrue(error is BridgeError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bottle.prefix.path))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        XCTAssertThrowsError(try PrefixPolicy.canonical(bottle.prefix))
        XCTAssertThrowsError(try PrefixPolicy.canonical(FileManager.default.homeDirectoryForCurrentUser))
    }
    func testLibraryRoundTripAndCorruptionPreserved() async throws {
        let file = root.appendingPathComponent("settings/library.json"), library = ApplicationLibrary(file: root.appendingPathComponent("settings/library.json"))
        let empty = try await library.load(); XCTAssertTrue(empty.applications.isEmpty)
        let engine = try runtime(), bottle = try initializedBottle(runtime: engine)
        var snapshot = LibrarySnapshot()
        snapshot.runtimes = [engine]; snapshot.bottles = [bottle]
        snapshot.applications = [.init(name: "Game", executable: try exe(), bottleID: bottle.id, arguments: ["hello world"])]
        try await library.save(snapshot)
        let loaded = try await ApplicationLibrary(file: file).load()
        XCTAssertEqual(loaded, snapshot)
        let broken = Data("corrupt data".utf8); try broken.write(to: file)
        do { _ = try await library.load(); XCTFail("Silently reset corrupt library") } catch { XCTAssertTrue(error is BridgeError) }
        do { try await library.save(snapshot); XCTFail("Overwrote corrupt library") } catch { XCTAssertTrue(error is BridgeError) }
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }
    func testLibraryRejectsDanglingAssociationsAndOverlappingPrefixes() async throws {
        let library = ApplicationLibrary(file: root.appendingPathComponent("library.json"))
        var snapshot = LibrarySnapshot()
        snapshot.applications = [.init(name: "Invalid", executable: try exe(), bottleID: UUID())]
        do { try await library.save(snapshot); XCTFail() } catch { XCTAssertTrue(error is BridgeError) }
        snapshot.applications = []
        let engine = try runtime(); snapshot.runtimes = [engine]
        let bottle = try initializedBottle(runtime: engine)
        snapshot.bottles = [bottle, .init(name: "Nested", prefix: bottle.prefix.appendingPathComponent("nested"), runtimeID: engine.id)]
        do { try await library.save(snapshot); XCTFail() } catch { XCTAssertTrue(error is BridgeError) }
    }
    func testGraphicsRequiresExistingRuntimeConfiguration() throws {
        let graphics = GraphicsManager()
        XCTAssertEqual(try graphics.environment(for: .runtimeDefault), [:])
        XCTAssertThrowsError(try graphics.environment(for: .d3dMetal))
        XCTAssertThrowsError(try graphics.environment(for: .dxvkMoltenVK))
        XCTAssertEqual(graphics.capabilities().filter(\.configurable).count, 1)
    }
    func testDiagnosticsRedactsKnownAndOtherUserPaths() {
        let diagnostics = DiagnosticsService(home: URL(fileURLWithPath: "/Users/alice"), host: mac)
        let input = "Error /Users/alice/Documents/game.exe\n/tmp/private/game.log\n/Users/bob/file.txt\nstatus 7"
        let redacted = diagnostics.redact(input)
        XCTAssertFalse(redacted.contains("alice")); XCTAssertFalse(redacted.contains("bob"))
        XCTAssertFalse(redacted.contains("/tmp/private")); XCTAssertTrue(redacted.contains("status 7"))
    }
    // These integration tests run only trusted system tools, never Wine or a PE file.
    func testFoundationExecutorCapturesBothStreamsAndExitCode() async throws {
        let recorder = OutputRecorder()
        let result = try await FoundationProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'hello world\\n'; printf 'error text\\n' >&2; exit 7"]), output: recorder.add)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, "hello world\n"); XCTAssertEqual(result.stderr, "error text\n")
        XCTAssertEqual(recorder.text(.stdout), result.stdout); XCTAssertEqual(recorder.text(.stderr), result.stderr)
    }
    func testFoundationExecutorDrainsLargePipesWithoutDeadlock() async throws {
        let result = try await FoundationProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ \"$i\" -lt 6000 ]; do printf 'abcdefghijklmnopqrstuvwxyz\\n'; printf 'abcdefghijklmnopqrstuvwxyz\\n' >&2; i=$((i+1)); done"], timeout: 20), output: { _ in })
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 162_000); XCTAssertEqual(result.stderr.utf8.count, 162_000)
    }
    func testFoundationExecutorLaunchFailure() async {
        do { _ = try await FoundationProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/bridge/nonexistent"), arguments: []), output: { _ in }); XCTFail() }
        catch { XCTAssertTrue(error is BridgeError) }
    }
    func testFoundationExecutorPreservesSplitUTF8() async throws {
        let recorder = OutputRecorder()
        let result = try await FoundationProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '\\342'; sleep 0.05; printf '\\202\\254'"]), output: recorder.add)
        XCTAssertEqual(result.stdout, "€")
        XCTAssertEqual(recorder.text(.stdout), "€")
    }
    func testFoundationExecutorTimeoutAndCancellation() async throws {
        let executor = FoundationProcessExecutor()
        do { _ = try await executor.run(.init(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.1), output: { _ in }); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("time limit")) }
        let task = Task { try await executor.run(.init(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]), output: { _ in }) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
}
