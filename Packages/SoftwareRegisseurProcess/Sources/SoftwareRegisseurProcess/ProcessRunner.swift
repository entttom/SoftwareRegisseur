import Foundation
import Synchronization

/// Runs executables with explicit argument vectors – never through a shell (spec L3).
///
/// Cancellation of the calling task (or of a stream consumer) terminates the whole child process
/// group: `SIGTERM` first, `SIGKILL` after `ProcessRequest.terminationGracePeriod`.
public struct ProcessRunner: Sendable {
    public init() {}

    /// Runs the process to completion and captures stdout/stderr up to `request.outputLimit` bytes each.
    ///
    /// - Throws: `ProcessRunnerError` if the process cannot be started, `CancellationError` if the task
    ///   was already cancelled before spawning. Once started, timeouts and cancellation are reported via
    ///   `ProcessResult.terminationReason` so that partial output stays available.
    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try Task.checkCancellation()
        let box = ExecutionBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let collector = OutputCollector(limit: max(0, request.outputLimit))
                do {
                    let execution = try ProcessExecution(request: request) { event in
                        switch event {
                        case .standardOutput(let chunk):
                            collector.standardOutput.append(chunk, limit: collector.limit)
                        case .standardError(let chunk):
                            collector.standardError.append(chunk, limit: collector.limit)
                        case .exited(let pid, let reason, let status, let duration):
                            continuation.resume(returning: ProcessResult(
                                executableURL: request.executableURL,
                                arguments: request.arguments,
                                processIdentifier: pid,
                                terminationReason: reason,
                                exitStatus: status,
                                standardOutput: collector.standardOutput,
                                standardError: collector.standardError,
                                duration: duration
                            ))
                        }
                    }
                    box.install(execution)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Convenience wrapper for `run(_:)`.
    public func run(
        _ executableURL: URL,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: ProcessEnvironment = .minimal(),
        standardInput: Data? = nil,
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        try await run(ProcessRequest(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput,
            timeout: timeout
        ))
    }

    /// Starts the process immediately and streams raw output chunks for long-running agents.
    /// Output is not captured; `.finished` is always the last element. Terminating the iteration
    /// (task cancellation or dropping the stream) terminates the process.
    public func stream(_ request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            do {
                let execution = try ProcessExecution(request: request) { event in
                    switch event {
                    case .standardOutput(let chunk):
                        continuation.yield(.standardOutput(chunk))
                    case .standardError(let chunk):
                        continuation.yield(.standardError(chunk))
                    case .exited(let pid, let reason, let status, let duration):
                        continuation.yield(.finished(ProcessResult(
                            executableURL: request.executableURL,
                            arguments: request.arguments,
                            processIdentifier: pid,
                            terminationReason: reason,
                            exitStatus: status,
                            standardOutput: CapturedOutput(),
                            standardError: CapturedOutput(),
                            duration: duration
                        )))
                        continuation.finish()
                    }
                }
                continuation.onTermination = { termination in
                    if case .cancelled = termination { execution.terminate(reason: .cancellation) }
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Line-oriented variant of `stream(_:)`; lines longer than `maxLineLength` bytes are split.
    public func streamLines(
        _ request: ProcessRequest,
        maxLineLength: Int = 1024 * 1024
    ) -> AsyncThrowingStream<ProcessLineEvent, Error> {
        let chunks = stream(request)
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                var stdout = LineSplitter(maxLineLength: maxLineLength)
                var stderr = LineSplitter(maxLineLength: maxLineLength)
                do {
                    for try await event in chunks {
                        switch event {
                        case .standardOutput(let data):
                            for line in stdout.append(data) { continuation.yield(.standardOutput(line)) }
                        case .standardError(let data):
                            for line in stderr.append(data) { continuation.yield(.standardError(line)) }
                        case .finished(let result):
                            for line in stdout.finish() { continuation.yield(.standardOutput(line)) }
                            for line in stderr.finish() { continuation.yield(.standardError(line)) }
                            continuation.yield(.finished(result))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }
}

/// Splits a byte stream into lines (`\n` or `\r\n`), bounding memory per line.
public struct LineSplitter: Sendable {
    public let maxLineLength: Int
    private var pending = Data()

    public init(maxLineLength: Int = 1024 * 1024) {
        self.maxLineLength = max(1, maxLineLength)
    }

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            var line = pending[pending.startIndex..<newline]
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            lines.append(contentsOf: Self.decode(line, maxLength: maxLineLength))
            pending = Data(pending[(newline + 1)...])
        }
        while pending.count > maxLineLength {
            lines.append(String(decoding: pending.prefix(maxLineLength), as: UTF8.self))
            pending = Data(pending.dropFirst(maxLineLength))
        }
        return lines
    }

    public mutating func finish() -> [String] {
        defer { pending = Data() }
        return pending.isEmpty ? [] : Self.decode(pending[...], maxLength: maxLineLength)
    }

    private static func decode(_ bytes: Data, maxLength: Int) -> [String] {
        var result: [String] = []
        var rest = bytes[...]
        repeat {
            result.append(String(decoding: rest.prefix(maxLength), as: UTF8.self))
            rest = rest.dropFirst(maxLength)
        } while !rest.isEmpty
        return result
    }
}

/// Mutable capture state; only touched from the execution's serial queue.
private final class OutputCollector: @unchecked Sendable {
    let limit: Int
    var standardOutput = CapturedOutput()
    var standardError = CapturedOutput()
    init(limit: Int) { self.limit = limit }
}

/// Bridges task cancellation to an execution that may not exist yet.
private final class ExecutionBox: Sendable {
    private struct State {
        var execution: ProcessExecution?
        var cancelled = false
    }
    private let state = Mutex(State())

    func install(_ execution: ProcessExecution) {
        let cancelled = state.withLock { state in
            state.execution = execution
            return state.cancelled
        }
        if cancelled { execution.terminate(reason: .cancellation) }
    }

    func cancel() {
        let execution = state.withLock { state in
            state.cancelled = true
            return state.execution
        }
        execution?.terminate(reason: .cancellation)
    }
}
