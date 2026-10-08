import Foundation
import XCTest
@testable import BridgeCore

final class DXVKInstallerTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BridgeDXVKTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func pe(dll: Bool = true, x64: Bool = true) -> Data {
        var bytes = [UInt8](repeating: 0, count: 96)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes[64] = 0x50; bytes[65] = 0x45
        bytes[68] = x64 ? 0x64 : 0x4c; bytes[69] = x64 ? 0x86 : 0x01
        bytes[87] = dll ? 0x20 : 0
        bytes[88] = 0x0b; bytes[89] = 2
        return Data(bytes)
    }
    private func fixture() throws -> (bottle: Bottle, package: URL, system: URL, engine: WineRuntime) {
        let engineFile = root.appendingPathComponent("wine")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1]).write(to: engineFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engineFile.path)
        let engine = WineRuntime(name: "Fake Wine", executable: engineFile, architecture: .x86_64, supportsWindowsX64: true)
        let bottle = Bottle(name: "Fixture", prefix: root.appendingPathComponent("prefix"), runtimeID: engine.id, graphics: .wineD3DVulkan)
        let system = bottle.prefix.appendingPathComponent("drive_c/windows/system32")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try Data().write(to: bottle.prefix.appendingPathComponent("system.reg"))
        let package = root.appendingPathComponent("user-supplied x64")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for name in DXVKInstaller.libraryNames { try pe().write(to: package.appendingPathComponent(name)) }
        try Data("Do not import this DLL".utf8).write(to: package.appendingPathComponent("dxgi.dll"))
        return (bottle, package, system, engine)
    }
    func testInspectRejectsWrongArchitectureNonDLLMissingAndSymlinkedLibraries() throws {
        let f = try fixture(), file = f.package.appendingPathComponent("d3d11.dll")
        let installer = DXVKInstaller()
        try pe(x64: false).write(to: file)
        XCTAssertThrowsError(try installer.inspect(f.package))
        try pe(dll: false).write(to: file)
        XCTAssertThrowsError(try installer.inspect(f.package))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try installer.inspect(f.package))
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.package.appendingPathComponent("d3d10core.dll"))
        XCTAssertThrowsError(try installer.inspect(f.package))
        XCTAssertFalse(DXVKInstaller.hasInstallation(f.bottle))
    }
    func testUnapprovedImportAndRestoreMakeNoChanges() async throws {
        let f = try fixture(), installer = DXVKInstaller()
        let package = try installer.inspect(f.package)
        do { _ = try await installer.install(package, bottle: f.bottle, approved: false); XCTFail("Imported without approval") }
        catch { XCTAssertEqual(error as? BridgeError, .approvalRequired) }
        do { _ = try await installer.restore(f.bottle, approved: false); XCTFail("Restored without approval") }
        catch { XCTAssertEqual(error as? BridgeError, .approvalRequired) }
        XCTAssertFalse(DXVKInstaller.hasInstallation(f.bottle))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.system.path).isEmpty)
    }
    func testImportSnapshotAndRestorePreserveOriginalSymlinkBytesAndDXGI() async throws {
        let f = try fixture(), installer = DXVKInstaller()
        let original = root.appendingPathComponent("original-wine-dll")
        try Data("Wine original".utf8).write(to: original)
        let link = f.system.appendingPathComponent("d3d11.dll")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let other = f.system.appendingPathComponent("d3d10core.dll"), otherBytes = Data("Other original".utf8)
        try otherBytes.write(to: other)
        let dxgi = f.system.appendingPathComponent("dxgi.dll"), dxgiBytes = Data("builtin DXGI".utf8)
        try dxgiBytes.write(to: dxgi)
        let package = try installer.inspect(f.package)
        // Approval is for captured bytes, not a path whose contents can change later.
        try Data("source changed".utf8).write(to: f.package.appendingPathComponent("d3d11.dll"))
        let installed = try await installer.install(package, bottle: f.bottle, approved: true)
        XCTAssertEqual(installed.graphics, .dxvkMoltenVK)
        XCTAssertEqual(try Data(contentsOf: link), package.libraries["d3d11.dll"])
        XCTAssertEqual(try Data(contentsOf: original), Data("Wine original".utf8))
        XCTAssertEqual(try Data(contentsOf: dxgi), dxgiBytes)
        try DXVKInstaller.validateInstallation(installed)
        let restored = try await installer.restore(installed, approved: true)
        XCTAssertEqual(restored.graphics, .wineD3DVulkan)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), original.path)
        XCTAssertEqual(try Data(contentsOf: other), otherBytes)
        XCTAssertEqual(try Data(contentsOf: dxgi), dxgiBytes)
        XCTAssertFalse(DXVKInstaller.hasInstallation(restored))
    }
    func testRestoreRemovesOnlyNewFilesAndRefusesToOverwriteModifiedImport() async throws {
        let f = try fixture(), installer = DXVKInstaller()
        let installed = try await installer.install(installer.inspect(f.package), bottle: f.bottle, approved: true)
        let file = f.system.appendingPathComponent("d3d11.dll")
        try Data("Changed by another application".utf8).write(to: file)
        do { _ = try await installer.restore(installed, approved: true); XCTFail("Overwrote modified DLL") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("Changed by another application".utf8))
        XCTAssertTrue(DXVKInstaller.hasInstallation(installed))
        try pe().write(to: file)
        _ = try await installer.restore(installed, approved: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.system.path).isEmpty)
    }
    func testActiveBottleAndSymlinkedSystemDirectoryBlockImport() async throws {
        let f = try fixture(), manager = BottleManager(), installer = DXVKInstaller(bottles: manager)
        let package = try installer.inspect(f.package)
        try await manager.acquire(f.bottle)
        do { _ = try await installer.install(package, bottle: f.bottle, approved: true); XCTFail("Modified leased prefix") }
        catch { XCTAssertEqual(error as? BridgeError, .busy) }
        await manager.release(f.bottle)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: f.system)
        try FileManager.default.createSymbolicLink(at: f.system, withDestinationURL: outside)
        do { _ = try await installer.install(package, bottle: f.bottle, approved: true); XCTFail("Followed system directory symlink") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertFalse(DXVKInstaller.hasInstallation(f.bottle))
    }
    func testLaunchUsesNativeDirect3DAndBuiltinDXGIAndMissingPackageNeverExecutes() async throws {
        let f = try fixture(), executor = MockExecutor()
        let host = HostCapabilities(isMacOS: true, isAppleSilicon: true, rosettaInstalled: true)
        let runtime = RuntimeManager(executor: executor, host: host)
        let manager = BottleManager(executor: executor, runtimes: runtime)
        let installer = DXVKInstaller(bottles: manager)
        let installed = try await installer.install(installer.inspect(f.package), bottle: f.bottle, approved: true)
        let file = root.appendingPathComponent("Game.exe"); try pe(dll: false).write(to: file)
        let app = ApplicationEntry(name: "Game", executable: file, bottleID: installed.id)
        let launcher = LaunchService(executor: executor, runtimes: runtime, bottles: manager)
        _ = try await launcher.launch(app, bottle: installed, runtime: f.engine, approved: true, output: { _ in })
        let commands = await executor.requests
        XCTAssertEqual(commands.count, 1, "Import must not execute Wine")
        XCTAssertEqual(commands.first?.environment["WINEDLLOVERRIDES"], "d3d11,d3d10core=n;dxgi=b")
        XCTAssertEqual(commands.first?.environment["DXVK_LOG_PATH"], "none")
        XCTAssertNil(commands.first?.environment["WINE_D3D_CONFIG"])
        do { _ = try await launcher.launch(app, bottle: f.bottle, runtime: f.engine, approved: true, output: { _ in }); XCTFail("Launched imported DLLs with a different backend") } catch {}
        _ = try await installer.restore(installed, approved: true)
        do { _ = try await launcher.launch(app, bottle: installed, runtime: f.engine, approved: true, output: { _ in }); XCTFail("Launched missing DXVK") } catch {}
        let after = await executor.requests; XCTAssertEqual(after.count, 1)
    }
    func testBackupIdentityAndInterruptedJournalPreventLaunchAndRestoration() async throws {
        let f = try fixture(), installer = DXVKInstaller()
        let installed = try await installer.install(installer.inspect(f.package), bottle: f.bottle, approved: true)
        var forged = installed; forged.id = UUID()
        XCTAssertThrowsError(try DXVKInstaller.validateInstallation(forged))
        do { _ = try await installer.restore(forged, approved: true); XCTFail("Restored another bottle's backup") } catch {}
        let record = f.bottle.prefix.appendingPathComponent(".bridge-dxvk/record.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        json["phase"] = "installing"
        try JSONSerialization.data(withJSONObject: json).write(to: record)
        XCTAssertThrowsError(try DXVKInstaller.validateInstallation(installed))
        do { _ = try await installer.restore(installed, approved: true); XCTFail("Restored interrupted journal blindly") } catch {}
        XCTAssertTrue(DXVKInstaller.hasInstallation(installed))
        XCTAssertEqual(try Data(contentsOf: f.system.appendingPathComponent("d3d11.dll")), pe())
    }
}
