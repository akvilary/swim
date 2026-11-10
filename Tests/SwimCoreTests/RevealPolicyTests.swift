import Testing
@testable import SwimCore

/// The two vertical reveal doctrines (RevealPolicy). Edge clamp: a
/// visible cursor decides nothing, an invisible one pulls the view the
/// minimum needed. Jump reveal: the target parks at ~1/3 from the top,
/// clamped at both buffer edges; a degenerate window decides nothing
/// (top of file).
struct RevealPolicyTests {

    // MARK: - edgeClamp

    /// A cursor anywhere INSIDE the window — not a single row of movement.
    @Test func edgeClampVisibleStays() {
        #expect(RevealPolicy.edgeClamp(cursorLine: 5, scrollY: 5, contentHeight: 30) == 5)
        #expect(RevealPolicy.edgeClamp(cursorLine: 15, scrollY: 5, contentHeight: 30) == 5)
        #expect(RevealPolicy.edgeClamp(cursorLine: 34, scrollY: 5, contentHeight: 30) == 5)
    }

    /// Above the window — the cursor becomes the top row.
    @Test func edgeClampAboveWindow() {
        #expect(RevealPolicy.edgeClamp(cursorLine: 2, scrollY: 5, contentHeight: 30) == 2)
        #expect(RevealPolicy.edgeClamp(cursorLine: 0, scrollY: 5, contentHeight: 30) == 0)
    }

    /// Below the window — the cursor becomes the bottom row.
    @Test func edgeClampBelowWindow() {
        // 40 >= 5 + 30 → 40 - 30 + 1
        #expect(RevealPolicy.edgeClamp(cursorLine: 40, scrollY: 5, contentHeight: 30) == 11)
        #expect(RevealPolicy.edgeClamp(cursorLine: 35, scrollY: 5, contentHeight: 30) == 6)
    }

    /// A degenerate height (a window not yet laid out) decides nothing.
    @Test func edgeClampDegenerateDecidesNothing() {
        #expect(RevealPolicy.edgeClamp(cursorLine: 100, scrollY: 7, contentHeight: 0) == 7)
        #expect(RevealPolicy.edgeClamp(cursorLine: 0, scrollY: 3, contentHeight: -5) == 3)
    }

    // MARK: - jumpScrollY

    /// The doctrine itself: the target sits at contentHeight/3 from
    /// the top (integer floor — slightly above the exact third).
    @Test func jumpRevealAtThird() {
        #expect(RevealPolicy.jumpScrollY(cursorLine: 60, lineCount: 100, contentHeight: 30) == 50)
        #expect(RevealPolicy.jumpScrollY(cursorLine: 60, lineCount: 100, contentHeight: 25) == 52)
        #expect(RevealPolicy.jumpScrollY(cursorLine: 60, lineCount: 100, contentHeight: 3) == 59)
    }

    /// Near the top of the file — parks at the first line.
    @Test func jumpRevealTopClamp() {
        #expect(RevealPolicy.jumpScrollY(cursorLine: 0, lineCount: 100, contentHeight: 30) == 0)
        #expect(RevealPolicy.jumpScrollY(cursorLine: 5, lineCount: 100, contentHeight: 30) == 0)
        #expect(RevealPolicy.jumpScrollY(cursorLine: 10, lineCount: 100, contentHeight: 30) == 0)
    }

    /// Near the end — the last screenful; the cursor may sit below 1/3.
    @Test func jumpRevealEofClamp() {
        #expect(RevealPolicy.jumpScrollY(cursorLine: 99, lineCount: 100, contentHeight: 30) == 70)
        #expect(RevealPolicy.jumpScrollY(cursorLine: 95, lineCount: 100, contentHeight: 30) == 70)
    }

    /// A file shorter than the window — no scrolling past the content.
    @Test func jumpRevealShortFile() {
        #expect(RevealPolicy.jumpScrollY(cursorLine: 8, lineCount: 10, contentHeight: 30) == 0)
        #expect(RevealPolicy.jumpScrollY(cursorLine: 9, lineCount: 10, contentHeight: 30) == 0)
        #expect(RevealPolicy.jumpScrollY(cursorLine: 0, lineCount: 0, contentHeight: 30) == 0)
    }

    /// A degenerate height yields 0 — matching ensureCursorVisible's
    /// degenerate reset, so a pre-layout jump corrupts nothing.
    @Test func jumpRevealDegenerate() {
        #expect(RevealPolicy.jumpScrollY(cursorLine: 50, lineCount: 100, contentHeight: 0) == 0)
        #expect(RevealPolicy.jumpScrollY(cursorLine: 50, lineCount: 100, contentHeight: -2) == 0)
    }

    /// The invariant every consumer relies on: the offset is legal and
    /// the (valid) cursor is visible after the reveal — for any height,
    /// including the tiny ones where 1/3 floors to the top row.
    @Test func jumpRevealAlwaysShowsValidCursor() {
        for h in 1...40 {
            for line in 0..<100 {
                let s = RevealPolicy.jumpScrollY(cursorLine: line, lineCount: 100, contentHeight: h)
                #expect(s >= 0)
                #expect(s <= max(0, 100 - h))
                #expect(line >= s)
                #expect(line < s + h)
            }
        }
    }
}
