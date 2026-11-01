import Foundation

/// German body section headings of a request file (spec F3).
public enum RequestSection: String, Sendable, Hashable, CaseIterable {
    case description = "Beschreibung"
    case problem = "Problem"
    case goal = "Ziel"
    case acceptanceCriteria = "Akzeptanzkriterien"
    case technicalNotes = "Technische Hinweise"
    case testNotes = "Testhinweise"
    case references = "Referenzen"

    /// Sections always written for new requests; the rest are omitted when empty.
    public var isAlwaysRendered: Bool {
        switch self {
        case .description, .problem, .goal, .acceptanceCriteria: true
        case .technicalNotes, .testNotes, .references: false
        }
    }
}

public enum RequestField {
    public static let id = "id"
    public static let uuid = "uuid"
    public static let type = "type"
    public static let status = "status"
    public static let title = "title"
    public static let createdAt = "createdAt"
    public static let updatedAt = "updatedAt"
    public static let priority = "priority"
    public static let labels = "labels"
    public static let dependsOn = "dependsOn"
    public static let agentJobIds = "agentJobIds"
    public static let reviewState = "reviewState"

    /// Fields with a typed representation in `RequestMetadata`, in spec F3 order.
    public static let known: [String] = [
        id, uuid, type, status, title, createdAt, updatedAt, priority, labels, dependsOn, agentJobIds, reviewState,
    ]
}

public struct RequestDiagnostic: Sendable, Hashable {
    public enum Severity: Sendable, Hashable { case error, warning }

    public enum Code: Sendable, Hashable {
        case frontmatter(FrontmatterDiagnostic)
        case missingField(String)
        case invalidValue(field: String, value: String)
        /// e.g. a list where a scalar is expected.
        case wrongValueKind(field: String)
        case idPrefixMismatch(id: String, type: String)
    }

    public var severity: Severity
    public var code: Code

    public init(_ severity: Severity, _ code: Code) {
        self.severity = severity
        self.code = code
    }
}

/// Typed view of the request frontmatter (spec F3). Raw strings are kept next to typed values so invalid
/// input is reported, not lost; unknown keys are listed in `unknownFields`.
public struct RequestMetadata: Sendable, Hashable {
    public var id: HumanID?
    public var rawID: String?
    public var uuid: UUID?
    public var type: RequestType?
    public var rawType: String?
    public var status: WorkItemStatus?
    public var rawStatus: String?
    public var title: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var priority: RequestPriority?
    public var rawPriority: String?
    public var labels: [String]
    public var dependsOn: [String]
    public var agentJobIds: [String]
    public var reviewState: String?
    /// Keys not in `RequestField.known`, in file order, with their values.
    public var unknownFields: [FrontmatterMappingEntry]
}

/// A request Markdown file: lossless frontmatter + body sections, typed metadata and validation.
public struct RequestDocument: Sendable, Hashable {
    public var frontmatter: FrontmatterDocument

    public init(text: String) {
        frontmatter = FrontmatterDocument(text: text)
    }

    public init(data: Data) throws(FrontmatterError) {
        frontmatter = try FrontmatterDocument(data: data)
    }

    public var text: String { frontmatter.text }
    public var data: Data { frontmatter.data }

    public var sections: MarkdownSections {
        get { MarkdownSections(parsing: frontmatter.body) }
        set { frontmatter.body = newValue.text }
    }

    public func sectionContent(_ section: RequestSection) -> String? {
        sections.content(of: section.rawValue)
    }

    /// Replaces one section's content (or appends the section); user sections stay untouched.
    public mutating func setSectionContent(_ content: String, for heading: String) {
        var current = sections
        current.setContent(content, of: heading)
        sections = current
    }

    // MARK: Typed read + validation

