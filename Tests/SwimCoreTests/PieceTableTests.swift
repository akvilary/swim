import Foundation
import Testing
@testable import SwimCore

/// Regression coverage for the piece-table delete. The two-phase rewrite
/// (plan cuts in original coordinates, then apply) fixed a corruption bug:
/// deleting a range that straddled piece boundaries mutated pieces while
/// walking them, so the walk's offset (original coordinates) disagreed
/// with the already-shrunk pieces (buffer coordinates) — it skipped
/// pieces inside the range and deleted bytes PAST the range, with correct
/// length bookkeeping. Found via a randomized editor-session stress test;
/// the fixtures below pin the exact shapes.
struct PieceTableTests {
    private func text(_ pt: PieceTable) -> String {
        pt.getText(range: 0..<pt.totalLength)
    }

    /// THE bug shape: a delete starting mid-piece, consuming its tail and
    /// continuing into a 1-byte piece. The old walk skipped the 1-byte
    /// piece (its accumulated length no longer satisfied the strict `>`
    /// bound after the first trim) and cut the head of the piece AFTER it.
    @Test func deleteStraddlingPieceBoundaries() {
        let pt = PieceTable(text: "0123456789")
        pt.insert("X", at: 5) // pieces: [01234][X][56789]
        pt.delete(at: 4, length: 2) // removes "4X" -> "012356789"
        #expect(text(pt) == "012356789")
        #expect(pt.lineCount == 1)
    }

    /// A long delete spanning many small pieces must remove exactly the
    /// requested range, never more.
    @Test func deleteSpanningManyPieces() {
        let pt = PieceTable(text: "0123456789ABCDEF")
        for i in 0..<8 { pt.insert(".", at: i * 2) } // fragmented layout
        let before = text(pt)
        let start = 3
        let len = 9
        let bytes = Array(before.utf8)
        let removed = String(decoding: bytes[start..<(start + len)], as: UTF8.self)
        let ref = String(decoding: bytes[0..<start] + bytes[(start + len)...], as: UTF8.self)
        pt.delete(at: start, length: len)
        #expect(text(pt) == ref)
        #expect(removed.utf8.count == len)
    }

    /// Deleting in the middle of a piece splits it; the survivors must
    /// read back exactly.
    @Test func deleteSplittingAPiece() {
        let pt = PieceTable(text: "AAAABBBB")
        pt.delete(at: 3, length: 2) // removes "AB" -> "AAABBB"
        #expect(text(pt) == "AAABBB")
    }

    /// Out-of-range deletes are clamped, never crash and never corrupt.
    @Test func deletePastEndIsClamped() {
        let pt = PieceTable(text: "hello")
        pt.delete(at: 3, length: 100) // clamps to "lo"
        #expect(text(pt) == "hel")
        pt.delete(at: 10, length: 1) // past the end: no-op
        #expect(text(pt) == "hel")
    }

    /// Deterministic property campaign: random inserts/deletes of varying
    /// lengths at random offsets against a byte-exact string reference,
    /// plus line-index coherence after every step. Same shape as the
    /// stress harness that caught the bug, compacted into a fixed seed.
    /// ASCII text throughout: byte offsets are always valid UTF-8
    /// boundaries, so the comparison never trips over lossy decoding.
    @Test func randomizedEditsMatchReference() {
        let pt = PieceTable(text: "func a() {\n    if x {\n        foo(|)\n}\nlet s = \"str (\"\n")
        var ref = Array(text(pt).utf8)
        srand48(42)
        for _ in 0..<600 {
            let offset = Int(drand48() * Double(pt.totalLength + 1))
            if drand48() < 0.5, offset < pt.totalLength {
                let maxLen = pt.totalLength - offset
                let len = max(1, Int(drand48() * Double(min(maxLen, 12))))
                pt.delete(at: offset, length: len)
                ref.removeSubrange(offset..<(offset + len))
            } else {
                let payload = "ab\nxy-"
                let cut = Int(drand48() * Double(payload.count))
                let piece = String(payload.prefix(max(0, cut)))
                pt.insert(piece, at: offset)
                ref.insert(contentsOf: Array(piece.utf8), at: offset)
            }
            // Text equality.
            let now = Array(text(pt).utf8)
            if now != ref {
                Issue.record("buffer diverged from reference at offset \(offset)")
                break
            }
            // Line-index coherence: starts are sorted and sum to the length.
            var summed = 0
            var coherent = true
            for i in 0..<pt.lineCount {
                if pt.lineStart(line: i) != summed { coherent = false; break }
                summed += pt.lineLength(line: i)
            }
            if !coherent || summed != pt.totalLength {
                Issue.record("line index incoherent after edit at offset \(offset)")
                break
            }
        }
    }
}
