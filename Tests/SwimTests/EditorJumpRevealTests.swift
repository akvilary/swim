import SwimCore
import Testing
@testable import Swim

/// The jump-reveal doctrine through the real window: goToPosition parks
/// the target at ~1/3 of the content height, clamped at both buffer
/// edges; ensureCursorVisible keeps the minimal edge clamp for motions.
/// Geometry 80×31, no header plate → contentHeight 31, 1/3 floor 10.
struct EditorJumpRevealTests {

    @Test func goToPositionRevealsAtThird() {
        let w = makeTestEditor(lineCount: 100)
        w.goToPosition(line: 60, colUtf16: 0)
        #expect(w.cursorLine == 60)
        #expect(w.scrollY == 50)   // 60 - 31/3
    }

    @Test func goToPositionClampsAtTopOfFile() {
        let w = makeTestEditor(lineCount: 100)
        w.goToPosition(line: 5, colUtf16: 0)
        #expect(w.cursorLine == 5)
        #expect(w.scrollY == 0)
    }

    @Test func goToPositionClampsAtEof() {
        let w = makeTestEditor(lineCount: 100)
        w.goToPosition(line: 99, colUtf16: 0)
        #expect(w.cursorLine == 99)
        #expect(w.scrollY == 69)   // 100 - 31
    }

    @Test func goToPositionShortFileParksAtTop() {
        let w = makeTestEditor(lineCount: 10)
        w.goToPosition(line: 9, colUtf16: 0)
        #expect(w.scrollY == 0)
    }

    /// A 0×0 window (pre-layout) corrupts nothing: the cursor lands,
    /// the scroll stays at the top — the pre-layout commit prefill
    /// relies on this.
    @Test func goToPositionDegenerateWindow() {
        let w = makeTestEditor(lineCount: 100)
        w.width = 0
        w.height = 0
        w.goToPosition(line: 60, colUtf16: 0)
        #expect(w.cursorLine == 60)
        #expect(w.scrollY == 0)
        #expect(w.scrollX == 0)
    }

    /// The column clamps to the line — a stale/out-of-range UTF-16
    /// column never leaks into the cursor.
    @Test func goToPositionClampsColumn() {
        let w = makeTestEditor(lineCount: 100)
        w.goToPosition(line: 0, colUtf16: 10_000)
        #expect(w.cursorCol <= w.buffer!.lineCharLength(line: 0))
    }

    /// The motions' doctrine is unchanged: the view moves only to pull
    /// the cursor back inside (both edges), and not a row otherwise.
    @Test func ensureCursorVisibleEdgeClamp() {
        let w = makeTestEditor(lineCount: 100)
        w.cursorLine = 50
        w.ensureCursorVisible()          // below → bottom row
        #expect(w.scrollY == 20)         // 50 - 31 + 1
        w.cursorLine = 5
        w.ensureCursorVisible()          // above → top row
        #expect(w.scrollY == 5)
        w.cursorLine = 10
        w.ensureCursorVisible()          // visible → stays
        #expect(w.scrollY == 5)
    }

    /// Window.clampedScroll (the lists) and the editor run the SAME
    /// edge-clamp law — one doctrine, no drift.
    @Test func clampedScrollDelegatesToRevealPolicy() {
        for scroll in [0, 3, 10, 40] {
            for idx in [0, 2, 3, 9, 10, 11, 12, 25, 60] {
                #expect(Window.clampedScroll(selectedIndex: idx, scrollOffset: scroll, visibleCount: 10)
                        == RevealPolicy.edgeClamp(cursorLine: idx, scrollY: scroll, contentHeight: 10))
            }
        }
        #expect(Window.clampedScroll(selectedIndex: 5, scrollOffset: 2, visibleCount: 0) == 2)
    }
}
