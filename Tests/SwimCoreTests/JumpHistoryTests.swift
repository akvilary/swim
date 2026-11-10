import Testing
@testable import SwimCore

/// The gb stack: LIFO, capped (the oldest dropped), pop-to-empty → nil.
struct JumpHistoryTests {

    @Test func lifoOrder() {
        var h = JumpHistory()
        h.push(.init(path: "a", line: 1, colUtf16: 2))
        h.push(.init(path: "b", line: 3, colUtf16: 4))
        #expect(h.pop() == .init(path: "b", line: 3, colUtf16: 4))
        #expect(h.pop() == .init(path: "a", line: 1, colUtf16: 2))
        #expect(h.pop() == nil)
    }

    /// Over the limit the OLDEST entries go — the recent jumps matter.
    @Test func capDropsOldest() {
        var h = JumpHistory(limit: 3)
        for i in 0..<5 { h.push(.init(path: "f\(i)", line: i, colUtf16: 0)) }
        #expect(h.pop() == .init(path: "f4", line: 4, colUtf16: 0))
        #expect(h.pop() == .init(path: "f3", line: 3, colUtf16: 0))
        #expect(h.pop() == .init(path: "f2", line: 2, colUtf16: 0))
        #expect(h.pop() == nil)
    }

    @Test func popEmptyIsNil() {
        var h = JumpHistory()
        #expect(h.pop() == nil)
    }

    /// A push after pops starts a fresh branch (the old tail stays
    /// gone) — the unwind never resurrects popped entries.
    @Test func pushAfterPopBranches() {
        var h = JumpHistory()
        h.push(.init(path: "a", line: 0, colUtf16: 0))
        _ = h.pop()
        h.push(.init(path: "b", line: 1, colUtf16: 1))
        #expect(h.pop() == .init(path: "b", line: 1, colUtf16: 1))
        #expect(h.pop() == nil)
    }
}
