import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A byte snapshot taken before approval, not a publisher authenticity check.
public struct DXVKPackage: Sendable {
    public let source: URL
    public let libraries: [String: Data]
    public var byteCount: Int { libraries.values.reduce(0) { $0 + $1.count } }
    init(source: URL, libraries: [String: Data]) { self.source = source; self.libraries = libraries }
}

public protocol GraphicsInstalling: Sendable {
    func inspect(_ directory: URL) throws -> DXVKPackage
    func install(_ package: DXVKPackage, bottle: Bottle, approved: Bool) async throws -> Bottle
    func restore(_ bottle: Bottle, approved: Bool) async throws -> Bottle
}

/// Manual integration of the macOS DXVK fork's two-DLL layout. Never runs Wine,
/// downloads libraries, edits the registry, or replaces DXGI. Backups stay in the
/// user's prefix. Interrupted transactions remain fail-closed with backups intact.
public struct DXVKInstaller: GraphicsInstalling {
    public static let libraryNames = ["d3d11.dll", "d3d10core.dll"]
    private static let folderName = ".bridge-dxvk"
    private let bottles: any BottleManaging
    public init(bottles: any BottleManaging = BottleManager()) { self.bottles = bottles }
    private struct Record: Codable {
        var bottleID: UUID
        var previousGraphics: GraphicsBackend
        var originals: [String]
        var phase: String
    }
    public func inspect(_ directory: URL) throws -> DXVKPackage {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw BridgeError.invalidExecutable("Select the extracted macOS DXVK x64 directory.")
        }
        let source = directory.resolvingSymlinksInPath().standardizedFileURL
        try Self.requireDirectory(source)
        var libraries: [String: Data] = [:]
        for name in Self.libraryNames {
            let file = source.appendingPathComponent(name)
            let bytes = try Self.readRegular(file)
            try ExecutableValidator.validateX64DLL(bytes)
            libraries[name] = bytes
        }
        return DXVKPackage(source: source, libraries: libraries)
    }
    public static func hasInstallation(_ bottle: Bottle) -> Bool {
        // Include incomplete transactions, so the UI does not silently hide backups.
        let path = bottle.prefix.appendingPathComponent(folderName)
        return (try? FileManager.default.attributesOfItem(atPath: path.path)) != nil
    }
    private static func paths(_ bottle: Bottle) throws -> (system: URL, state: URL) {
        try PrefixPolicy.validateInitialized(bottle.prefix)
        let prefix = try PrefixPolicy.canonical(bottle.prefix)
        var current = prefix
        for part in ["drive_c", "windows", "system32"] {
            current.appendPathComponent(part, isDirectory: true)
            try requireDirectory(current)
        }
        return (current, prefix.appendingPathComponent(folderName, isDirectory: true))
    }
    private static func requireDirectory(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw BridgeError.invalidPrefix("Graphics integration requires real directories, not symlinks: \(url.path)")
        }
    }
    private static func readRegular(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1024 * 1024 else {
            throw BridgeError.invalidExecutable("Graphics files must be regular files of at most 64 MiB: \(url.lastPathComponent)")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024 * 1024 else { throw BridgeError.invalidExecutable("Graphics file exceeds the size limit.") }
        return data
    }
    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw BridgeError.invalidPrefix("Cannot inspect graphics path (errno \(errno)).")
    }
    private static func record(_ bottle: Bottle, state: URL) throws -> Record {
        try requireDirectory(state)
        let file = state.appendingPathComponent("record.json")
        let data = try readRegular(file)
        let value = try JSONDecoder().decode(Record.self, from: data)
        guard value.bottleID == bottle.id, Set(value.originals).isSubset(of: Set(libraryNames)),
              value.originals.count == Set(value.originals).count,
              value.previousGraphics != .dxvkMoltenVK else {
            throw BridgeError.invalidPrefix("DXVK backup does not match this bottle or its expected layout.")
        }
        return value
    }
    private static func write(_ record: Record, state: URL) throws {
        try JSONEncoder().encode(record).write(to: state.appendingPathComponent("record.json"), options: .atomic)
    }
    public static func validateInstallation(_ bottle: Bottle) throws {
        let paths = try paths(bottle)
        let record = try record(bottle, state: paths.state)
        guard record.phase == "installed" else {
            throw BridgeError.invalidPrefix("DXVK transaction was interrupted. Backups remain in .bridge-dxvk; inspect them before manually recovering the bottle.")
        }
        try requireDirectory(paths.state.appendingPathComponent("imported"))
        for name in libraryNames {
            let expected = try readRegular(paths.state.appendingPathComponent("imported/\(name)"))
            try ExecutableValidator.validateX64DLL(expected)
            guard try readRegular(paths.system.appendingPathComponent(name)) == expected else {
                throw BridgeError.invalidPrefix("Installed \(name) changed since import. Bridge will not launch or overwrite it as the recorded DXVK package.")
            }
        }
    }
    public func install(_ package: DXVKPackage, bottle: Bottle, approved: Bool) async throws -> Bottle {
        guard approved else { throw BridgeError.approvalRequired }
        guard Set(package.libraries.keys) == Set(Self.libraryNames), bottle.graphics != .dxvkMoltenVK else {
            throw BridgeError.invalidExecutable("Select the macOS DXVK x64 package; restore an existing import before replacing it.")
        }
        for bytes in package.libraries.values { try ExecutableValidator.validateX64DLL(bytes) }
        try await bottles.acquire(bottle)
        do {
            let updated = try installFiles(package, bottle: bottle)
            await bottles.release(bottle)
            return updated
        } catch { await bottles.release(bottle); throw error }
    }
    private func installFiles(_ package: DXVKPackage, bottle: Bottle) throws -> Bottle {
        let paths = try Self.paths(bottle)
        guard try !Self.exists(paths.state) else { throw BridgeError.invalidPrefix("DXVK backups already exist. Restore or inspect them before importing another package.") }
        let fm = FileManager.default
        // Complete all source/destination checks before creating a journal or changing DLLs.
        var originals: [String] = []
        for name in Self.libraryNames {
            let file = paths.system.appendingPathComponent(name)
            if try Self.exists(file) {
                let type = try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else {
                    throw BridgeError.invalidPrefix("Existing \(name) is not a file or Wine DLL link.")
                }
                originals.append(name)
            }
        }
        try fm.createDirectory(at: paths.state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var record = Record(bottleID: bottle.id, previousGraphics: bottle.graphics, originals: originals, phase: "preparing")
        try Self.write(record, state: paths.state)
        for part in ["originals", "imported"] {
            try fm.createDirectory(at: paths.state.appendingPathComponent(part), withIntermediateDirectories: false)
        }
        for name in originals {
            try fm.copyItem(at: paths.system.appendingPathComponent(name), to: paths.state.appendingPathComponent("originals/\(name)"))
        }
        for name in Self.libraryNames {
            try package.libraries[name]!.write(to: paths.state.appendingPathComponent("imported/\(name)"), options: .atomic)
        }
        record.phase = "installing"; try Self.write(record, state: paths.state)
        var changed: [String] = []
        do {
            for name in Self.libraryNames {
                try Self.replace(from: paths.state.appendingPathComponent("imported/\(name)"), to: paths.system.appendingPathComponent(name))
                changed.append(name)
            }
            record.phase = "installed"; try Self.write(record, state: paths.state)
        } catch {
            // In-process failures roll back, but interrupted/failed recovery retains
            // the journal. Never hide an uncertain DLL state or discard its backups.
            do {
                for name in changed.reversed() { try Self.restoreFile(name, record: record, paths: paths) }
                try fm.removeItem(at: paths.state)
            } catch { throw BridgeError.invalidPrefix("DXVK import/recovery failed; backups retained in \(paths.state.path).") }
            throw error
        }
        var updated = bottle; updated.graphics = .dxvkMoltenVK
        return updated
    }
    public func restore(_ bottle: Bottle, approved: Bool) async throws -> Bottle {
        guard approved else { throw BridgeError.approvalRequired }
        try await bottles.acquire(bottle)
        do {
            let paths = try Self.paths(bottle)
            var record = try Self.record(bottle, state: paths.state)
            try Self.validateInstallation(bottle)
            try Self.requireDirectory(paths.state.appendingPathComponent("originals"))
            for name in record.originals {
                let backup = paths.state.appendingPathComponent("originals/\(name)")
                guard try Self.exists(backup) else { throw BridgeError.invalidPrefix("Original DLL backup is missing. No files restored.") }
                let type = try FileManager.default.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else { throw BridgeError.invalidPrefix("Invalid original DLL backup.") }
            }
            record.phase = "restoring"; try Self.write(record, state: paths.state)
            for name in Self.libraryNames { try Self.restoreFile(name, record: record, paths: paths) }
            // The whole restoration succeeded before any backups are deleted.
            try FileManager.default.removeItem(at: paths.state)
            var updated = bottle; updated.graphics = record.previousGraphics
            await bottles.release(bottle)
            return updated
        } catch { await bottles.release(bottle); throw error }
    }
    private static func restoreFile(_ name: String, record: Record, paths: (system: URL, state: URL)) throws {
        let destination = paths.system.appendingPathComponent(name)
        if record.originals.contains(name) {
            try replace(from: paths.state.appendingPathComponent("originals/\(name)"), to: destination)
        } else { try FileManager.default.removeItem(at: destination) }
    }
    private static func replace(from source: URL, to destination: URL) throws {
        // Copy preserves original DLL symlinks and attributes; rename atomically
        // replaces the directory entry without following a destination symlink.
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".bridge-dll-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.copyItem(at: source, to: temp)
        guard rename(temp.path, destination.path) == 0 else {
            throw BridgeError.invalidPrefix("Cannot replace graphics DLL (errno \(errno)).")
        }
    }
}
