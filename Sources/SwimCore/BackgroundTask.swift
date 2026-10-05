import Foundation

/// A restartable one-slot result mailbox for snapshot-style background
/// work: `start` schedules work on a background thread, the poll-side
/// `consume()` drains the finished result exactly once.
///
/// Restart semantics — the newest request wins, and eras never mix:
///
/// - `start` immediately discards any unconsumed result of previous
///   work: a value the main loop has not drained yet is stale by
///   definition once newer work is requested. Consumers observe
///   results of the latest `start` lineage only — the observed
///   sequence never steps backwards.
/// - A `start` issued while work is running never runs concurrently:
///   it replaces any earlier queued request (bursts coalesce into the
///   latest one), and when the running work finishes, its result is
///   dropped in favour of running the queued request. At most one
///   worker thread exists at any moment, so a late completion of
///   superseded work physically cannot clobber a fresher result — the
///   race the naive one-slot mailbox had.
///
/// This is snapshot semantics — the right shape for refresh-style
/// pipelines (git status, diffs, search, stats). Callers that must not
/// lose a result (the terminal's command output) cannot overlap starts
/// and serialize them at the call site instead: the terminal UI blocks
/// submission while a command is running.
public final class BackgroundTask<T>: @unchecked Sendable {
    private struct State {
        var running = false
        var pending: (@Sendable () -> T)?
        var result: T?
        var done = false
    }
    private let state = Locked(State())

    public init() {}

    public func start(_ work: @escaping @Sendable () -> T) {
        var runNow: (@Sendable () -> T)?
        state.withLock { state in
            state.result = nil
            state.done = false
            if state.running {
                state.pending = work
            } else {
                state.running = true
                runNow = work
            }
        }
        if let work = runNow {
            spawn(work)
        }
    }

    public func consume() -> T? {
        state.withLock { state in
            guard state.done else { return nil }
            state.done = false
            let value = state.result
            state.result = nil
            return value
        }
    }

    /// Publishes `result` unless a newer request superseded the
    /// finished work — then the result is dropped and the latest
    /// queued request is returned to run next. `running` stays true
    /// across the hand-off, preserving the single-worker invariant.
    private func finish(with result: T) -> (@Sendable () -> T)? {
        state.withLock { state in
            if let next = state.pending {
                state.pending = nil
                return next
            }
            state.result = result
            state.done = true
            state.running = false
            return nil
        }
    }

    /// The worker: runs the given work, then whatever superseded it,
    /// all on one thread — the hand-off in `finish` keeps `running`
    /// true, so no second worker can be spawned mid-chain.
    private func spawn(_ work: @escaping @Sendable () -> T) {
        Thread { [weak self] in
            var current = work
            while true {
                let result = current()
                guard let self, let next = self.finish(with: result) else { return }
                current = next
            }
        }.start()
    }
}
