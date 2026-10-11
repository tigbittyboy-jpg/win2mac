import Foundation
import XCTest
@testable import BridgeCore

private actor DelayedBoot: ProcessExecuting {
    var count = 0
    func run(_ request: ProcessRequest, output: @escaping OutputHandler) async throws -> ProcessResult {
        count += 1
        let prefix = URL(fileURLWithPath: request.environment["WINEPREFIX"]!)
        Task {
            try await Task.sleep(for: .milliseconds(40))
            try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
            try Data("WINE REGISTRY Version 2\n#arch=win64\n".utf8).write(to: prefix.appendingPathComponent("system.reg"))
        }
        return .init(exitCode: 0)
    }
}

final class OverhaulTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var host: HostCapabilities { .init(isMacOS: true, isAppleSilicon: true, rosettaInstalled: true) }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeOverhaul-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func bytes(machine: UInt16 = 0x8664, plus: Bool = true, managed: Bool = false, msi: Bool = false) -> Data {
        var b = [UInt8](repeating: 0, count: 1024)
        func u16(_ p: Int, _ n: UInt16) { b[p] = UInt8(n & 255); b[p + 1] = UInt8(n >> 8) }
        func u32(_ p: Int, _ n: UInt32) { for i in 0..<4 { b[p + i] = UInt8((n >> (i * 8)) & 255) } }
        b[0] = 0x4d; b[1] = 0x5a; u32(60, 64); b[64] = 0x50; b[65] = 0x45
        u16(68, machine); u16(70, 1); u16(84, 240); u16(86, 2); u16(88, plus ? 0x20b : 0x10b)
        u32(148, 512)
        let directories = plus ? 200 : 184
        u32(directories - 4, 16)
        // One raw section at file 512, RVA 0x1000.
        u32(336, 512); u32(340, 0x1000); u32(344, 512); u32(348, 512)
        if managed { u32(directories + 14 * 8, 0x1000); u32(directories + 14 * 8 + 4, 72); u32(512, 72); u32(528, 2) }
        if msi {
            u32(directories + 8, 0x1080); u32(directories + 12, 40)
            u32(640 + 12, 0x10c0)
            for (i, byte) in "msi.dll".utf8.enumerated() { b[704 + i] = byte }
        }
        return Data(b)
    }
    private func image(_ data: Data) throws -> URL {
        let url = root.appendingPathComponent("\(UUID()).exe"); try data.write(to: url); return url
    }
    private func engine(_ name: String = "Wine Devel") throws -> WineRuntime {
        let url = root.appendingPathComponent(name)
        try Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return .init(name: name, executable: url, architecture: .x86_64, supportsWindowsX64: true, supportsWindowsX86: true)
    }
    func testAllMachineTypesAndIndependentFormats() throws {
        for (code, type, plus) in [(UInt16(0x14c), WindowsMachine.x86, false), (0x8664, .x64, true), (0xaa64, .arm64, true), (0xa641, .arm64EC, true)] {
            let info = try ExecutableInspector.inspect(image(bytes(machine: code, plus: plus)))
            XCTAssertEqual(info.machine, type); XCTAssertEqual(info.format, plus ? .pe32Plus : .pe32)
        }
        XCTAssertEqual(try ExecutableInspector.inspect(image(bytes(machine: 0x9999))).machine, .unknown)
        XCTAssertThrowsError(try ExecutableInspector.inspect(image(bytes(machine: 0x14c, plus: true))))
    }
    func testMalformedHeaderSectionAndDirectoryBounds() throws {
        let valid = bytes()
        for length in [0, 10, 64, 90, 300, 900] { XCTAssertThrowsError(try ExecutableInspector.inspect(image(valid.prefix(length)))) }
        var bad = valid; bad[60] = 0xff; bad[61] = 0xff; bad[62] = 0xff; bad[63] = 0xff
        XCTAssertThrowsError(try ExecutableInspector.inspect(image(bad)))
        bad = valid; bad[348] = 0xff; bad[349] = 0xff
        XCTAssertThrowsError(try ExecutableInspector.inspect(image(bad)))
        bad = valid; bad[208] = 1; bad[212] = 40
        XCTAssertThrowsError(try ExecutableInspector.inspect(image(bad)))
        bad = valid; bad[196] = 255
        XCTAssertThrowsError(try ExecutableInspector.inspect(image(bad)))
    }
    func testManagedAndInstallerEvidenceDoesNotUseFilename() throws {
        let info = try ExecutableInspector.inspect(image(bytes(machine: 0x14c, plus: false, managed: true, msi: true)))
        XCTAssertTrue(info.managed); XCTAssertTrue(info.requires32Bit)
        XCTAssertEqual(info.imports, ["msi.dll"]); XCTAssertEqual(info.kind, .installerCandidate)
        let misleading = root.appendingPathComponent("setup.exe"); try bytes().write(to: misleading)
        XCTAssertEqual(try ExecutableInspector.inspect(misleading).kind, .application)
    }
    func testRouterSelectsConfirmedArchitectureAndPreferredEngine() throws {
        let manager = RuntimeManager(host: host), router = CompatibilityRouter(runtimes: manager)
        var unsupported = try engine("unconfirmed"); unsupported.supportsWindowsX86 = false
        let supported = try engine("supported"), other = try engine("other")
        let info = try ExecutableInspector.inspect(image(bytes(machine: 0x14c, plus: false)))
        XCTAssertEqual(try router.select(info: info, installed: [unsupported, supported], preferred: unsupported.id).id, supported.id)
        XCTAssertEqual(try router.select(info: info, installed: [other, supported], preferred: supported.id).id, supported.id)
        XCTAssertThrowsError(try router.select(info: info, installed: []))
        XCTAssertThrowsError(try router.select(info: info, installed: [unsupported]))
    }
    func testRouterRefusesARMProprietaryAdaptersAndMissingRosetta() throws {
        let runtime = try engine()
        let arm = try ExecutableInspector.inspect(image(bytes(machine: 0xaa64)))
        XCTAssertThrowsError(try CompatibilityRouter(runtimes: RuntimeManager(host: host)).select(info: arm, installed: [runtime]))
        let info = try ExecutableInspector.inspect(image(bytes()))
        let crossover = try engine("CrossOver wine")
        XCTAssertThrowsError(try CompatibilityRouter(runtimes: RuntimeManager(host: host)).select(info: info, installed: [crossover]))
        let noRosetta = RuntimeManager(host: .init(isMacOS: true, isAppleSilicon: true, rosettaInstalled: false))
        XCTAssertThrowsError(try CompatibilityRouter(runtimes: noRosetta).select(info: info, installed: [runtime]))
    }
    func testDelayedInitializationWaitsForActualStructure() async throws {
        let executor = DelayedBoot(), runtime = try engine()
        let manager = BottleManager(executor: executor, runtimes: RuntimeManager(host: host), readinessAttempts: 30, readinessInterval: .milliseconds(10))
        let bottle = try await manager.create(name: "Delayed", prefix: root.appendingPathComponent("delayed"), runtime: runtime, approved: true, output: { _ in })
        XCTAssertNoThrow(try PrefixPolicy.validateWin64(bottle.prefix))
        let count = await executor.count; XCTAssertEqual(count, 1)
    }
    func testBoundedRepairPreservesDataAndChecksApprovalOwnership() async throws {
        let runtime = try engine(), executor = MockExecutor()
        let manager = BottleManager(executor: executor, runtimes: RuntimeManager(host: host), readinessAttempts: 2, readinessInterval: .milliseconds(1))
        let path = root.appendingPathComponent("partial")
        do { _ = try await manager.create(name: "Partial", prefix: path, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
        let owner = try PrefixPolicy.ownedBottle(at: path, runtimeID: runtime.id)
        let data = path.appendingPathComponent("user-data"); try Data("keep".utf8).write(to: data)
        do { _ = try await manager.repair(owner, runtime: runtime, approved: false, output: { _ in }); XCTFail() } catch { XCTAssertEqual(error as? BridgeError, .approvalRequired) }
        do { _ = try await manager.repair(owner, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "keep")
        let requests = await executor.requests; XCTAssertEqual(requests.count, 2); XCTAssertNil(requests.last?.environment["WINEARCH"])
        var external = owner; external.managed = false
        do { _ = try await manager.repair(external, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
        let after = await executor.requests; XCTAssertEqual(after.count, 2)
    }
    func testRepairVerifiesWin64AndRetainsUserData() async throws {
        let runtime = try engine(), failed = MockExecutor()
        let manager = BottleManager(executor: failed, runtimes: RuntimeManager(host: host), readinessAttempts: 1)
        let prefix = root.appendingPathComponent("repair")
        do { _ = try await manager.create(name: "Repair", prefix: prefix, runtime: runtime, approved: true, output: { _ in }) } catch {}
        let owner = try PrefixPolicy.ownedBottle(at: prefix, runtimeID: runtime.id)
        let good = BottleManager(executor: MockExecutor(initializePrefix: true), runtimes: RuntimeManager(host: host), readinessAttempts: 1)
        _ = try await good.repair(owner, runtime: runtime, approved: true, output: { _ in })
        try Data("WINE REGISTRY Version 2\n#arch=win32\n".utf8).write(to: prefix.appendingPathComponent("system.reg"))
        XCTAssertThrowsError(try PrefixPolicy.validateWin64(prefix))
        do { _ = try await good.repair(owner, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
    }
    func testFailureClassificationUsesEvidenceNotExitThree() {
        XCTAssertEqual(LaunchDiagnosis.classify(result: .init(exitCode: 3)).category, .crash)
        XCTAssertEqual(LaunchDiagnosis.classify(result: .init(exitCode: 3, stderr: "err:module:import_dll Library MSVCP140.dll not found")).category, .dependency)
        XCTAssertEqual(LaunchDiagnosis.classify(result: .init(exitCode: 1, stderr: "None of the requested D3D feature levels is supported")).category, .graphics)
        XCTAssertEqual(LaunchDiagnosis.classify(error: BridgeError.process("Operation not permitted")).category, .permission)
    }
    func testCompleteStreamedLogSurvivesProcessCaptureLimits() throws {
        let log = try RunLog(directory: root.appendingPathComponent("Logs"))
        let large = String(repeating: "abcdefgh", count: 200_000)
        log.append(.init(stream: .stdout, text: large)); log.append(.init(stream: .stderr, text: "tail")); try log.finish()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(text.contains(large)); XCTAssertTrue(text.hasSuffix("tail"))
    }
    func testLegacyLibraryMetadataRoundTripAndQuery() async throws {
        var a = ApplicationEntry(name: "Alpha", executable: root.appendingPathComponent("a.exe"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        for key in ["favorite", "inspection", "launchCount", "lastLog", "isInstaller"] { json.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(ApplicationEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.id, a.id); XCTAssertNil(old.favorite)
        a.favorite = true; a.launchCount = 4; a.lastLaunchedAt = Date()
        let b = ApplicationEntry(name: "Beta", executable: root.appendingPathComponent("b.exe"))
        var snapshot = LibrarySnapshot(); snapshot.applications = [a, b]
        let file = root.appendingPathComponent("library.json"); try await ApplicationLibrary(file: file).save(snapshot)
        let restored = try await ApplicationLibrary(file: file).load(); XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(LibraryQuery.filter(restored.applications, search: "ALP", favoritesOnly: true, sort: .name), [a])
        XCTAssertEqual(LibraryQuery.filter(restored.applications, search: "", favoritesOnly: false, sort: .recent).first?.id, a.id)
    }
    func testInstallerScannerIgnoresLinksAndLetsUserChooseTargets() throws {
        let prefix = root.appendingPathComponent("scan")
        let directory = prefix.appendingPathComponent("drive_c/Program Files/App")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exe = directory.appendingPathComponent("app.exe"); try bytes().write(to: exe)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.exe"), withDestinationURL: image(bytes()))
        let targets = try InstalledApplicationScanner.scan(prefix: prefix)
        XCTAssertEqual(targets.map { $0.executable.resolvingSymlinksInPath() }, [exe.resolvingSymlinksInPath()])
        XCTAssertTrue(try InstalledApplicationScanner.scan(prefix: prefix, excluding: [exe]).isEmpty)
    }
    func testInheritedWineArchitectureCannotLeakIntoLaunchOrRepair() {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
            environment: ["WINEPREFIX": "/safe/environment"], removingInheritedEnvironment: ["WINEPREFIX", "WINEARCH"])
        let merged = request.resolvedEnvironment(inheriting: ["WINEPREFIX": "/wrong", "WINEARCH": "win32", "PROVIDER_SETTING": "keep"])
        XCTAssertEqual(merged["WINEPREFIX"], "/safe/environment"); XCTAssertNil(merged["WINEARCH"])
        XCTAssertEqual(merged["PROVIDER_SETTING"], "keep")
    }

}
