import Darwin
import Dispatch
import Foundation
import SoftwareRegisseurProcess

/// How an interactive child ended.
public struct InteractiveProcessExit: Hashable, Sendable {
    public let exitStatus: Int32?
    public let signal: Int32?
    /// True when `terminate()` was requested before the process ended.
    public let terminatedByRequest: Bool

    public var succeeded: Bool { exitStatus == 0 && signal == nil }
}

public enum InteractiveProcessError: Error, Hashable, Sendable {
    case standardInputClosed
    case writeFailed(errno: Int32)
    case invalidEnvironmentVariable(String)
}

/// Long-running child process with a writable stdin, needed for the bidirectional agent protocols
/// (Codex JSON-RPC, Claude stream-json control channel).
///
/// `SoftwareRegisseurProcess.ProcessRunner` only supports one-shot stdin (`ProcessRequest.standardInput`
/// is written once and closed), so this type mirrors its guarantees for the interactive case: explicit
/// executable and argument vector via `posix_spawn` (no shell, spec L3), explicit environment, own
/// process group (termination also stops descendants such as MCP servers), `CLOEXEC_DEFAULT`.
final class InteractiveProcess: @unchecked Sendable {
    enum Output: Sendable, Hashable {
        case standardOutput(String)
        case standardError(String)
        case exited(InteractiveProcessExit)
    }

    let processIdentifier: pid_t
    /// Lines from stdout/stderr; `.exited` is the last element.
    let output: AsyncStream<Output>

    private let continuation: AsyncStream<Output>.Continuation
    private let queue = DispatchQueue(label: "SoftwareRegisseurAgents.process")
    private let writeQueue = DispatchQueue(label: "SoftwareRegisseurAgents.process.stdin")

    // `queue`-confined.
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var stdoutOpen = true
    private var stderrOpen = true
    private var stdoutSplitter: LineSplitter
    private var stderrSplitter: LineSplitter
    private var reaped = false
    private var waitStatus: Int32 = 0
    private var terminationRequested = false
    private var didFinish = false
    // `writeQueue`-confined.
    private var stdinFD: Int32

