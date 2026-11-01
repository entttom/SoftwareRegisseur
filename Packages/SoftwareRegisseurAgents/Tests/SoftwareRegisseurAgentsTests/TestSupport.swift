import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurProcess
@testable import SoftwareRegisseurAgents

/// Temporary directory removed on deinit.
final class TempDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        // `realpath` so paths compare equal to what child processes report (/private/var/...).
        let base = URL(filePath: canonicalPath(FileManager.default.temporaryDirectory), directoryHint: .isDirectory)
        url = base.appending(path: "sr-agents-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func directory(_ name: String) throws -> URL {
        let directory = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func writeExecutable(_ name: String, in directory: URL, content: String) throws -> URL {
        let file = directory.appending(path: name, directoryHint: .notDirectory)
        try content.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        return file
    }

    var logURL: URL { url.appending(path: "received.jsonl") }

    /// Lines the fake agent logged (every message it received, plus argv/env records).
    func loggedMessages() -> [JSONValue] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
    }

    /// Raw logged lines exactly as received on stdin.
    func loggedRawLines() -> [String] {
        guard let text = try? String(contentsOf: url.appending(path: "raw.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

enum Fixtures {
    static let hostId = HostID(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
    static let fixedDate = Date(timeIntervalSince1970: 1_793_000_000)

    static func locator(_ directories: URL...) -> ExecutableLocator {
        ExecutableLocator(userDirectories: directories, includeDefaultDirectories: false)
    }

    static func snapshot(
        provider: ProviderID, model: ModelSelection = .providerDefault, effort: EffortLevel = .auto,
        revision: Int = 1, version: String = "0.164.0"
    ) -> ConfigurationSnapshot {
        ConfigurationSnapshot(
            providerId: provider,
            requestedModel: model == .providerDefault ? nil : model,
            requestedEffort: effort.isAuto ? nil : effort,
            resolvedModel: model,
            resolvedEffort: effort,
            profileSource: ProfileSources(model: .job, effort: .job),
            capabilityRevision: revision,
            agentVersion: version,
            createdAt: fixedDate
        )
    }

    static func codexProvider(bin: URL, extra: [URL] = [], workDir: URL) -> CodexAgentProvider {
        CodexAgentProvider(configuration: .init(
            hostId: hostId,
            locator: ExecutableLocator(userDirectories: [bin] + extra, includeDefaultDirectories: false),
            desktopAppCandidates: [],
            detectionWorkingDirectory: workDir,
            commandTimeout: .seconds(20),
            requestTimeout: .seconds(20),
            now: { fixedDate }
        ))
    }

    static func claudeProvider(bin: URL, workDir: URL, environment: [String: String] = [:]) -> ClaudeCodeAgentProvider {
        ClaudeCodeAgentProvider(configuration: .init(
            hostId: hostId,
            locator: ExecutableLocator(userDirectories: [bin], includeDefaultDirectories: false),
            detectionWorkingDirectory: workDir,
            commandTimeout: .seconds(20),
            catalogTimeout: .seconds(20),
            environmentPassthrough: environment,
            now: { fixedDate }
        ))
    }
}

/// Drives a session to completion, answering approvals with `decide`.
func runSession(
    _ session: any AgentSession,
    decide: @escaping @Sendable (AgentApprovalRequest) -> AgentApprovalDecision? = { _ in .allow },
    onEvent: @escaping @Sendable (AgentSessionEvent, any AgentSession) async -> Void = { _, _ in }
) async -> [AgentSessionEvent] {
    var events: [AgentSessionEvent] = []
    for await event in session.events {
        events.append(event)
        if case let .approvalRequested(request) = event, let decision = decide(request) {
            try? await session.respond(to: request.id, with: decision)
        }
        await onEvent(event, session)
    }
    return events
}

extension Array where Element == AgentSessionEvent {
    var result: AgentSessionResult? {
        for event in self { if case let .finished(result) = event { return result } }
        return nil
    }

    var approvals: [AgentApprovalRequest] {
        compactMap { if case let .approvalRequested(request) = $0 { request } else { nil } }
    }

    var effectiveConfigurations: [EffectiveConfiguration] {
        compactMap { if case let .effectiveConfiguration(value) = $0 { value } else { nil } }
    }

    var quotaSignals: [QuotaSignal] {
        compactMap { if case let .quota(value) = $0 { value } else { nil } }
    }

    var assistantTexts: [String] {
        compactMap { if case let .assistantText(text, _) = $0 { text } else { nil } }
    }

    var sessionIds: [String] {
        compactMap { if case let .sessionIdentified(id, _) = $0 { id } else { nil } }
    }
}
