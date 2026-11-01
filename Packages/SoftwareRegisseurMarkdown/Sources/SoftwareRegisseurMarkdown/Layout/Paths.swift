import Foundation

public enum RelativePathError: Error, Sendable, Hashable {
    case empty
    case absolute
    case parentTraversal
    case currentDirectoryComponent
    case emptyComponent
    case homeDirectory
    case invalidCharacter(String)
}

/// Validated repository-relative path (spec E2/F2: no traversal, no absolute paths, no empty components).
/// A single trailing "/" is tolerated; "." alone denotes the repository root.
public struct RelativePath: Sendable, Hashable, Codable, CustomStringConvertible {
    public let components: [String]

    public static let root = RelativePath(validatedComponents: [])

    public init(_ string: String) throws(RelativePathError) {
        if string == "." {
            components = []
            return
        }
        guard !string.isEmpty else { throw .empty }
        if string.hasPrefix("/") { throw .absolute }
        if string.hasPrefix("~") { throw .homeDirectory }
        for scalar in string.unicodeScalars {
            if scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F {
                throw .invalidCharacter(String(scalar))
            }
        }
        var raw = string
        if raw.hasSuffix("/") { raw.removeLast() }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty { throw .emptyComponent }
            if part == ".." { throw .parentTraversal }
            if part == "." { throw .currentDirectoryComponent }
        }
        components = parts
    }

    private init(validatedComponents: [String]) {
        components = validatedComponents
    }

    public var isRoot: Bool { components.isEmpty }

    /// "docs/adr" (no trailing slash; "." for root).
    public var string: String { isRoot ? "." : components.joined(separator: "/") }

    /// "docs/adr/" for display in agent instructions (spec G example).
    public var directoryString: String { isRoot ? "./" : string + "/" }

    public var description: String { string }

    public var lastComponent: String? { components.last }

    public var parent: RelativePath {
        RelativePath(validatedComponents: Array(components.dropLast()))
    }

    public func appending(_ other: RelativePath) -> RelativePath {
        RelativePath(validatedComponents: components + other.components)
    }

    /// Appends one validated file/folder name.
    public func appending(component: String) throws(RelativePathError) -> RelativePath {
        let path = try RelativePath(component)
        guard path.components.count == 1 else { throw .invalidCharacter("/") }
        return appending(path)
    }

    public func hasPrefix(_ other: RelativePath) -> Bool {
        components.starts(with: other.components)
    }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        do {
            self = try RelativePath(string)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid relative path '\(string)': \(error)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

/// Slug from a title (spec F2 file names): lowercase, German transliteration, other diacritics folded,
/// non-alphanumerics collapsed to "-", at most `maxLength` characters, no leading/trailing "-".
public enum Slug {
    public static let defaultMaxLength = 60

    public static func make(from title: String, maxLength: Int = defaultMaxLength) -> String {
        var text = title.lowercased()
        for (umlaut, replacement) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss"), ("ẞ", "ss")] {
            text = text.replacingOccurrences(of: umlaut, with: replacement)
        }
        text = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = ""
        var pendingDash = false
        for scalar in text.unicodeScalars {
            let isAlnum = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            if isAlnum {
                if pendingDash, !slug.isEmpty { slug += "-" }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        guard slug.count > maxLength else { return slug }
        var truncated = String(slug.prefix(maxLength))
        // Prefer cutting at a word boundary when one exists in the second half.
        if slug[slug.index(slug.startIndex, offsetBy: maxLength)] != "-",
           let lastDash = truncated.lastIndex(of: "-"),
           truncated.distance(from: truncated.startIndex, to: lastDash) >= maxLength / 2 {
            truncated = String(truncated[..<lastDash])
        }
        while truncated.hasSuffix("-") { truncated.removeLast() }
        return truncated
    }
}

/// `<HUMANID>-<slug>.md` (spec F2).
public enum RequestFileName {
    public static func make(id: HumanID, title: String, maxSlugLength: Int = Slug.defaultMaxLength) -> String {
        let slug = Slug.make(from: title, maxLength: maxSlugLength)
        return slug.isEmpty ? "\(id).md" : "\(id)-\(slug).md"
    }

    /// Parses `FR-0001-some-title.md` → (FR-0001, "some-title"). Returns nil for other names.
    public static func parse(_ fileName: String) -> (id: HumanID, slug: String)? {
        guard let match = fileName.wholeMatch(of: /([A-Z]+-[0-9]{1,9})(?:-(.*))?\.md/),
              let id = HumanID(String(match.1)) else { return nil }
        return (id, match.2.map(String.init) ?? "")
    }
}