    public var metadata: RequestMetadata { parse().metadata }
    public var diagnostics: [RequestDiagnostic] { parse().diagnostics }

    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    private func parse() -> (metadata: RequestMetadata, diagnostics: [RequestDiagnostic]) {
        var diagnostics: [RequestDiagnostic] = frontmatter.diagnostics.map {
            RequestDiagnostic(.error, .frontmatter($0))
        }
        let values = frontmatter.values

        func scalar(_ key: String, required: RequestDiagnostic.Severity?) -> String? {
            switch values[key] {
            case let .scalar(value)?:
                return value
            case nil, .null?:
                if let required { diagnostics.append(RequestDiagnostic(required, .missingField(key))) }
                return nil
            default:
                diagnostics.append(RequestDiagnostic(.error, .wrongValueKind(field: key)))
                return nil
            }
        }

        func list(_ key: String) -> [String] {
            switch values[key] {
            case nil, .null?: return []
            case let value?:
                if let strings = value.stringList { return strings }
                diagnostics.append(RequestDiagnostic(.error, .wrongValueKind(field: key)))
                return []
            }
        }

        func invalid(_ key: String, _ value: String, _ severity: RequestDiagnostic.Severity = .error) {
            diagnostics.append(RequestDiagnostic(severity, .invalidValue(field: key, value: value)))
        }

        // ADR-0018: a file written by the host always has an ID; missing IDs are reported as warning.
        let rawID = scalar(RequestField.id, required: .warning)
        let id = rawID.flatMap(HumanID.init)
        if let rawID, id == nil { invalid(RequestField.id, rawID) }

        let rawUUID = scalar(RequestField.uuid, required: .error)
        let uuid = rawUUID.flatMap { UUID(uuidString: $0.trimmingWhitespace()) }
        if let rawUUID, uuid == nil { invalid(RequestField.uuid, rawUUID) }

        let rawType = scalar(RequestField.type, required: .error)
        let type = rawType.flatMap(RequestType.init(rawValue:))
        if let rawType, type == nil { invalid(RequestField.type, rawType) }
        if let id, let type, id.prefix != type.idPrefix {
            diagnostics.append(RequestDiagnostic(.warning, .idPrefixMismatch(id: id.description, type: type.rawValue)))
        }

        let rawStatus = scalar(RequestField.status, required: .error)
        let status = rawStatus.flatMap(WorkItemStatus.init(rawValue:))
        if let rawStatus, status == nil { invalid(RequestField.status, rawStatus) }

        let title = scalar(RequestField.title, required: .error)
        if let title, title.trimmingWhitespace().isEmpty { invalid(RequestField.title, title) }

        let rawCreated = scalar(RequestField.createdAt, required: .error)
        let createdAt = rawCreated.flatMap(RequestTimestamp.parse)
        if let rawCreated, createdAt == nil { invalid(RequestField.createdAt, rawCreated) }

        let rawUpdated = scalar(RequestField.updatedAt, required: .warning)
        let updatedAt = rawUpdated.flatMap(RequestTimestamp.parse)
        if let rawUpdated, updatedAt == nil { invalid(RequestField.updatedAt, rawUpdated) }

        let rawPriority = scalar(RequestField.priority, required: nil)
        let priority = rawPriority.flatMap(RequestPriority.init(rawValue:))
        if let rawPriority, priority == nil { invalid(RequestField.priority, rawPriority, .warning) }

        let metadata = RequestMetadata(
            id: id, rawID: rawID, uuid: uuid, type: type, rawType: rawType, status: status, rawStatus: rawStatus,
            title: title, createdAt: createdAt, updatedAt: updatedAt, priority: priority, rawPriority: rawPriority,
            labels: list(RequestField.labels), dependsOn: list(RequestField.dependsOn),
            agentJobIds: list(RequestField.agentJobIds),
            reviewState: scalar(RequestField.reviewState, required: nil),
            unknownFields: frontmatter.keys.filter { !RequestField.known.contains($0) }.map {
                FrontmatterMappingEntry(key: $0, value: values[$0] ?? .null)
            }
        )
        return (metadata, diagnostics)
    }

    // MARK: Surgical updates

    /// Status change touching only the `status` and `updatedAt` lines (spec F3/F5).
    public mutating func setStatus(_ status: WorkItemStatus, updatedAt: Date, timeZone: TimeZone) throws(FrontmatterError) {
        try frontmatter.setScalar(key: RequestField.status, value: status.rawValue)
        try touch(updatedAt: updatedAt, timeZone: timeZone)
    }

    public mutating func setTitle(_ title: String, updatedAt: Date, timeZone: TimeZone) throws(FrontmatterError) {
        try frontmatter.setScalar(key: RequestField.title, value: title)
        try touch(updatedAt: updatedAt, timeZone: timeZone)
    }

    public mutating func touch(updatedAt: Date, timeZone: TimeZone) throws(FrontmatterError) {
        try frontmatter.setScalar(key: RequestField.updatedAt,
                                  value: RequestTimestamp.format(updatedAt, timeZone: timeZone))
    }
}
