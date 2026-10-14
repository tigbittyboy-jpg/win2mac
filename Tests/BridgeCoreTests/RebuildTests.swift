import Foundation
import XCTest
@testable import BridgeCore

private actor DependencyTestExecutor: ProcessExecuting {
    var requests: [ProcessRequest] = []
    let result: ProcessResult
    let createEvidence: Bool
    init(result: ProcessResult = .init(exitCode: 0), createEvidence: Bool = true) { self.result = result; self.createEvidence = createEvidence }
    func run(_ request: ProcessRequest, output: @escaping OutputHandler) throws -> ProcessResult {
        requests.append(request)
        if createEvidence, let path = request.environment["WINEPREFIX"] {
            for name in ["vcruntime140.dll", "msvcp140.dll"] {
                let file = URL(fileURLWithPath: path).appendingPathComponent("drive_c/windows/system32/" + name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                var bytes = [UInt8](repeating: 0, count: 512)
                bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64; bytes[64] = 0x50; bytes[65] = 0x45
                bytes[68] = 0x64; bytes[69] = 0x86; bytes[70] = 1; bytes[84] = 240; bytes[86] = 2; bytes[149] = 2; bytes[87] = 0x20; bytes[88] = 0x0b; bytes[89] = 2
                try Data(bytes).write(to: file)
            }
        }
        return result
    }
}

final class RebuildTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Win2MacRebuild-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var host: HostCapabilities { .init(isMacOS: true, isAppleSilicon: true, rosettaInstalled: true) }
    private func exe(_ name: String = "Game.exe", x86: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64; bytes[64] = 0x50; bytes[65] = 0x45
        bytes[68] = x86 ? 0x4c : 0x64; bytes[69] = x86 ? 1 : 0x86
        bytes[70] = 1; bytes[84] = 240; bytes[86] = 2; bytes[88] = 0x0b; bytes[89] = x86 ? 1 : 2; bytes[149] = 2
        try Data(bytes).write(to: url); return url
    }
    private func engine() throws -> WineRuntime {
        let path = root.appendingPathComponent("wine")
        try Data([0xcf,0xfa,0xed,0xfe,7,0,0,1]).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return WineRuntime(name: "Wine", executable: path, architecture: .x86_64, supportsWindowsX64: true, supportsWindowsX86: true)
    }
    private func bottle(_ runtime: WineRuntime, name: String = "Environment") throws -> Bottle {
        let prefix = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try Data("WINE REGISTRY Version 2\n#arch=win64\n".utf8).write(to: prefix.appendingPathComponent("system.reg"))
        let value = Bottle(name: name, prefix: prefix, runtimeID: runtime.id, managed: true)
        try JSONEncoder().encode(value).write(to: prefix.appendingPathComponent(".bridge-bottle.json"))
        return value
    }
    private func text(_ value: String, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file)
    }
    private func steam(_ bottle: Bottle) throws -> URL {
        try exe(bottle.prefix.lastPathComponent + "/drive_c/Program Files (x86)/Steam/steam.exe", x86: true)
    }

    func testSHA256KnownVectorsAndStreamingBoundaries() throws {
        XCTAssertEqual(FileIntegrity.sha256(data: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(FileIntegrity.sha256(data: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let data = Data(repeating: 97, count: 1_000_000), file = root.appendingPathComponent("large")
        try data.write(to: file)
        XCTAssertEqual(try FileIntegrity.sha256(file), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
    func testRuntimeIdentityDetectsInPlaceUpdateWithoutMutatingOldMetadata() throws {
        let old = try RuntimeIntegrity.record(engine())
        try RuntimeIntegrity.validate(old)
        try Data("changed".utf8).write(to: old.executable)
        XCTAssertThrowsError(try RuntimeIntegrity.validate(old))
        XCTAssertThrowsError(try RuntimeManager(host: host).validate(old, forLaunch: true))
        XCTAssertNotEqual(old.identity?.sha256, try FileIntegrity.sha256(old.executable))
    }
    func testLegacyLibraryCanLoadWithoutNewMetadataAndPreservesNewRecords() async throws {
        let runtime = try engine(), env = try bottle(runtime)
        var app = ApplicationEntry(name: "Game", executable: try exe(), bottleID: env.id)
        app.graphicsOverride = .wineD3DVulkan
        app.compatibilityRecords = [CompatibilityRecord(applicationName: "Game", executableSHA256: "bytes", architecture: .x64,
            runtime: runtime, graphics: .wineD3DVulkan, os: "Test host", launch: .passed)]
        var snapshot = LibrarySnapshot(); snapshot.applications = [app]; snapshot.bottles = [env]; snapshot.runtimes = [runtime]
        let store = ApplicationLibrary(file: root.appendingPathComponent("library.json"))
        try await store.save(snapshot)
        let loaded = try await store.load(); XCTAssertEqual(loaded, snapshot)
        XCTAssertNil(loaded.runtimes[0].identity); XCTAssertEqual(loaded.applications[0].compatibilityRecords?[0].status, .launchSuccessful)
    }
    func testPerGameGraphicsDoNotAlterSharedBottleAndInheritedGraphicsAreRemoved() async throws {
        let runtime = try engine(), env = try bottle(runtime), executor = MockExecutor()
        let bottles = BottleManager(runtimes: RuntimeManager(host: host))
        let service = LaunchService(executor: executor, runtimes: RuntimeManager(host: host), bottles: bottles)
        var a = ApplicationEntry(name: "A", executable: try exe(), bottleID: env.id); a.graphicsOverride = .wineD3DVulkan
        let b = ApplicationEntry(name: "B", executable: a.executable, bottleID: env.id)
        _ = try await service.launch(a, bottle: env, runtime: runtime, approved: true, output: { _ in })
        _ = try await service.launch(b, bottle: env, runtime: runtime, approved: true, output: { _ in })
        let requests = await executor.requests
        XCTAssertEqual(requests[0].environment["WINE_D3D_CONFIG"], "renderer=vulkan")
        let clean = requests[1].resolvedEnvironment(inheriting: ["WINEDLLOVERRIDES": "bad=n", "WINE_D3D_CONFIG": "renderer=vulkan", "DYLD_LIBRARY_PATH": "/bad", "PROVIDER_CONFIG": "retain"])
        XCTAssertNil(clean["WINEDLLOVERRIDES"]); XCTAssertNil(clean["WINE_D3D_CONFIG"]); XCTAssertNil(clean["DYLD_LIBRARY_PATH"])
        XCTAssertEqual(clean["PROVIDER_CONFIG"], "retain"); XCTAssertEqual(env.graphics, .runtimeDefault)
    }
    func testNativeDLLConflictsAndReservedOverridesFailBeforeExecution() async throws {
        let runtime = try engine(); var env = try bottle(runtime)
        var app = ApplicationEntry(name: "Game", executable: try exe(), bottleID: env.id)
        app.graphicsOverride = .dxvkMoltenVK
        XCTAssertThrowsError(try ExecutionEnvironmentPolicy.environment(application: app, bottle: env))
        env.graphics = .dxvkMoltenVK; app.graphicsOverride = .runtimeDefault
        XCTAssertThrowsError(try ExecutionEnvironmentPolicy.environment(application: app, bottle: env))
        app.environment = ["WINEDLLOVERRIDES": "anything"]
        XCTAssertThrowsError(try ExecutionEnvironmentPolicy.validate(overrides: app.environment!))
        let executor = MockExecutor()
        let service = LaunchService(executor: executor, runtimes: RuntimeManager(host: host))
        do { _ = try await service.launch(app, bottle: env, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
        let commands = await executor.requests; XCTAssertTrue(commands.isEmpty)
    }
    func testBackupRestoreRetainsCurrentSavesAndVerifiesSnapshot() async throws {
        let runtime = try engine(), env = try bottle(runtime)
        let save = env.prefix.appendingPathComponent("drive_c/save.dat")
        try text("original save", save)
        let recovery = EnvironmentRecovery(directory: root.appendingPathComponent("Backups"))
        let backup = try await recovery.backup(env, approved: true)
        try text("newer save", save)
        let restored = try await recovery.restore(backup, bottle: env, approved: true)
        XCTAssertEqual(restored.id, env.id)
        XCTAssertEqual(try String(contentsOf: save, encoding: .utf8), "original save")
        let retained = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: []).first { $0.lastPathComponent.hasPrefix("Environment-retained-") })
        XCTAssertEqual(try String(contentsOf: retained.appendingPathComponent("drive_c/save.dat"), encoding: .utf8), "newer save")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.prefix.appendingPathComponent(".win2mac-restore-pending.json").path))
        let listed = try await recovery.backups(for: env); XCTAssertEqual(listed, [backup])
    }
    func testBackupApprovalOwnershipTamperingAndOverlapAreRefused() async throws {
        let runtime = try engine(), env = try bottle(runtime)
        let directory = root.appendingPathComponent("Backups"), recovery = EnvironmentRecovery(directory: directory)
        do { _ = try await recovery.backup(env, approved: false); XCTFail() } catch { XCTAssertEqual(error as? BridgeError, .approvalRequired) }
        let backup = try await recovery.backup(env, approved: true)
        try text("tampered", directory.appendingPathComponent(backup.id.uuidString + "/prefix/system.reg"))
        do { _ = try await recovery.restore(backup, bottle: env, approved: true); XCTFail() } catch {}
        XCTAssertTrue(try String(contentsOf: env.prefix.appendingPathComponent("system.reg"), encoding: .utf8).contains("win64"))
        do { _ = try await recovery.duplicate(env, destination: env.prefix.appendingPathComponent("nested"), name: "Bad", approved: true); XCTFail() } catch {}
        let recursive = EnvironmentRecovery(directory: env.prefix)
        do { _ = try await recursive.backup(env, approved: true); XCTFail() } catch {}
        var foreign = env; foreign.managed = false
        do { _ = try await recovery.backup(foreign, approved: true); XCTFail() } catch {}
    }
    func testDuplicatePreservesSymlinksWithoutFollowingHostMappings() async throws {
        let env = try bottle(engine())
        let outside = root.appendingPathComponent("private-host"); try text("private", outside)
        let link = env.prefix.appendingPathComponent("drive_c/host-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let recovery = EnvironmentRecovery(directory: root.appendingPathComponent("Backups"))
        let duplicate = try await recovery.duplicate(env, destination: root.appendingPathComponent("Copy"), name: "Copy", approved: true)
        XCTAssertNotEqual(duplicate.id, env.id)
        XCTAssertEqual(try PrefixPolicy.ownedBottle(at: duplicate.prefix, runtimeID: env.runtimeID).id, duplicate.id)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: duplicate.prefix.appendingPathComponent("drive_c/host-link").path), outside.path)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
    }
    func testInterruptedRestoreBlocksLaunchLeaseAndRepairWithoutExecution() async throws {
        let runtime = try engine(), env = try bottle(runtime), executor = MockExecutor()
        try text("pending", env.prefix.appendingPathComponent(".win2mac-restore-pending.json"))
        let manager = BottleManager(executor: executor, runtimes: RuntimeManager(host: host))
        do { try await manager.acquire(env); XCTFail() } catch {}
        do { _ = try await manager.repair(env, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
        let commands = await executor.requests; XCTAssertTrue(commands.isEmpty)
    }
    func testBackupCannotRunWhileBottleIsLeased() async throws {
        let env = try bottle(engine()), manager = BottleManager()
        try await manager.acquire(env)
        let recovery = EnvironmentRecovery(directory: root.appendingPathComponent("Backups"), bottles: manager)
        do { _ = try await recovery.backup(env, approved: true); XCTFail() } catch { XCTAssertEqual(error as? BridgeError, .busy) }
        await manager.release(env)
        _ = try await recovery.backup(env, approved: true)
    }
    func testDependencyInstallApprovalEvidenceAndIdempotence() async throws {
        let runtime = try engine(), env = try bottle(runtime), executor = DependencyTestExecutor()
        let manager = DependencyManager(executor: executor, runtimes: RuntimeManager(host: host), directory: root.appendingPathComponent("Installers"))
        let installer = try await manager.inspect(installer: exe("VC.exe"), component: .visualC2015To2022, version: "14.test")
        do { _ = try await manager.install(installer, bottle: env, runtime: runtime, approved: false, output: { _ in }); XCTFail() } catch { XCTAssertEqual(error as? BridgeError, .approvalRequired) }
        let first = try await manager.install(installer, bottle: env, runtime: runtime, approved: true, output: { _ in })
        XCTAssertEqual(first.state, .filePresenceVerified)
        let second = try await manager.install(installer, bottle: env, runtime: runtime, approved: true, output: { _ in })
        XCTAssertEqual(second.id, first.id)
        let commands = await executor.requests; XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].arguments, [installer.capturedFile.path, "/install", "/passive", "/norestart"])
        XCTAssertEqual(commands[0].environment["WINEPREFIX"], env.prefix.path)
    }
    func testExitZeroWithoutDependencyEvidenceIsUnverifiedAndRetryRequiresReview() async throws {
        let runtime = try engine(), env = try bottle(runtime), executor = DependencyTestExecutor(createEvidence: false)
        let manager = DependencyManager(executor: executor, runtimes: RuntimeManager(host: host), directory: root.appendingPathComponent("Installers"))
        let installer = try await manager.inspect(installer: exe("VC.exe"), component: .visualC2015To2022, version: "14.test")
        let result = try await manager.install(installer, bottle: env, runtime: runtime, approved: true, output: { _ in })
        XCTAssertEqual(result.state, .outcomeUnverified)
        do { _ = try await manager.install(installer, bottle: env, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
        _ = try await manager.install(installer, bottle: env, runtime: runtime, approved: true, retryUncertain: true, output: { _ in })
        let commands = await executor.requests; XCTAssertEqual(commands.count, 2)
    }
    func testFailedDependencyInstallerRecordsFailureAndChangedApprovalBytesBlockExecution() async throws {
        let runtime = try engine(), env = try bottle(runtime), executor = DependencyTestExecutor(result: .init(exitCode: 1603))
        let manager = DependencyManager(executor: executor, runtimes: RuntimeManager(host: host), directory: root.appendingPathComponent("Installers"))
        let installer = try await manager.inspect(installer: exe("VC.exe"), component: .visualC2015To2022, version: "14.test")
        let result = try await manager.install(installer, bottle: env, runtime: runtime, approved: true, output: { _ in })
        XCTAssertEqual(result.state, .failed); XCTAssertEqual(result.exitCode, 1603)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installer.capturedFile.path)
        try Data("changed".utf8).write(to: installer.capturedFile)
        do { _ = try await manager.install(installer, bottle: env, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
        let commands = await executor.requests; XCTAssertEqual(commands.count, 1)
    }
    func testDirectXCaptureRequiresAndBindsAdjacentOfficialPayloads() async throws {
        let manager = DependencyManager(directory: root.appendingPathComponent("Installers"))
        let setup = try exe("DirectX/DXSETUP.exe")
        do { _ = try await manager.inspect(installer: setup, component: .directXJune2010, version: "June 2010"); XCTFail() } catch {}
        for name in ["dsetup.dll", "dsetup32.dll", "Jun2010.cab"] { try text("payload", setup.deletingLastPathComponent().appendingPathComponent(name)) }
        let capture = try await manager.inspect(installer: setup, component: .directXJune2010, version: "June 2010")
        XCTAssertEqual(capture.assets.count, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.capturedFile.deletingLastPathComponent().appendingPathComponent("Jun2010.cab").path))
    }
    func testValveParserCommentsEscapesMalformedAndDuplicateKeys() throws {
        let parsed = try ValveKeyValues.parse("// comment\n\"Root\" { \"path\" \"C:\\\\Games\" \"name\" \"A \\\"game\\\"\" }")
        XCTAssertEqual(parsed["root"]?.object?["path"]?.text, "C:\\Games")
        XCTAssertEqual(parsed["root"]?.object?["name"]?.text, "A \"game\"")
        for text in ["\"x\" {", "\"x\" \"unterminated", "x 1 X 2", "}"] { XCTAssertThrowsError(try ValveKeyValues.parse(text)) }
    }
    func testSteamScansInstalledGamesAndRejectsUnsafeOrIncompleteManifests() async throws {
        let env = try bottle(engine()), client = try steam(env)
        let apps = client.deletingLastPathComponent().appendingPathComponent("steamapps")
        try text("\"AppState\" { \"appid\" \"10\" \"name\" \"Test Game\" \"installdir\" \"Test Game\" \"StateFlags\" \"4\" }", apps.appendingPathComponent("appmanifest_10.acf"))
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/Test Game"), withIntermediateDirectories: true)
        try text("\"AppState\" { \"appid\" \"11\" \"name\" \"Bad\" \"installdir\" \"../escape\" \"StateFlags\" \"4\" }", apps.appendingPathComponent("appmanifest_11.acf"))
        try text("\"libraryfolders\" { \"0\" { \"path\" \"Z:\\\\host-games\" } }", apps.appendingPathComponent("libraryfolders.vdf"))
        let scan = try await SteamManager().scan(env)
        XCTAssertEqual(scan.games.map(\.appID), ["10"]); XCTAssertEqual(scan.client, client)
        XCTAssertEqual(scan.warnings.count, 2)
    }
    func testSteamHostSymlinkManifestIsNotFollowed() async throws {
        let env = try bottle(engine()), client = try steam(env)
        let apps = client.deletingLastPathComponent().appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("private.acf"); try text("private", outside)
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("appmanifest_10.acf"), withDestinationURL: outside)
        let result = try await SteamManager().scan(env)
        XCTAssertTrue(result.games.isEmpty); XCTAssertEqual(result.warnings.count, 1)
    }
    func testSteamLaunchUsesClientAppIDAndExactArgumentArray() async throws {
        let runtime = try engine(), env = try bottle(runtime), client = try steam(env), executor = MockExecutor()
        var app = ApplicationEntry(name: "Steam Game", executable: client, bottleID: env.id, arguments: ["--name", "space ; $(unsafe)"])
        app.steamAppID = "10"; app.steamClient = client
        let service = LaunchService(executor: executor, runtimes: RuntimeManager(host: host))
        _ = try await service.launch(app, bottle: env, runtime: runtime, approved: true, output: { _ in })
        let commands = await executor.requests
        XCTAssertEqual(commands[0].arguments, [client.path, "-applaunch", "10", "--name", "space ; $(unsafe)"])
        app.steamAppID = "10;rm"
        do { _ = try await service.launch(app, bottle: env, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
        let after = await executor.requests; XCTAssertEqual(after.count, 1)
    }
    func testSteamInstallerApprovalAndExitZeroWithoutClientDoNotClaimInstallation() async throws {
        let runtime = try engine(), env = try bottle(runtime), executor = MockExecutor()
        let launcher = LaunchService(executor: executor, runtimes: RuntimeManager(host: host))
        let manager = SteamManager(launcher: launcher, directory: root.appendingPathComponent("Installers"))
        let installer = try await manager.inspectInstaller(exe("SteamSetup.exe"))
        do { _ = try await manager.install(installer, bottle: env, runtime: runtime, approved: false, output: { _ in }); XCTFail() } catch { XCTAssertEqual(error as? BridgeError, .approvalRequired) }
        do { _ = try await manager.install(installer, bottle: env, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
        let commands = await executor.requests; XCTAssertEqual(commands.count, 1)
    }
    func testDiagnosticConfidenceDoesNotTurnExitThreeOrIncidentalMentionsIntoCauses() {
        let unknown = LaunchDiagnosis.classify(result: .init(exitCode: 3, stderr: "Steam, DRM, anti-cheat and graphics modules loaded"))
        XCTAssertEqual(unknown.category, .crash); XCTAssertEqual(unknown.confidence, .unknown)
        let login = LaunchDiagnosis.classify(result: .init(exitCode: 1, stderr: "Steam authentication failed"))
        XCTAssertEqual(login.category, .steamAuthentication); XCTAssertEqual(login.confidence, .probable)
        XCTAssertFalse(login.evidence.isEmpty)
        let protection = LaunchDiagnosis.classify(result: .init(exitCode: 1, stderr: "Unsupported anti-cheat"))
        XCTAssertEqual(protection.category, .drmAntiCheat)
    }
    func testCompatibilityMatrixRequiresObservedSubsystemResults() throws {
        let runtime = try engine()
        func record(launch: VerificationOutcome = .passed, rendering: VerificationOutcome = .notTested,
                    input: VerificationOutcome = .notTested, audio: VerificationOutcome = .notTested,
                    stability: VerificationOutcome = .notTested) -> CompatibilityRecord {
            .init(applicationName: "Test", executableSHA256: "bytes", architecture: .x64, runtime: runtime,
                  graphics: .runtimeDefault, os: "Test", launch: launch, rendering: rendering, input: input, audio: audio, stability: stability)
        }
        XCTAssertEqual(record(launch: .notTested).status, .notTested)
        XCTAssertEqual(record(launch: .failed).status, .launchFailed)
        XCTAssertEqual(record().status, .launchSuccessful)
        XCTAssertEqual(record(rendering: .failed).status, .partiallyFunctional)
        XCTAssertEqual(record(rendering: .passed, input: .passed, stability: .passed).status, .playable)
        XCTAssertEqual(record(rendering: .passed, input: .passed, audio: .passed, stability: .passed).status, .fullyFunctional)
    }
    func testGraphicsRecommendationsOnlyReuseMatchingObservedConfiguration() throws {
        let runtime = try RuntimeIntegrity.record(engine()), env = try bottle(runtime)
        var app = ApplicationEntry(name: "Game", executable: try exe(), bottleID: env.id)
        let known = CompatibilityRecord(applicationName: app.name, executableSHA256: "bytes", architecture: .x64,
            runtime: runtime, graphics: .wineD3DVulkan, os: ProcessInfo.processInfo.operatingSystemVersionString,
            launch: .passed, rendering: .passed, input: .passed, audio: .passed, stability: .passed)
        app.compatibilityRecords = [known]
        XCTAssertEqual(GraphicsRecommender.recommend(application: app, bottle: env, runtime: runtime, executableSHA256: "bytes").evidenceRecordID, known.id)
        XCTAssertNil(GraphicsRecommender.recommend(application: app, bottle: env, runtime: runtime, executableSHA256: "changed").evidenceRecordID)
        XCTAssertEqual(GraphicsRecommender.recommend(application: app, bottle: env, runtime: runtime, executableSHA256: "changed").backend, .runtimeDefault)
        app.steamAppID = "10"
        XCTAssertNil(GraphicsRecommender.recommend(application: app, bottle: env, runtime: runtime, executableSHA256: "bytes").evidenceRecordID)
    }
    func testInterruptedLaunchRecoveryPreservesHistoryAndNeverMarksPlayable() throws {
        let runtime = try engine(), env = try bottle(runtime)
        var app = ApplicationEntry(name: "Game", executable: try exe(), bottleID: env.id)
        let pending = LaunchHistoryRecord(runtime: runtime, bottle: env, graphics: .runtimeDefault, log: root.appendingPathComponent("run.log"))
        app.launchHistory = [pending]
        var snapshot = LibrarySnapshot(); snapshot.applications = [app]
        let recovered = LaunchRecovery.markInterrupted(snapshot)
        XCTAssertEqual(recovered.applications[0].launchHistory?[0].state, .interrupted)
        XCTAssertEqual(recovered.applications[0].launchHistory?[0].id, pending.id)
        XCTAssertNil(recovered.applications[0].compatibilityRecords)
        XCTAssertEqual(LaunchRecovery.markInterrupted(recovered), recovered)
        XCTAssertEqual(snapshot.applications[0].launchHistory?[0].state, .pending)
    }
    func testConfigurationCheckpointRestoresOnlySettingsAndClearsConsent() throws {
        let runtime = try engine(), env = try bottle(runtime)
        var app = ApplicationEntry(name: "Game", executable: try exe(), bottleID: env.id, arguments: ["original"])
        app.environment = ["LANG": "en_US.UTF-8"]; app.graphicsOverride = .wineD3DVulkan
        let checkpoint = try XCTUnwrap(ApplicationConfiguration(app))
        app.arguments = ["changed"]; app.name = "Renamed"; app.launchCount = 12; app.executionConsent = "old approval"
        let restored = try checkpoint.restoring(app)
        XCTAssertEqual(restored.arguments, ["original"]); XCTAssertEqual(restored.name, "Renamed")
        XCTAssertEqual(restored.launchCount, 12); XCTAssertNil(restored.executionConsent)
        app.bottleID = UUID(); XCTAssertThrowsError(try checkpoint.restoring(app))
    }
    func testEnvironmentBackupIncludesAssociatedConfigurationOnly() async throws {
        let runtime = try engine(), env = try bottle(runtime)
        let app = ApplicationEntry(name: "Game", executable: try exe(), bottleID: env.id, arguments: ["saved"])
        let recovery = EnvironmentRecovery(directory: root.appendingPathComponent("Backups"))
        let backup = try await recovery.backup(env, applications: [app], approved: true)
        XCTAssertEqual(backup.configurations?.first?.arguments, ["saved"])
        let foreign = ApplicationEntry(name: "Foreign", executable: app.executable, bottleID: UUID())
        do { _ = try await recovery.backup(env, applications: [foreign], approved: true); XCTFail() } catch {}
    }
    func testWindowsVersionRequestRequiresApprovalAssociationAndReleasesLease() async throws {
        let runtime = try engine(), env = try bottle(runtime), executor = MockExecutor(), bottles = BottleManager()
        let manager = EnvironmentConfigurationManager(executor: executor, runtimes: RuntimeManager(host: host), bottles: bottles)
        do { _ = try await manager.setWindowsVersion(.windows10, bottle: env, runtime: runtime, approved: false, output: { _ in }); XCTFail() } catch { XCTAssertEqual(error as? BridgeError, .approvalRequired) }
        let configured = try await manager.setWindowsVersion(.windows10, bottle: env, runtime: runtime, approved: true, output: { _ in })
        XCTAssertEqual(configured.requestedWindowsVersion, .windows10)
        let commands = await executor.requests; XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].arguments, ["winecfg", "-v", "win10"])
        try await bottles.acquire(env); await bottles.release(env)
        var foreign = env; foreign.id = UUID()
        do { _ = try await manager.setWindowsVersion(.windows11, bottle: foreign, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
    }
    func testSteamRejectsHostMappedDriveC() async throws {
        let env = try bottle(engine()), outside = root.appendingPathComponent("host-drive")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: env.prefix.appendingPathComponent("drive_c"))
        try FileManager.default.createSymbolicLink(at: env.prefix.appendingPathComponent("drive_c"), withDestinationURL: outside)
        do { _ = try await SteamManager().scan(env); XCTFail() } catch {}
    }
    func testExplicitProviderCannotEnableUnimplementedProprietaryAdapters() throws {
        var runtime = try engine(); runtime.provider = .crossOver
        let capabilities = BackendCapabilities(runtime: runtime)
        XCTAssertEqual(capabilities.family, .crossover); XCTAssertFalse(capabilities.supportsStandardPrefixes)
        XCTAssertTrue(capabilities.architectures.isEmpty)
    }
    func testManagedEnvironmentRemovesOtherDistributionLoaderOverrides() {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], removingInheritedEnvironment: ExecutionEnvironmentPolicy.managedKeys)
        let effective = request.resolvedEnvironment(inheriting: ["WINELOADER": "/other/wine", "WINESERVER": "/other/wineserver", "WINEDLLPATH": "/other/dlls", "LANG": "C"])
        XCTAssertNil(effective["WINELOADER"]); XCTAssertNil(effective["WINESERVER"]); XCTAssertNil(effective["WINEDLLPATH"])
        XCTAssertEqual(effective["LANG"], "C")
    }

    func testBootstrapInstallerArchitectureDoesNotDetermineDependencyPayloadArchitecture() async throws {
        let runtime = try engine(), env = try bottle(runtime), executor = DependencyTestExecutor()
        let manager = DependencyManager(executor: executor, runtimes: RuntimeManager(host: host), directory: root.appendingPathComponent("Installers"))
        let installer = try await manager.inspect(installer: exe("bootstrap.exe", x86: true), component: .visualC2015To2022, version: "14.test", target: .x64)
        XCTAssertEqual(installer.info.machine, .x86); XCTAssertEqual(installer.targetArchitecture, .x64)
        let result = try await manager.install(installer, bottle: env, runtime: runtime, approved: true, output: { _ in })
        XCTAssertEqual(result.targetArchitecture, .x64); XCTAssertEqual(result.state, .filePresenceVerified)
        var incapable = runtime; incapable.supportsWindowsX86 = false
        do { _ = try await manager.install(installer, bottle: env, runtime: incapable, approved: true, output: { _ in }); XCTFail() } catch {}
        let commands = await executor.requests; XCTAssertEqual(commands.count, 1)
    }
    func testInvalidNativeProcessRequestIsRejectedBeforeStartingChild() async throws {
        for request in [
            ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: ["bad\0argument"]),
            ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: .nan),
            ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: ["BAD=NAME": "value"])
        ] {
            let output = OutputRecorder()
            do { _ = try await FoundationProcessExecutor().run(request, output: { output.add($0) }); XCTFail() } catch {}
            XCTAssertTrue(output.text(.stdout).isEmpty)
        }
    }
    func testDependencyEvidenceIsNotCombinedAcrossUnrelatedLogLines() {
        let result = LaunchDiagnosis.classify(result: .init(exitCode: 3, stderr: "import_dll loaded successfully\nUnrelated config not found"))
        XCTAssertEqual(result.category, .crash); XCTAssertEqual(result.confidence, .unknown)
    }
    func testUncertainSteamInstallJournalPreventsBlindRetryAndSurvivesDuplication() async throws {
        let runtime = try engine(), env = try bottle(runtime), executor = MockExecutor()
        let manager = SteamManager(launcher: LaunchService(executor: executor, runtimes: RuntimeManager(host: host)), directory: root.appendingPathComponent("Installers"))
        let installer = try await manager.inspectInstaller(exe("SteamSetup.exe"))
        do { _ = try await manager.install(installer, bottle: env, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
        do { _ = try await manager.install(installer, bottle: env, runtime: runtime, approved: true, output: { _ in }); XCTFail() } catch {}
        let commands = await executor.requests; XCTAssertEqual(commands.count, 1)
        let record = try JSONDecoder().decode(SteamInstallationRecord.self, from: Data(contentsOf: env.prefix.appendingPathComponent(".win2mac-steam-install.json")))
        XCTAssertEqual(record.state, .outcomeUnverified)
        let copy = try await EnvironmentRecovery(directory: root.appendingPathComponent("Backups")).duplicate(env, destination: root.appendingPathComponent("Copy"), name: "Copy", approved: true)
        let copied = try JSONDecoder().decode(SteamInstallationRecord.self, from: Data(contentsOf: copy.prefix.appendingPathComponent(".win2mac-steam-install.json")))
        XCTAssertEqual(copied.bottleID, copy.id); XCTAssertEqual(copied.state, .outcomeUnverified)
    }

    func testDependencyLibraryInspectionRejectsRenamedExecutable() throws {
        let executable = try exe("vcruntime140.dll")
        XCTAssertThrowsError(try ExecutableInspector.inspect(executable, requiringDLL: true))
        var bytes = try Data(contentsOf: executable); bytes[87] = 0x20; try bytes.write(to: executable)
        XCTAssertEqual(try ExecutableInspector.inspect(executable, requiringDLL: true).machine, .x64)
        XCTAssertThrowsError(try ExecutableInspector.inspect(executable))
    }

}
