import Foundation

/// Bounded parser for Valve's text KeyValues files, not JSON or executable code.
public indirect enum ValveValue: Equatable, Sendable {
    case text(String), object([String: ValveValue])
    public var text: String? { if case .text(let value) = self { value } else { nil } }
    public var object: [String: ValveValue]? { if case .object(let value) = self { value } else { nil } }
}
public enum ValveKeyValues {
    public static func parse(_ text: String) throws -> [String: ValveValue] {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw BridgeError.persistence("Steam manifest exceeds size limit.") }
        var parser = Parser(bytes: Array(text.utf8)); return try parser.object(depth: 0, nested: false)
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var entries = 0
        mutating func skip() {
            while index < bytes.count {
                if [9,10,13,32].contains(bytes[index]) { index += 1 }
                else if bytes[index] == 47 && index + 1 < bytes.count && bytes[index + 1] == 47 {
                    while index < bytes.count && bytes[index] != 10 { index += 1 }
                } else { break }
            }
        }
        mutating func token() throws -> String {
            skip(); guard index < bytes.count else { throw BridgeError.persistence("Truncated Steam manifest.") }
            var result: [UInt8] = []
            if bytes[index] == 34 {
                index += 1
                while index < bytes.count {
                    let byte = bytes[index]; index += 1
                    if byte == 34 {
                        guard let text = String(bytes: result, encoding: .utf8) else { throw BridgeError.persistence("Invalid Steam manifest encoding.") }
                        return text
                    }
                    if byte == 92 {
                        guard index < bytes.count else { break }
                        let escaped = bytes[index]; index += 1
                        if escaped == 34 || escaped == 92 { result.append(escaped) }
                        else { result.append(92); result.append(escaped) }
                    } else { result.append(byte) }
                }
                throw BridgeError.persistence("Unterminated Steam manifest string.")
            }
            while index < bytes.count && ![9,10,13,32,123,125].contains(bytes[index]) { result.append(bytes[index]); index += 1 }
            guard !result.isEmpty, let text = String(bytes: result, encoding: .utf8) else { throw BridgeError.persistence("Invalid Steam manifest token.") }
            return text
        }
        mutating func object(depth: Int, nested: Bool) throws -> [String: ValveValue] {
            guard depth <= 16 else { throw BridgeError.persistence("Steam manifest nesting exceeds limit.") }
            var values: [String: ValveValue] = [:]
            while true {
                skip()
                if index == bytes.count {
                    guard !nested else { throw BridgeError.persistence("Truncated Steam manifest object.") }
                    return values
                }
                if bytes[index] == 125 {
                    guard nested else { throw BridgeError.persistence("Unexpected Steam manifest closing brace.") }
                    index += 1; return values
                }
                let key = try token().lowercased()
                guard values[key] == nil else { throw BridgeError.persistence("Duplicate Steam manifest key.") }
                entries += 1; guard entries <= 20_000 else { throw BridgeError.persistence("Steam manifest entry limit exceeded.") }
                skip(); guard index < bytes.count else { throw BridgeError.persistence("Missing Steam manifest value.") }
                if bytes[index] == 123 { index += 1; values[key] = .object(try object(depth: depth + 1, nested: true)) }
                else { values[key] = .text(try token()) }
            }
        }
    }
}

public struct SteamGame: Identifiable, Equatable, Sendable {
    public var id: String { appID }
    public let appID: String
    public let name: String
    public let installation: URL
    public let manifest: URL
    public let artwork: URL?
}
public struct SteamScan: Sendable {
    public let client: URL
    public let games: [SteamGame]
    public let warnings: [String]
}
public struct SteamInstaller: Sendable {
    public let source: URL
    public let capturedFile: URL
    public let sha256: String
}
public struct SteamInstallationRecord: Codable, Equatable, Sendable {
    public let installerSHA256: String
    public let bottleID: UUID
    public let date: Date
    public var state: DependencyInstallState
    public var exitCode: Int32?
    public var details: String
}
public protocol SteamManaging: Sendable {
    func inspectInstaller(_ url: URL) async throws -> SteamInstaller
    func install(_ installer: SteamInstaller, bottle: Bottle, runtime: WineRuntime, approved: Bool,
                 retryUncertain: Bool, output: @escaping OutputHandler) async throws -> SteamScan
    func scan(_ bottle: Bottle) async throws -> SteamScan
}

