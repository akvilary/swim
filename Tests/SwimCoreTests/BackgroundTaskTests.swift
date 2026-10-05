import Foundation
import Testing
@testable import SwimCore

/// Contracts of `BackgroundTask`'s restart semantics. Tests coordinate
/// through generous sleeps — the work closures run on their own
/// threads, and only the ordering between separate `start` calls is
/// asserted (single worker ⇒ deterministic hand-off).
@Suite struct BackgroundTaskTests {

    /// Drains the mailbox with a deadline so a broken publish fails
    /// the test instead of hanging it.
    private func drain<T>(_ task: BackgroundTask<T>,
                          timeout: TimeInterval = 5) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = task.consume() { return value }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    @Test func singleRunPublishesExactlyOnce() {
        let task = BackgroundTask<Int>()
        task.start { 42 }
        #expect(drain(task) == 42)
        // The slot is emptied by consume — a second drain sees nothing.
        Thread.sleep(forTimeInterval: 0.05)
        #expect(task.consume() == nil)
    }

    @Test func supersededResultIsDropped() {
        // The original race, now impossible by construction: slow old
        // work A, restart with fast B while A runs — only B may be
        // published, no matter when A completes.
        let task = BackgroundTask<String>()
        task.start {
            Thread.sleep(forTimeInterval: 0.3)
            return "stale-A"
        }
        Thread.sleep(forTimeInterval: 0.05)  // A is provably running
        task.start { "fresh-B" }
        #expect(drain(task) == "fresh-B")
        // And nothing arrives later from A either.
        Thread.sleep(forTimeInterval: 0.4)
        #expect(task.consume() == nil)
    }

    @Test func restartBurstCoalescesToLatest() {
        // A runs; B, C, D queue behind it — only the latest (D) ever
        // executes after A; B and C are dropped before starting.
        let task = BackgroundTask<Int>()
        task.start {
            Thread.sleep(forTimeInterval: 0.3)
            return 0
        }
        Thread.sleep(forTimeInterval: 0.05)
        task.start { 1 }
        task.start { 2 }
        task.start { 3 }
        #expect(drain(task) == 3)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(task.consume() == nil)
    }

    @Test func restartClearsUnconsumedStaleResult() {
        // A finished-but-unconsumed result is stale once newer work is
        // requested: the restart clears the slot synchronously, so an
        // interim consume sees nothing (loading), and the next
        // published value is the new work's — never the old one's.
        let task = BackgroundTask<String>()
        task.start { "old" }
        Thread.sleep(forTimeInterval: 0.1)  // published, unconsumed
        task.start {
            Thread.sleep(forTimeInterval: 0.05)
            return "new"
        }
        #expect(task.consume() == nil)  // cleared by the restart itself
        #expect(drain(task) == "new")
        Thread.sleep(forTimeInterval: 0.1)
        #expect(task.consume() == nil)  // nothing older resurfaces
    }

    @Test func freshStartAfterCompletionRunsImmediately() {
        // Consume clears the slot; the next start is not treated as a
        // restart — it runs and publishes on its own.
        let task = BackgroundTask<Int>()
        task.start { 1 }
        #expect(drain(task) == 1)
        task.start { 2 }
        #expect(drain(task) == 2)
    }
}
