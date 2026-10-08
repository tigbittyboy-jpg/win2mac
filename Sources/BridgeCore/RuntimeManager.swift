import Foundation

public protocol RuntimeManaging: Sendable {
    func discover() -> [WineRuntime]
    func inspect(_ executable: URL) throws -> WineRuntime
    func validate(_ runtime: WineRuntime, forLaunch: Bool) throws
    func probe(_ runtime: WineRuntime, approved: Bool, output: @escaping OutputHandler) async throws -> WineRuntime
}

public struct RuntimeManager: RuntimeManaging {
    private let executor: any ProcessExecuting
    private let host: HostCapabilities
    private let discoveryPaths: [URL]
    public init(executor: any ProcessExecuting = FoundationProcessExecutor(), host: HostCapabilities = .current,
                discoveryPaths: [URL]? = nil) {
        self.executor = executor; self.host = host
        self.discoveryPaths = discoveryPaths ?? Self.commonPaths
    }
    private static var commonPaths: [URL] {
        var paths = ["/opt/homebrew/bin/wine", "/opt/homebrew/bin/wine64", "/usr/local/bin/wine", "/usr/local/bin/wine64"]
            .map { URL(fileURLWithPath: $0) }
        for directory in [URL(fileURLWithPath: "/Applications", isDirectory: true),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)] {
            for app in ["Wine Stable.app", "Wine Devel.app", "Wine Staging.app"] {
                for executable in ["wine", "wine64"] {
                    paths.append(directory.appendingPathComponent("\(app)/Contents/Resources/wine/bin/\(executable)"))
                }
            }
        }
        return paths
    }
    public func discover() -> [WineRuntime] {
        var seen: Set<String> = []
        return discoveryPaths.compactMap { candidate in
            let url = candidate.resolvingSymlinksInPath()
            guard seen.insert(url.path).inserted else { return nil }
            return try? inspect(url)
        }
    }
    public func inspect(_ executable: URL) throws -> WineRuntime {
        try validateFile(executable)
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        let bytes = [UInt8](try handle.read(upToCount: 4096) ?? Data())
        return WineRuntime(name: executable.lastPathComponent, executable: executable.standardizedFileURL,
                           architecture: architecture(bytes))
    }
    public func validate(_ runtime: WineRuntime, forLaunch: Bool) throws {
        try validateFile(runtime.executable)
        guard host.isMacOS else { throw BridgeError.unsupported("Wine execution requires a supported macOS host.") }
        if runtime.architecture == .unknown {
            throw BridgeError.invalidRuntime("Unknown runtime architecture. For a wrapper, select its provider-documented architecture.")
        }
        if host.isAppleSilicon && runtime.architecture == .x86_64 && !host.rosettaInstalled {
            throw BridgeError.unsupported("This Intel runtime requires Rosetta 2. Follow Apple's installation instructions; Bridge will not install it.")
        }
        if forLaunch && !runtime.supportsWindowsX64 {
            throw BridgeError.unsupported("Confirm the runtime provider documents Windows x64 support before launching.")
        }
    }
    public func probe(_ runtime: WineRuntime, approved: Bool, output: @escaping OutputHandler) async throws -> WineRuntime {
        guard approved else { throw BridgeError.approvalRequired }
        try validate(runtime, forLaunch: false)
        let result = try await executor.run(.init(executable: runtime.executable, arguments: ["--version"], timeout: 15), output: output)
        let version = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !result.wasSignalled, version.lowercased().contains("wine") else {
            throw BridgeError.invalidRuntime("Runtime version probe failed or did not identify Wine (exit \(result.exitCode)).")
        }
        var verified = runtime
        verified.version = String(version.prefix(512))
        return verified
    }
    private func validateFile(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw BridgeError.invalidRuntime("Select an absolute local runtime executable.")
        }
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw BridgeError.invalidRuntime("Selected runtime is not an executable file.")
        }
    }
    private func architecture(_ bytes: [UInt8]) -> RuntimeArchitecture {
        func uint32(_ offset: Int, little: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let indices = little ? [3, 2, 1, 0] : [0, 1, 2, 3]
            return indices.reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
        }
        guard let magic = uint32(0, little: false) else { return .unknown }
        var cpus: Set<UInt32> = []
        if magic == 0xcffaedfe || magic == 0xcefaedfe {
            if let cpu = uint32(4, little: true) { cpus.insert(cpu) }
        } else if magic == 0xfeedfacf || magic == 0xfeedface {
            if let cpu = uint32(4, little: false) { cpus.insert(cpu) }
        } else if [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) {
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
            guard let count = uint32(4, little: little), count <= 64 else { return .unknown }
            for i in 0..<Int(count) { if let cpu = uint32(8 + i * stride, little: little) { cpus.insert(cpu) } }
        }
        let x64 = cpus.contains(0x01000007), arm = cpus.contains(0x0100000c)
        if x64 && arm { return .universal }
        if x64 { return .x86_64 }
        if arm { return .arm64 }
        return .unknown
    }
}