public actor SteamManager: SteamManaging {
    private let launcher: any LaunchServing
    private let directory: URL
    private var installing: Set<UUID> = []
    public static let installerURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!
    public init(launcher: any LaunchServing = LaunchService(), directory: URL = BridgePaths.dataDirectory.appendingPathComponent("Installers")) {
        self.launcher = launcher; self.directory = directory
    }
    public func inspectInstaller(_ url: URL) throws -> SteamInstaller {
        _ = try ExecutableValidator.architecture(of: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 128 * 1024 * 1024 else { throw BridgeError.invalidExecutable("Steam installer exceeds capture limit.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let captured = directory.appendingPathComponent("SteamSetup-\(UUID()).exe")
        try FileManager.default.copyItem(at: url, to: captured)
        let digest = try FileIntegrity.sha256(captured)
        guard digest == (try FileIntegrity.sha256(url)) else { throw BridgeError.invalidExecutable("Steam installer changed during capture.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: captured.path)
        return .init(source: url, capturedFile: captured, sha256: digest)
    }
    public func install(_ installer: SteamInstaller, bottle: Bottle, runtime: WineRuntime, approved: Bool,
                        retryUncertain: Bool = false, output: @escaping OutputHandler) async throws -> SteamScan {
        guard approved else { throw BridgeError.approvalRequired }
        guard !installing.contains(bottle.id) else { throw BridgeError.busy }
        guard installer.sha256 == (try FileIntegrity.sha256(installer.capturedFile)) else { throw BridgeError.invalidExecutable("Captured Steam installer changed; approve a new capture.") }
        try PrefixPolicy.validateWin64(bottle.prefix)
        try EnvironmentRecovery.validateNoInterruptedRestore(bottle.prefix)
        let journal = bottle.prefix.appendingPathComponent(".win2mac-steam-install.json")
        if FileManager.default.fileExists(atPath: journal.path) {
            guard try FileManager.default.attributesOfItem(atPath: journal.path)[.type] as? FileAttributeType == .typeRegular else {
                throw BridgeError.persistence("Steam installation journal must be a regular file.")
            }
            let previous = try JSONDecoder().decode(SteamInstallationRecord.self, from: Data(contentsOf: journal))
            guard previous.bottleID == bottle.id else { throw BridgeError.persistence("Steam installation record belongs to a different environment.") }
            if (previous.state == .pending || previous.state == .outcomeUnverified) && !retryUncertain {
                throw BridgeError.unsupported("Previous Steam installation outcome is uncertain. Inspect its log and close any detached installer before explicitly approving a retry.")
            }
        }
        if (try? scan(bottle)) != nil {
            throw BridgeError.unsupported("Windows Steam is already detected. Launch the existing client and use Valve's supported update flow instead of reinstalling automatically.")
        }
        installing.insert(bottle.id); defer { installing.remove(bottle.id) }
        var record = SteamInstallationRecord(installerSHA256: installer.sha256, bottleID: bottle.id, date: Date(),
                                            state: .pending, details: "Approved installer started; authentication and game behavior are unverified.")
        func save() throws { try JSONEncoder().encode(record).write(to: journal, options: .atomic) }
        try save()
        do {
            let app = ApplicationEntry(name: "Windows Steam installer", executable: installer.capturedFile, bottleID: bottle.id)
            let result = try await launcher.launch(app, bottle: bottle, runtime: runtime, approved: true, output: output)
            record.exitCode = result.exitCode
            guard result.exitCode == 0 && !result.wasSignalled else {
                record.state = .failed
                throw BridgeError.process("Steam installation exited with \(result.exitCode). Inspect the retained log; no authentication or compatibility success is assumed.")
            }
            let installed = try scan(bottle)
            record.state = .filePresenceVerified; record.details = "Steam client image detected. Login, networking, game launch and rendering remain untested."
            try save(); return installed
        } catch {
            if record.state != .failed { record.state = .outcomeUnverified }
            record.details = error.localizedDescription; try save(); throw error
        }
    }
    private func read(_ file: URL) throws -> [String: ValveValue] {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024 else {
            throw BridgeError.persistence("Steam manifests must be regular files up to 2 MiB.")
        }
        return try ValveKeyValues.parse(String(contentsOf: file, encoding: .utf8))
    }
    private func contained(_ file: URL, root: URL) throws -> URL {
        guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw BridgeError.persistence("Steam path escapes the selected environment.") }
        return file
    }
    public func scan(_ bottle: Bottle) throws -> SteamScan {
        try PrefixPolicy.validateWin64(bottle.prefix)
        let drive = try PrefixPolicy.canonical(bottle.prefix).appendingPathComponent("drive_c")
        guard try FileManager.default.attributesOfItem(atPath: drive.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw BridgeError.invalidPrefix("Steam scanning requires a real drive_c directory; host symlinks are not followed.")
        }
        let root = drive.resolvingSymlinksInPath()
        let candidates = ["Program Files (x86)/Steam", "Program Files/Steam"].map { root.appendingPathComponent($0) }
        guard let steam = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("steam.exe").path) }) else {
            throw BridgeError.invalidExecutable("Windows Steam is not installed in this environment's standard folders. Select its existing client as an application or approve installation in a dedicated environment.")
        }
        let client = try contained(steam.appendingPathComponent("steam.exe"), root: root)
        _ = try ExecutableValidator.architecture(of: client)
        var libraries = [steam]
        var warnings: [String] = []
        let folders = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        if FileManager.default.fileExists(atPath: folders.path) {
            do {
                let values = try read(try contained(folders, root: root))["libraryfolders"]?.object ?? [:]
                for key in values.keys.sorted() where key.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    let path = values[key]?.object?["path"]?.text ?? values[key]?.text ?? ""
                    let normalized = path.replacingOccurrences(of: "\\", with: "/")
                    guard normalized.lowercased().hasPrefix("c:/") else {
                        warnings.append("Library \(key) uses a non-C: mapping. Import that installation explicitly; Win2Mac will not follow host drive mappings."); continue
                    }
                    let parts = normalized.dropFirst(3).split(separator: "/").map(String.init)
                    guard !parts.contains(".."), !parts.contains("."), !parts.contains(where: { $0.contains(":") || $0.contains("\0") }) else { throw BridgeError.persistence("Unsafe Steam library path.") }
                    let library = parts.reduce(root) { $0.appendingPathComponent($1) }
                    _ = try contained(library, root: root)
                    if !libraries.contains(where: { $0.standardizedFileURL.path == library.standardizedFileURL.path }) { libraries.append(library) }
                }
            } catch { warnings.append("Library folders could not be read: " + error.localizedDescription) }
        }
        var games: [SteamGame] = [], ids = Set<String>()
        for library in libraries {
            let steamapps = try contained(library.appendingPathComponent("steamapps"), root: root)
            guard FileManager.default.fileExists(atPath: steamapps.path) else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: [])
            guard files.count <= 20_000 else { throw BridgeError.persistence("Steam library exceeds scan limit.") }
            for file in files.sorted(by: { $0.path < $1.path }) where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                do {
                    let values = try read(try contained(file, root: root))["appstate"]?.object ?? [:]
                    guard let id = values["appid"]?.text, Self.validAppID(id), file.lastPathComponent == "appmanifest_\(id).acf",
                          let name = values["name"]?.text, !name.isEmpty, let folder = values["installdir"]?.text,
                          !folder.isEmpty, folder != ".", folder != "..", !folder.contains("/"), !folder.contains("\\"), !folder.contains(":"), !folder.contains("\0"),
                          let flags = values["stateflags"]?.text.flatMap(UInt64.init), flags & 4 != 0 else {
                        throw BridgeError.persistence("Incomplete or invalid installed-game manifest.")
                    }
                    let installation = try contained(steamapps.appendingPathComponent("common/" + folder), root: root)
                    guard try installation.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw BridgeError.persistence("Game installation folder is missing.") }
                    guard ids.insert(id).inserted else { continue }
                    let art = steam.appendingPathComponent("appcache/librarycache/\(id)_library_600x900.jpg")
                    let artwork = (try? contained(art, root: root)).flatMap { image -> URL? in
                        guard let attributes = try? FileManager.default.attributesOfItem(atPath: image.path),
                              attributes[.type] as? FileAttributeType == .typeRegular,
                              let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024 else { return nil }
                        return image
                    }
                    games.append(.init(appID: id, name: name, installation: installation, manifest: file, artwork: artwork))
                } catch { warnings.append("\(file.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        return .init(client: client, games: games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, warnings: warnings)
    }
    static func rebindCopiedRecord(prefix: URL, from: UUID, to: UUID) throws {
        let steamJournal = prefix.appendingPathComponent(".win2mac-steam-install.json")
        if FileManager.default.fileExists(atPath: steamJournal.path) {
            guard try FileManager.default.attributesOfItem(atPath: steamJournal.path)[.type] as? FileAttributeType == .typeRegular else {
                throw BridgeError.persistence("Copied Steam journal must be a regular file.")
            }
            let old = try JSONDecoder().decode(SteamInstallationRecord.self, from: Data(contentsOf: steamJournal))
            guard old.bottleID == from else { throw BridgeError.persistence("Copied Steam journal does not match source.") }
            let rebound = SteamInstallationRecord(installerSHA256: old.installerSHA256, bottleID: to, date: old.date,
                state: old.state, exitCode: old.exitCode, details: old.details)
            try JSONEncoder().encode(rebound).write(to: steamJournal, options: .atomic)
        }
    }
    public static func validAppID(_ value: String) -> Bool {
        value.count <= 10 && !value.isEmpty && value.allSatisfy({ $0.isASCII && $0.isNumber }) && UInt32(value).map({ $0 > 0 }) == true
    }
    public static func launchArguments(_ application: ApplicationEntry, bottle: Bottle) throws -> [String] {
        guard let id = application.steamAppID, validAppID(id), let client = application.steamClient,
              client.standardizedFileURL == application.executable.standardizedFileURL,
              client.resolvingSymlinksInPath().path.hasPrefix(try PrefixPolicy.canonical(bottle.prefix).appendingPathComponent("drive_c").resolvingSymlinksInPath().path + "/") else {
            throw BridgeError.invalidExecutable("Steam launch must use a valid AppID and this environment's client. No arbitrary Steam command or host drive mapping is accepted.")
        }
        return [client.path, "-applaunch", id] + application.arguments
    }
}
