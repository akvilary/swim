import Testing
import SwimCore

/// MultilineInsert.cursorDelta — where the cursor lands after a bulk
/// text insert: whole lines down plus grapheme clusters (never bytes —
/// a CJK/emoji tail is one column-step) on the final line.
@Suite struct MultilineInsertTests {

    private func delta(_ text: String) -> (lines: Int, tailCols: Int) {
        MultilineInsert.cursorDelta(for: text)
    }

    @Test func singleLineStaysOnLine() {
        #expect(delta("abc") == (0, 3))
        #expect(delta("") == (0, 0))
    }

    @Test func trailingNewlineLandsAtColumnZero() {
        #expect(delta("foo\n") == (1, 0))
    }

    @Test func multilineCountsLinesAndTail() {
        #expect(delta("    foo {\n        bar\n    }") == (2, 5))
    }

    @Test func tailCountsGraphemesNotBytes() {
        #expect(delta("x\nпривет") == (1, 6))
        #expect(delta("x\n你好") == (1, 2))
        #expect(delta("x\n👍") == (1, 1))
    }

    @Test func emptyLinesCount() {
        #expect(delta("\n\n") == (2, 0))
        #expect(delta("a\n\nb") == (2, 1))
    }
}
