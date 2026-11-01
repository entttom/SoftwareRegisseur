import Darwin
import Foundation
import SoftwareRegisseurDomain

/// Kept for source compatibility: `AgentSession` itself exposes `processIdentifier` and
/// `processGroupIdentifier` since v4; the orchestrator reads them from every session.
public protocol AgentProcessIdentifying: Sendable {
    var processIdentifier: Int32? { get async }
}

/// Process facts for lock reconciliation and crash recovery (spec L1, A21).
public protocol ProcessInspecting: Sendable {
    /// `running` if the PID exists and (when given) started at `startedAt`; PID reuse counts as not running.
    func observe(pid: Int32, startedAt: Date?) -> ProcessObservation
    /// Whether any process has its current directory inside `directory` (agents run with the worktree as cwd).
    func observeProcesses(inside directory: URL) -> ProcessObservation
    func startTime(of pid: Int32) -> Date?
    /// SIGTERM to the process group – only on an explicit user request.
    func terminateProcessGroup(_ pid: Int32) -> Bool
    /// Whether any process of the group is alive. `unknown` lets the caller fall back to a cwd scan.
    func observeProcessGroup(_ processGroup: Int32) -> ProcessObservation
}

extension ProcessInspecting {
    public func observeProcessGroup(_ processGroup: Int32) -> ProcessObservation { .unknown }
}

/// libproc-based inspector for the logged-in user's processes.
public struct DarwinProcessInspector: ProcessInspecting {
    public init() {}

    public func observe(pid: Int32, startedAt: Date?) -> ProcessObservation {
        guard pid > 0 else { return .notRunning }
        if kill(pid, 0) != 0 {
            switch errno {
            case ESRCH: return .notRunning
            case EPERM: break // exists, owned by someone else
            default: return .unknown
            }
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return kill(pid, 0) == 0 ? .running : .unknown
        }
        if info.pbi_status == UInt32(SZOMB) { return .notRunning }
        if let startedAt {
            let actual = Self.date(info)
            if abs(actual.timeIntervalSince(startedAt)) > 2 { return .notRunning }
        }
        return .running
    }

    public func observeProcesses(inside directory: URL) -> ProcessObservation {
        // realpath keeps `/private/var/...` like the kernel's cwd (URL symlink resolution strips `/private`).
        let raw = directory.path(percentEncoded: false)
        var target = realpath(raw, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? raw
        while target.count > 1, target.hasSuffix("/") { target.removeLast() }
        let prefix = target + "/"
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return .unknown }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return .unknown }
        let own = getpid()
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 && pid != own {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if cwd == target || cwd.hasPrefix(prefix) { return .running }
        }
        return .notRunning
    }

    public func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Self.date(info)
    }

    /// `kill(-pgid, 0)`: succeeds while any member of the group exists (EPERM: exists, other owner).
    public func observeProcessGroup(_ processGroup: Int32) -> ProcessObservation {
        guard processGroup > 1 else { return .unknown }
        if kill(-processGroup, 0) == 0 { return .running }
        switch errno {
        case ESRCH: return .notRunning
        case EPERM: return .running
        default: return .unknown
        }
    }

    public func terminateProcessGroup(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(-pid, SIGTERM) == 0 || kill(pid, SIGTERM) == 0
    }

    private static func date(_ info: proc_bsdinfo) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}
