import Foundation
import Testing
import SwimCore
@testable import Swim

/// The LSP sync invariant: every tracked change must describe to the
/// server EXACTLY the buffer swap that happened — direction, position
/// and text. The server model applies each pending change strictly per
/// the LSP spec (UTF-16 positions, contentChanges sequential over the
/// state the previous one left); any drift diverges the server's copy
/// and its diagnostics describe a document that no longer exists —
/// the false "unclosed bracket" class of errors after edits.
///
/// Written RED against the undo tracking bug: `undo()` passed the
/// ALREADY-inverted steps' fields swapped once more, so every `u`
/// told the server to re-INSERT the text it had just deleted (and
/// vice versa) — one keypress desynced the server's copy forever.
struct LSPUndoSyncTests {

    // MARK: - Server-side document model (LSP spec semantics)

    /// A spec-conformant server's view: content lines, UTF-16
    /// addressable. Deliberately external — it imitates the server
    /// and must NOT share any position math with the editor (the
    /// invariant is only meaningful against an independent oracle).
    private struct ServerDoc {
        var lines: [String]

        init(_ text: String) { lines = ServerDoc.splitLines(text) }

        /// Any of "\n", "\r\n", "\r" ends a line (the spec's three
        /// line breaks; a Swift Character "\r\n" is ONE grapheme).
        static func splitLines(_ t: String) -> [String] {
            var out: [String] = []
            var cur = ""
            for ch in t {
                if ch == "\n" || ch == "\r\n" || ch == "\r" { out.append(cur); cur = "" }
                else { cur.append(ch) }
            }
            out.append(cur)
            return out
        }

        /// (line, UTF-16 character) clamped the way a server clamps.
        private func resolve(_ line: Int, _ col16: Int) -> (Int, Int) {
            let l = min(max(0, line), lines.count - 1)
            let c = min(max(0, col16), lines[l].utf16.count)
            return (l, c)
        }

        private static func slice16(_ s: String, _ from: Int, _ to: Int) -> String {
            let u = s.utf16
            return String(decoding: u[u.index(u.startIndex, offsetBy: from)..<u.index(u.startIndex, offsetBy: to)],
                          as: UTF16.self)
        }

        mutating func apply(_ c: LSPTextChange) {
            let (sl, sc) = resolve(c.startLine, c.startChar)
            let (el, ec) = resolve(c.endLine, c.endChar)
            #expect(sl < el || (sl == el && sc <= ec), "reversed range: \(c)")
            let head = sl > 0 ? Array(lines[0..<sl]) : []
            let headPartial = ServerDoc.slice16(lines[sl], 0, sc)
            let tailPartial = ServerDoc.slice16(lines[el], ec, lines[el].utf16.count)
            let tail = el + 1 < lines.count ? Array(lines[(el + 1)...]) : []
            let mid = ServerDoc.splitLines(c.text)
            var out = head
            out.append(headPartial + (mid.first ?? ""))
            for m in mid.dropFirst() { out.append(m) }
            out[out.count - 1] += tailPartial
            out.append(contentsOf: tail)
            lines = out
        }
    }

    // MARK: - Harness

    private func makeEditor(_ content: String) throws -> (EditorWindow, dir: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swim-lsp-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("t.swift")
        try content.write(toFile: file.path, atomically: true, encoding: .utf8)
        let w = makeTestEditor(lineCount: 0)
        w.editFile(file.path)
        return (w, dir.path)
    }

    /// The app's flush shape as one oracle: didOpen with the full text
    /// at load, then the accumulated changes per key as one didChange
    /// (sequential application). After EVERY key the server's document
    /// must equal the buffer's lines.
    private final class Sync {
        let w: EditorWindow
        var server: ServerDoc
        init(_ w: EditorWindow) {
            self.w = w
            server = ServerDoc(w.buffer!.getAllText())
        }
        func key(_ k: Key) {
            _ = w.handleKey(k)
            for c in w.takeLSPPendingChanges() { server.apply(c) }
            var bufLines: [String] = []
            for i in 0..<w.buffer!.lineCount { bufLines.append(w.buffer!.getLine(i)) }
            #expect(bufLines == server.lines, "server diverged on \(k): buffer=\(bufLines) server=\(server.lines)")
        }
        func chars(_ s: String) { for c in s { key(.char(c)) } }
    }

    // MARK: - Direction pins (the regression, spelled out)

