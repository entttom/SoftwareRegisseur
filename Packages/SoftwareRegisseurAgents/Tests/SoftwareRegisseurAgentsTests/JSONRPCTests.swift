import Foundation
import Synchronization
import Testing
@testable import SoftwareRegisseurAgents

/// Captures lines the connection sends.
final class SentLines: Sendable {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    func append(_ data: Data) { storage.withLock { $0.append(String(decoding: data, as: UTF8.self)) } }

    func waitForCount(_ count: Int) async {
        for _ in 0..<500 where lines.count < count { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

@Suite("JSON-RPC framing and correlation (Codex app-server)")
struct JSONRPCTests {
    @Test func requestFramingHasNoJSONRPCMember() async throws {
        let sent = SentLines()
        let connection = JSONRPCConnection(send: { sent.append($0) })
        async let result = connection.request("model/list", params: ["limit": 100], timeout: .seconds(5))
        await sent.waitForCount(1)
        let line = try #require(sent.lines.first)
        let json = try JSONValue.parse(line)
        #expect(json["jsonrpc"] == nil)
        #expect(json["method"] == "model/list")
        #expect(json["id"] == .integer(1))
        #expect(json["params"]?["limit"] == .integer(100))
        #expect(!line.contains("\n"))
        _ = await connection.receive(line: #"{"id":1,"result":{"data":[],"nextCursor":null}}"#)
        #expect(try await result["data"] == .array([]))
    }

    @Test func outOfOrderResponsesAreCorrelatedById() async throws {
        let sent = SentLines()
        let connection = JSONRPCConnection(send: { sent.append($0) })
        async let first = connection.request("a", timeout: .seconds(5))
        async let second = connection.request("b", timeout: .seconds(5))
        await sent.waitForCount(2)
        let ids = try sent.lines.map { try JSONValue.parse($0) }
        let idForA = try #require(ids.first { $0["method"] == "a" }?["id"]?.int64Value)
        let idForB = try #require(ids.first { $0["method"] == "b" }?["id"]?.int64Value)
        _ = await connection.receive(line: #"{"id":\#(idForB),"result":"B"}"#)
        _ = await connection.receive(line: #"{"id":\#(idForA),"result":"A"}"#)
        #expect(try await first == "A")
        #expect(try await second == "B")
        #expect(await connection.pendingCount == 0)
    }

    @Test func errorResponseIsThrownAsRemoteError() async throws {
        let sent = SentLines()
        let connection = JSONRPCConnection(send: { sent.append($0) })
        let result = Task { try await connection.request("thread/start", timeout: .seconds(5)) }
        await sent.waitForCount(1)
        _ = await connection.receive(line: #"{"id":1,"error":{"code":-32600,"message":"unknown variant workspaceWrite"}}"#)
        await #expect(throws: JSONRPCError.remote(method: "thread/start", JSONRPCErrorObject(code: -32600, message: "unknown variant workspaceWrite"))) {
            try await result.value
        }
    }

    @Test func notificationsAndServerRequestsAreDelivered() async throws {
        let connection = JSONRPCConnection(send: { _ in })
        let notification = await connection.receive(line: #"{"method":"turn/started","params":{"threadId":"t"}}"#)
        #expect(notification == .notification(method: "turn/started", params: ["threadId": "t"]))
        let request = await connection.receive(line: #"{"id":0,"method":"item/fileChange/requestApproval","params":{"itemId":"i"}}"#)
        #expect(request == .request(id: .int(0), method: "item/fileChange/requestApproval", params: ["itemId": "i"]))
        let stringId = await connection.receive(line: #"{"id":"srv-7","method":"item/commandExecution/requestApproval"}"#)
        #expect(stringId == .request(id: .string("srv-7"), method: "item/commandExecution/requestApproval", params: nil))
        let garbage = await connection.receive(line: "not json")
        #expect(garbage == .invalid("not json"))
        // Responses for unknown ids are dropped, empty lines ignored.
        #expect(await connection.receive(line: #"{"id":99,"result":{}}"#) == nil)
        #expect(await connection.receive(line: "  ") == nil)
    }

    @Test func responsesToServerRequestsUseTheServerId() async throws {
        let sent = SentLines()
        let connection = JSONRPCConnection(send: { sent.append($0) })
        try await connection.respond(to: .int(0), result: ["decision": "decline"])
        try await connection.respondError(to: .string("x"), code: -32601, message: "nope")
        #expect(try JSONValue.parse(sent.lines[0]) == ["id": 0, "result": ["decision": "decline"]])
        #expect(try JSONValue.parse(sent.lines[1]) == ["id": "x", "error": ["code": -32601, "message": "nope"]])
    }

    @Test func resetCreditConsumptionIsRefusedAndNeverSent() async throws {
        let sent = SentLines()
        let connection = JSONRPCConnection(send: { sent.append($0) })
        await #expect(throws: JSONRPCError.forbiddenMethod("account/rateLimitResetCredit/consume")) {
            try await connection.request("account/rateLimitResetCredit/consume", params: [:])
        }
        await #expect(throws: JSONRPCError.forbiddenMethod("account/RateLimitResetCredit/Consume")) {
            try await connection.notify("account/RateLimitResetCredit/Consume")
        }
        #expect(JSONRPCConnection.isForbidden("account/rateLimitResetCredit/consume"))
        #expect(!JSONRPCConnection.isForbidden("account/rateLimits/read"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(sent.lines.isEmpty)
    }

    @Test func closeFailsPendingRequests() async throws {
        let connection = JSONRPCConnection(send: { _ in })
        let result = Task { try await connection.request("model/list", timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(20))
        await connection.close()
        await #expect(throws: JSONRPCError.connectionClosed) { try await result.value }
        await #expect(throws: JSONRPCError.connectionClosed) { try await connection.request("x") }
    }

    @Test func requestTimesOut() async throws {
        let connection = JSONRPCConnection(send: { _ in })
        await #expect(throws: JSONRPCError.timeout(method: "initialize")) {
            try await connection.request("initialize", timeout: .milliseconds(50))
        }
    }

    @Test func jsonValueRoundTripKeepsIntegersAndUnknownFields() throws {
        let text = #"{"a":1793363552,"b":1.5,"c":[true,null,"x"],"d":{"future":"field"}}"#
        let value = try JSONValue.parse(text)
        #expect(value["a"] == .integer(1_793_363_552))
        #expect(value["b"] == .number(1.5))
        #expect(try value.serializedString() == text)
    }
}
