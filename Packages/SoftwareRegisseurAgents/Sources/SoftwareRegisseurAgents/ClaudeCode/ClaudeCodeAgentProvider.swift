import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurProcess

/// Claude Code headless via stream-json (ADR-0021, spec J5, spike claude-code). Remote Control is not a
/// start mode yet: ADR-0010 is `proposed` until the real tests T3–T6 pass.
public struct ClaudeCodeAgentProvider: AgentProvider {
    public struct Configuration: Sendable {
        public var hostId: HostID
        public var locator: ExecutableLocator
        public var executableOverride: URL?
        public var detectionWorkingDirectory: URL
        public var commandTimeout: Duration
        /// Timeout for the `initialize` control handshake (runs the user's SessionStart hooks).
        public var catalogTimeout: Duration
        /// Oldest version verified in the spike (2.1.212).
        public var minimumVerifiedVersion: SemanticVersion
        public var environmentPassthrough: [String: String]
        public var now: @Sendable () -> Date

        public init(
            hostId: HostID,
            locator: ExecutableLocator? = nil,
            executableOverride: URL? = nil,
            detectionWorkingDirectory: URL = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory),
            commandTimeout: Duration = .seconds(20),
            catalogTimeout: Duration = .seconds(45),
            minimumVerifiedVersion: SemanticVersion = SemanticVersion(2, 1, 212),
            environmentPassthrough: [String: String] = [:],
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.hostId = hostId
            // Native installer location first (spike §2.1), then the default LaunchAgent-safe dirs.
            let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
            self.locator = locator ?? ExecutableLocator(userDirectories: [home.appending(path: ".local/bin", directoryHint: .isDirectory)])
            self.executableOverride = executableOverride
            self.detectionWorkingDirectory = detectionWorkingDirectory
            self.commandTimeout = commandTimeout
            self.catalogTimeout = catalogTimeout
            self.minimumVerifiedVersion = minimumVerifiedVersion
            self.environmentPassthrough = environmentPassthrough
            self.now = now
        }
    }

    /// Native `AGENTS.md` support (spike claude-code §1, row 10).
    public static let nativeAgentsMarkdownVersion = SemanticVersion(2, 1, 277)

    public let providerId = ProviderID.claudeCode
    public let displayName = "Claude Code"
    public let isFullyImplemented = true
    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: Detection (spec J1, J5)

    public func detect(previous: AgentCapability?) async -> AgentDetectionReport {
        let date = configuration.now()
        var diagnostics: [AgentDiagnostic] = []
        let (located, locateDiagnostics) = AgentDetectionSupport.locate(
            name: "claude", override: configuration.executableOverride, locator: configuration.locator)
        diagnostics += locateDiagnostics
        guard let located else {
            diagnostics.append(AgentDiagnostic(code: "claude.notInstalled", severity: .blocking,
                                               message: "Claude Code wurde nicht gefunden."))
            return report(date: date, previous: previous, executable: nil, version: nil, installed: false,
                          authenticated: false, catalog: nil, diagnostics: diagnostics, toolchain: nil)
        }

        var pathDirectories = [located.candidate.url.deletingLastPathComponent()]
        if located.scriptInterpreter == "node" {
            // npm-global install: the shim needs `node` on PATH.
            if let node = try? configuration.locator.locate("node").preferred {
                pathDirectories.insert(node.url.deletingLastPathComponent(), at: 0)
            } else {
                diagnostics.append(AgentDiagnostic(code: "claude.nodeMissing", severity: .blocking,
                                                   message: "Claude Code ist als npm-Paket installiert, aber `node` fehlt im Suchpfad."))
            }
        }
        pathDirectories += configuration.locator.searchDirectories
        let environment = AgentEnvironment.make(pathDirectories: pathDirectories, passthrough: configuration.environmentPassthrough)
        var toolchain = AgentToolchain(executableURL: located.candidate.url, environment: environment, version: nil)

        var version: SemanticVersion?
        if !diagnostics.hasBlocking {
            let result = await AgentDetectionSupport.run(toolchain, ClaudeCodeCommand.versionArguments(), timeout: configuration.commandTimeout)
            if let result, result.succeeded { version = ClaudeCodeCommand.parseVersion(result.standardOutputString) }
            if version == nil {
                diagnostics.append(AgentDiagnostic(code: "claude.versionUnknown", severity: .blocking,
                                                   message: "`claude --version` lieferte keine Version."))
            }
        }
        toolchain = AgentToolchain(executableURL: located.candidate.url, environment: environment, version: version)
        if let version {
            if version < configuration.minimumVerifiedVersion {
                diagnostics.append(AgentDiagnostic(
                    code: "claude.versionUnverified", severity: .blocking,
                    message: String(localized: "Claude Code \(version) ist älter als die verifizierte Version \(configuration.minimumVerifiedVersion).", bundle: .module)
                ))
            }
            // SR-SEC-03: jobs start with `--setting-sources user --strict-mcp-config`; the installed
            // CLI must list both flags, otherwise it is not used (no silent fallback).
            if !diagnostics.hasBlocking {
                let help = await AgentDetectionSupport.run(toolchain, ClaudeCodeCommand.helpArguments(), timeout: configuration.commandTimeout)
                let missing = ClaudeCodeCommand.missingIsolationFlags(inHelp: help?.standardOutputString ?? "")
                if !missing.isEmpty {
                    diagnostics.append(AgentDiagnostic(
                        code: "claude.isolationFlagsMissing", severity: .blocking,
                        message: String(localized: "Claude Code \(version) kennt \(missing.joined(separator: ", ")) nicht. Ohne diese Optionen würde die Projektkonfiguration des Repositorys (Hooks, Freigaben, MCP-Server) geladen; bitte Claude Code aktualisieren.", bundle: .module)
                    ))
                }
            }
            if version < Self.nativeAgentsMarkdownVersion {
                diagnostics.append(AgentDiagnostic(
                    code: "claude.agentsMarkdownImport", severity: .info,
                    message: "Claude Code \(version) liest AGENTS.md erst ab \(Self.nativeAgentsMarkdownVersion) selbst; CLAUDE.md muss `@AGENTS.md` importieren."
                ))
            }
        }

        var authenticated = false
        if version != nil {
            let status = await AgentDetectionSupport.run(toolchain, ClaudeCodeCommand.authStatusArguments(), timeout: configuration.commandTimeout)
            let auth = Self.parseAuthStatus(status?.standardOutputString ?? "")
            authenticated = auth.loggedIn == true
            if !authenticated {
                diagnostics.append(AgentDiagnostic(
                    code: "claude.notAuthenticated", severity: .blocking,
                    message: "Claude Code ist nicht angemeldet oder die Anmeldung ist abgelaufen (`claude auth login` im Terminal)."
                ))
            }
            if let provider = auth.apiProvider, provider != "firstParty" {
                diagnostics.append(AgentDiagnostic(code: "claude.apiProvider", severity: .info,
                                                   message: String(localized: "Claude Code nutzt den Anbieter „\(provider)“; Remote Control ist damit nicht möglich.", bundle: .module)))
            }
        }

        var catalog: [ClaudeStreamParser.CatalogEntry]?
        if version != nil, !diagnostics.contains(where: { $0.code == "claude.versionUnverified" }) {
            do {
                catalog = try await fetchCatalog(toolchain: toolchain)
            } catch {
                // ADR-0021: no built-in fallback list; explicit-model jobs are blocked.
                diagnostics.append(AgentDiagnostic(
                    code: "claude.catalogFailed", severity: .warning,
                    message: String(localized: "Modellkatalog (initialize) nicht abrufbar; nur Anbieterstandard möglich, Jobs mit explizitem Modell werden blockiert. \(AgentDetectionSupport.redactedTail(String(describing: error), maxLength: 200))", bundle: .module)
                ))
            }
        }
        diagnostics.append(AgentDiagnostic(
            code: "claude.remoteControlPending", severity: .info,
            message: String(localized: "Remote Control ist noch nicht als Startmodus freigegeben (ADR-0010 proposed, reale Tests T3–T6 ausstehend); Jobs laufen headless mit Freigaben über Software Regisseur.", bundle: .module)
        ))
        return report(date: date, previous: previous, executable: located.candidate.url, version: version, installed: true,
                      authenticated: authenticated, catalog: catalog, diagnostics: diagnostics, toolchain: toolchain)
    }

    struct AuthStatus: Hashable {
        var loggedIn: Bool?
        var authMethod: String?
        var apiProvider: String?
    }

    /// `claude auth status --json` → `loggedIn`, `authMethod`, `apiProvider` (spike 1c). Only these
    /// fields are read; account details are ignored.
    static func parseAuthStatus(_ output: String) -> AuthStatus {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let json = try? JSONValue.parse(String(output[start...end])) else { return AuthStatus() }
        return AuthStatus(loggedIn: json["loggedIn"]?.boolValue, authMethod: json["authMethod"]?.stringValue,
                          apiProvider: json["apiProvider"]?.stringValue)
    }

    /// SDK `initialize` control request over stream-json, without a prompt (spike 4b).
    func fetchCatalog(toolchain: AgentToolchain) async throws -> [ClaudeStreamParser.CatalogEntry] {
        let process = try InteractiveProcess(
            executableURL: toolchain.executableURL,
            arguments: ClaudeCodeCommand.catalogArguments(),
            workingDirectory: configuration.detectionWorkingDirectory,
            environment: toolchain.environment
        )
        let requestId = "sr-initialize-\(UUID().uuidString.lowercased())"
        defer {
            process.closeStandardInput()
            let process = process
            Task {
                try? await Task.sleep(for: .seconds(5))
                process.terminate(gracePeriod: .seconds(1))
            }
        }
        try await process.writeLine(ClaudeCodeInput.controlRequest(id: requestId, subtype: "initialize").serialized())
        let timeout = configuration.catalogTimeout
        let response: JSONValue = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                var stderr = BoundedLineBuffer(capacity: 10)
                for await output in process.output {
                    switch output {
                    case let .standardOutput(line):
                        if case let .controlResponse(id, success, response, error) = ClaudeStreamParser.parse(line), id == requestId {
                            guard success, let response else {
                                throw JSONRPCError.invalidResponse(method: "initialize", error ?? "Fehlerantwort")
                            }
                            return response
                        }
                    case let .standardError(line):
                        stderr.append(line)
                    case let .exited(status):
                        throw JSONRPCError.invalidResponse(method: "initialize", "Prozess beendet (\(status.exitStatus.map(String.init) ?? "Signal")) \(stderr.text)")
                    }
                }
                throw JSONRPCError.connectionClosed
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw JSONRPCError.timeout(method: "initialize")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        return try ClaudeStreamParser.decodeCatalog(response)
    }

    private func report(
        date: Date, previous: AgentCapability?, executable: URL?, version: SemanticVersion?, installed: Bool,
        authenticated: Bool, catalog: [ClaudeStreamParser.CatalogEntry]?, diagnostics: [AgentDiagnostic],
        toolchain: AgentToolchain?
    ) -> AgentDetectionReport {
        let models = ClaudeStreamParser.capabilities(from: catalog ?? [], at: date)
        let supportsModels = !models.isEmpty
        let supportsEffort = models.contains { !$0.supportedEffortIds.isEmpty }
        let runnable = isFullyImplemented && installed && authenticated && version != nil && !diagnostics.hasBlocking
        let versionText = version?.description ?? ""
        var resolutions: [ModelID: String] = [:]
        for entry in catalog ?? [] {
            if let id = ModelID(rawValue: entry.value), let resolved = entry.resolvedModel { resolutions[id] = resolved }
        }
        let capability = AgentCapability(
            providerId: providerId,
            displayName: displayName,
            hostId: configuration.hostId,
            executablePath: executable?.path(percentEncoded: false),
            appBundleId: nil,
            version: versionText,
            installed: installed,
            authenticated: authenticated,
            runnable: runnable,
            supportsRemote: false,
            supportsAutomaticStart: runnable,
            supportsResume: false,
            supportsApprovals: true,
            supportsModelSelection: supportsModels,
            supportsEffortSelection: supportsEffort,
            modelCatalog: models,
            defaultModelId: models.first { $0.modelId.rawValue == "default" }?.modelId,
            capabilitySource: .sdk,
            capabilityRevision: CapabilityRevision.next(previous: previous, version: versionText, catalog: models,
                                                        flags: [supportsModels, supportsEffort, runnable]),
            lastChecked: date,
            detectionTimestamp: date,
            sessionLinkFormat: nil,
            diagnostic: diagnostics.filter { $0.severity != .info }.joinedMessage
        )
        return AgentDetectionReport(capability: capability, diagnostics: diagnostics, toolchain: toolchain,
                                    modelResolutions: resolutions)
    }

    // MARK: Launch (spec J3, ADR-0006)

    public func prepareLaunch(snapshot: ConfigurationSnapshot, previous: AgentCapability?) async -> LaunchPreparation {
        Self.plan(snapshot: snapshot, report: await detect(previous: previous))
    }

    static func plan(snapshot: ConfigurationSnapshot, report: AgentDetectionReport) -> LaunchPreparation {
        let capability = report.capability
        switch LaunchValidator.validate(snapshot: snapshot, capability: capability) {
        case let .notRunnable(reason): return .notRunnable(reason: reason, capability: capability)
        case let .needsConfiguration(issues): return .needsConfiguration(issues, capability: capability)
        case .ok: break
        }
        guard let toolchain = report.toolchain else {
            return .notRunnable(reason: "Claude-Code-Programm nicht gefunden.", capability: capability)
        }
        let model = snapshot.resolvedModel.modelID
        let effort = snapshot.resolvedEffort.isAuto ? nil : snapshot.resolvedEffort
        return .ready(AgentLaunchPlan(
            providerId: .claudeCode, snapshot: snapshot, capability: capability,
            modelArgument: model, effortArgument: effort,
            resolvedModelName: model.flatMap { report.modelResolutions[$0] },
            toolchain: toolchain
        ))
    }

    public func startSession(plan: AgentLaunchPlan, request: AgentSessionRequest) async throws -> any AgentSession {
        guard plan.providerId == providerId else {
            throw AgentSessionError.providerMismatch(expected: providerId, found: plan.providerId)
        }
        try CodexAgentProvider.checkWorkingDirectory(request.workingDirectory)
        return try await ClaudeCodeSession.start(plan: plan, request: request, now: configuration.now)
    }
}
