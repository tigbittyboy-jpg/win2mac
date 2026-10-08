import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ProcessOutputStream: String, Sendable { case stdout, stderr }
public struct ProcessOutput: Sendable {
    public let stream: ProcessOutputStream
    public let text: String
    public init(stream: ProcessOutputStream, text: String) { self.stream = stream; self.text = text }
}
public typealias OutputHandler = @Sendable (ProcessOutput) -> Void

public struct ProcessRequest: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?
    public let timeout: TimeInterval?
    public init(executable: URL, arguments: [String], environment: [String: String] = [:],
                workingDirectory: URL? = nil, timeout: TimeInterval? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.workingDirectory = workingDirectory; self.timeout = timeout
    }
}

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let wasSignalled: Bool
    public init(exitCode: Int32, stdout: String = "", stderr: String = "", wasSignalled: Bool = false) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr; self.wasSignalled = wasSignalled
    }
}

public protocol ProcessExecuting: Sendable {
    func run(_ request: ProcessRequest, output: @escaping OutputHandler) async throws -> ProcessResult
}

// Foundation Process and pipe buffers are confined behind locks/worker queues.
// Blocking wait/read work never runs on the cooperative Swift concurrency executor.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var completed = false
    private var timedOut = false

    func start(_ child: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try child.run()
        process = child
    }
    func cancel(timeout: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if completed { return }
        cancelled = true; timedOut = timeout
        if let process, process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.forceStop() }
    }
    private func forceStop() {
        lock.lock(); defer { lock.unlock() }
        if !completed, let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
    func finish() { lock.lock(); completed = true; lock.unlock() }
    var isCompleted: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if timedOut { throw BridgeError.process("Process exceeded its time limit and was terminated.") }
        if cancelled { throw CancellationError() }
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var truncated = false
    private let limit = 1_048_576
    private var readError: String?

    func drain(_ handle: FileHandle, stream: ProcessOutputStream, control: ProcessControl,
               output: @escaping OutputHandler) {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            lock.lock(); readError = "Could not configure process output pipe."; lock.unlock(); return
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                let chunk = Data(buffer.prefix(count))
                lock.lock()
                let remaining = limit - bytes.count
                bytes.append(chunk.prefix(remaining))
                truncated = truncated || count > remaining
                lock.unlock()
                pending.append(chunk)
                // Retain incomplete UTF-8 sequences across reads. Malformed output is replaced.
                var end = pending.count
                if end > 0 {
                    var start = end - 1
                    while start > 0 && pending[start] & 0xc0 == 0x80 { start -= 1 }
                    let lead = pending[start]
                    let needed = lead & 0xf8 == 0xf0 ? 4 : (lead & 0xf0 == 0xe0 ? 3 : (lead & 0xe0 == 0xc0 ? 2 : 1))
                    if end - start < needed { end = start }
                }
                if end > 0 {
                    output(.init(stream: stream, text: String(decoding: pending.prefix(end), as: UTF8.self)))
                    pending = Data(pending.dropFirst(end))
                }
            } else if count == 0 { break }
            else if errno == EAGAIN || errno == EWOULDBLOCK {
                // Child processes (e.g. wineserver) can retain a pipe after the primary exits.
                // Drain currently available bytes, then finish rather than wait on those children.
                if control.isCompleted { break }
                Thread.sleep(forTimeInterval: 0.01)
            } else if errno != EINTR {
                lock.lock(); readError = "Could not read process output (errno \(errno))."; lock.unlock(); break
            }
        }
        if !pending.isEmpty { output(.init(stream: stream, text: String(decoding: pending, as: UTF8.self))) }
    }
    func text() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let readError { throw BridgeError.process(readError) }
        return String(decoding: bytes, as: UTF8.self) + (truncated ? "\n[Capture truncated at 1 MiB]" : "")
    }
}

public struct FoundationProcessExecutor: ProcessExecuting {
    public init() {}
    public func run(_ request: ProcessRequest, output: @escaping OutputHandler) async throws -> ProcessResult {
        guard request.executable.isFileURL, request.executable.path.hasPrefix("/") else {
            throw BridgeError.process("Process executable must be an absolute local file URL.")
        }
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let child = Process()
                    let stdout = Pipe(), stderr = Pipe()
                    child.executableURL = request.executable
                    child.arguments = request.arguments
                    // Preserve supported user-installed runtime environments; never log values.
                    child.environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, new in new }
                    child.currentDirectoryURL = request.workingDirectory
                    child.standardInput = FileHandle.nullDevice
                    child.standardOutput = stdout; child.standardError = stderr
                    let out = PipeCapture(), err = PipeCapture()
                    let readers = DispatchGroup()
                    var timer: DispatchSourceTimer?
                    defer {
                        timer?.cancel()
                        try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
                        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                    }
                    do {
                        try control.start(child)
                        try stdout.fileHandleForWriting.close(); try stderr.fileHandleForWriting.close()
                        readers.enter()
                        DispatchQueue.global().async {
                            out.drain(stdout.fileHandleForReading, stream: .stdout, control: control, output: output)
                            readers.leave()
                        }
                        readers.enter()
                        DispatchQueue.global().async {
                            err.drain(stderr.fileHandleForReading, stream: .stderr, control: control, output: output)
                            readers.leave()
                        }
                        if let seconds = request.timeout {
                            let deadline = DispatchSource.makeTimerSource(queue: .global())
                            deadline.schedule(deadline: .now() + max(0.1, seconds))
                            deadline.setEventHandler { control.cancel(timeout: true) }
                            deadline.resume(); timer = deadline
                        }
                        child.waitUntilExit()
                        control.finish(); timer?.cancel()
                        readers.wait()
                        try control.checkCancellation()
                        continuation.resume(returning: ProcessResult(
                            exitCode: child.terminationStatus, stdout: try out.text(), stderr: try err.text(),
                            wasSignalled: child.terminationReason == .uncaughtSignal))
                    } catch {
                        control.cancel(); control.finish(); readers.wait()
                        if error is CancellationError { continuation.resume(throwing: error) }
                        else if let bridgeError = error as? BridgeError { continuation.resume(throwing: bridgeError) }
                        else { continuation.resume(throwing: BridgeError.process(error.localizedDescription)) }
                    }
                }
            }
        } onCancel: { control.cancel() }
    }
}
