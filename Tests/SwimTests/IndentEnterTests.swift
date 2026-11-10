import Testing
@testable import Swim

/// Enter's indent plan through the real window. The plan's inputs are
/// computed BEFORE the split: the tail right of the cursor reaches
/// IndentEngine as `after` — before the fix the code inserted "\n"
/// first and read an already-split first half, so `after` was always
/// empty and the closer branches were dead from their only caller.
/// The plain branch keeps its exact pre-fix behavior
/// (fullLine/baseIndent stay measured from the FIRST HALF — a split
/// inside leading whitespace preserves the cursor's column, a split
/// before a trailing "{" adds no level). [No Name] geometry:
/// shiftWidth 4, tabWidth 4.
struct IndentEnterTests {

    /// A window over synthetic content (one line, or lines joined by
    /// \n), the cursor placed by hand, insert mode entered for real —
    /// Enter goes through the real dispatch.
    private func makeEditor(_ content: String, line: Int = 0, col: Int) -> EditorWindow {
        let w = makeTestEditor(lineCount: 0)
        w.buffer?.insert(content, at: 0)
        w.cursorLine = line
        w.cursorCol = col
        press("i", on: w)
        return w
    }

    @Test func plainSplitMidWord() {
        let w = makeEditor("hello world", col: 5)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(0) == "hello")
        #expect(w.buffer!.getLine(1) == " world")
        #expect(w.cursorLine == 1)
        #expect(w.cursorCol == 0)
    }

    @Test func plainExtraLevelAfterTrailingBrace() {
        // Cursor at EOL of a line ending in "{" — one level deeper
        // (the pre-fix behavior, pinned as the regression baseline).
        let w = makeEditor("  foo() {", col: 9)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(0) == "  foo() {")
        #expect(w.buffer!.getLine(1) == "      ")   // 2 + 4
        #expect(w.cursorLine == 1)
        #expect(w.cursorCol == 6)
    }

    @Test func splitInsideLeadingWhitespaceKeepsColumn() {
        // The zero-drift edge: baseIndent comes from the FIRST HALF,
        // so splitting inside the indent preserves the cursor's
        // column (1 inserted + the tail's own 3 = the original 4).
        let w = makeEditor("    foo", col: 1)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(0) == " ")
        #expect(w.buffer!.getLine(1) == "    foo")
        #expect(w.cursorCol == 1)
    }

    @Test func splitBeforeTrailingBraceAddsNoLevel() {
        // The "{" moves down with the tail — the NEW line's own first
        // char is "{", not an opener left behind: no extra level
        // (fullLine is the first half, not the whole original line).
        let w = makeEditor("foo() {", col: 6)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(0) == "foo() ")
        #expect(w.buffer!.getLine(1) == "{")
        #expect(w.cursorCol == 0)
    }

    @Test func closerWithBodyOpensBodyLine() {
        // The resurrected branch: cursor before ")" of "foo()" —
        // opener scanned back on the same line (indent 2), the closer
        // drops to its own line aligned with it, a fresh body line
        // opens in between at 2+4.
        let w = makeEditor("  foo()", col: 6)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(0) == "  foo(")
        #expect(w.buffer!.getLine(1) == "      ")   // cursorIndent 2+4
        #expect(w.buffer!.getLine(2) == "  )")       // aligned with the opener
        #expect(w.cursorLine == 1)
        #expect(w.cursorCol == 6)

        // One undo action — the whole split with its two insertions.
        _ = w.handleKey(.escape)                     // → normal mode
        press("u", on: w)
        #expect(w.buffer!.lineCount == 1)
        #expect(w.buffer!.getLine(0) == "  foo()")
    }

    @Test func closerOnlyAlignsAcrossLines() {
        // The opener sits on the line ABOVE — the balance walk
        // crosses the line boundary (the split line's tail must not
        // tip the scan for the closer AT the cursor).
        let w = makeEditor("  foo(a\n  b)", line: 1, col: 3)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(0) == "  foo(a")
        #expect(w.buffer!.getLine(1) == "  b")
        #expect(w.buffer!.getLine(2) == "  )")       // aligned with "  foo("
        #expect(w.cursorLine == 2)
        #expect(w.cursorCol == 2)                    // leadingSpaces of "  )"
    }

    @Test func splitAtEolStaysPlain() {
        let w = makeEditor("abc", col: 3)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(0) == "abc")
        #expect(w.buffer!.getLine(1) == "")
        #expect(w.cursorCol == 0)
    }
}
