import Foundation

public struct GraphicsRecommendation: Sendable {
    public let backend: GraphicsBackend
    public let reason: String
    public let evidenceRecordID: UUID?
}
public enum GraphicsRecommender {
    public static func recommend(application: ApplicationEntry, bottle: Bottle, runtime: WineRuntime,
                                 executableSHA256: String) -> GraphicsRecommendation {
        guard application.steamAppID == nil else {
            return .init(backend: application.graphicsOverride ?? bottle.graphics,
                         reason: "Steam records identify its client, not every game binary. Retain this game's selected backend; no automatic recommendation is made from a client checksum.", evidenceRecordID: nil)
        }
        let known = (application.compatibilityRecords ?? []).reversed().first {
            $0.executableSHA256 == executableSHA256 && $0.runtimeID == runtime.id &&
            $0.runtimeSHA256 != nil && $0.runtimeSHA256 == runtime.identity?.sha256 &&
            $0.os == ProcessInfo.processInfo.operatingSystemVersionString &&
            ($0.status == .playable || $0.status == .fullyFunctional) &&
            ($0.graphics != .dxvkMoltenVK || bottle.graphics == .dxvkMoltenVK) &&
            (bottle.graphics != .dxvkMoltenVK || $0.graphics == .dxvkMoltenVK)
        }
        if let known {
            return .init(backend: known.graphics, reason: "Previously observed playable configuration for these executable/engine bytes and OS. Revalidation is needed after other runtime/library changes.", evidenceRecordID: known.id)
        }
        return .init(backend: application.graphicsOverride ?? bottle.graphics,
                     reason: "Retain the configured backend. No verified evidence supports an automatic graphics change.", evidenceRecordID: nil)
    }
}
