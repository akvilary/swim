import Testing
import SwimCore

/// NormalMotion — motion destinations and operator-range
/// normalization: vim categories (exclusive/inclusive/linewise), ordering
/// of backward-going ones, the "exclusive end at start of line → end of
/// the previous line" adjustment, clamps and empty ranges.
@Suite struct NormalMotionTests {
    private func dest(_ m: NormalMotion, _ text: String,
                      line: Int = 0, col: Int = 0, count: Int? = nil) -> NormalMotion.Destination {
        NormalMotion.destination(of: m, in: PieceTable(text: text), line: line, col: col, count: count)
    }

    private func range(_ text: String, cursorLine: Int, cursorCol: Int,
                       _ m: NormalMotion, count: Int? = nil) -> NormalMotion.OperatorRange? {
        let buf = PieceTable(text: text)
        let d = NormalMotion.destination(of: m, in: buf, line: cursorLine, col: cursorCol, count: count)
        return NormalMotion.operatorRange(cursorLine: cursorLine, cursorCol: cursorCol,
                                          destination: d, in: buf)
    }

    // MARK: - Destinations

    @Test func leftRightClamp() {
        #expect(dest(.left, "hello", col: 2).col == 1)
        #expect(dest(.left, "hello", col: 1, count: 5).col == 0)
        #expect(dest(.right, "hello", col: 1).col == 2)
        #expect(dest(.right, "hello", col: 3, count: 9).col == 4)
        #expect(dest(.right, "hello", col: 4, count: 2).col == 4)
        // one-past-end (after a vertical move) — no motion
        #expect(dest(.right, "hello", col: 5, count: 1).col == 5)
    }

    @Test func upDownClamp() {
        #expect(dest(.down, "a\nb\nc", line: 1, col: 1).line == 2)
        #expect(dest(.down, "a\nb\nc", line: 1, col: 1, count: 9).line == 2)
        #expect(dest(.up, "a\nb\nc", line: 2).line == 1)
        #expect(dest(.up, "a\nb\nc", line: 1, count: 9).line == 0)
    }

    @Test func wordMotionsWithCount() {
        #expect(dest(.wordForward, "aa bb cc dd", col: 0).col == 3)
        #expect(dest(.wordForward, "aa bb cc dd", col: 0, count: 3).col == 9)
        #expect(dest(.wordBackward, "aa bb cc dd", col: 9).col == 6)
        #expect(dest(.wordEnd, "aa bb cc dd", col: 4).col == 7) // tail of bb → end of cc
        // across lines
        #expect(dest(.wordForward, "foo\nbar", col: 0) == NormalMotion.Destination(line: 1, col: 0, kind: .exclusive))
    }

    @Test func endOfLineWithCountSpansLines() {
        #expect(dest(.endOfLine, "foo\nbar", col: 0).col == 2)
        let d = dest(.endOfLine, "foo\nbar", col: 0, count: 2)
        #expect(d.line == 1 && d.col == 2)
    }

    @Test func fileStartFileEndWithCount() {
        let text = "a\nb\nc"
        // Without a count — defaults (vim G → last, gg → first); the count
        // picks the 1-based line: 1G is the first one too
        #expect(dest(.fileEnd, text).line == 2)
        #expect(dest(.fileEnd, text, count: 2).line == 1)
        #expect(dest(.fileEnd, text, count: 1).line == 0)
        #expect(dest(.fileStart, text, line: 2).line == 0)
        #expect(dest(.fileStart, text, line: 2, count: 2).line == 1)
        // Defensive clamp of the public API: count ≤ 0 never comes from
        // real input, but it must not become a -1 line either
        #expect(dest(.fileEnd, text, count: 0).line == 0)
        #expect(dest(.fileStart, text, count: -3).line == 0)
    }

    // MARK: - Linewise ranges

