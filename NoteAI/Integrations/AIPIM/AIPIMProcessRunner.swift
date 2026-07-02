import Foundation
import Darwin

struct AIPIMCommand: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let timeout: TimeInterval
    let maxOutputBytes: Int
}

struct AIPIMCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: Data
}

enum AIPIMExecutionError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case outputLimitExceeded
}

protocol AIPIMCommandExecuting: Sendable {
    func execute(_ command: AIPIMCommand) async throws -> AIPIMCommandResult
}

struct AIPIMProcessRunner: AIPIMCommandExecuting, Sendable {
    func execute(_ command: AIPIMCommand) async throws -> AIPIMCommandResult {
        try await Task.detached(priority: .utility) {
            try executeSynchronously(command)
        }.value
    }
}

private func executeSynchronously(_ command: AIPIMCommand) throws -> AIPIMCommandResult {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let accumulator = AIPIMOutputAccumulator(limit: command.maxOutputBytes)
    let termination = DispatchSemaphore(value: 0)

    process.executableURL = command.executableURL
    process.arguments = command.arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    var environment = ProcessInfo.processInfo.environment
    environment["AI_PIM_UTILS_TELEMETRY_DISABLED"] = "1"
    process.environment = environment
    process.terminationHandler = { _ in termination.signal() }

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        if accumulator.consume(data, capture: true), process.isRunning {
            process.terminate()
        }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        if accumulator.consume(data, capture: false), process.isRunning {
            process.terminate()
        }
    }

    do {
        try process.run()
    } catch {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        throw AIPIMExecutionError.launchFailed
    }

    let waitResult = termination.wait(timeout: .now() + max(0.01, command.timeout))
    if waitResult == .timedOut {
        if process.isRunning {
            process.terminate()
        }
        if termination.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + 1)
        }
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    accumulator.consume(stdoutPipe.fileHandleForReading.readDataToEndOfFile(), capture: true)
    accumulator.consume(stderrPipe.fileHandleForReading.readDataToEndOfFile(), capture: false)

    if waitResult == .timedOut {
        throw AIPIMExecutionError.timedOut
    }
    if accumulator.exceededLimit {
        throw AIPIMExecutionError.outputLimitExceeded
    }

    return AIPIMCommandResult(exitCode: process.terminationStatus, stdout: accumulator.stdout)
}

private final class AIPIMOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var byteCount = 0
    private var capturedOutput = Data()
    private var didExceedLimit = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    @discardableResult
    func consume(_ data: Data, capture: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !data.isEmpty else { return didExceedLimit }
        let remaining = max(0, limit - byteCount)
        if capture, remaining > 0 {
            capturedOutput.append(data.prefix(remaining))
        }
        byteCount += data.count
        if byteCount > limit {
            didExceedLimit = true
        }
        return didExceedLimit
    }

    var exceededLimit: Bool {
        lock.withLock { didExceedLimit }
    }

    var stdout: Data {
        lock.withLock { capturedOutput }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
