import Foundation

public protocol LaunchServing: Sendable {
    func launch(_ application: ApplicationEntry, bottle: Bottle, runtime: WineRuntime, approved: Bool,
                output: @escaping OutputHandler) async throws -> ProcessResult
}

public actor LaunchService: LaunchServing {
    private let executor: any ProcessExecuting
    private let runtimes: any RuntimeManaging
    private let bottles: any BottleManaging
    private let graphics: any GraphicsManaging
    private var running = false
    public init(executor: any ProcessExecuting = FoundationProcessExecutor(),
                runtimes: any RuntimeManaging = RuntimeManager(), bottles: any BottleManaging = BottleManager(),
                graphics: any GraphicsManaging = GraphicsManager()) {
        self.executor = executor; self.runtimes = runtimes; self.bottles = bottles; self.graphics = graphics
    }
    public func launch(_ application: ApplicationEntry, bottle: Bottle, runtime: WineRuntime, approved: Bool,
                       output: @escaping OutputHandler) async throws -> ProcessResult {
        guard approved else { throw BridgeError.approvalRequired }
        guard !running else { throw BridgeError.busy }
        guard application.bottleID == bottle.id, bottle.runtimeID == runtime.id else {
            throw BridgeError.invalidPrefix("Application, bottle, and runtime associations do not match.")
        }
        try runtimes.validate(runtime, forLaunch: true)
        try ExecutableValidator.validateX64(application.executable)
        var environment = try graphics.environment(for: bottle.graphics)
        environment["WINEPREFIX"] = try PrefixPolicy.canonical(bottle.prefix).path
        running = true; defer { running = false }
        try await bottles.acquire(bottle)
        do {
            if bottle.graphics == .dxvkMoltenVK {
                try DXVKInstaller.validateInstallation(bottle)
            } else if DXVKInstaller.hasInstallation(bottle) {
                throw BridgeError.invalidPrefix("This bottle has imported or incomplete DXVK files. Select its recorded DXVK backend or restore the original DLLs before launching.")
            }
            let result = try await executor.run(.init(executable: runtime.executable,
                arguments: [application.executable.path] + application.arguments, environment: environment,
                workingDirectory: application.executable.deletingLastPathComponent()), output: output)
            await bottles.release(bottle)
            return result
        } catch {
            await bottles.release(bottle)
            throw error
        }
    }
}
