import Darwin
import Foundation
import Testing
@testable import SoftwareRegisseurProcess

private let echo = URL(filePath: "/bin/echo")
private let printf = URL(filePath: "/usr/bin/printf")
private let sleepTool = URL(filePath: "/bin/sleep")
private let sh = URL(filePath: "/bin/sh")

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    let runner = ProcessRunner()

    static let hostileArguments = [
        "two words", "\"double\"", "'single'", "a; rm -rf /tmp/nothing", "$(whoami)", "`id`", "*", "$HOME", "| cat", "\\n",
    ]

    @Test func echoPassesArgumentsLiterally() async throws {
        let result = try await runner.run(echo, arguments: Self.hostileArguments)
        #expect(result.succeeded)
        #expect(result.standardOutputString == Self.hostileArguments.joined(separator: " ") + "\n")
    }

    @Test func printfReceivesEachArgumentSeparately() async throws {
        let result = try await runner.run(printf, arguments: ["[%s]\n"] + Self.hostileArguments)
        #expect(result.succeeded)
        #expect(result.standardOutputString == Self.hostileArguments.map { "[\($0)]\n" }.joined())
    }

    @Test func nulByteInArgumentIsRejected() async throws {
        await #expect(throws: ProcessRunnerError.invalidArgument(index: 0)) {
            try await runner.run(echo, arguments: ["a\u{0}b"])
        }
    }

    @Test func missingExecutableThrows() async throws {
        await #expect(throws: ProcessRunnerError.executableNotFound("/nonexistent/tool")) {
            try await runner.run(URL(filePath: "/nonexistent/tool"))
        }
    }

    @Test func exitCodeAndSignalAreReported() async throws {
        let failed = try await runner.run(URL(filePath: "/usr/bin/false"))
        #expect(failed.terminationReason == .exit)
        #expect(failed.exitStatus == 1)
        #expect(!failed.succeeded)

        let killed = try await runner.run(sh, arguments: ["-c", "kill -9 $$"])
        #expect(killed.terminationReason == .uncaughtSignal)
        #expect(killed.exitStatus == SIGKILL)
    }

    @Test func stdinIsDeliveredAndClosed() async throws {
        let input = Data("line one\nline two with ; and $(x)\n".utf8)
        let result = try await runner.run(URL(filePath: "/bin/cat"), standardInput: input)
        #expect(result.standardOutput.data == input)
    }

    @Test func stdinDefaultsToDevNull() async throws {
        let result = try await runner.run(URL(filePath: "/bin/cat"), timeout: .seconds(5))
        #expect(result.succeeded)
        #expect(result.standardOutput.data.isEmpty)
    }

    @Test func workingDirectoryIsApplied() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let result = try await runner.run(URL(filePath: "/bin/pwd"), arguments: ["-P"], workingDirectory: directory.url)
        let expected = String(cString: realpath(directory.url.path(percentEncoded: false), nil)!)
        #expect(result.standardOutputString == expected + "\n")
    }

    @Test func standardErrorIsCapturedSeparately() async throws {
        let result = try await runner.run(sh, arguments: ["-c", "echo out; echo err >&2"])
        #expect(result.standardOutputString == "out\n")
        #expect(result.standardErrorString == "err\n")
    }

    @Test func timeoutTerminatesSleep() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(ProcessRequest(
            executableURL: sleepTool, arguments: ["30"], timeout: .milliseconds(300)
        ))
        #expect(result.terminationReason == .timeout)
        #expect(result.exitStatus == SIGTERM)
        #expect(clock.now - start < .seconds(5))
    }

    @Test func timeoutEscalatesToKillWhenTermIsIgnored() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(ProcessRequest(
            executableURL: sh,
            arguments: ["-c", "trap '' TERM; /bin/sleep 30"],
            timeout: .milliseconds(200),
            terminationGracePeriod: .milliseconds(500)
        ))
        let elapsed = clock.now - start
        #expect(result.terminationReason == .timeout)
        #expect(result.exitStatus == SIGKILL)
        #expect(elapsed >= .milliseconds(700))
        #expect(elapsed < .seconds(6))
    }

    @Test func cancellationTerminatesProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { try await runner.run(sleepTool, arguments: ["30"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = try await task.value
        #expect(result.terminationReason == .cancellation)
        #expect(clock.now - start < .seconds(5))
    }

    @Test func cancellationBeforeStartThrows() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(sleepTool, arguments: ["30"])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func outputLimitTruncatesButDrains() async throws {
        let result = try await runner.run(ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/head"),
            arguments: ["-c", "200000", "/dev/zero"],
            outputLimit: 1000
        ))
        #expect(result.succeeded)
        #expect(result.standardOutput.data.count == 1000)
        #expect(result.standardOutput.totalByteCount == 200_000)
        #expect(result.standardOutput.isTruncated)
        #expect(!result.standardError.isTruncated)
    }

    @Test func environmentIsIsolatedFromParent() async throws {
        setenv("SR_PROCESS_TEST_SECRET", "parent-only", 1)
        defer { unsetenv("SR_PROCESS_TEST_SECRET") }
        let env = URL(filePath: "/usr/bin/env")

        let minimal = try await runner.run(env, environment: .minimal())
        #expect(!minimal.standardOutputString.contains("SR_PROCESS_TEST_SECRET"))
        let names = Set(minimal.standardOutputString.split(separator: "\n").map { String($0.prefix { $0 != "=" }) })
        #expect(names == ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR"])
        #expect(minimal.standardOutputString.contains("PATH=\(ProcessEnvironment.safeSystemPath)\n"))

        let extended = try await runner.run(env, environment: .minimal().merging(["CUSTOM_VAR": "a b; $(c)"]))
        #expect(extended.standardOutputString.contains("CUSTOM_VAR=a b; $(c)\n"))

        let empty = try await runner.run(env, environment: .empty)
        #expect(empty.standardOutputString.isEmpty)
    }

    @Test func invalidEnvironmentNameIsRejected() async throws {
        await #expect(throws: ProcessRunnerError.invalidEnvironmentVariable("A=B")) {
            try await runner.run(echo, environment: ProcessEnvironment(["A=B": "x"]))
        }
    }

    @Test func streamLinesDeliversLinesAndResult() async throws {
        var lines: [String] = []
        var errors: [String] = []
        var finished: ProcessResult?
        let request = ProcessRequest(executableURL: sh, arguments: ["-c", "printf 'a\\r\\nb\\n'; echo e >&2; printf c"])
        for try await event in runner.streamLines(request) {
            switch event {
            case .standardOutput(let line): lines.append(line)
            case .standardError(let line): errors.append(line)
            case .finished(let result): finished = result
            }
        }
        #expect(lines == ["a", "b", "c"])
        #expect(errors == ["e"])
        #expect(finished?.succeeded == true)
    }

    @Test func abandoningStreamTerminatesProcess() async throws {
        let request = ProcessRequest(executableURL: sh, arguments: ["-c", "echo $$; while true; do /bin/sleep 0.05; done"])
        var pid: pid_t?
        for try await event in runner.streamLines(request) {
            if case .standardOutput(let line) = event {
                pid = pid_t(line)
                break
            }
        }
        let childPID = try #require(pid)
        let deadline = ContinuousClock.now + .seconds(8)
        while kill(childPID, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(kill(childPID, 0) == -1)
    }

    @Test func streamTimeoutFinishesWithReason() async throws {
        var reason: ProcessTerminationReason?
        for try await event in runner.stream(ProcessRequest(executableURL: sleepTool, arguments: ["30"], timeout: .milliseconds(200))) {
            if case .finished(let result) = event { reason = result.terminationReason }
        }
        #expect(reason == .timeout)
    }

    @Test func lineSplitterHandlesChunksAndLongLines() {
        var splitter = LineSplitter(maxLineLength: 4)
        #expect(splitter.append(Data("ab".utf8)) == [])
        #expect(splitter.append(Data("c\r\nde".utf8)) == ["abc"])
        #expect(splitter.append(Data("fghij\n".utf8)) == ["defg", "hij"])
        #expect(splitter.append(Data("xyz".utf8)) == [])
        #expect(splitter.finish() == ["xyz"])
        #expect(splitter.finish() == [])
    }
}

struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "SRProcessTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
