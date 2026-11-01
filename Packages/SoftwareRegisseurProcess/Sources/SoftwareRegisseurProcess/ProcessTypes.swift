import Foundation

/// A fully explicit process invocation: executable URL plus argument vector. There is no shell
/// and no string joining anywhere in this package (spec L3).
public struct ProcessRequest: Sendable, Hashable {
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectory: URL?
    public var environment: ProcessEnvironment
    /// Bytes written to the child's stdin, which is then closed. `nil` connects stdin to `/dev/null`.
    public var standardInput: Data?
    /// Wall-clock limit; on expiry the process group is terminated (`SIGTERM`, then `SIGKILL`).
    public var timeout: Duration?
    /// Time between `SIGTERM` and `SIGKILL` on timeout or cancellation.
    public var terminationGracePeriod: Duration
    /// Maximum bytes captured per stream by `ProcessRunner.run`; excess output is drained and discarded.
    public var outputLimit: Int
    /// How long to wait for pipe EOF after the process exited (descendants may hold the pipes open).
    public var outputDrainTimeout: Duration

    public init(
        executableURL: URL,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: ProcessEnvironment = .minimal(),
        standardInput: Data? = nil,
        timeout: Duration? = nil,
        terminationGracePeriod: Duration = .seconds(3),
        outputLimit: Int = 16 * 1024 * 1024,
        outputDrainTimeout: Duration = .seconds(2)
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.outputLimit = outputLimit
        self.outputDrainTimeout = outputDrainTimeout
    }
}

public enum ProcessTerminationReason: String, Sendable, Hashable, Codable {
    /// The process exited normally; `exitStatus` is its exit code.
    case exit
    /// The process was killed by a signal it did not handle; `exitStatus` is the signal number.
    case uncaughtSignal
    /// `ProcessRequest.timeout` expired and the runner terminated the process.
    case timeout
    /// The calling task (or stream consumer) was cancelled and the runner terminated the process.
    case cancellation
}

/// Bytes captured from one output stream, honouring `ProcessRequest.outputLimit` (the head is kept).
public struct CapturedOutput: Sendable, Hashable {
    public internal(set) var data = Data()
    public internal(set) var totalByteCount = 0
    public var isTruncated: Bool { totalByteCount > data.count }

    public init() {}

    public var string: String { String(decoding: data, as: UTF8.self) }

    mutating func append(_ chunk: Data, limit: Int) {
        totalByteCount += chunk.count
        let room = limit - data.count
        if room > 0 { data.append(chunk.prefix(room)) }
    }
}

public struct ProcessResult: Sendable, Hashable {
    public let executableURL: URL
    public let arguments: [String]
    public let processIdentifier: Int32
    public let terminationReason: ProcessTerminationReason
    /// Exit code for `.exit`, signal number for `.uncaughtSignal`, raw wait status otherwise.
    public let exitStatus: Int32
    public let standardOutput: CapturedOutput
    public let standardError: CapturedOutput
    public let duration: Duration

    public var succeeded: Bool { terminationReason == .exit && exitStatus == 0 }
    public var standardOutputString: String { standardOutput.string }
    public var standardErrorString: String { standardError.string }
}

/// Chunks emitted by `ProcessRunner.stream(_:)`.
public enum ProcessOutputEvent: Sendable, Hashable {
    case standardOutput(Data)
    case standardError(Data)
    /// Always the last event. Streamed output is not captured in the result.
    case finished(ProcessResult)
}

/// Lines emitted by `ProcessRunner.streamLines(_:)` (UTF-8, lossy; without the line terminator).
public enum ProcessLineEvent: Sendable, Hashable {
    case standardOutput(String)
    case standardError(String)
    case finished(ProcessResult)
}

public enum ProcessRunnerError: Error, Sendable, Hashable, CustomStringConvertible {
    case executableNotFound(String)
    case notExecutable(String)
    case invalidArgument(index: Int)
    case invalidEnvironmentVariable(String)
    case workingDirectoryNotFound(String)
    case pipeFailed(errno: Int32)
    case spawnFailed(path: String, errno: Int32)

    public var description: String {
        switch self {
        case .executableNotFound(let path): "Executable not found: \(path)"
        case .notExecutable(let path): "Not an executable file: \(path)"
        case .invalidArgument(let index): "Argument \(index) contains a NUL byte"
        case .invalidEnvironmentVariable(let name): "Invalid environment variable: \(name)"
        case .workingDirectoryNotFound(let path): "Working directory not found: \(path)"
        case .pipeFailed(let code): "pipe() failed: \(String(cString: strerror(code)))"
        case .spawnFailed(let path, let code): "posix_spawn(\(path)) failed: \(String(cString: strerror(code)))"
        }
    }
}