    @Test func linewiseOrderedBothDirections() {
        #expect(range("a\nb\nc", cursorLine: 1, cursorCol: 1, .fileEnd)
                == .linewise(lower: 1, upper: 2))
        #expect(range("a\nb\nc", cursorLine: 1, cursorCol: 1, .fileStart)
                == .linewise(lower: 0, upper: 1))
        #expect(range("a\nb\nc", cursorLine: 1, cursorCol: 1, .down)
                == .linewise(lower: 1, upper: 2))
        #expect(range("a\nb\nc", cursorLine: 1, cursorCol: 1, .up)
                == .linewise(lower: 0, upper: 1))
        // dj on the last line — clamps to a single-line range (like dd)
        #expect(range("a\nb\nc", cursorLine: 2, cursorCol: 0, .down)
                == .linewise(lower: 2, upper: 2))
        // d2j — three lines (cursor + two down)
        #expect(range("a\nb\nc\nd", cursorLine: 1, cursorCol: 0, .down, count: 2)
                == .linewise(lower: 1, upper: 3))
    }

    // MARK: - Charwise ranges

    @Test func exclusiveForward() {
        // dw on the first word: "foo " (with the trailing space, like vim)
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .wordForward)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 4))
        // d0 — from the cursor to the start of the line
        #expect(range("foo bar", cursorLine: 0, cursorCol: 5, .bol)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 5))
    }

    @Test func inclusivePlusOne() {
        // de — the word without a space; d$ — the whole line without the terminator
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .wordEnd)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 3))
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .endOfLine)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 7))
        // dl — one character (l exclusive, vim: dl == x)
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .right)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 1))
        // d3l — three characters
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .right, count: 3)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 3))
    }

    @Test func backwardOrdered() {
        // db from the middle of a word: b goes to the start of the CURRENT word,
        // exclusive up to the cursor — "b" is deleted (vim)
        #expect(range("foo bar", cursorLine: 0, cursorCol: 5, .wordBackward)
                == .charwise(startLine: 0, startCol: 4, endLine: 0, endCol: 5))
        // db from a space before a word — to the start of the previous word
        #expect(range("foo bar", cursorLine: 0, cursorCol: 3, .wordBackward)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 3))
        // dh — one character to the left (exclusive)
        #expect(range("foo bar", cursorLine: 0, cursorCol: 3, .left)
                == .charwise(startLine: 0, startCol: 2, endLine: 0, endCol: 3))
    }

    // MARK: - Adjustment: exclusive end at start of line

    @Test func dwAcrossNewlineKeepsIt() {
        // dw on the last word of a line: the destination is the next line's BOL,
        // the end moves to the current line's EOL: the newline survives
        #expect(range("foo bar\nbaz", cursorLine: 0, cursorCol: 4, .wordForward)
                == .charwise(startLine: 0, startCol: 4, endLine: 0, endCol: 7))
    }

    @Test func dbAtBOLKeepsNewline() {
        // db at BOL: the end (cursor) in column 0 → vim :h exclusive
        // rule 1 — the end moves to the end of the previous line,
        // the range does NOT include the terminator: the word is deleted,
        // the lines are not joined
        #expect(range("foo bar\nbaz", cursorLine: 1, cursorCol: 0, .wordBackward)
                == .charwise(startLine: 0, startCol: 4, endLine: 0, endCol: 7))
    }

    @Test func dwOnLastWordOfBuffer() {
        // Buffer tail with a newline: unclamped w reaches the phantom
        // line, the adjustment moves the end back to EOL — the whole word
        #expect(range("ab cd\n", cursorLine: 0, cursorCol: 3, .wordForward)
                == .charwise(startLine: 0, startCol: 3, endLine: 0, endCol: 5))
        #expect(range("ab cd", cursorLine: 0, cursorCol: 3, .wordForward)
                == .charwise(startLine: 0, startCol: 3, endLine: 0, endCol: 5))
    }

    // MARK: - Empty ranges

    @Test func emptyRangesAreNil() {
        // dh in column 0
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .left) == nil)
        // dl at one-past-end (parity with x)
        #expect(range("foo bar", cursorLine: 0, cursorCol: 7, .right) == nil)
        // d0 in column 0
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .bol) == nil)
        // db on the buffer's very first word
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .wordBackward) == nil)
        // dw on the last word of a single-line buffer without a newline —
        // NOT empty: the word is deleted whole (unclamped + adjustment
        // not needed here, the end is already past the word)
        #expect(range("foo", cursorLine: 0, cursorCol: 0, .wordForward)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 3))
    }

    @Test func multilineCharwiseViaCountedDollar() {
        // d2$ — from the cursor to the end of the next line (including the
        // first line's newline: the byte range runs straight through)
        #expect(range("foo\nbar", cursorLine: 0, cursorCol: 0, .endOfLine, count: 2)
                == .charwise(startLine: 0, startCol: 0, endLine: 1, endCol: 3))
    }
}
