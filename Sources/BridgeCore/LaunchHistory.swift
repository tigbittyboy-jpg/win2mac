import Foundation

public enum LaunchState: String, Codable, Sendable { case pending, completed, failed, interrupted, cancelled }
public struct LaunchHistoryRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let runtimeID: UUID
    public let runtimeVersion: String?
    public let bottleID: UUID
    public let graphics: GraphicsBackend
    public let log: URL
    public var state: LaunchState
    public var elapsedSeconds: TimeInterval?
    public var exitCode: Int32?
    public var wasSignalled: Bool?
    public var diagnosis: LaunchDiagnosis?
    public init(runtime: WineRuntime, bottle: Bottle, graphics: GraphicsBackend, log: URL) {
        id = UUID(); startedAt = Date(); runtimeID = runtime.id; runtimeVersion = runtime.version
        bottleID = bottle.id; self.graphics = graphics; self.log = log; state = .pending
    }
}
public enum LaunchRecovery {
    /// A previous launcher process ended before recording its child's outcome.
    /// Never restart that child or assume detached Wine children have stopped.
    public static func markInterrupted(_ snapshot: LibrarySnapshot) -> LibrarySnapshot {
        var recovered = snapshot
        for index in recovered.applications.indices {
            guard var history = recovered.applications[index].launchHistory else { continue }
            for run in history.indices where history[run].state == .pending {
                history[run].state = .interrupted
                history[run].diagnosis = LaunchDiagnosis.classify(error: BridgeError.process("The previous launcher session ended without a recorded result. Inspect its saved log and close detached Wine processes before recovery."))
            }
            recovered.applications[index].launchHistory = history
        }
        return recovered
    }
}
