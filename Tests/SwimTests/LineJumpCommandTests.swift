import Testing
@testable import Swim

/// Line jumps through the real dispatch: `:N` (executeCommand) and the
/// counted `123gg` / `123G` (handleKey with the pending-count machine)
/// are ONE operation — gb snapshot, line clamp, ~1/3 reveal. The
/// uncounted gg/G keep the plain edge clamp and record nothing.
/// Geometry 80×31 → contentHeight 31, 1/3 floor 10.
struct LineJumpCommandTests {

    // MARK: - :N

    @Test func colonNRevealsAtThird() {
        let w = makeTestEditor(lineCount: 100)
        #expect(w.executeCommand("25") == true)
        #expect(w.cursorLine == 24)
        #expect(w.scrollY == 14)   // 24 - 10
    }

    @Test func colonZeroClampsToFirstLine() {
        let w = makeTestEditor(lineCount: 100)
        w.goToPosition(line: 50, colUtf16: 0)
        #expect(w.executeCommand("0") == true)
        #expect(w.cursorLine == 0)
        #expect(w.scrollY == 0)
    }

    /// Int("+5") == 5 — the same leniency as today's branch.
    @Test func colonPlusCount() {
        let w = makeTestEditor(lineCount: 100)
        #expect(w.executeCommand("+5") == true)
        #expect(w.cursorLine == 4)
    }

    /// Past the end — clamps to the last line, EOF reveal.
    @Test func colonHugeClampsToLastLine() {
        let w = makeTestEditor(lineCount: 100)
        #expect(w.executeCommand("9999") == true)
        #expect(w.cursorLine == 99)
        #expect(w.scrollY == 69)
    }

    // MARK: - counted gg / G

    @Test func countedGgRevealsAtThird() {
        let w = makeTestEditor(lineCount: 100)
        press("60gg", on: w)
        #expect(w.cursorLine == 59)
        #expect(w.scrollY == 49)   // 59 - 10
    }

    /// vim parity: NG ≡ Ngg — same line, same reveal.
    @Test func countedGMatchesCountedGg() {
        let gg = makeTestEditor(lineCount: 100)
        press("60gg", on: gg)
        let g = makeTestEditor(lineCount: 100)
        press("60G", on: g)
        #expect(g.cursorLine == gg.cursorLine)
        #expect(g.scrollY == gg.scrollY)
        #expect(g.cursorLine == 59)
        #expect(g.scrollY == 49)
    }

    @Test func countedZeroClampsToFirstLine() {
        let w = makeTestEditor(lineCount: 100)
        press("0gg", on: w)
        #expect(w.cursorLine == 0)
        #expect(w.scrollY == 0)
    }

    // MARK: - plain gg / G stay minimal

    @Test func plainGgLandsOnFirstLineAtTop() {
        let w = makeTestEditor(lineCount: 100)
        w.goToPosition(line: 50, colUtf16: 0)   // scroll the view first
        press("gg", on: w)
        #expect(w.cursorLine == 0)
        #expect(w.scrollY == 0)
    }

    @Test func plainGLandsOnLastLineAtBottomEdge() {
        let w = makeTestEditor(lineCount: 100)
        press("G", on: w)
        #expect(w.cursorLine == 99)
        #expect(w.scrollY == 69)   // the last screenful, cursor on the bottom row
    }

    /// The operator form dG/dgg is an EDIT, not a jump — it must bypass
    /// the jump machinery entirely (no snapshot, no reveal side effects
    /// on the cursor beyond the operator's own motion).
    @Test func operatorGIsNotAJump() {
        let w = makeTestEditor(lineCount: 100)
        w.cursorLine = 10
        press("dG", on: w)
        #expect(w.cursorLine == 10)              // deleted to the end, cursor stayed
        #expect(w.buffer!.lineCount == 11)       // lines 0...10 remain
        // No gb target was recorded: gb on the fresh stack reports empty.
        press("gb", on: w)
        #expect(w.lastError == "No previous position")
    }
}
