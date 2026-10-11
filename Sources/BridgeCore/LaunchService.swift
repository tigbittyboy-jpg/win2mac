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
        guard BackendCapabilities(runtime: runtime).supportsStandardPrefixes else {
            throw BridgeError.unsupported("This provider requires a dedicated backend adapter; generic Wine commands are unavailable.")
        }
        try runtimes.validate(runtime, forLaunch: true)
        let architecture = try ExecutableValidator.architecture(of: application.executable)
        if architecture == .x86 {
            guard runtime.supportsWindowsX86 == true else {
                throw BridgeError.unsupported("This EXE is 32-bit Windows x86. In Runtimes, confirm and save provider-documented x86/WoW64 support on this Mac. A Wine version probe alone does not establish support.")
            }
            guard bottle.graphics != .dxvkMoltenVK else {
                throw BridgeError.unsupported("Bridge imports x64 DXVK libraries only. Create a separate bottle with Runtime Default graphics for this 32-bit EXE; keep your existing x64 game bottle intact.")
            }
        }
        var environment = application.environment ?? [:]
        let reserved = ["WINEPREFIX", "WINEARCH", "WINEDLLOVERRIDES", "WINE_D3D_CONFIG", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH"]
        guard environment.keys.allSatisfy({ !reserved.contains($0) && $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }),
              environment.values.allSatisfy({ !$0.contains("\0") }) else {
            throw BridgeError.unsupported("Invalid environment override. Prefix, architecture, loader and graphics variables are managed by Bridge.")
        }
        environment.merge(try graphics.environment(for: bottle.graphics)) { _, managed in managed }
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
                workingDirectory: application.workingDirectory ?? application.executable.deletingLastPathComponent(),
                removingInheritedEnvironment: ["WINEARCH", "WINEPREFIX"]), output: output)
            await bottles.release(bottle)
            return result
        } catch {
            await bottles.release(bottle)
            throw error
        }
    }
}
