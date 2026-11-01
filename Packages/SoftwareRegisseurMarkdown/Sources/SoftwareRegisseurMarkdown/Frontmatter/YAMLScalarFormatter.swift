import Foundation

/// Quoting style for a written scalar.
public enum ScalarStyle: Sendable, Hashable {
    case plain
    case singleQuoted
    case doubleQuoted
}

/// Style for a written list.
public enum ListStyle: Sendable, Hashable {
    /// `key: [a, b]` (spec F3 example).
    case flow
    /// `key:` followed by `- item` lines.
    case block
}

/// Renders YAML scalars so the written text decodes back to exactly the given string.
public enum YAMLScalarFormatter {
    public enum Context: Sendable {
        case block
        case flow
    }

    /// How a plain scalar would be resolved by a YAML 1.1/1.2 loader.
    enum PlainKind: Equatable {
        case string, null, bool, number, timestamp
    }

    /// Renders `value` in the requested style, falling back to a safe quoted style when the requested one cannot
    /// represent it (e.g. plain text containing ": ", single quotes with control characters).
    /// `allowAmbiguousPlain` permits plain output that a loader would type as number/date/bool (e.g. `adr: 0004`).
    public static func render(
        _ value: String,
        style: ScalarStyle? = nil,
        context: Context = .block,
        allowAmbiguousPlain: Bool = false
    ) -> String {
        switch style {
        case .plain?:
            if isPlainSafe(value, context: context), allowAmbiguousPlain || plainKind(value) == .string {
                return value
            }
            return doubleQuoted(value)
        case .singleQuoted?:
            return canSingleQuote(value) ? singleQuoted(value) : doubleQuoted(value)
        case .doubleQuoted?:
            return doubleQuoted(value)
        case nil:
            if isPlainSafe(value, context: context), plainKind(value) == .string { return value }
            return doubleQuoted(value)
        }
    }

    public static func doubleQuoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\u{0}": result += "\\0"
            case "\u{85}": result += "\\N"
            case "\u{2028}": result += "\\L"
            case "\u{2029}": result += "\\P"
            default:
                if needsEscape(scalar) {
                    result += scalar.value <= 0xFF
                        ? String(format: "\\x%02X", scalar.value)
                        : String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func canSingleQuote(_ value: String) -> Bool {
        !value.unicodeScalars.contains(where: needsEscape)
    }

    private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F, 0x80...0x9F, 0xFEFF, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// Syntactic plain-scalar safety (YAML 1.2 §7.3.3, conservative subset).
    static func isPlainSafe(_ value: String, context: Context) -> Bool {
        guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last else { return false }
        if first == " " || first == "\t" || last == " " || last == "\t" { return false }
        if value.unicodeScalars.contains(where: needsEscape) { return false }
        if "-?:,[]{}#&*!|>'\"%@`".unicodeScalars.contains(first) { return false }
        if value.contains(": ") || value.contains(":\t") || value.hasSuffix(":") { return false }
        if value.contains(" #") || value.contains("\t#") { return false }
        if value.hasPrefix("---") || value.hasPrefix("...") { return false }
        if context == .flow, value.unicodeScalars.contains(where: { ",[]{}".unicodeScalars.contains($0) }) {
            return false
        }
        return true
    }

    static func isNullLiteral(_ value: String) -> Bool {
        ["", "~", "null", "Null", "NULL"].contains(value)
    }

    /// Resolution of an unquoted scalar under YAML 1.1 (superset of 1.2 core schema rules).
    static func plainKind(_ value: String) -> PlainKind {
        if isNullLiteral(value) { return .null }
        let lower = value.lowercased()
        if ["true", "false", "yes", "no", "on", "off", "y", "n"].contains(lower) { return .bool }
        if value.wholeMatch(of: /[-+]?(\.[0-9]+|[0-9][0-9_]*(\.[0-9_]*)?)([eE][-+]?[0-9]+)?/) != nil { return .number }
        if value.wholeMatch(of: /[-+]?0[xX][0-9a-fA-F_]+|[-+]?0[oO]?[0-7_]+|[-+]?0b[01_]+/) != nil { return .number }
        if value.wholeMatch(of: /[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+(\.[0-9_]*)?/) != nil { return .number }
        if [".inf", "-.inf", "+.inf", ".nan"].contains(lower) { return .number }
        if value.prefixMatch(of: /[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}/) != nil { return .timestamp }
        if value == "<<" || value == "=" { return .bool }
        return .string
    }
}
