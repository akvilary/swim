import Testing
@testable import SwimCore

/// The undo-command entity: a step log against the evolving buffer.
/// The executor cannot drift from the mutations (it mutates and logs
/// in one call), no-op invocations are not edits, inverted() is an
/// involution, and a non-contiguous multi-step operation round-trips
/// byte-identically — the composite undo vim achieves with its
/// u_entry lists, in byte space instead of line space.
struct EditOperationTests {

    private func buf(_ text: String) -> PieceTable { PieceTable(text: text) }

    @Test func executorLogsWhatItMutated() {
        let b = buf("hello world")
        var op = EditOperation()
        op.replace(b, at: 0, length: 5, with: "HELLO")
        #expect(b.getText(range: 0..<11) == "HELLO world")
        #expect(op.steps == [.init(offset: 0, deleted: "hello", inserted: "HELLO")])
    }

    @Test func noopsAreNotEdits() {
        let b = buf("abc")
        var op = EditOperation()
        op.delete(b, at: 0, length: 0)      // zero-length delete
        op.insert(b, "", at: 0)             // empty insert
        op.replace(b, at: 0, length: 3, with: "abc")   // identity swap
        #expect(op.isEmpty)
        #expect(b.getAllText() == "abc")    // untouched
    }

    @Test func nonContiguousRoundTrip() {
        // Two disjoint edits on one line — the shape a contiguous
        // action cannot express without swallowing the middle.
        let b = buf("aaa bbb ccc")
        var op = EditOperation()
        op.replace(b, at: 0, length: 3, with: "X")      // "X bbb ccc"
        // Offsets are against the EVOLVING buffer: after the first
        // swap the text is "X bbb ccc" (9 bytes) — "bbb" sits at 2..<5.
        #expect(b.getText(range: 2..<5) == "bbb")
        op.replace(b, at: 2, length: 3, with: "YY")
        #expect(b.getAllText() == "X YY ccc")

        op.inverted().apply(to: b)
        #expect(b.getAllText() == "aaa bbb ccc")
    }

    @Test func invertedIsAnInvolution() {
        var op = EditOperation()
        op.insert(buf("abc"), "_", at: 1)
        op.delete(buf("abc"), at: 2, length: 1)
        let once = op.inverted()
        let twice = once.inverted()
        #expect(twice == op)
        // Anchors are not carried into inverses — they belong to the
        // forward operation.
        #expect(once.undoAnchor == nil && once.redoAnchor == nil)
    }

    @Test func insertThenDeleteInterleavedOffsets() {
        // Steps at offsets that SHIFT each other: insert grows the
        // head, a delete at the old address lands elsewhere — the log
        // records what actually happened, replay reproduces it.
        let b = buf("0123")
        var op = EditOperation()
        op.insert(b, "ab", at: 1)            // "0ab123"
        op.delete(b, at: 4, length: 2)       // removes "23" → "0ab1"
        #expect(b.getAllText() == "0ab1")

        op.inverted().apply(to: b)
        #expect(b.getAllText() == "0123")

        // Forward replay on the restored state is the same edit.
        op.apply(to: b)
        #expect(b.getAllText() == "0ab1")
    }

    @Test func anchorDefaults() {
        var op = EditOperation()
        op.insert(buf("abc"), "X", at: 2)     // one step at 2
        op.insert(buf("abc"), "Y", at: 0)     // second step at 0
        #expect(op.firstOffset == 2)          // where the command began
        #expect(op.lastInsertionEnd == 1)     // end of the LAST step's insert
    }

    @Test func applyOnFreshBufferMatchesExecutor() {
        let original = "one\ntwo\nthree"
        let b = buf(original)
        var op = EditOperation()
        op.replace(b, at: 0, length: 3, with: "ONE")
        op.insert(b, "\n", at: 7)

        let replay = buf(original)
        op.apply(to: replay)
        #expect(replay.getAllText() == b.getAllText())
    }
}