    /// `x` then `u`: the undo RESTORES the grapheme, so the server
    /// must be told a pure INSERT of "a" at the deletion point
    /// (start == end, the char as text). The bug tracked the inverse
    /// — a delete range over "a" with empty text.
    @Test func undoTracksInsertionOfRestoredText() throws {
        let (w, dir) = try makeEditor("alpha\nbeta\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        press("x", on: w)
        _ = w.takeLSPPendingChanges()                 // flush the edit itself
        press("u", on: w)
        let changes = w.takeLSPPendingChanges()
        #expect(changes.count == 1)
        if let c = changes.first {
            #expect(c.text == "a")
            #expect(c.startLine == 0 && c.endLine == 0)
            #expect(c.startChar == 0 && c.endChar == 0)
        }
    }

    /// `x`, `u`, Ctrl+R: the redo deletes the grapheme again — a
    /// non-empty range with empty text, exactly the range "a"
    /// occupies.
    @Test func redoTracksDeletion() throws {
        let (w, dir) = try makeEditor("alpha\nbeta\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        press("x", on: w)
        _ = w.takeLSPPendingChanges()
        press("u", on: w)
        _ = w.takeLSPPendingChanges()
        _ = w.handleKey(.ctrl("r"))
        let changes = w.takeLSPPendingChanges()
        #expect(changes.count == 1)
        if let c = changes.first {
            #expect(c.text == "")
            #expect(c.startLine == 0 && c.endLine == 0)
            #expect(c.startChar == 0 && c.endChar == 1)
        }
    }

    // MARK: - The invariant across real editing sessions

    /// A mixed session of single-step edits and their undos/redos —
    /// every op class (char delete, linewise delete, O + typing)
    /// undone and redone with the oracle watching each key.
    @Test func modelTypingUndoRedoChain() throws {
        let (w, dir) = try makeEditor("alpha\nbeta\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = Sync(w)
        s.key(.char("x"))
        s.chars("dd")
        s.chars("O"); s.chars("new"); s.key(.escape)
        s.chars("u")
        s.chars("u")
        s.key(.ctrl("r"))
        s.key(.ctrl("r"))
        s.chars("u")
    }

    /// CRLF files: line-break-producing keys (o, Enter), the
    /// backspace join, linewise paste — and the UNDO of the paste and
    /// of the Enter split (a multi-line inverted step whose replaced
    /// text carries the "\r\n" break).
    @Test func modelCrlfEditsAndUndo() throws {
        let (w, dir) = try makeEditor("ab\r\ncd\r\nef")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = Sync(w)
        s.key(.char("j"))
        s.chars("o"); s.chars("hello"); s.key(.escape)
        s.chars("x")
        s.chars("i"); s.key(.enter); s.key(.escape)
        s.chars("yy"); s.key(.char("p"))
        s.chars("u")                                   // undo the paste
        s.chars("u")                                   // undo the Enter split
        s.chars("u")                                   // undo the x
    }

    /// `:s` with several hits is ONE multi-step operation; its undo
    /// replays the inverted log with interleaved tracking — the
    /// offsets shift between steps, the cursor has moved away from
    /// every edit before `u` (offset-anchored tracking).
    @Test func modelSubstituteUndoRedo() throws {
        let (w, dir) = try makeEditor("foo a\nfoo b\nfoo c\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = Sync(w)
        s.key(.char(":")); s.chars("s/foo/BAR/"); s.key(.enter)
        s.key(.char("j"))
        s.chars("u")
        s.key(.ctrl("r"))
        s.chars("u")
    }

    /// `r<CR>` is a TWO-step operation (delete the replaced graphemes,
    /// then insert the split blob) — undo inverts both steps.
    @Test func modelReplaceEnterUndo() throws {
        let (w, dir) = try makeEditor("abcdef\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = Sync(w)
        s.chars("2r"); s.key(.enter); s.key(.escape)
        s.chars("u")
        s.key(.ctrl("r"))
    }

    /// A visual-block delete is per-row steps applied top-down; its
    /// undo replays them BOTTOM-UP — reversed-order offsets.
    @Test func modelBlockDeleteUndo() throws {
        let (w, dir) = try makeEditor("aaa\nbbb\nccc\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = Sync(w)
        s.key(.ctrl("v")); s.key(.char("j")); s.key(.char("l")); s.key(.char("x"))
        s.chars("u")
    }

    /// UTF-16 correctness: a surrogate pair (😀, two units) before the
    /// edit point must not shift the tracked position by one — the
    /// oracle's UTF-16 addressing catches any grapheme/byte/UTF-16
    /// confusion, on the edit and on its undo alike.
    @Test func modelUnicodePositions() throws {
        let (w, dir) = try makeEditor("// привет\nlet s = \"😀\"\n")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = Sync(w)
        s.key(.char("j"))
        s.chars("A"); s.chars("й"); s.key(.escape)
        s.chars("x")                                    // delete the й (past the 😀)
        s.chars("u")
        s.chars("u")
    }
}
