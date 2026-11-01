import Foundation

/// Explicit environment for a child process. Nothing is inherited from the parent unless the
/// caller adds it (spec L3, Q1: no accidental leakage of secrets or `GIT_DIR`-style variables).
public struct ProcessEnvironment: Sendable, Hashable {
    public private(set) var variables: [String: String]

    /// Search path used when no other `PATH` is configured. Deliberately free of user-writable dirs.
    public static let safeSystemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public init(_ variables: [String: String] = [:]) {
        self.variables = variables
    }

    /// Empty environment.
    public static let empty = ProcessEnvironment()

    /// Minimal environment for tools run from a LaunchAgent: `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`.
    /// Values come from the user database / Foundation, not from the (possibly polluted) parent environment.
    public static func minimal(path: String = safeSystemPath) -> ProcessEnvironment {
        var env = ProcessEnvironment()
        env["PATH"] = path
        env["HOME"] = NSHomeDirectory()
        env["USER"] = NSUserName()
        env["LOGNAME"] = NSUserName()
        env["TMPDIR"] = NSTemporaryDirectory()
        return env
    }

    public subscript(name: String) -> String? {
        get { variables[name] }
        set { variables[name] = newValue }
    }

    public mutating func merge(_ other: [String: String]) {
        variables.merge(other) { _, new in new }
    }

    public func merging(_ other: [String: String]) -> ProcessEnvironment {
        var copy = self
        copy.merge(other)
        return copy
    }

    /// Validates names/values so they survive the conversion to C strings unchanged.
    func validated() throws(ProcessRunnerError) -> [String] {
        var result: [String] = []
        for (name, value) in variables.sorted(by: { $0.key < $1.key }) {
            guard !name.isEmpty, !name.contains("="), !name.utf8.contains(0), !value.utf8.contains(0) else {
                throw .invalidEnvironmentVariable(name)
            }
            result.append("\(name)=\(value)")
        }
        return result
    }
}
