import Testing
@testable import Swim

/// Characterization of the CURRENT undo/redo semantics, written
/// BEFORE the EditOperation migration (zero-coverage until now): the
/// migration must keep every pin here byte-identical — these are the
/// proof of zero drift, not a wish list. Written against the flat
/// (offset, deleted, inserted) action stacks.
struct UndoCharacterizationTests {

    @Test func xThenURestoresTextAndCursor() {
        let w = makeTestEditor(lineCount: 3)
        w.cursorCol = 2
        press("x", on: w)
        #expect(w.buffer!.getLine(0) == "lie 0")
        #expect(w.modified == true)

        press("u", on: w)
        #expect(w.buffer!.getLine(0) == "line 0")
        #expect(w.cursorLine == 0)
        #expect(w.cursorCol == 2)          // parked at the action's offset
        #expect(w.modified == false)       // the stack emptied
    }

    @Test func ddThenUThenCtrlR() {
        let w = makeTestEditor(lineCount: 3)
        press("dd", on: w)
        #expect(w.buffer!.getLine(0) == "line 1")

        press("u", on: w)
        #expect(w.buffer!.getLine(0) == "line 0")
        #expect(w.buffer!.lineCount == 3)

        _ = w.handleKey(.ctrl("r"))
        #expect(w.buffer!.getLine(0) == "line 1")
        #expect(w.buffer!.lineCount == 2)
    }

    @Test func substituteUndoRestoresWholeRange() {
        let w = makeTestEditor(lineCount: 3)
        #expect(w.executeCommand("s/line/LINE/") == true)
        #expect(w.buffer!.getLine(0) == "LINE 0")

        press("u", on: w)
        #expect(w.buffer!.getLine(0) == "line 0")
        #expect(w.cursorLine == 0 && w.cursorCol == 0)   // the record's offset
    }

    @Test func substituteRedoCursorAtRangeEnd() {
        // The redo anchor of a :s is the END of the whole final range
        // (offset + inserted.length) — and a plain `:s` here scopes to
        // the WHOLE BUFFER (all three lines substituted: the final
        // text is 20 bytes), so redo parks at the buffer's last line,
        // past its end. The migration's explicit redoAnchor must
        // reproduce exactly this landing.
        let w = makeTestEditor(lineCount: 3)
        #expect(w.executeCommand("s/line/LINE/") == true)
        #expect(w.buffer!.getLine(1) == "LINE 1")   // whole-buffer scope
        press("u", on: w)
        _ = w.handleKey(.ctrl("r"))
        #expect(w.buffer!.getLine(0) == "LINE 0")
        #expect(w.cursorLine == 2)         // end of the whole final text
        #expect(w.cursorCol == 6)
    }

    @Test func newEditClearsRedo() {
        let w = makeTestEditor(lineCount: 3)
        press("x", on: w)
        press("u", on: w)
        press("x", on: w)                  // a new edit discards the redo
        _ = w.handleKey(.ctrl("r"))
        #expect(w.buffer!.getLine(0) == "ine 0")    // nothing redone
    }

    @Test func noopSubstituteKeepsRedo() {
        // An identity :s (no byte changes) records NO undo action —
        // and must NOT clear the redo stack either: the pending redo
        // of the earlier x survives it (the guard runs before the
        // recording, touching nothing).
        let w = makeTestEditor(lineCount: 3)
        press("x", on: w)
        press("u", on: w)
        #expect(w.executeCommand("s/l/l/") == true)   // 1 substitution, 0 bytes
        _ = w.handleKey(.ctrl("r"))
        #expect(w.buffer!.getLine(0) == "ine 0")      // the x was redone
    }

    @Test func undoOnCleanBufferIsNoop() {
        let w = makeTestEditor(lineCount: 3)
        press("u", on: w)
        #expect(w.buffer!.getLine(0) == "line 0")
        #expect(w.modified == false)
    }
}
