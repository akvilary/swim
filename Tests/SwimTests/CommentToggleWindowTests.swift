import Foundation
import Testing
@testable import Swim

/// The WINDOW half of the visual `/` — the application of the pure
/// planner's output through the real dispatch (V/j + `/`),
/// characterized BEFORE the per-line step conversion (the planner
/// itself is pinned by CommentToggleTests; this suite owns the
/// buffer edit, the cursor, the mode exit and the undo/redo landings).
struct CommentToggleWindowTests {

    /// A window over a REAL temp .swift file (the token comes from
    /// the path's extension; [No Name] has none).
    private func makeEditor(_ content: String) throws -> (EditorWindow, dir: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swim-comment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("t.swift")
        try content.write(toFile: file.path, atomically: true, encoding: .utf8)
        let w = makeTestEditor(lineCount: 0)
        w.editFile(file.path)
        return (w, dir.path)
    }

    @Test func visualLineToggleCoversSelectedOnly() throws {
        let (w, dir) = try makeEditor("let a\nlet b\nlet c")
        defer { try? FileManager.default.removeItem(atPath: dir) }

        press("Vj", on: w)                  // two lines selected
        press("/", on: w)
        #expect(w.buffer!.getLine(0) == "// let a")
        #expect(w.buffer!.getLine(1) == "// let b")
        #expect(w.buffer!.getLine(2) == "let c")   // the tail untouched
        #expect(w.mode == WindowMode.normal)        // a finishing operator

        // The cursor — on the first changed line, at the planner's
        // edit point (observed: column 0 — the marker's start for
        // the indent anchor).
        #expect(w.cursorLine == 0)
        #expect(w.cursorCol == 0)
    }

    @Test func toggleRemovesAndRoundTrips() throws {
        let (w, dir) = try makeEditor("// let a\n// let b")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        press("Vj", on: w)
        press("/", on: w)
        #expect(w.buffer!.getLine(0) == "let a")
        #expect(w.buffer!.getLine(1) == "let b")
    }

    @Test func blankMiddleLineSurvivesVerbatim() throws {
        // The planner skips blanks; the application must not corrupt
        // them (the old path reassembled them verbatim — the byte
        // identity is the pin).
        let (w, dir) = try makeEditor("a\n\nb")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        press("Vj", on: w)                  // lines 0-1 (blank included in span)
        press("/", on: w)
        #expect(w.buffer!.getLine(0) == "// a")
        #expect(w.buffer!.getLine(1) == "")
        #expect(w.buffer!.getLine(2) == "b")
    }

    @Test func crlfTerminatorsSurvive() throws {
        // The byte gap between a line's content and the next line's
        // start must stay 2 (\r\n) — the pin for terminator handling.
        let (w, dir) = try makeEditor("a\r\nb\r\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        press("V", on: w)
        press("/", on: w)
        #expect(w.buffer!.getLine(0) == "// a")
        let buf = w.buffer!
        let gap0 = buf.lineStart(line: 1) - (buf.lineStart(line: 0) + buf.getLine(0).utf8.count)
        #expect(gap0 == 2)
    }

    @Test func oneUndoRestoresWholeToggle() throws {
        let (w, dir) = try makeEditor("let a\nlet b")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        press("Vj", on: w)
        press("/", on: w)
        press("u", on: w)
        #expect(w.buffer!.getLine(0) == "let a")
        #expect(w.buffer!.getLine(1) == "let b")
        #expect(w.cursorLine == 0 && w.cursorCol == 0)   // the record's offset
    }

    @Test func redoCursorAtSpanEnd() throws {
        // Today's record spans the whole edited range incl. its last
        // terminator — redo parks at the start of the line AFTER the
        // span (the same landing shape as :s).
        let (w, dir) = try makeEditor("let a\nlet b\nlet c")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        press("Vj", on: w)
        press("/", on: w)
        press("u", on: w)
        _ = w.handleKey(.ctrl("r"))
        #expect(w.buffer!.getLine(0) == "// let a")
        #expect(w.cursorLine == 2)
        #expect(w.cursorCol == 0)
    }
}
