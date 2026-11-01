import Foundation
import Synchronization

/// One `codex app-server --listen stdio://` child process with its JSON-RPC connection
/// (ADR-0021; spike codex §2). Responses are correlated by `JSONRPCConnection`; everything else is
/// delivered on `events`.
final class CodexAppServerClient: Sendable {
    enum Event: Sendable, Hashable {
        case incoming(JSONRPCIncoming)
        case standardError(String)
        case exited(InteractiveProcessExit)
    }

    /// `--disable hooks` (documented in `codex app-server --help` 0.164.0, feature `hooks` listed by
    /// `codex features list`): hooks of a trusted project's `.codex/` would otherwise also apply to the
    /// job worktree and run commands outside the approval flow (SR-SEC-03). Sandbox and approval policy
    /// are set explicitly per thread anyway (`CodexProtocol.threadStartParams`).
    static let arguments = ["app-server", "--listen", "stdio://", "--disable", "hooks"]

    let connection: JSONRPCConnection
    let events: AsyncStream<Event>
    private let process: InteractiveProcess
    private let exit = ExitSignal()

    /// PID (= process group) of the app-server child.
    var processIdentifier: Int32 { process.processIdentifier }

    private init(process: InteractiveProcess) {
        self.process = process
        connection = JSONRPCConnection(send: { [process] line in try await process.writeLine(line) })
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        events = stream
        let connection = connection
        let exit = exit
        Task {
            for await output in process.output {
                switch output {
                case let .standardOutput(line):
                    if let incoming = await connection.receive(line: line) { continuation.yield(.incoming(incoming)) }
                case let .standardError(line):
                    continuation.yield(.standardError(line))
                case let .exited(status):
                    await connection.close()
                    exit.signal(status)
                    continuation.yield(.exited(status))
                }
            }
            continuation.finish()
        }
    }

    static func launch(toolchain: AgentToolchain, workingDirectory: URL) throws -> CodexAppServerClient {
        let process = try InteractiveProcess(
            executableURL: toolchain.executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: toolchain.environment
        )
        return CodexAppServerClient(process: process)
    }

    /// `initialize` request followed by the `initialized` notification (mandatory handshake).
    @discardableResult
    func initialize(_ client: CodexProtocol.ClientInfo, timeout: Duration) async throws -> JSONValue {
        let result = try await connection.request(CodexProtocol.Method.initialize, params: CodexProtocol.initializeParams(client), timeout: timeout)
        try await connection.notify(CodexProtocol.Method.initialized)
        return result
    }

    /// Paginates `model/list` until `nextCursor == null`.
    func listModels(timeout: Duration) async throws -> [CodexProtocol.Model] {
        var models: [CodexProtocol.Model] = []
        var cursor: String?
        var pages = 0
        repeat {
            let result = try await connection.request(CodexProtocol.Method.modelList, params: CodexProtocol.modelListParams(cursor: cursor), timeout: timeout)
            let page = try CodexProtocol.decodeModelPage(result)
            models += page.models
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 50
        return models
    }

    /// Closes stdin (app-server exits on EOF), waits up to `grace`, then terminates the process group.
    func shutdown(grace: Duration = .seconds(3)) async {
        process.closeStandardInput()
        if await exit.wait(timeout: grace) == nil {
            process.terminate(gracePeriod: .seconds(2))
            _ = await exit.wait(timeout: .seconds(5))
        }
    }

    func terminate() {
        process.terminate(gracePeriod: .seconds(2))
    }

    func waitForExit(timeout: Duration) async -> InteractiveProcessExit? {
        await exit.wait(timeout: timeout)
    }
}

/// One-shot exit notification usable by several waiters.
final class ExitSignal: Sendable {
    private struct State {
        var value: InteractiveProcessExit?
        var waiters: [UUID: CheckedContinuation<InteractiveProcessExit?, Never>] = [:]
    }

    private let state = Mutex(State())

    func signal(_ value: InteractiveProcessExit) {
        let waiters = state.withLock { state -> [CheckedContinuation<InteractiveProcessExit?, Never>] in
            guard state.value == nil else { return [] }
            state.value = value
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    var value: InteractiveProcessExit? { state.withLock { $0.value } }

    func wait(timeout: Duration) async -> InteractiveProcessExit? {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            let existing = state.withLock { state -> InteractiveProcessExit?? in
                if let value = state.value { return .some(value) }
                state.waiters[token] = continuation
                return .none
            }
            if case let .some(value) = existing {
                continuation.resume(returning: value)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                let waiter = self.state.withLock { $0.waiters.removeValue(forKey: token) }
                waiter?.resume(returning: nil)
            }
        }
    }
}
