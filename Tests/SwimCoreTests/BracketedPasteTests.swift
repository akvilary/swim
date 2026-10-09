import Testing
import SwimCore

/// BracketedPaste.Scanner — the incremental payload scanner for
/// bracketed paste (the bytes between ESC[200~ and ESC[201~). The end
/// marker is matched byte-by-byte, so content that merely starts like
/// the marker survives; CR/CRLF newlines (what terminals actually send
/// inside a paste) normalize to "\n".
@Suite struct BracketedPasteTests {

    private static let endMarker: [UInt8] = [27, 91, 50, 48, 49, 126] // ESC [ 2 0 1 ~

    private func scan(_ bytes: [UInt8]) -> (result: BracketedPaste.FeedResult, partial: String) {
        var scanner = BracketedPaste.Scanner()
        var result: BracketedPaste.FeedResult = .needMore
        for b in bytes {
            result = scanner.feed(b)
            if case .done = result { break }
        }
        return (result, scanner.partialText)
    }

    @Test func plainPayloadEndsAtMarker() {
        let (result, _) = scan(Array("foo {\n    bar\n}".utf8) + Self.endMarker)
        #expect(result == .done("foo {\n    bar\n}"))
    }

    @Test func emptyPayload() {
        let (result, _) = scan(Self.endMarker)
        #expect(result == .done(""))
    }

    @Test func crAndCrlfNormalizeToLf() {
        let (result, _) = scan(Array("a\r\nb\rc\n".utf8) + Self.endMarker)
        #expect(result == .done("a\nb\nc\n"))
    }

    @Test func utf8PayloadPreserved() {
        let (result, _) = scan(Array("привет 🌊 — fine".utf8) + Self.endMarker)
        #expect(result == .done("привет 🌊 — fine"))
    }

    /// Content that starts like the marker ("ESC[2", a lone ESC) must
    /// not be swallowed — only the exact ESC[201~ terminates.
    @Test func markerLookalikeStaysContent() {
        let (result, _) = scan(Array("x\u{1b}[2y\u{1b}".utf8) + Self.endMarker)
        #expect(result == .done("x\u{1b}[2y\u{1b}"))
    }

    /// A payload ending in ESC right before the real marker: the lone
    /// ESC is content, the full marker still closes the paste.
    @Test func trailingEscBeforeRealMarker() {
        let (result, _) = scan(Array("a\u{1b}".utf8) + Self.endMarker)
        #expect(result == .done("a\u{1b}"))
    }

    /// Two content ESCs then the marker: both survive — the match
    /// restarts at the marker's own ESC.
    @Test func doubleEscThenMarker() {
        let (result, _) = scan(Array("a\u{1b}\u{1b}".utf8) + Self.endMarker)
        #expect(result == .done("a\u{1b}\u{1b}"))
    }

    /// An unfinished paste (EOF before the marker) yields its partial
    /// text, including bytes parked in the tentative match.
    @Test func eofMidPasteKeepsPartialText() {
        let (_, partial) = scan(Array("abc\u{1b}[2".utf8))
        #expect(partial == "abc\u{1b}[2")
    }

    @Test func bytesBeforeMarkerAreNeedMore() {
        // "abc" + a partial marker match ("ESC[2"): still waiting; the
        // parked match bytes count as partial text (they may yet turn
        // out to be content).
        let (result, partial) = scan(Array("abc".utf8) + [27, 91, 50])
        #expect(result == .needMore)
        #expect(partial == "abc\u{1b}[2")
    }
}
