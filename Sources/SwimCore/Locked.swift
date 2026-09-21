import Foundation

/// A synchronous cross-thread mailbox cell. The lock discipline cannot be
/// forgotten: the stored value is unreachable except through `withLock`,
/// so a one-slot hand-off between two threads (a reader queue producing,
/// the main loop draining) has no unlocked path by construction.
///
/// Deliberately NOT an actor: consumers are synchronous (the editor's
/// event loop), and synchronous waits on actor isolation deadlock. The
/// cell holds a single value for nanoseconds — no nested locks, no
/// acquisition ordering, no deadlock surface.
public final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) {
        self.value = value
    }

    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
