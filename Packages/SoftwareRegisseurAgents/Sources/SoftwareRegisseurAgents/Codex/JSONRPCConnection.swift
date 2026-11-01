import Foundation

/// JSON-RPC request id (`RequestId = string | number`, Codex schema).
public enum JSONRPCID: Hashable, Sendable, CustomStringConvertible {
    case int(Int64)
    case string(String)

    init?(_ json: JSONValue?) {
        switch json {
        case let .integer(value)?: self = .int(value)
        case let .number(value)? where value.rounded() == value: self = .int(Int64(value))
        case let .string(value)?: self = .string(value)
        default: return nil
        }
    }

    var json: JSONValue {
        switch self {
        case let .int(value): .integer(value)
        case let .string(value): .string(value)
        }
    }

    public var description: String {
        switch self {
        case let .int(value): String(value)
        case let .string(value): value
        }
    }
}

public struct JSONRPCErrorObject: Error, Hashable, Sendable {
    public let code: Int64
    public let message: String
    public let data: JSONValue?

    public init(code: Int64, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum JSONRPCError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Refused locally; never sent (spec K2: limits are not bypassed).
    case forbiddenMethod(String)
    case connectionClosed
    case timeout(method: String)
    case remote(method: String, JSONRPCErrorObject)
    case invalidResponse(method: String, String)

    public var description: String {
        switch self {
        case let .forbiddenMethod(method): "Methode \(method) ist gesperrt"
        case .connectionClosed: String(localized: "Verbindung zum Agenten geschlossen", bundle: .module)
        case let .timeout(method): String(localized: "Zeitüberschreitung bei \(method)", bundle: .module)
        case let .remote(method, error): String(localized: "\(method): \(error.message) (\(error.code))", bundle: .module)
        case let .invalidResponse(method, detail): String(localized: "Ungültige Antwort auf \(method): \(detail)", bundle: .module)
        }
    }
}

/// Messages that are not responses to our own requests.
public enum JSONRPCIncoming: Hashable, Sendable {
    case notification(method: String, params: JSONValue?)
    /// Server→client request (approvals); must be answered with `respond`/`respondError`.
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    /// Undecodable line (kept for diagnostics, redacted by the caller).
    case invalid(String)
}

/// Wire format of `codex app-server --listen stdio://`: JSON-RPC 2.0 shapes **without** the `jsonrpc`
/// member, one JSON object per line (spike codex §2 „Protokollform“).
enum JSONRPCFraming {
    static func request(id: JSONRPCID, method: String, params: JSONValue?) -> JSONValue {
        var object: [String: JSONValue] = ["id": id.json, "method": .string(method)]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func notification(method: String, params: JSONValue?) -> JSONValue {
        var object: [String: JSONValue] = ["method": .string(method)]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func response(id: JSONRPCID, result: JSONValue) -> JSONValue {
        ["id": id.json, "result": result]
    }

    static func errorResponse(id: JSONRPCID, code: Int64, message: String) -> JSONValue {
        ["id": id.json, "error": ["code": .integer(code), "message": .string(message)]]
    }

    enum Classified: Hashable, Sendable {
        case response(id: JSONRPCID, result: Result<JSONValue, JSONRPCErrorObject>)
        case incoming(JSONRPCIncoming)
    }

    static func classify(_ line: String) -> Classified {
        guard let message = try? JSONValue.parse(line), let object = message.objectValue else {
            return .incoming(.invalid(line))
        }
        let id = JSONRPCID(object["id"])
        if let method = object["method"]?.stringValue {
            if let id { return .incoming(.request(id: id, method: method, params: JSONValue.nonNull(object["params"]))) }
            return .incoming(.notification(method: method, params: JSONValue.nonNull(object["params"])))
        }
        if let id {
            if let error = object["error"], let errorObject = error.objectValue {
                return .response(id: id, result: .failure(JSONRPCErrorObject(
                    code: errorObject["code"]?.int64Value ?? 0,
                    message: errorObject["message"]?.stringValue ?? "",
                    data: errorObject["data"]
                )))
            }
            if let result = object["result"] { return .response(id: id, result: .success(result)) }
        }
        return .incoming(.invalid(line))
    }
}

/// Request/response correlation over a line transport. The owner feeds every received line into
/// `receive(line:)` and calls `close()` when the transport ends.
actor JSONRPCConnection {
    /// Methods the client refuses to send. `account/rateLimitResetCredit/consume` would spend the
    /// user's reset credit (spike codex §7, ADR-0021, spec K2).
    static let forbiddenMethods: Set<String> = ["account/rateLimitResetCredit/consume"]

    static func isForbidden(_ method: String) -> Bool {
        forbiddenMethods.contains(method) || method.lowercased().contains("ratelimitresetcredit")
    }

    private let send: @Sendable (Data) async throws -> Void
    private var nextId: Int64 = 1
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private var pending: [JSONRPCID: Pending] = [:]
    private var closed = false

    init(send: @escaping @Sendable (Data) async throws -> Void) {
        self.send = send
    }

    func request(_ method: String, params: JSONValue? = nil, timeout: Duration? = .seconds(60)) async throws -> JSONValue {
        guard !Self.isForbidden(method) else { throw JSONRPCError.forbiddenMethod(method) }
        guard !closed else { throw JSONRPCError.connectionClosed }
        let id = JSONRPCID.int(nextId)
        nextId += 1
        let line = try JSONRPCFraming.request(id: id, method: method, params: params).serialized()
        return try await withCheckedThrowingContinuation { continuation in
            var entry = Pending(method: method, continuation: continuation)
            if let timeout {
                entry.timeoutTask = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self.fail(id, with: JSONRPCError.timeout(method: method))
                }
            }
            pending[id] = entry
            Task { await self.transmit(line, failing: id) }
        }
    }

    func notify(_ method: String, params: JSONValue? = nil) async throws {
        guard !Self.isForbidden(method) else { throw JSONRPCError.forbiddenMethod(method) }
        guard !closed else { throw JSONRPCError.connectionClosed }
        try await send(try JSONRPCFraming.notification(method: method, params: params).serialized())
    }

    func respond(to id: JSONRPCID, result: JSONValue) async throws {
        guard !closed else { throw JSONRPCError.connectionClosed }
        try await send(try JSONRPCFraming.response(id: id, result: result).serialized())
    }

    func respondError(to id: JSONRPCID, code: Int64, message: String) async throws {
        guard !closed else { throw JSONRPCError.connectionClosed }
        try await send(try JSONRPCFraming.errorResponse(id: id, code: code, message: message).serialized())
    }

    /// Resolves responses internally; returns everything else for the owner.
    func receive(line: String) -> JSONRPCIncoming? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        switch JSONRPCFraming.classify(line) {
        case let .response(id, result):
            guard let entry = pending.removeValue(forKey: id) else { return nil }
            entry.timeoutTask?.cancel()
            switch result {
            case let .success(value): entry.continuation.resume(returning: value)
            case let .failure(error): entry.continuation.resume(throwing: JSONRPCError.remote(method: entry.method, error))
            }
            return nil
        case let .incoming(incoming):
            return incoming
        }
    }

    /// Fails all pending requests; later calls throw `connectionClosed`.
    func close() {
        closed = true
        let entries = pending.values
        pending.removeAll()
        for entry in entries {
            entry.timeoutTask?.cancel()
            entry.continuation.resume(throwing: JSONRPCError.connectionClosed)
        }
    }

    var pendingCount: Int { pending.count }

    private func transmit(_ line: Data, failing id: JSONRPCID) async {
        do { try await send(line) } catch { fail(id, with: JSONRPCError.connectionClosed) }
    }

    private func fail(_ id: JSONRPCID, with error: Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel()
        entry.continuation.resume(throwing: error)
    }
}
