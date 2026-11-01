import CloudKit
import Foundation
@testable import SoftwareRegisseurSync
import Synchronization
import Testing

/// Scripted sync target for the scheduler loop.
final class ScriptedTarget: SyncTriggering {
    private let state: Mutex<(results: [SyncRunResult], calls: Int)>

    init(_ results: [SyncRunResult]) {
        state = Mutex((results, 0))
    }

    var calls: Int { state.withLock { $0.calls } }

    func syncNow(reason: SyncReason) async -> SyncRunResult {
        #expect(reason == .poll)
        return state.withLock { state in
            state.calls += 1
            return state.results.isEmpty ? .completed(SyncRunReport()) : state.results.removeFirst()
        }
    }
}

@Suite("Polling")
struct PollingSchedulerTests {
    let configuration = PollingConfiguration(interval: 300, maxInterval: 3_600, backoffMultiplier: 2, jitter: 0.2)
    let failure = SyncRunResult.failed(SyncFailure(message: "Keine Verbindung", code: .networkUnavailable, retryAfter: nil))

    func seconds(_ decision: PollDecision) -> TimeInterval? {
        if case let .wait(value) = decision { value } else { nil }
    }

    @Test func backoffStaysWithinBounds() {
        for unit in stride(from: 0.0, through: 1.0, by: 0.05) {
            var backoff = PollingBackoff(configuration: configuration)
            let success = seconds(backoff.next(after: .completed(SyncRunReport()), unitRandom: unit, now: t0))!
            #expect(success >= 240 && success <= 360)

            var previousUpper = 0.0
            for failures in 1...12 {
                let delay = seconds(backoff.next(after: failure, unitRandom: unit, now: t0))!
                let nominal = min(300 * pow(2, Double(failures)), 3_600)
                #expect(delay >= nominal * 0.8 - 0.001, "failure \(failures)")
                #expect(delay <= min(nominal * 1.2, 3_600) + 0.001, "failure \(failures)")
                #expect(delay <= 3_600)
                previousUpper = max(previousUpper, delay)
            }
            #expect(backoff.consecutiveFailures == 12)
            // Success resets the backoff.
            let reset = seconds(backoff.next(after: .completed(SyncRunReport()), unitRandom: unit, now: t0))!
            #expect(reset <= 360)
            #expect(backoff.consecutiveFailures == 0)
        }
    }

    @Test func retryAfterAndDeferralAreHonoured() {
        var backoff = PollingBackoff(configuration: configuration)
        let rateLimited = SyncRunResult.failed(SyncFailure(message: "", code: .requestRateLimited, retryAfter: 5_000))
        #expect(seconds(backoff.next(after: rateLimited, unitRandom: 0, now: t0)) == 5_000)
        #expect(seconds(backoff.next(after: .deferred(until: t0.addingTimeInterval(42)), unitRandom: 1, now: t0)) == 42)
        #expect(backoff.next(after: .paused(.accountUnavailable), unitRandom: 0.5, now: t0) == .pauseUntilResumed)
    }

    @Test func schedulerPausesWhileAccountUnavailableAndResumes() async throws {
        let target = ScriptedTarget([.completed(SyncRunReport()), failure, .paused(.accountUnavailable)])
        let sleeps = Mutex<[TimeInterval]>([])
        let scheduler = PollingScheduler(
            target: target, configuration: configuration,
            sleep: { seconds in
                let count = sleeps.withLock { $0.append(seconds); return $0.count }
                if count >= 4 { throw CancellationError() }
            },
            random: { 0.5 }
        )
        await scheduler.start()
        // Wait until the loop reaches the account pause (3 polls).
        while target.calls < 3 { await Task.yield() }
        while await scheduler.decisions.count < 3 { await Task.yield() }
        #expect(await scheduler.decisions == [.wait(300), .wait(600), .pauseUntilResumed])
        #expect(target.calls == 3)

        await scheduler.resume()
        await scheduler.waitUntilStopped()
        #expect(target.calls == 5)
        #expect(sleeps.withLock { $0 } == [300, 600, 300, 300])
    }
}
