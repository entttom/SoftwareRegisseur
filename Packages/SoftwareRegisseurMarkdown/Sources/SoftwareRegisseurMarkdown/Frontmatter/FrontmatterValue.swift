import Yams

/// Decoded value of a frontmatter key. Scalars keep their textual form (no implicit typing), so `adr: 0004`
/// reads as "0004" and `date: 2026-10-30` stays a string.
public indirect enum FrontmatterValue: Sendable, Hashable {
    case null
    case scalar(String)
    case sequence([FrontmatterValue])
    case mapping([FrontmatterMappingEntry])

    /// Scalar text, or nil for anything else.
    public var scalarString: String? {
        if case let .scalar(value) = self { return value }
        return nil
    }

    /// A sequence of scalars as strings; nil if this is not a sequence or contains non-scalars.
    public var stringList: [String]? {
        guard case let .sequence(items) = self else { return nil }
        var result: [String] = []
        for item in items {
            guard let string = item.scalarString else { return nil }
            result.append(string)
        }
        return result
    }

    public var isNull: Bool { self == .null }
}

public struct FrontmatterMappingEntry: Sendable, Hashable {
    public var key: String
    public var value: FrontmatterValue

    public init(key: String, value: FrontmatterValue) {
        self.key = key
        self.value = value
    }
}

extension FrontmatterValue {
    /// Converts a Yams node immediately into a Sendable value (Yams nodes are not Sendable).
    init(node: Node) {
        switch node {
        case let .scalar(scalar):
            if scalar.style == .plain || scalar.style == .any, YAMLScalarFormatter.isNullLiteral(scalar.string) {
                self = .null
            } else {
                self = .scalar(scalar.string)
            }
        case let .sequence(sequence):
            self = .sequence(sequence.map(FrontmatterValue.init(node:)))
        case let .mapping(mapping):
            self = .mapping(mapping.map { pair in
                FrontmatterMappingEntry(key: pair.key.scalar?.string ?? "", value: FrontmatterValue(node: pair.value))
            })
        case .alias:
            // Aliases are not used by Software Regisseur files; treat them as opaque.
            self = .null
        }
    }
}
