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
    guard !command.executableURL.path.contains("\0"),
          !command.arguments.contains(where: { $0.contains("\0") }) else {
        throw AIPIMExecutionError.launchFailed
    }

    var stdoutPipe = try AIPIMPipe()
    var stderrPipe = try AIPIMPipe()
    let accumulator = AIPIMOutputAccumulator(limit: command.maxOutputBytes)
    var processID: pid_t = 0
    var processStatus: Int32 = 0
    var processWasReaped = false

    do {
        processID = try spawn(command, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
    } catch {
        stdoutPipe.closeAll()
        stderrPipe.closeAll()
        throw AIPIMExecutionError.launchFailed
    }

    stdoutPipe.closeWriteEnd()
    stderrPipe.closeWriteEnd()
    defer {
        stdoutPipe.closeReadEnd()
        stderrPipe.closeReadEnd()
    }

    let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, command.timeout)
    while true {
        let stdoutOutcome = drain(
            &stdoutPipe,
            capture: true,
            accumulator: accumulator,
            until: deadline
        )
        let drainOutcome = stdoutOutcome == .yielded
            ? drain(
                &stderrPipe,
                capture: false,
                accumulator: accumulator,
                until: deadline
            )
            : stdoutOutcome
        reap(processID, status: &processStatus, wasReaped: &processWasReaped)

        if let executionError = drainOutcome.executionError {
            terminateProcessGroup(
                processID,
                stdoutPipe: &stdoutPipe,
                stderrPipe: &stderrPipe,
                accumulator: accumulator,
                processStatus: &processStatus,
                processWasReaped: &processWasReaped
            )
            throw executionError
        }

        if processWasReaped, !stdoutPipe.readIsOpen, !stderrPipe.readIsOpen {
            return AIPIMCommandResult(
                exitCode: decodedExitCode(processStatus),
                stdout: accumulator.stdout
            )
        }

        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining <= 0 {
            terminateProcessGroup(
                processID,
                stdoutPipe: &stdoutPipe,
                stderrPipe: &stderrPipe,
                accumulator: accumulator,
                processStatus: &processStatus,
                processWasReaped: &processWasReaped
            )
            throw AIPIMExecutionError.timedOut
        }

        waitForPipeActivity(stdoutPipe, stderrPipe, maximumWait: min(remaining, 0.01))
    }
}

private func spawn(
    _ command: AIPIMCommand,
    stdoutPipe: AIPIMPipe,
    stderrPipe: AIPIMPipe
) throws -> pid_t {
    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0,
          posix_spawnattr_init(&attributes) == 0 else {
        throw AIPIMExecutionError.launchFailed
    }
    defer {
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attributes)
    }

    let actionResults = [
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.writeDescriptor, STDOUT_FILENO),
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.writeDescriptor, STDERR_FILENO),
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.readDescriptor),
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe.readDescriptor),
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.writeDescriptor),
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe.writeDescriptor)
    ]
    guard actionResults.allSatisfy({ $0 == 0 }) else {
        throw AIPIMExecutionError.launchFailed
    }

    let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
        throw AIPIMExecutionError.launchFailed
    }

    var environment = ProcessInfo.processInfo.environment
    environment["AI_PIM_UTILS_TELEMETRY_DISABLED"] = "1"
    let environmentValues = environment.map { "\($0.key)=\($0.value)" }
    let executablePath = command.executableURL.path
    let argumentValues = [executablePath] + command.arguments
    var processID: pid_t = 0

    let result = try withCStringArray(argumentValues) { arguments in
        try withCStringArray(environmentValues) { environment in
            executablePath.withCString { path in
                posix_spawn(
                    &processID,
                    path,
                    &fileActions,
                    &attributes,
                    arguments,
                    environment
                )
            }
        }
    }
    guard result == 0 else {
        throw AIPIMExecutionError.launchFailed
    }
    return processID
}

private func terminateProcessGroup(
    _ processID: pid_t,
    stdoutPipe: inout AIPIMPipe,
    stderrPipe: inout AIPIMPipe,
    accumulator: AIPIMOutputAccumulator,
    processStatus: inout Int32,
    processWasReaped: inout Bool
) {
    signalProcessGroup(processID, signal: SIGTERM)
    waitForTermination(
        processID,
        until: ProcessInfo.processInfo.systemUptime + 0.025,
        stdoutPipe: &stdoutPipe,
        stderrPipe: &stderrPipe,
        accumulator: accumulator,
        processStatus: &processStatus,
        processWasReaped: &processWasReaped
    )

    signalProcessGroup(processID, signal: SIGKILL)
    waitForTermination(
        processID,
        until: ProcessInfo.processInfo.systemUptime + 0.2,
        stdoutPipe: &stdoutPipe,
        stderrPipe: &stderrPipe,
        accumulator: accumulator,
        processStatus: &processStatus,
        processWasReaped: &processWasReaped
    )

    if !processWasReaped {
        AIPIMChildReaper.reapLater(processID)
    }
}

