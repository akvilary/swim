import Foundation

/// An incomplete normal-mode command sequence — the vim model of the
/// grammar `[count1] operator [count2] motion`:
/// - `count` — the count BEFORE the operator (`3dd`);
/// - `op` — the armed operator d/y/c (operator-pending);
/// - `opCount` — the count AFTER the operator (`d3d`);
/// - `gPrefix` — the g-prefix of two-letter commands (`gg`/`gt`/`gT`/`gb`/`gd`).
///   Lives separately from the operator: `dgg` arms d and g at once —
///   g is part of the motion, not an operator, and must not displace it.
///
/// Discipline (a consumer invariant): the key handler EITHER explicitly
/// keeps the sequence (the `keepPending` flag at the arm point — arming
/// an operator/g-prefix, accumulating a count — an early return BEFORE
/// the defer), OR it dies in a single reset on the tail — a stray key
/// and any departure into another mode (insert/visual/command line)
/// leaves no "standing order" behind (a leak class: `d v … Esc d` → `dd`).
/// Application-level global intercepts bypass handleKey — their points
/// reset via `EditorWindow.interruptPending()`/`enterCommandMode`.
///
/// The operator and g-prefix slots are independent; there are three
/// operators: d/y/c (last-wins within the slot). The vim rule multiplies
/// the counts at consumption: `2d3d` = 6 lines.
public struct NormalPending: Equatable {
    public enum Op: Equatable {
        case d, y, c
    }

    /// The maximum count (as in vim) — protects the consumer's repeat loops.
    public static let countCap = 999_999

    public private(set) var count: Int?
    public private(set) var op: Op?
    public private(set) var opCount: Int?
    public private(set) var gPrefix = false

    public init() {}

    public var isEmpty: Bool { count == nil && opCount == nil && op == nil && !gPrefix }

    /// A count digit into the ACTIVE slot: operator armed → `opCount`
    /// (`d3d`), otherwise → `count` (`3dd`). A bare leading `0` in the
    /// active slot is not a digit (motion to beginning of line, `d0`):
    /// false with no mutations.
    @discardableResult
    public mutating func appendDigit(_ d: Int) -> Bool {
        let target = op != nil ? opCount : count
        guard d > 0 || target != nil else { return false }
        let acc = min((target ?? 0) * 10 + d, Self.countCap)
        if op != nil { opCount = acc } else { count = acc }
        return true
    }

    /// Arm an operator — replaces any previous one (last-wins).
    /// Consumption has no explicit API: the operator is read directly
    /// (`pending.op`), the slot dies in the tail defer/reset — the
    /// take pattern remains for the count and the g-prefix
    /// (takeCount/takeGPrefix, one consumption point per key).
    public mutating func arm(_ op: Op) {
        self.op = op
    }

    /// Arm / consume the g-prefix.
    public mutating func armGPrefix() { gPrefix = true }

    @discardableResult
    public mutating func takeGPrefix() -> Bool {
        guard gPrefix else { return false }
        gPrefix = false
        return true
    }

    /// The effective count: vim multiplies the counts on both sides of
    /// the operator (`2d3w` = 6); nil — no count was given at all.
    /// No fallback parameter by design: mixing a 1-based count with a
    /// value in the caller's domain (a 0-based line) is a sharp edge
    /// that has already caused an off-by-one; the domain of the
    /// fallback belongs to the caller (`?? 1`).
    public mutating func takeCount() -> Int? {
        defer {
            count = nil
            opCount = nil
        }
        switch (count, opCount) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?): return min(a * b, Self.countCap)
        }
    }

    /// Full reset (handler tail, paste interception).
    public mutating func reset() {
        count = nil
        opCount = nil
        op = nil
        gPrefix = false
    }
}
