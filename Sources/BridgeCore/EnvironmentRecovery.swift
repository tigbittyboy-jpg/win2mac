import Foundation

public struct EnvironmentBackup: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let bottle: Bottle
    public let files: [String: String]
    public let configurations: [ApplicationConfiguration]?
}

public protocol EnvironmentRecovering: Sendable {
    func backups(for bottle: Bottle) async throws -> [EnvironmentBackup]
    func backup(_ bottle: Bottle, applications: [ApplicationEntry], approved: Bool) async throws -> EnvironmentBackup
    func restore(_ backup: EnvironmentBackup, bottle: Bottle, approved: Bool) async throws -> Bottle
    func duplicate(_ bottle: Bottle, destination: URL, name: String, approved: Bool) async throws -> Bottle
}

public extension EnvironmentRecovering {
    func backup(_ bottle: Bottle, approved: Bool) async throws -> EnvironmentBackup {
        try await backup(bottle, applications: [], approved: approved)
    }
}

/// Offline snapshots: all Wine clients must be closed by the user. In-memory
/// leases cannot establish that externally launched Wine processes are idle.
public actor EnvironmentRecovery: EnvironmentRecovering {
    private let directory: URL
    private let bottles: any BottleManaging
    private static let journal = ".win2mac-restore-pending.json"
    public init(directory: URL = BridgePaths.dataDirectory.appendingPathComponent("Backups"),
                bottles: any BottleManaging = BottleManager()) {
        self.directory = directory; self.bottles = bottles
    }
    public static func validateNoInterruptedRestore(_ prefix: URL) throws {
        if FileManager.default.fileExists(atPath: prefix.appendingPathComponent(journal).path) {
            throw BridgeError.invalidPrefix("An environment restore was interrupted. Do not launch or repair it. Inspect its recovery journal and retained previous environment before recovery.")
        }
    }
    private func owned(_ bottle: Bottle) throws {
        guard bottle.managed, try PrefixPolicy.ownedBottle(at: bottle.prefix, runtimeID: bottle.runtimeID).id == bottle.id else {
            throw BridgeError.invalidPrefix("Environment recovery requires matching ownership; external environments are read-only associations.")
        }
        try Self.validateNoInterruptedRestore(bottle.prefix)
    }
    private func artifact(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func realDirectory(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw BridgeError.invalidPrefix("Backup/recovery directories must not be symbolic links.")
        }
    }
    private func manifest(_ root: URL) throws -> [String: String] {
        try realDirectory(root)
        var result: [String: String] = [:]
        var enumerationFailure: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [], options: [], errorHandler: { _, error in
            enumerationFailure = error; return false
        }) else { throw BridgeError.persistence("Cannot enumerate environment backup.") }
        for case let url as URL in iterator {
            guard result.count < 200_000 else { throw BridgeError.persistence("Environment exceeds backup file-count limit.") }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            switch type {
            case .typeSymbolicLink:
                iterator.skipDescendants()
                result[relative] = "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            case .typeDirectory: result[relative] = "directory"
            case .typeRegular: result[relative] = "sha256:" + (try FileIntegrity.sha256(url))
            default: throw BridgeError.invalidPrefix("Environment contains unsupported special files. Close Wine before taking an offline backup.")
            }
        }
        if let enumerationFailure { throw enumerationFailure }
        return result
    }
    public func backups(for bottle: Bottle) throws -> [EnvironmentBackup] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try realDirectory(directory)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: []).compactMap { child in
            guard UUID(uuidString: child.lastPathComponent) != nil else { return nil }
            try realDirectory(child)
            let record = child.appendingPathComponent("backup.json")
            guard FileManager.default.fileExists(atPath: record.path) else { return nil } // Incomplete copies remain inspectable.
            let value = try JSONDecoder().decode(EnvironmentBackup.self, from: Data(contentsOf: record))
            guard value.id.uuidString == child.lastPathComponent else { throw BridgeError.persistence("Backup identity mismatch.") }
            return value.bottle.id == bottle.id ? value : nil
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func backup(_ bottle: Bottle, applications: [ApplicationEntry] = [], approved: Bool) async throws -> EnvironmentBackup {
        guard approved else { throw BridgeError.approvalRequired }
        try owned(bottle)
        guard applications.allSatisfy({ $0.bottleID == bottle.id }) else {
            throw BridgeError.persistence("Backup configuration contains an unrelated application.")
        }
        for application in applications { try ExecutionEnvironmentPolicy.validate(overrides: application.environment ?? [:]) }
        try await bottles.acquire(bottle)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try realDirectory(directory)
            let root = try PrefixPolicy.canonical(bottle.prefix)
            let backupRoot = directory.resolvingSymlinksInPath().path
            guard backupRoot != root.path, !backupRoot.hasPrefix(root.path + "/") else {
                throw BridgeError.invalidPrefix("Backups must be outside the environment.")
            }
            let before = try manifest(root)
            let id = UUID(), target = artifact(id)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let copy = target.appendingPathComponent("prefix", isDirectory: true)
            try FileManager.default.copyItem(at: root, to: copy)
            guard try manifest(copy) == before, try manifest(root) == before else {
                throw BridgeError.persistence("Environment changed while backing up. Incomplete copy retained; close all Wine clients and retry.")
            }
            let value = EnvironmentBackup(id: id, createdAt: Date(), bottle: bottle, files: before,
                                          configurations: applications.compactMap(ApplicationConfiguration.init))
            try JSONEncoder().encode(value).write(to: target.appendingPathComponent("backup.json"), options: .atomic)
            await bottles.release(bottle); return value
        } catch { await bottles.release(bottle); throw error }
    }
    public func restore(_ backup: EnvironmentBackup, bottle: Bottle, approved: Bool) async throws -> Bottle {
        guard approved else { throw BridgeError.approvalRequired }
        try owned(bottle)
        guard backup.bottle.id == bottle.id, backup.bottle.runtimeID == bottle.runtimeID,
              backup.bottle.prefix.standardizedFileURL.path == bottle.prefix.standardizedFileURL.path else {
            throw BridgeError.invalidPrefix("Backup belongs to a different environment or engine; no files restored.")
        }
        for settings in backup.configurations ?? [] {
            guard settings.bottleID == bottle.id else { throw BridgeError.persistence("Backup contains unrelated application settings.") }
            try ExecutionEnvironmentPolicy.validate(overrides: settings.environment ?? [:])
        }
        try realDirectory(directory); try realDirectory(artifact(backup.id))
        let saved = try JSONDecoder().decode(EnvironmentBackup.self, from: Data(contentsOf: artifact(backup.id).appendingPathComponent("backup.json")))
        let source = artifact(backup.id).appendingPathComponent("prefix", isDirectory: true)
        guard saved == backup, try manifest(source) == backup.files else {
            throw BridgeError.persistence("Backup contents or identity changed. Restore refused.")
        }
        try await bottles.acquire(bottle)
        do {
            let path = try PrefixPolicy.canonical(bottle.prefix)
            let parent = path.deletingLastPathComponent()
            let staged = parent.appendingPathComponent(".win2mac-restore-\(UUID())", isDirectory: true)
            let previous = parent.appendingPathComponent("\(path.lastPathComponent)-retained-\(UUID())", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: staged)
            guard try manifest(staged) == backup.files else { throw BridgeError.persistence("Staged restore does not match backup.") }
            let journal = try JSONEncoder().encode(["previous": previous.path, "staged": staged.path, "backup": backup.id.uuidString])
            // Both versions carry the journal until the transaction is complete.
            try journal.write(to: staged.appendingPathComponent(Self.journal), options: .atomic)
            try journal.write(to: path.appendingPathComponent(Self.journal), options: .atomic)
            try FileManager.default.moveItem(at: path, to: previous)
            do { try FileManager.default.moveItem(at: staged, to: path) }
            catch {
                try FileManager.default.moveItem(at: previous, to: path)
                try FileManager.default.removeItem(at: path.appendingPathComponent(Self.journal))
                throw error
            }
            try FileManager.default.removeItem(at: path.appendingPathComponent(Self.journal))
            // Previous data is deliberately retained, never recursively deleted.
            await bottles.release(bottle); return backup.bottle
        } catch { await bottles.release(bottle); throw error }
    }
    public func duplicate(_ bottle: Bottle, destination: URL, name: String, approved: Bool) async throws -> Bottle {
        guard approved else { throw BridgeError.approvalRequired }
        try owned(bottle)
        guard !DXVKInstaller.hasInstallation(bottle) else {
            throw BridgeError.unsupported("Restore imported DXVK before duplication; installation records are tied to the original environment identity.")
        }
        let source = try PrefixPolicy.canonical(bottle.prefix), target = try PrefixPolicy.canonical(destination)
        guard !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/"),
              !FileManager.default.fileExists(atPath: target.path) else {
            throw BridgeError.invalidPrefix("Duplicate needs a new, separate environment directory.")
        }
        try await bottles.acquire(bottle)
        do {
            let before = try manifest(source)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: source, to: target)
            guard try manifest(target) == before, try manifest(source) == before else {
                throw BridgeError.persistence("Source changed during duplication. Copy retained, not registered.")
            }
            var copy = bottle; copy.id = UUID(); copy.name = name; copy.prefix = target
            try JSONEncoder().encode(copy).write(to: target.appendingPathComponent(".bridge-bottle.json"), options: .atomic)
            try DependencyManager.rebindCopiedRecords(prefix: target, from: bottle.id, to: copy.id)
            try SteamManager.rebindCopiedRecord(prefix: target, from: bottle.id, to: copy.id)
            await bottles.release(bottle); return copy
        } catch { await bottles.release(bottle); throw error }
    }
}
