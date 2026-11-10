import Testing
@testable import Swim

/// `r{char}` in normal mode through the real dispatch — vim :h r
/// semantics: the count captured at the arm (`3rx`), EVERY character
/// after `r` is the replacement (a digit included — `r3` replaces
/// with "3"), the cursor left on the LAST replaced grapheme, a count
/// past the line end refused WHOLE, no register traffic, r<CR> a
/// single autoindented break through the split core shared with
/// Enter. Deliberately not vim: v_r (visual), gr/gR, CTRL-E/CTRL-Y
/// and digraphs, Ctrl+V-quoted literal CR, and `.` repeat (the app
/// has no dot command at all).
struct NormalReplaceTests {

    /// A window over synthetic content with the cursor placed by
    /// hand; keys go through the real normal-mode dispatch.
    private func makeEditor(_ content: String, col: Int = 0) -> EditorWindow {
        let w = makeTestEditor(lineCount: 0)
        w.buffer?.insert(content, at: 0)
        w.cursorCol = col
        return w
    }

    @Test func replacesCharUnderCursor() {
        let w = makeEditor("line 0", col: 2)
        press("rX", on: w)
        #expect(w.buffer!.getLine(0) == "liXe 0")
        #expect(w.cursorCol == 2)          // stays on the replaced char
    }

    @Test func countReplacesAndParksOnLast() {
        let w = makeEditor("line 0")
        press("3rX", on: w)
        #expect(w.buffer!.getLine(0) == "XXXe 0")
        #expect(w.cursorCol == 2)          // the LAST replaced grapheme
    }

    @Test func countPastLineEndRefusedWhole() {
        let w = makeEditor("line 0", col: 4)
        press("5rX", on: w)                // 4 + 5 > 6
        #expect(w.buffer!.getLine(0) == "line 0")
        #expect(w.cursorCol == 4)
        #expect(w.modified == false)
    }

    @Test func emptyLineRefused() {
        let w = makeTestEditor(lineCount: 0)
        w.buffer?.insert("a\n\nb", at: 0)
        w.cursorLine = 1
        press("rX", on: w)
        #expect(w.buffer!.getLine(1) == "")
    }

    @Test func digitIsTheReplacement() {
        let w = makeEditor("line 0")
        press("r3", on: w)
        #expect(w.buffer!.getLine(0) == "3ine 0")
    }

    @Test func escapeDropsTheQuote() {
        let w = makeEditor("line 0", col: 2)
        press("r", on: w)
        _ = w.handleKey(.escape)
        #expect(w.buffer!.getLine(0) == "line 0")
        press("X", on: w)                  // the quote is gone — X is a key again
        #expect(w.buffer!.getLine(0) == "line 0")
    }

    @Test func registerUntouched() {
        let w = makeEditor("line 0")
        press("yl", on: w)                 // yank "l" at col 0
        press("ll", on: w)                 // cursor col 2 ('n')
        press("rX", on: w)                 // replace 'n' — NOT into the register
        press("p", on: w)                  // pastes the yanked "l"
        #expect(w.buffer!.getLine(0) == "liXle 0")
    }

    @Test func oneUndoStep() {
        let w = makeEditor("line 0", col: 2)
        press("3rX", on: w)
        press("u", on: w)
        #expect(w.buffer!.getLine(0) == "line 0")
    }

    @Test func identityReplaceIsNotAnEdit() {
        let w = makeEditor("Xine 0")
        press("rX", on: w)
        #expect(w.modified == false)       // no undo entry, no flag
        press("u", on: w)
        #expect(w.buffer!.getLine(0) == "Xine 0")
    }

    @Test func enterSplitsWithAutoindent() {
        // vim: r<CR> = delete the char, then i<CR><Esc> — the char is
        // REPLACED by the break, the second line keeps the indent
        // (the shared split core). "  abcdef", cursor on 'c' (col 4).
        let w = makeEditor("  abcdef", col: 4)
        press("r", on: w)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(0) == "  ab")
        #expect(w.buffer!.getLine(1) == "  def")
        #expect(w.cursorLine == 1)
        #expect(w.cursorCol == 2)

        // The two-step operation ([delete, insert-blob]) undoes as
        // ONE step through the per-step inverse drive.
        press("u", on: w)
        #expect(w.buffer!.lineCount == 1)
        #expect(w.buffer!.getLine(0) == "  abcdef")
    }

    @Test func enterCountIsOneBreak() {
        // 2r<CR>: TWO characters replaced by a SINGLE break.
        let w = makeEditor("abcdef", col: 2)
        press("2r", on: w)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(0) == "ab")
        #expect(w.buffer!.getLine(1) == "ef")
        #expect(w.cursorLine == 1 && w.cursorCol == 0)
    }

    @Test func enterOnTrailingCharCoalescesWithExistingBreak() {
        // r<CR> on a TRAILING char: the break after it already exists
        // — the replacement coalesces with it (the latent double-break
        // bug: the blob used to insert a second break, leaving an
        // empty line between the split and the next original line).
        let w = makeEditor("ab\ncd", col: 1)
        press("r", on: w)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.lineCount == 2)
        #expect(w.buffer!.getLine(0) == "a")
        #expect(w.buffer!.getLine(1) == "cd")
        #expect(w.cursorLine == 1 && w.cursorCol == 0)
    }
}