    init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: ProcessEnvironment,
        maxLineLength: Int = 8 * 1024 * 1024
    ) throws {
        let path = executableURL.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ProcessRunnerError.executableNotFound(path)
        }
        guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) else {
            throw ProcessRunnerError.notExecutable(path)
        }
        if let cwd = workingDirectory?.path(percentEncoded: false) {
            var cwdIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &cwdIsDirectory), cwdIsDirectory.boolValue else {
                throw ProcessRunnerError.workingDirectoryNotFound(cwd)
            }
        }
        for (index, argument) in arguments.enumerated() where argument.utf8.contains(0) {
            throw ProcessRunnerError.invalidArgument(index: index)
        }
        var environmentStrings: [String] = []
        for (name, value) in environment.variables.sorted(by: { $0.key < $1.key }) {
            guard !name.isEmpty, !name.contains("="), !name.utf8.contains(0), !value.utf8.contains(0) else {
                throw InteractiveProcessError.invalidEnvironmentVariable(name)
            }
            environmentStrings.append("\(name)=\(value)")
        }

        let stdinPipe = try Self.makePipe()
        let stdoutPipe = try Self.makePipe()
        let stderrPipe = try Self.makePipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe.read, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.write, STDERR_FILENO)
        if let cwd = workingDirectory?.path(percentEncoded: false) {
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
        let spawnResult = Self.withCStringArray([path] + arguments) { argv in
            Self.withCStringArray(environmentStrings) { envp in
                posix_spawn(&pid, path, &fileActions, &attributes, argv, envp)
            }
        }
        Self.close(stdinPipe.read, stdoutPipe.write, stderrPipe.write)
        guard spawnResult == 0 else {
            Self.close(stdinPipe.write, stdoutPipe.read, stderrPipe.read)
            throw ProcessRunnerError.spawnFailed(path: path, errno: spawnResult)
        }

        processIdentifier = pid
        stdinFD = stdinPipe.write
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)
        stdoutSplitter = LineSplitter(maxLineLength: maxLineLength)
        stderrSplitter = LineSplitter(maxLineLength: maxLineLength)
        (output, continuation) = AsyncStream.makeStream(of: Output.self, bufferingPolicy: .unbounded)

        queue.sync {
            stdoutSource = makeReadSource(fd: stdoutPipe.read, isStandardOutput: true)
            stderrSource = makeReadSource(fd: stderrPipe.read, isStandardOutput: false)
        }
        startWaiter()
    }

    deinit {
        if stdinFD >= 0 { Darwin.close(stdinFD) }
    }

    /// Writes all bytes to stdin (in order with other writes and `closeStandardInput`).
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                guard stdinFD >= 0 else { return resume.resume(throwing: InteractiveProcessError.standardInputClosed) }
                let failure: Int32? = data.withUnsafeBytes { raw -> Int32? in
                    guard let base = raw.baseAddress else { return nil }
                    var offset = 0
                    while offset < raw.count {
                        let written = Darwin.write(stdinFD, base.advanced(by: offset), raw.count - offset)
                        if written > 0 {
                            offset += written
                        } else if written == -1 && errno == EINTR {
                            continue
                        } else {
                            return errno
                        }
                    }
                    return nil
                }
                if let failure {
                    resume.resume(throwing: InteractiveProcessError.writeFailed(errno: failure))
                } else {
                    resume.resume()
                }
            }
        }
    }

    /// Writes `line` followed by `\n` (JSONL framing).
    func writeLine(_ line: Data) async throws {
        var data = line
        data.append(UInt8(ascii: "\n"))
        try await write(data)
    }

    /// Closes stdin after all queued writes (EOF tells both agents to finish).
    func closeStandardInput() {
        writeQueue.async { [self] in
            if stdinFD >= 0 {
                Darwin.close(stdinFD)
                stdinFD = -1
            }
        }
    }

    /// `SIGTERM` to the process group, `SIGKILL` after `gracePeriod`.
    func terminate(gracePeriod: Duration = .seconds(3)) {
        closeStandardInput()
        queue.async { [self] in
            guard !reaped, !terminationRequested else { return }
            terminationRequested = true
            Darwin.kill(-processIdentifier, SIGTERM)
            let seconds = Double(gracePeriod.components.seconds) + Double(gracePeriod.components.attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + max(0, seconds)) { [self] in
                guard !reaped else { return }
                Darwin.kill(-processIdentifier, SIGKILL)
            }
        }
    }

    // MARK: - Queue-confined

    private func makeReadSource(fd: Int32, isStandardOutput: Bool) -> DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self, unowned source] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    let chunk = Data(buffer[0..<count])
                    if isStandardOutput {
                        for line in stdoutSplitter.append(chunk) { continuation.yield(.standardOutput(line)) }
                    } else {
                        for line in stderrSplitter.append(chunk) { continuation.yield(.standardError(line)) }
                    }
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
            if isStandardOutput {
                for line in stdoutSplitter.finish() { continuation.yield(.standardOutput(line)) }
                stdoutOpen = false
            } else {
                for line in stderrSplitter.finish() { continuation.yield(.standardError(line)) }
                stderrOpen = false
            }
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
            queue.async { [self] in
                reaped = true
                waitStatus = finalStatus
                closeStandardInput()
                // Descendants may keep the pipes open; give them a moment, then stop reading.
                queue.asyncAfter(deadline: .now() + .seconds(2)) { [self] in
                    stdoutSource?.cancel()
                    stderrSource?.cancel()
                }
                finishIfPossible()
            }
        }
        thread.name = "SoftwareRegisseurAgents.wait.\(pid)"
        thread.start()
    }

    private func finishIfPossible() {
        guard reaped, !stdoutOpen, !stderrOpen, !didFinish else { return }
        didFinish = true
        stdoutSource = nil
        stderrSource = nil
        let signal = waitStatus & 0x7f
        let exit = InteractiveProcessExit(
            exitStatus: signal == 0 ? (waitStatus >> 8) & 0xff : nil,
            signal: signal == 0 ? nil : signal,
            terminatedByRequest: terminationRequested
        )
        continuation.yield(.exited(exit))
        continuation.finish()
    }

    // MARK: - Helpers

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw ProcessRunnerError.pipeFailed(errno: errno) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    private static func close(_ fds: Int32...) {
        for fd in fds { Darwin.close(fd) }
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
