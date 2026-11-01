import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurProcess

/// OpenAI Codex via `codex app-server` (ADR-0021, spec J4, spike codex).
public struct CodexAgentProvider: AgentProvider {
    public struct Configuration: Sendable {
        public var hostId: HostID
        public var locator: ExecutableLocator
        /// User-configured executable path (spec J1 „benutzerdefinierte Pfade“).
        public var executableOverride: URL?
        public var clientName: String
        public var clientTitle: String
        public var clientVersion: String
        /// Bundles checked for the Codex desktop app (`com.openai.codex`, spike §1).
        public var desktopAppCandidates: [URL]
        /// Neutral cwd for the detection app-server (no project config involved).
        public var detectionWorkingDirectory: URL
        public var commandTimeout: Duration
        public var requestTimeout: Duration
        /// Oldest CLI version whose protocol was verified in the spike (0.164.0).
        public var minimumVerifiedVersion: SemanticVersion
        /// Extra environment variables (filtered by `AgentEnvironment`).
        public var environmentPassthrough: [String: String]
        public var now: @Sendable () -> Date

        public init(
            hostId: HostID,
            locator: ExecutableLocator = ExecutableLocator(),
            executableOverride: URL? = nil,
            clientName: String = "software_regisseur",
            clientTitle: String = "Software Regisseur",
            clientVersion: String = "1.0.0",
            desktopAppCandidates: [URL]? = nil,
            detectionWorkingDirectory: URL = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory),
            commandTimeout: Duration = .seconds(20),
            requestTimeout: Duration = .seconds(60),
            minimumVerifiedVersion: SemanticVersion = SemanticVersion(0, 164, 0),
            environmentPassthrough: [String: String] = [:],
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.hostId = hostId
            self.locator = locator
            self.executableOverride = executableOverride
            self.clientName = clientName
            self.clientTitle = clientTitle
            self.clientVersion = clientVersion
            let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
            self.desktopAppCandidates = desktopAppCandidates ?? [
                URL(filePath: "/Applications/ChatGPT.app"), URL(filePath: "/Applications/Codex.app"),
                home.appending(path: "Applications/ChatGPT.app"), home.appending(path: "Applications/Codex.app"),
            ]
            self.detectionWorkingDirectory = detectionWorkingDirectory
            self.commandTimeout = commandTimeout
            self.requestTimeout = requestTimeout
            self.minimumVerifiedVersion = minimumVerifiedVersion
            self.environmentPassthrough = environmentPassthrough
            self.now = now
        }
    }

    public static let desktopBundleIdentifier = "com.openai.codex"

    public let providerId = ProviderID.codex
    public let displayName = "OpenAI Codex"
    public let isFullyImplemented = true
    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    var clientInfo: CodexProtocol.ClientInfo {
        CodexProtocol.ClientInfo(name: configuration.clientName, title: configuration.clientTitle, version: configuration.clientVersion)
    }

    // MARK: Detection (spec J1)

    public func detect(previous: AgentCapability?) async -> AgentDetectionReport {
        let date = configuration.now()
        var diagnostics: [AgentDiagnostic] = []
        let appBundleId = detectDesktopApp()
        if appBundleId != nil {
            diagnostics.append(AgentDiagnostic(
                code: "codex.desktopApp", severity: .info,
                message: "Codex-Desktop-App (\(Self.desktopBundleIdentifier)) gefunden; Übernahme laufender Jobs in die App ist noch nicht verifiziert (ADR-0010, Test O6)."
            ))
        }

        let (located, locateDiagnostics) = AgentDetectionSupport.locate(
            name: "codex", override: configuration.executableOverride, locator: configuration.locator)
        diagnostics += locateDiagnostics
        guard let located else {
            diagnostics.append(AgentDiagnostic(code: "codex.notInstalled", severity: .blocking,
                                               message: "Codex-CLI wurde nicht gefunden."))
            return report(date: date, previous: previous, executable: nil, appBundleId: appBundleId, version: nil,
                          installed: false, authenticated: false, catalog: nil, diagnostics: diagnostics, toolchain: nil)
        }

        // npm shim `#!/usr/bin/env node` needs `node` on the child PATH (spike §1).
        var pathDirectories: [URL] = []
        if located.scriptInterpreter == "node" {
            if let node = try? configuration.locator.locate("node").preferred {
                pathDirectories.append(node.url.deletingLastPathComponent())
            } else {
                diagnostics.append(AgentDiagnostic(
                    code: "codex.nodeMissing", severity: .blocking,
                    message: String(localized: "Codex ist als npm-Paket installiert, aber `node` wurde in den Suchpfaden nicht gefunden.", bundle: .module)
                ))
            }
        }
        pathDirectories.append(located.candidate.url.deletingLastPathComponent())
        if let resolved = located.candidate.resolvedURL { pathDirectories.append(resolved.deletingLastPathComponent()) }
        pathDirectories += configuration.locator.searchDirectories
        let environment = AgentEnvironment.make(pathDirectories: pathDirectories, passthrough: configuration.environmentPassthrough)

        var toolchain = AgentToolchain(executableURL: located.candidate.url, environment: environment, version: nil)
        var version: SemanticVersion?
        if !diagnostics.hasBlocking {
            let result = await AgentDetectionSupport.run(toolchain, ["--version"], timeout: configuration.commandTimeout)
            if let result, result.succeeded {
                version = Self.parseVersion(result.standardOutputString)
            }
            if version == nil {
                diagnostics.append(AgentDiagnostic(
                    code: "codex.versionUnknown", severity: .blocking,
                    message: "`codex --version` lieferte keine Version. \(AgentDetectionSupport.redactedTail(result?.standardErrorString ?? ""))"
                ))
            }
        }
        toolchain = AgentToolchain(executableURL: located.candidate.url, environment: environment, version: version)
        if let version, version < configuration.minimumVerifiedVersion {
            diagnostics.append(AgentDiagnostic(
                code: "codex.versionUnverified", severity: .blocking,
                message: String(localized: "Codex \(version) ist älter als die verifizierte Version \(configuration.minimumVerifiedVersion); bitte aktualisieren.", bundle: .module)
            ))
        }

        var authenticated = false
        if version != nil {
            // Exit 0 = credentials present (spike §1); credential files are never read.
            let login = await AgentDetectionSupport.run(toolchain, ["login", "status"], timeout: configuration.commandTimeout)
            authenticated = login?.succeeded ?? false
            if !authenticated {
                diagnostics.append(AgentDiagnostic(code: "codex.notAuthenticated", severity: .blocking,
                                                   message: String(localized: "Codex ist nicht angemeldet (`codex login`).", bundle: .module)))
            }
        }

        var catalog: [CodexProtocol.Model]?
        if version != nil, !diagnostics.contains(where: { $0.code == "codex.versionUnverified" }) {
            do {
                catalog = try await fetchCatalog(toolchain: toolchain)
            } catch {
                diagnostics.append(AgentDiagnostic(
                    code: "codex.catalogFailed", severity: .blocking,
                    message: String(localized: "Modellkatalog über app-server nicht abrufbar: \(AgentDetectionSupport.redactedTail(String(describing: error)))", bundle: .module)
                ))
            }
        }
        diagnostics.append(AgentDiagnostic(
            code: "codex.mobilePending", severity: .info,
            message: String(localized: "Mobile Weiterführung in der ChatGPT-App ist nicht verifiziert; Status und Freigaben laufen über Software Regisseur (ADR-0010).", bundle: .module)
        ))
        return report(date: date, previous: previous, executable: located.candidate.url, appBundleId: appBundleId,
                      version: version, installed: true, authenticated: authenticated, catalog: catalog,
                      diagnostics: diagnostics, toolchain: toolchain)
    }

    func fetchCatalog(toolchain: AgentToolchain) async throws -> [CodexProtocol.Model] {
        let client = try CodexAppServerClient.launch(toolchain: toolchain, workingDirectory: configuration.detectionWorkingDirectory)
        do {
            try await client.initialize(clientInfo, timeout: configuration.requestTimeout)
            let models = try await client.listModels(timeout: configuration.requestTimeout)
            await client.shutdown()
            return models
        } catch {
            await client.shutdown(grace: .seconds(1))
            throw error
        }
    }

    static func parseVersion(_ output: String) -> SemanticVersion? {
        // `codex-cli 0.164.0`
        for line in output.split(separator: "\n") where line.hasPrefix("codex-cli ") {
            return SemanticVersion.firstMatch(in: String(line.dropFirst("codex-cli ".count)))
        }
        return SemanticVersion.firstMatch(in: output)
    }

    private func detectDesktopApp() -> String? {
        for url in configuration.desktopAppCandidates {
            if let bundle = Bundle(url: url), bundle.bundleIdentifier == Self.desktopBundleIdentifier {
                return Self.desktopBundleIdentifier
            }
        }
        return nil
    }

    private func report(
        date: Date, previous: AgentCapability?, executable: URL?, appBundleId: String?, version: SemanticVersion?,
        installed: Bool, authenticated: Bool, catalog: [CodexProtocol.Model]?, diagnostics: [AgentDiagnostic],
        toolchain: AgentToolchain?
    ) -> AgentDetectionReport {
        let models = CodexProtocol.capabilities(from: catalog ?? [], providerId: providerId, at: date)
        let supportsModels = !models.isEmpty
        let supportsEffort = models.contains { !$0.supportedEffortIds.isEmpty }
        let runnable = isFullyImplemented && installed && authenticated && catalog != nil && !diagnostics.hasBlocking
        let versionText = version?.description ?? ""
        let capability = AgentCapability(
            providerId: providerId,
            displayName: displayName,
            hostId: configuration.hostId,
            executablePath: executable?.path(percentEncoded: false),
            appBundleId: appBundleId,
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
            defaultModelId: catalog?.first(where: \.isDefault).flatMap { ModelID(rawValue: $0.id) },
            capabilitySource: .appServer,
            capabilityRevision: CapabilityRevision.next(previous: previous, version: versionText, catalog: models,
                                                        flags: [supportsModels, supportsEffort, runnable]),
            lastChecked: date,
            detectionTimestamp: date,
            sessionLinkFormat: nil,
            diagnostic: diagnostics.filter { $0.severity != .info }.joinedMessage
        )
        return AgentDetectionReport(capability: capability, diagnostics: diagnostics, toolchain: toolchain)
    }

    // MARK: Launch (spec J3, ADR-0006)

    public func prepareLaunch(snapshot: ConfigurationSnapshot, previous: AgentCapability?) async -> LaunchPreparation {
        let report = await detect(previous: previous)
        return Self.plan(snapshot: snapshot, report: report)
    }

    static func plan(snapshot: ConfigurationSnapshot, report: AgentDetectionReport) -> LaunchPreparation {
        let capability = report.capability
        switch LaunchValidator.validate(snapshot: snapshot, capability: capability) {
        case let .notRunnable(reason):
            return .notRunnable(reason: reason, capability: capability)
        case let .needsConfiguration(issues):
            return .needsConfiguration(issues, capability: capability)
        case .ok:
            break
        }
        guard let toolchain = report.toolchain else {
            return .notRunnable(reason: "Codex-Programm nicht gefunden.", capability: capability)
        }
        // Provider default is pinned to the catalog default so the user's config.toml cannot change it (spike §4).
        guard let modelId = snapshot.resolvedModel.modelID ?? capability.defaultModelId else {
            return .notRunnable(reason: String(localized: "Codex meldet kein Standardmodell; bitte ein Modell ausdrücklich wählen.", bundle: .module), capability: capability)
        }
        guard let model = capability.model(modelId) else {
            return .needsConfiguration([.unknownModel(modelId)], capability: capability)
        }
        let effort = snapshot.resolvedEffort.isAuto ? model.defaultEffortId : snapshot.resolvedEffort
        return .ready(AgentLaunchPlan(
            providerId: .codex, snapshot: snapshot, capability: capability,
            modelArgument: modelId, effortArgument: effort, toolchain: toolchain
        ))
    }

    public func startSession(plan: AgentLaunchPlan, request: AgentSessionRequest) async throws -> any AgentSession {
        guard plan.providerId == providerId else {
            throw AgentSessionError.providerMismatch(expected: providerId, found: plan.providerId)
        }
        try Self.checkWorkingDirectory(request.workingDirectory)
        return try CodexSession.start(plan: plan, request: request, clientInfo: clientInfo,
                                      requestTimeout: configuration.requestTimeout, now: configuration.now)
    }

    static func checkWorkingDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard url.isFileURL, path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentSessionError.invalidWorkingDirectory(path)
        }
    }
}
