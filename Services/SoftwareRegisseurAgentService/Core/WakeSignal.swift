import Foundation
import Synchronization

/// Weckt eine wartende Schleife vorzeitig (Sync-Ergebnis, IPC-Befehl, Aufwachen aus dem Ruhezustand).
///
/// Ein Signal ohne wartende Schleife bleibt gespeichert und beendet die nächste Wartezeit sofort,
/// damit kein Anlass zwischen zwei Durchläufen verloren geht. Genau ein Wartender zur Zeit.
final class WakeSignal: Sendable {
    private struct State {
        var pending = false
        var waiter: CheckedContinuation<Void, Never>?
        var timeout: Task<Void, Never>?
        var generation: UInt64 = 0
    }

    private let state = Mutex(State())

    func signal() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.waiter else {
                state.pending = true
                return nil
            }
            state.waiter = nil
            state.timeout?.cancel()
            state.timeout = nil
            return waiter
        }
        waiter?.resume()
    }

    /// Wartet bis zum nächsten Signal, höchstens `timeout`. Kehrt bei Task-Abbruch sofort zurück.
    func wait(timeout: Duration) async {
        guard timeout > .zero else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let immediate = state.withLock { state -> Bool in
                    if state.pending || Task.isCancelled {
                        state.pending = false
                        return true
                    }
                    state.generation &+= 1
                    let generation = state.generation
                    state.waiter = continuation
                    state.timeout = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        self?.expire(generation)
                    }
                    return false
                }
                if immediate { continuation.resume() }
            }
        } onCancel: {
            self.expire(nil)
        }
    }

    private func expire(_ generation: UInt64?) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.waiter, generation == nil || generation == state.generation else { return nil }
            state.waiter = nil
            state.timeout?.cancel()
            state.timeout = nil
            return waiter
        }
        waiter?.resume()
    }
}
