import Foundation
import Testing
@testable import Swim

/// Line-break parity in CRLF files (vim's fileformat behavior): every
/// NEW break matches the file's convention — Enter/o/O/r<CR> keep the
/// split line's terminator (an unterminated last line falls back to
/// the file's first-line convention), and the backspace-join removes
/// the FULL break above ("\r\n" is two bytes — one byte leaves a
/// dangling "\r" as content). LF files are the regression control.
/// Written red-first against the current LF-always behavior.
struct LineBreakCrlfTests {

    private func makeEditor(_ content: String) throws -> (EditorWindow, dir: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swim-crlf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("t.txt")
        try content.write(toFile: file.path, atomically: true, encoding: .utf8)
        let w = makeTestEditor(lineCount: 0)
        w.editFile(file.path)
        return (w, dir.path)
    }

    /// The byte gap between a line's content end and the next line's
    /// start: 2 = CRLF survived, 1 = an LF break leaked in.
    private func gap(_ w: EditorWindow, _ line: Int) -> Int {
        let buf = w.buffer!
        return buf.lineStart(line: line + 1)
            - (buf.lineStart(line: line) + buf.getLine(line).utf8.count)
    }

    @Test func enterKeepsCrlf() throws {
        let (w, dir) = try makeEditor("aa\r\nbb\r\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        w.cursorCol = 1
        press("i", on: w)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(0) == "a")
        #expect(w.buffer!.getLine(1) == "a")
        #expect(gap(w, 0) == 2)                  // CRLF survived the split
        #expect(w.buffer!.getAllText() != "a\nabb\r\n")   // no LF leak anywhere

        // Undo restores the original bytes exactly.
        _ = w.handleKey(.escape)
        press("u", on: w)
        #expect(w.buffer!.getAllText() == "aa\r\nbb\r\n")
    }

    @Test func oKeepsCrlf() throws {
        let (w, dir) = try makeEditor("aa\r\nbb\r\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        press("o", on: w)
        #expect(w.buffer!.getLine(1) == "")
        #expect(gap(w, 1) == 2)                  // the NEW break (below the empty line)
    }

    @Test func uppercaseOKeepsCrlf() throws {
        let (w, dir) = try makeEditor("aa\r\nbb\r\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        w.cursorLine = 1
        press("O", on: w)
        #expect(w.buffer!.getLine(1) == "")
        #expect(gap(w, 1) == 2)                  // the NEW break (below the new empty line)
    }

    @Test func rEnterKeepsCrlf() throws {
        let (w, dir) = try makeEditor("ab\r\ncd")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        w.cursorCol = 1
        press("r", on: w)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(0) == "a")
        #expect(w.buffer!.getLine(1) == "cd")
        #expect(gap(w, 0) == 2)
    }

    @Test func backspaceJoinRemovesFullCrlfBreak() throws {
        // The corruption pin: joining at col 0 must remove BOTH bytes
        // of the "\r\n" — today one byte leaves a dangling "\r" as
        // content of the joined line.
        let (w, dir) = try makeEditor("ab\r\ncd")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        w.cursorLine = 1
        press("i", on: w)
        _ = w.handleKey(.backspace)
        #expect(w.buffer!.lineCount == 1)
        #expect(w.buffer!.getLine(0) == "abcd")

        _ = w.handleKey(.escape)
        press("u", on: w)
        #expect(w.buffer!.getAllText() == "ab\r\ncd")
    }

    @Test func unterminatedLastLineSplitsWithFileConvention() throws {
        // The split line has no terminator of its own — the file's
        // first-line convention (CRLF) supplies the new break.
        let (w, dir) = try makeEditor("x\r\nyz")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        w.cursorLine = 1
        w.cursorCol = 1
        press("i", on: w)
        _ = w.handleKey(.enter)
        #expect(w.buffer!.getLine(1) == "y")
        #expect(w.buffer!.getLine(2) == "z")
        #expect(gap(w, 1) == 2)
    }

    // --- the LF regression control: nothing changes for LF files ---

    @Test func lfFilesUnchanged() throws {
        let (w, dir) = try makeEditor("aa\nbb\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        w.cursorCol = 1
        press("i", on: w)
        _ = w.handleKey(.enter)
        #expect(gap(w, 0) == 1)

        _ = w.handleKey(.escape)                 // → normal
        press("o", on: w)                        // o enters insert
        #expect(gap(w, 2) == 1)                  // the new break below the new empty line
        _ = w.handleKey(.escape)                 // → normal before undo

        press("u", on: w)
        press("u", on: w)
        #expect(w.buffer!.getAllText() == "aa\nbb\n")
    }

    @Test func lfBackspaceJoinUnchanged() throws {
        let (w, dir) = try makeEditor("ab\ncd")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        w.cursorLine = 1
        press("i", on: w)
        _ = w.handleKey(.backspace)
        #expect(w.buffer!.getLine(0) == "abcd")
    }

    // --- the register tails: a linewise yank/delete of an
    // unterminated last line must force the FILE's convention —
    // a bare "\n" tail would leak an LF break back in via `p`.
    // Observed by pasting BELOW a line that owns a terminator (the
    // paste-at-unterminated-EOF merge is a separate latent paste
    // quirk, out of this block's scope). ---

    @Test func yyOnUnterminatedLastLinePastesCrlf() throws {
        let (w, dir) = try makeEditor("x\r\ny\r\nz")   // z unterminated
        defer { try? FileManager.default.removeItem(atPath: dir) }
        w.cursorLine = 2
        press("yy", on: w)
        w.cursorLine = 0
        press("p", on: w)                        // paste below line 0
        #expect(w.buffer!.getLine(1) == "z")
        #expect(gap(w, 1) == 2)                  // the pasted tail is CRLF
    }

    @Test func ddOnUnterminatedLastLinePastesCrlf() throws {
        let (w, dir) = try makeEditor("x\r\ny\r\nz")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        w.cursorLine = 2
        press("dd", on: w)                       // deletes to EOF, forced tail
        #expect(w.buffer!.getLine(1) == "y")
        w.cursorLine = 0
        press("p", on: w)
        #expect(w.buffer!.getLine(1) == "z")
        #expect(gap(w, 1) == 2)
    }

    @Test func registerTailLfUnchanged() throws {
        let (w, dir) = try makeEditor("x\ny\nz")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        w.cursorLine = 2
        press("yy", on: w)
        w.cursorLine = 0
        press("p", on: w)
        #expect(w.buffer!.getLine(1) == "z")
        #expect(gap(w, 1) == 1)
    }
}
