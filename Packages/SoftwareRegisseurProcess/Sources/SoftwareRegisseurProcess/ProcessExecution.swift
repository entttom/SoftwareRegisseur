import Darwin
import Dispatch
import Foundation

/// One spawned child process. Uses `posix_spawn` directly (no shell, spec L3) so that the child gets
/// its own process group (timeouts/cancellation also stop descendants), a default signal setup and
/// only stdin/stdout/stderr as inherited descriptors (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
///
/// All mutable state is confined to `queue`.
final class ProcessExecution: @unchecked Sendable {
    enum Event: Sendable {
        case standardOutput(Data)
        case standardError(Data)
        case exited(pid: Int32, reason: ProcessTerminationReason, status: Int32, duration: Duration)
    }

    let processIdentifier: pid_t
    private let queue = DispatchQueue(label: "SoftwareRegisseurProcess.execution")
    private let handler: @Sendable (Event) -> Void
    private let request: ProcessRequest
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant

    // Queue-confined state.
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var stdoutOpen = true
    private var stderrOpen = true
    private var reaped = false
    private var waitStatus: Int32 = 0
    private var requestedReason: ProcessTerminationReason?
    private var didFinish = false

    init(request: ProcessRequest, handler: @escaping @Sendable (Event) -> Void) throws(ProcessRunnerError) {
        self.request = request
        self.handler = handler

        let path = request.executableURL.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw .executableNotFound(path)
        }
        guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) else {
            throw .notExecutable(path)
        }
        if let cwd = request.workingDirectory?.path(percentEncoded: false) {
            var cwdIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &cwdIsDirectory),
                  cwdIsDirectory.boolValue else {
                throw .workingDirectoryNotFound(cwd)
            }
        }
        for (index, argument) in request.arguments.enumerated() where argument.utf8.contains(0) {
            throw .invalidArgument(index: index)
        }
        let environment = try request.environment.validated()

        let stdoutPipe = try Self.makePipe()
        let stderrPipe = try Self.makePipe()
        var stdinPipe: (read: Int32, write: Int32)?
        if request.standardInput != nil {
            do { stdinPipe = try Self.makePipe() } catch {
                Self.close(stdoutPipe.read, stdoutPipe.write, stderrPipe.read, stderrPipe.write)
                throw error
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        if let stdinPipe {
            posix_spawn_file_actions_adddup2(&fileActions, stdinPipe.read, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.write, STDERR_FILENO)
        if let cwd = request.workingDirectory?.path(percentEncoded: false) {
            posix_spawn_file_actions_addchdir(&fileActions, cwd)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals: sigset_t = 0
        var allSignals: sigset_t = ~0
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        var pid: pid_t = 0
        let argv = [path] + request.arguments
        let spawnResult = Self.withCStringArray(argv) { argvPointer in
            Self.withCStringArray(environment) { envPointer in
                posix_spawn(&pid, path, &fileActions, &attributes, argvPointer, envPointer)
            }
        }

        // The child owns its ends now (or spawning failed); the parent never needs them.
        Self.close(stdoutPipe.write, stderrPipe.write)
        if let stdinPipe { Self.close(stdinPipe.read) }
        guard spawnResult == 0 else {
            Self.close(stdoutPipe.read, stderrPipe.read)
            if let stdinPipe { Self.close(stdinPipe.write) }
            throw .spawnFailed(path: path, errno: spawnResult)
        }

        processIdentifier = pid
        startedAt = clock.now

        if let stdinPipe, let input = request.standardInput {
            Self.writeAsync(input, to: stdinPipe.write)
        }
        queue.sync {
            stdoutSource = makeReadSource(fd: stdoutPipe.read, isStandardOutput: true)
            stderrSource = makeReadSource(fd: stderrPipe.read, isStandardOutput: false)
            if let timeout = request.timeout {
                queue.asyncAfter(deadline: .now() + timeout.dispatchInterval) { [self] in
                    terminateOnQueue(reason: .timeout)
                }
            }
        }
        startWaiter()
    }

    /// Requests termination: `SIGTERM` to the process group, `SIGKILL` after the grace period.
    func terminate(reason: ProcessTerminationReason) {
        queue.async { [self] in terminateOnQueue(reason: reason) }
    }

    // MARK: - Queue-confined implementation

    private func terminateOnQueue(reason: ProcessTerminationReason) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !reaped, requestedReason == nil else { return }
        requestedReason = reason
        Darwin.kill(-processIdentifier, SIGTERM)
        queue.asyncAfter(deadline: .now() + request.terminationGracePeriod.dispatchInterval) { [self] in
            guard !reaped else { return }
            Darwin.kill(-processIdentifier, SIGKILL)
        }
    }

    private func makeReadSource(fd: Int32, isStandardOutput: Bool) -> DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self, unowned source] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    let chunk = Data(buffer[0..<count])
                    handler(isStandardOutput ? .standardOutput(chunk) : .standardError(chunk))
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    source.cancel()
                    return
                } else if errno == EAGAIN {
                    return
                }
            }
        }
        source.setCancelHandler { [self] in
            Darwin.close(fd)
            if isStandardOutput { stdoutOpen = false } else { stderrOpen = false }
            finishIfPossible()
        }
        source.activate()
        return source
    }

    private func startWaiter() {
        let pid = processIdentifier
        let thread = Thread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let finalStatus = status
            queue.async { [self] in handleExit(status: finalStatus) }
        }
        thread.name = "SoftwareRegisseurProcess.wait.\(pid)"
        thread.start()
    }

    private func handleExit(status: Int32) {
        reaped = true
        waitStatus = status
        if requestedReason != nil {
            // Stop remaining descendants so they release the output pipes.
            Darwin.kill(-processIdentifier, SIGKILL)
        }
        queue.asyncAfter(deadline: .now() + request.outputDrainTimeout.dispatchInterval) { [self] in
            stdoutSource?.cancel()
            stderrSource?.cancel()
        }
        finishIfPossible()
    }

    private func finishIfPossible() {
        guard reaped, !stdoutOpen, !stderrOpen, !didFinish else { return }
        didFinish = true
        stdoutSource = nil
        stderrSource = nil
        let duration = clock.now - startedAt
        let signal = waitStatus & 0x7f
        let reason: ProcessTerminationReason
        let status: Int32
        if let requestedReason {
            reason = requestedReason
            status = signal == 0 ? (waitStatus >> 8) & 0xff : signal
        } else if signal == 0 {
            reason = .exit
            status = (waitStatus >> 8) & 0xff
        } else {
            reason = .uncaughtSignal
            status = signal
        }
        handler(.exited(pid: processIdentifier, reason: reason, status: status, duration: duration))
    }

    // MARK: - Helpers

    private static func makePipe() throws(ProcessRunnerError) -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw .pipeFailed(errno: errno) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    private static func close(_ fds: Int32...) {
        for fd in fds { Darwin.close(fd) }
    }

    private static func writeAsync(_ data: Data, to fd: Int32) {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .utility).async {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written == -1 && errno == EINTR {
                        continue
                    } else {
                        break // EPIPE: the child closed stdin or exited.
                    }
                }
            }
            Darwin.close(fd)
        }
    }

    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        let nanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !nanoseconds.overflow else { return .never }
        return .nanoseconds(Int(max(0, nanoseconds.partialValue + attoseconds / 1_000_000_000)))
    }
}
