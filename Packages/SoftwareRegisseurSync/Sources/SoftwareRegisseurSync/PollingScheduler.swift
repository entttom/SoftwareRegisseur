import Foundation

/// Polling settings for the macOS Agent Service (ADR-0011: explicit periodic fetch instead of push).
/// Apple publishes no polling quota (apple-platform.md §2.1), hence conservative defaults.
public struct PollingConfiguration: Sendable, Equatable {
    /// Delay after a successful poll.
    public var interval: TimeInterval
    /// Upper bound for the error backoff (a CloudKit retry-after may exceed it).
    public var maxInterval: TimeInterval
    public var backoffMultiplier: Double
    /// ± fraction applied to every delay so several hosts do not poll in lockstep.
    public var jitter: Double

    public init(interval: TimeInterval = 300, maxInterval: TimeInterval = 3_600, backoffMultiplier: Double = 2, jitter: Double = 0.2) {
        self.interval = max(interval, 1)
        self.maxInterval = max(maxInterval, self.interval)
        self.backoffMultiplier = max(backoffMultiplier, 1)
        self.jitter = min(max(jitter, 0), 0.5)
    }
}

public enum PollDecision: Sendable, Equatable {
    case wait(TimeInterval)
    /// Account unavailable / needs a user decision: no polling until `resume()`.
    case pauseUntilResumed
}

/// Pure backoff computation (exponential with jitter, honours CloudKit retry-after).
public struct PollingBackoff: Sendable, Equatable {
    public let configuration: PollingConfiguration
    public private(set) var consecutiveFailures = 0

    public init(configuration: PollingConfiguration) {
        self.configuration = configuration
    }

    /// - Parameters:
    ///   - unitRandom: value in `0...1` (0.5 = no jitter).
    ///   - now: reference time for `.deferred(until:)`.
    public mutating func next(after result: SyncRunResult, unitRandom: Double, now: Date) -> PollDecision {
        switch result {
        case .completed, .coalesced:
            consecutiveFailures = 0
            return .wait(jittered(configuration.interval, unitRandom))
        case .paused:
            return .pauseUntilResumed
        case let .deferred(until):
            return .wait(max(until.timeIntervalSince(now), 1))
        case let .failed(failure):
            consecutiveFailures += 1
            let exponent = Double(min(consecutiveFailures, 30))
            let base = min(configuration.interval * pow(configuration.backoffMultiplier, exponent), configuration.maxInterval)
            let delay = min(jittered(base, unitRandom), configuration.maxInterval)
            return .wait(max(delay, failure.retryAfter ?? 0))
        }
    }

    public mutating func reset() { consecutiveFailures = 0 }

    func jittered(_ value: TimeInterval, _ unitRandom: Double) -> TimeInterval {
        let unit = min(max(unitRandom, 0), 1)
        return value * (1 + configuration.jitter * (unit * 2 - 1))
    }
}

/// Runs `syncNow(reason: .poll)` periodically in the macOS Agent Service. Also call `resume()` after
/// wake, network return or an account sign-in (apple-platform.md §2.1).
public actor PollingScheduler {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let target: any SyncTriggering
    private var backoff: PollingBackoff
    private let sleep: Sleep
    private let random: @Sendable () -> Double
    private let now: @Sendable () -> Date
    private var loop: Task<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var resumeRequested = false
    /// Decisions taken so far (diagnostics, tests).
    public private(set) var decisions: [PollDecision] = []

    public init(
        target: any SyncTriggering,
        configuration: PollingConfiguration = PollingConfiguration(),
        sleep: @escaping Sleep = { seconds in try await Task.sleep(for: .seconds(seconds)) },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.target = target
        self.backoff = PollingBackoff(configuration: configuration)
        self.sleep = sleep
        self.random = random
        self.now = now
    }

    public var isRunning: Bool { loop != nil }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    /// Ends a pause (account available again, wake, network back) and resets the error backoff.
    public func resume() {
        backoff.reset()
        if let continuation = resumeContinuation {
            resumeContinuation = nil
            continuation.resume()
        } else {
            resumeRequested = true
        }
    }

    /// Completes when the loop has ended (after `stop()` or a throwing sleep).
    public func waitUntilStopped() async {
        await loop?.value
    }

    private func run() async {
        pollLoop: while !Task.isCancelled {
            let result = await target.syncNow(reason: .poll)
            if Task.isCancelled { break pollLoop }
            let decision = backoff.next(after: result, unitRandom: random(), now: now())
            decisions.append(decision)
            switch decision {
            case let .wait(seconds):
                do {
                    try await sleep(seconds)
                } catch {
                    break pollLoop
                }
            case .pauseUntilResumed:
                await waitForResume()
            }
            if Task.isCancelled { break }
        }
    }

    private func waitForResume() async {
        if resumeRequested {
            resumeRequested = false
            return
        }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }
}
