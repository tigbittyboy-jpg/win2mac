import Foundation

public enum WindowsDependency: String, Codable, CaseIterable, Sendable {
    case visualC2015To2022 = "Visual C++ 2015–2022", directXJune2010 = "DirectX June 2010", dotNetFramework4 = ".NET Framework 4"
    public var documentation: URL {
        switch self {
        case .visualC2015To2022: URL(string: "https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist")!
        case .directXJune2010: URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109")!
        case .dotNetFramework4: URL(string: "https://learn.microsoft.com/en-us/dotnet/framework/install/")!
        }
    }
    public var installerArguments: [String] {
        switch self {
        case .visualC2015To2022: ["/install", "/passive", "/norestart"]
        case .directXJune2010: ["/silent"] // Select the extracted DXSETUP.exe, not the self-extracting archive.
        case .dotNetFramework4: ["/passive", "/norestart"]
        }
    }
    var evidencePaths: [String] {
        switch self {
        case .visualC2015To2022: ["windows/system32/vcruntime140.dll", "windows/system32/msvcp140.dll"]
        case .directXJune2010: ["windows/system32/d3dx9_43.dll", "windows/system32/xinput1_3.dll"]
        case .dotNetFramework4: ["windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll"]
        }
    }
}
public enum DependencyInstallState: String, Codable, Sendable { case pending, filePresenceVerified, failed, outcomeUnverified }
public struct DependencyRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let bottleID: UUID
    public let component: WindowsDependency
    public let requestedVersion: String
    public var targetArchitecture: WindowsMachine?
    public let installerSHA256: String
    public let date: Date
    public var state: DependencyInstallState
    public var exitCode: Int32?
    public var evidence: [String: String]
    public var details: String
}
public struct DependencyInstaller: Sendable {
    public let id: UUID
    public let component: WindowsDependency
    public let requestedVersion: String
    public let source: URL
    public let capturedFile: URL
    public let sha256: String
    public let assets: [String: String]
    public let info: ExecutableInfo
    public let targetArchitecture: WindowsMachine
    public var arguments: [String] { component.installerArguments }
}
public struct DependencySuggestion: Equatable, Sendable {
    public let component: WindowsDependency
    public let evidence: [String]
    public let explanation: String
}
public protocol DependencyManaging: Sendable {
    func inspect(installer: URL, component: WindowsDependency, version: String, target: WindowsMachine) async throws -> DependencyInstaller
    func records(in bottle: Bottle) async throws -> [DependencyRecord]
    func install(_ installer: DependencyInstaller, bottle: Bottle, runtime: WineRuntime, approved: Bool,
                 retryUncertain: Bool, output: @escaping OutputHandler) async throws -> DependencyRecord
}

