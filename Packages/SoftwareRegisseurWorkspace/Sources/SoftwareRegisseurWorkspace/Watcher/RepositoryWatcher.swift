import CoreServices
import Dispatch
import Foundation

/// File system change notifications for repository folders (spec E3/U4) via FSEvents
/// (`FSEventStream` on a private dispatch queue), bridged to `AsyncStream`.
///
/// FSEvents may coalesce or drop events (e.g. `kFSEventStreamEventFlagMustScanSubDirs`); consumers must
/// therefore also reconcile periodically (`RepositorySyncService`).
public final class RepositoryWatcher: @unchecked Sendable {
    public struct Change: Sendable, Hashable {
        /// Absolute real path reported by FSEvents.
        public let path: String
        /// FSEvents asked for a rescan of everything below `path` (events were dropped).
        public let requiresRescan: Bool
    }

    private final class Box: @unchecked Sendable {
        let continuation: AsyncStream<[Change]>.Continuation
        init(_ continuation: AsyncStream<[Change]>.Continuation) { self.continuation = continuation }
    }

    public let paths: [String]
    public let latency: TimeInterval
    private let queue = DispatchQueue(label: "SoftwareRegisseur.RepositoryWatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var box: Unmanaged<Box>?
    public let changes: AsyncStream<[Change]>
    private let continuation: AsyncStream<[Change]>.Continuation

    /// `paths` are resolved to real paths (FSEvents reports real paths, e.g. `/private/var/...`).
    public init(paths: [URL], latency: TimeInterval = 0.2) {
        self.paths = paths.map { FileSystem.realPath($0) }
        self.latency = latency
        (changes, continuation) = AsyncStream<[Change]>.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        lock.withLock { stream != nil }
    }

    public func start() throws {
        try lock.withLock {
            guard stream == nil else { return }
            let retained = Unmanaged.passRetained(Box(continuation))
            var context = FSEventStreamContext(
                version: 0, info: retained.toOpaque(), retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
                var changes: [Change] = []
                changes.reserveCapacity(count)
                for index in 0..<count {
                    guard let path = array[index] as? String else { continue }
                    let flags = eventFlags[index]
                    let rescan = flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                        || flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0
                    let name = (path as NSString).lastPathComponent
                    if name.hasPrefix(AtomicFileWriter.temporaryPrefix) { continue }
                    changes.append(Change(path: path, requiresRescan: rescan))
                }
                if !changes.isEmpty { box.continuation.yield(changes) }
            }
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
            )
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
            ) else {
                retained.release()
                throw WorkspaceError.ioError("FSEventStreamCreate fehlgeschlagen")
            }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                retained.release()
                throw WorkspaceError.ioError("FSEventStreamStart fehlgeschlagen")
            }
            stream = created
            box = retained
        }
    }

    /// Stops the stream; the `changes` sequence finishes.
    public func stop() {
        lock.withLock {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            // Drain pending callbacks before releasing the context.
            queue.sync {}
            box?.release()
            box = nil
        }
        continuation.finish()
    }
}
