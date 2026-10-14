import Foundation
#if os(macOS)
import Darwin
import Metal
#endif

public enum CompatibilityStatus: String, Codable, CaseIterable, Sendable {
    case notTested = "Not tested", launchFailed = "Launch failed", launchSuccessful = "Launch successful"
    case partiallyFunctional = "Partially functional", playable = "Playable", fullyFunctional = "Fully functional"
}
public enum VerificationOutcome: String, Codable, CaseIterable, Sendable { case notTested, passed, failed }

/// Explicit observations, never inferred from an exit code or runtime probe.
public struct CompatibilityRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let applicationName: String
    public let executableSHA256: String
    public let architecture: WindowsMachine
    public let runtimeID: UUID
    public let runtimeVersion: String?
    public let runtimeSHA256: String?
    public let graphics: GraphicsBackend
    public let os: String
    public let launch: VerificationOutcome
    public let rendering: VerificationOutcome
    public let input: VerificationOutcome
    public let audio: VerificationOutcome
    public let stability: VerificationOutcome
    public let notes: String
    public var status: CompatibilityStatus {
        if launch == .failed { return .launchFailed }
        if launch != .passed { return .notTested }
        let observations = [rendering, input, audio, stability]
        if observations.allSatisfy({ $0 == .passed }) { return .fullyFunctional }
        if rendering == .passed && input == .passed && stability == .passed && audio != .failed { return .playable }
        if observations.contains(.passed) || observations.contains(.failed) { return .partiallyFunctional }
        return .launchSuccessful
    }
    public init(applicationName: String, executableSHA256: String, architecture: WindowsMachine,
                runtime: WineRuntime, graphics: GraphicsBackend, os: String,
                launch: VerificationOutcome, rendering: VerificationOutcome = .notTested,
                input: VerificationOutcome = .notTested, audio: VerificationOutcome = .notTested,
                stability: VerificationOutcome = .notTested, notes: String = "") {
        id = UUID(); date = Date(); self.applicationName = applicationName; self.executableSHA256 = executableSHA256
        self.architecture = architecture; runtimeID = runtime.id; runtimeVersion = runtime.version
        runtimeSHA256 = runtime.identity?.sha256; self.graphics = graphics; self.os = os
        self.launch = launch; self.rendering = rendering; self.input = input; self.audio = audio
        self.stability = stability; self.notes = notes
    }
}

public struct HostInventory: Codable, Sendable {
    public let operatingSystem: String
    public let hardwareModel: String
    public let processArchitecture: String
    public let physicalMemoryBytes: UInt64
    public let logicalProcessorCount: Int
    public let rosettaRuntimePresent: Bool
    public let graphicsMeasurement: String
    public static var current: Self {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "other"
        #endif
        #if os(macOS)
        func systemString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 4096 else { return nil }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
            return String(cString: bytes)
        }
        let model = [systemString("hw.model"), systemString("machdep.cpu.brand_string")].compactMap { $0 }.joined(separator: " · ")
        let graphics = MTLCreateSystemDefaultDevice().map { "Metal device: \($0.name); unified memory: \($0.hasUnifiedMemory). DirectX compatibility and FPS not measured." } ?? "No Metal device reported; FPS not measured."
        #else
        let model = "Host hardware model not collected on Linux"
        let graphics = "Metal capabilities and game FPS not measured"
        #endif
        return Self(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    hardwareModel: model, processArchitecture: architecture, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                    logicalProcessorCount: ProcessInfo.processInfo.processorCount,
                    rosettaRuntimePresent: HostCapabilities.current.rosettaInstalled,
                    graphicsMeasurement: graphics)
    }
}

public struct CompatibilityMatrixRow: Codable, Sendable {
    public let status: CompatibilityStatus
    public let observation: CompatibilityRecord
    public init(_ record: CompatibilityRecord) { status = record.status; observation = record }
}