/// Only reviewed local official installers. No DLL/engine downloads, registry
/// guesses or unverified automatic repair. Presence is not functionality proof.
public actor DependencyManager: DependencyManaging {
    private let executor: any ProcessExecuting
    private let runtimes: any RuntimeManaging
    private let bottles: any BottleManaging
    private let directory: URL
    private static let recordName = ".win2mac-dependencies.json"
    public init(executor: any ProcessExecuting = FoundationProcessExecutor(), runtimes: any RuntimeManaging = RuntimeManager(),
                bottles: any BottleManaging = BottleManager(), directory: URL = BridgePaths.dataDirectory.appendingPathComponent("Installers")) {
        self.executor = executor; self.runtimes = runtimes; self.bottles = bottles; self.directory = directory
    }
    public static func suggestions(for info: ExecutableInfo) -> [DependencySuggestion] {
        let imports = info.imports.map { $0.lowercased() }
        var result: [DependencySuggestion] = []
        let vc = imports.filter { $0.hasPrefix("vcruntime140") || $0.hasPrefix("msvcp140") }
        if !vc.isEmpty { result.append(.init(component: .visualC2015To2022, evidence: vc, explanation: "Imports request the VC 14 runtime; this does not prove it is missing.")) }
        let dx = imports.filter { $0 == "d3dx9_43.dll" || $0 == "xinput1_3.dll" }
        if !dx.isEmpty { result.append(.init(component: .directXJune2010, evidence: dx, explanation: "Legacy DirectX helper imports; this installer does not provide DirectX-to-Metal translation.")) }
        if info.managed { result.append(.init(component: .dotNetFramework4, evidence: ["CLR header"], explanation: "Managed PE evidence does not establish the required .NET version. Check the publisher and Wine provider before installation.")) }
        return result
    }
    public func inspect(installer: URL, component: WindowsDependency, version: String, target: WindowsMachine = .x64) throws -> DependencyInstaller {
        guard target == .x86 || target == .x64 else { throw BridgeError.unsupported("Choose the dependency payload architecture independently from its bootstrap installer architecture.") }
        let info = try ExecutableInspector.inspect(installer)
        guard info.machine == .x64 || info.machine == .x86 else { throw BridgeError.unsupported("Installer architecture is unsupported.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: installer.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 512 * 1024 * 1024,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.unsupported("Select an installer up to 512 MiB and enter its publisher-reported version.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID(), captureDirectory = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let captured = captureDirectory.appendingPathComponent(installer.lastPathComponent)
        var sourceFiles = [installer]
        if component == .directXJune2010 {
            guard installer.lastPathComponent.lowercased() == "dxsetup.exe" else {
                throw BridgeError.unsupported("Extract Microsoft's DirectX June 2010 package and select DXSETUP.exe, not the self-extracting archive.")
            }
            let siblings = try FileManager.default.contentsOfDirectory(at: installer.deletingLastPathComponent(), includingPropertiesForKeys: [])
            sourceFiles += siblings.filter { ["cab", "dll"].contains($0.pathExtension.lowercased()) }
            let names = Set(sourceFiles.map { $0.lastPathComponent.lowercased() })
            guard names.contains("dsetup.dll"), names.contains("dsetup32.dll"), sourceFiles.contains(where: { $0.pathExtension.lowercased() == "cab" }) else {
                throw BridgeError.invalidExecutable("DXSETUP needs the official extracted adjacent DLLs and CAB payloads. No installer was executed.")
            }
        }
        guard sourceFiles.count <= 512 else { throw BridgeError.invalidExecutable("Installer payload file count exceeds capture limit.") }
        var assets: [String: String] = [:], total: UInt64 = 0
        for file in sourceFiles {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { throw BridgeError.invalidExecutable("Installer payloads must be real regular files, not symlinks.") }
            total += size.uint64Value
            guard total <= 512 * 1024 * 1024 else { throw BridgeError.invalidExecutable("Installer payload exceeds 512 MiB capture limit.") }
            let destination = captureDirectory.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: destination)
            let digest = try FileIntegrity.sha256(destination)
            guard digest == (try FileIntegrity.sha256(file)) else { throw BridgeError.persistence("Installer payload changed during capture.") }
            assets[file.lastPathComponent] = digest
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
        }
        return .init(id: id, component: component, requestedVersion: version, source: installer,
                     capturedFile: captured, sha256: try FileIntegrity.sha256(captured), assets: assets, info: info, targetArchitecture: target)
    }

    private static func read(prefix: URL) throws -> [DependencyRecord] {
        let file = prefix.appendingPathComponent(recordName)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
            throw BridgeError.persistence("Dependency journal must be a regular file.")
        }
        return try JSONDecoder().decode([DependencyRecord].self, from: Data(contentsOf: file))
    }
    public func records(in bottle: Bottle) throws -> [DependencyRecord] {
        let records = try Self.read(prefix: bottle.prefix)
        guard records.allSatisfy({ $0.bottleID == bottle.id }) else { throw BridgeError.persistence("Dependency journal belongs to a different environment.") }
        return records
    }
    private static func write(_ records: [DependencyRecord], prefix: URL) throws {
        let file = prefix.appendingPathComponent(recordName)
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func rebindCopiedRecords(prefix: URL, from: UUID, to: UUID) throws {
        let records = try read(prefix: prefix)
        guard records.allSatisfy({ $0.bottleID == from }) else { throw BridgeError.persistence("Copied dependency journal does not match source.") }
        if !records.isEmpty {
            let updated = records.map { DependencyRecord(id: $0.id, bottleID: to, component: $0.component,
                requestedVersion: $0.requestedVersion, targetArchitecture: $0.targetArchitecture, installerSHA256: $0.installerSHA256, date: $0.date,
                state: $0.state, exitCode: $0.exitCode, evidence: $0.evidence, details: $0.details) }
            try write(updated, prefix: prefix)
        }
    }
    private func evidence(_ component: WindowsDependency, prefix: URL, machine: WindowsMachine) throws -> [String: String] {
        var result: [String: String] = [:]
        let root = try PrefixPolicy.canonical(prefix).appendingPathComponent("drive_c")
        for relative in component.evidencePaths {
            let path = machine == .x86 ? relative.replacingOccurrences(of: "system32", with: "syswow64").replacingOccurrences(of: "Framework64", with: "Framework") : relative
            let file = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                  try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { continue }
            guard let info = try? ExecutableInspector.inspect(file, requiringDLL: true), info.machine == machine else { continue }
            result[path] = try FileIntegrity.sha256(file)
        }
        return result
    }
    public func install(_ installer: DependencyInstaller, bottle: Bottle, runtime: WineRuntime, approved: Bool,
                        retryUncertain: Bool = false, output: @escaping OutputHandler) async throws -> DependencyRecord {
        guard approved else { throw BridgeError.approvalRequired }
        guard bottle.runtimeID == runtime.id, BackendCapabilities(runtime: runtime).supportsStandardPrefixes else {
            throw BridgeError.unsupported("Dependency installation needs the environment's supported Wine adapter.")
        }
        try runtimes.validate(runtime, forLaunch: true)
        if (installer.info.machine == .x86 || installer.targetArchitecture == .x86) && runtime.supportsWindowsX86 != true { throw BridgeError.unsupported("This installer needs provider-confirmed WoW64 support.") }
        for (name, digest) in installer.assets {
            guard name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("/"), !name.contains("\\"),
                  digest == (try FileIntegrity.sha256(installer.capturedFile.deletingLastPathComponent().appendingPathComponent(name))) else {
                throw BridgeError.invalidExecutable("Captured installer payload changed; request a new approval.")
            }
        }
        guard installer.sha256 == (try FileIntegrity.sha256(installer.capturedFile)) else { throw BridgeError.invalidExecutable("Captured installer changed; request a new approval.") }
        if DXVKInstaller.hasInstallation(bottle) && installer.component == .directXJune2010 {
            throw BridgeError.unsupported("Restore imported DXVK before installing DirectX components; shared graphics files must not conflict.")
        }
        try await bottles.acquire(bottle)
        do {
            var history = try records(in: bottle)
            let matches = history.filter { $0.component == installer.component }
            if let prior = matches.last, prior.state == .filePresenceVerified,
               prior.requestedVersion == installer.requestedVersion, prior.targetArchitecture == installer.targetArchitecture, prior.installerSHA256 == installer.sha256,
               try evidence(installer.component, prefix: bottle.prefix, machine: installer.targetArchitecture) == prior.evidence {
                await bottles.release(bottle); return prior
            }
            if matches.last.map({ $0.state == .pending || $0.state == .outcomeUnverified }) == true && !retryUncertain {
                throw BridgeError.unsupported("Previous installation outcome is uncertain. Inspect the environment and logs before explicitly approving a retry.")
            }
            var record = DependencyRecord(id: UUID(), bottleID: bottle.id, component: installer.component,
                requestedVersion: installer.requestedVersion, targetArchitecture: installer.targetArchitecture, installerSHA256: installer.sha256, date: Date(),
                state: .pending, evidence: [:], details: "Installer approved; outcome not yet known.")
            history.append(record); try Self.write(history, prefix: bottle.prefix)
            do {
                let result = try await executor.run(.init(executable: runtime.executable,
                    arguments: [installer.capturedFile.path] + installer.arguments,
                    environment: ["WINEPREFIX": try PrefixPolicy.canonical(bottle.prefix).path],
                    workingDirectory: installer.capturedFile.deletingLastPathComponent(), timeout: 600,
                    removingInheritedEnvironment: ExecutionEnvironmentPolicy.managedKeys), output: output)
                record.exitCode = result.exitCode
                record.evidence = try evidence(installer.component, prefix: bottle.prefix, machine: installer.targetArchitecture)
                let acceptedExit = [Int32(0), 3010].contains(result.exitCode) && !result.wasSignalled
                record.state = !acceptedExit ? .failed : record.evidence.count == installer.component.evidencePaths.count ? .filePresenceVerified : .outcomeUnverified
                record.details = "Exit \(result.exitCode). \(record.evidence.count) expected files found. Requested version is user-reported; file presence does not certify version, Wine support or application functionality."
                history[history.count - 1] = record; try Self.write(history, prefix: bottle.prefix)
                await bottles.release(bottle); return record
            } catch {
                record.state = .outcomeUnverified; record.details = error.localizedDescription
                history[history.count - 1] = record; try Self.write(history, prefix: bottle.prefix)
                throw error
            }
        } catch { await bottles.release(bottle); throw error }
    }
}