private func waitForTermination(
    _ processID: pid_t,
    until deadline: TimeInterval,
    stdoutPipe: inout AIPIMPipe,
    stderrPipe: inout AIPIMPipe,
    accumulator: AIPIMOutputAccumulator,
    processStatus: inout Int32,
    processWasReaped: inout Bool
) {
    while ProcessInfo.processInfo.systemUptime < deadline {
        if drain(
            &stdoutPipe,
            capture: true,
            accumulator: accumulator,
            until: deadline
        ) == .timedOut {
            return
        }
        if drain(
            &stderrPipe,
            capture: false,
            accumulator: accumulator,
            until: deadline
        ) == .timedOut {
            return
        }
        reap(processID, status: &processStatus, wasReaped: &processWasReaped)
        if processWasReaped, !processGroupExists(processID) {
            return
        }
        waitForPipeActivity(stdoutPipe, stderrPipe, maximumWait: 0.005)
    }
}

private func signalProcessGroup(_ processID: pid_t, signal: Int32) {
    guard processID > 0 else { return }
    _ = Darwin.kill(-processID, signal)
}

private func processGroupExists(_ processID: pid_t) -> Bool {
    guard processID > 0 else { return false }
    if Darwin.kill(-processID, 0) == 0 {
        return true
    }
    return errno == EPERM
}

private func reap(_ processID: pid_t, status: inout Int32, wasReaped: inout Bool) {
    guard !wasReaped else { return }
    let result = waitpid(processID, &status, WNOHANG)
    if result == processID || (result == -1 && errno == ECHILD) {
        wasReaped = true
    }
}

private func decodedExitCode(_ status: Int32) -> Int32 {
    let terminatingSignal = status & 0x7f
    if terminatingSignal == 0 {
        return (status >> 8) & 0xff
    }
    return 128 + terminatingSignal
}

private func drain(
    _ pipe: inout AIPIMPipe,
    capture: Bool,
    accumulator: AIPIMOutputAccumulator,
    until deadline: TimeInterval
) -> AIPIMDrainOutcome {
    guard pipe.readIsOpen else { return .yielded }
    var buffer = [UInt8](repeating: 0, count: 8_192)

    while ProcessInfo.processInfo.systemUptime < deadline {
        let count = Darwin.read(pipe.readDescriptor, &buffer, buffer.count)
        if count > 0 {
            if accumulator.consume(Data(buffer.prefix(count)), capture: capture) {
                return .outputLimitExceeded
            }
            continue
        }
        if count == 0 {
            pipe.closeReadEnd()
            return .yielded
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            return .yielded
        }
        if errno == EINTR {
            continue
        }
        pipe.closeReadEnd()
        return .yielded
    }

    return .timedOut
}

private enum AIPIMDrainOutcome: Equatable {
    case yielded
    case outputLimitExceeded
    case timedOut

    var executionError: AIPIMExecutionError? {
        switch self {
        case .yielded:
            nil
        case .outputLimitExceeded:
            .outputLimitExceeded
        case .timedOut:
            .timedOut
        }
    }
}

private func waitForPipeActivity(
    _ stdoutPipe: AIPIMPipe,
    _ stderrPipe: AIPIMPipe,
    maximumWait: TimeInterval
) {
    var descriptors: [pollfd] = []
    if stdoutPipe.readIsOpen {
        descriptors.append(pollfd(fd: stdoutPipe.readDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0))
    }
    if stderrPipe.readIsOpen {
        descriptors.append(pollfd(fd: stderrPipe.readDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0))
    }

    let timeoutMilliseconds = Int32(max(1, ceil(maximumWait * 1_000)))
    if descriptors.isEmpty {
        usleep(useconds_t(timeoutMilliseconds * 1_000))
        return
    }
    descriptors.withUnsafeMutableBufferPointer { buffer in
        _ = Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), timeoutMilliseconds)
    }
}

private func withCStringArray<Result>(
    _ values: [String],
    operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) throws -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    guard pointers.allSatisfy({ $0 != nil }) else {
        pointers.forEach { pointer in
            if let pointer { free(pointer) }
        }
        throw AIPIMExecutionError.launchFailed
    }
    pointers.append(nil)
    defer {
        pointers.forEach { pointer in
            if let pointer { free(pointer) }
        }
    }
    return try pointers.withUnsafeMutableBufferPointer { buffer in
        try operation(buffer.baseAddress!)
    }
}

private struct AIPIMPipe {
    private(set) var readDescriptor: Int32
    private(set) var writeDescriptor: Int32
    private(set) var readIsOpen = true
    private(set) var writeIsOpen = true

    init() throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        let pipeResult = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard pipeResult == 0 else {
            throw AIPIMExecutionError.launchFailed
        }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]

        let flags = fcntl(readDescriptor, F_GETFL)
        guard flags >= 0, fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            closeAll()
            throw AIPIMExecutionError.launchFailed
        }
    }

    mutating func closeReadEnd() {
        guard readIsOpen else { return }
        Darwin.close(readDescriptor)
        readIsOpen = false
    }

    mutating func closeWriteEnd() {
        guard writeIsOpen else { return }
        Darwin.close(writeDescriptor)
        writeIsOpen = false
    }

    mutating func closeAll() {
        closeReadEnd()
        closeWriteEnd()
    }
}

private enum AIPIMChildReaper {
    static func reapLater(_ processID: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(processID, &status, 0) == -1, errno == EINTR {}
        }
    }
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
