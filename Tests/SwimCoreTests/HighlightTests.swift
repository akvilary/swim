import Foundation
import Testing
@testable import SwimCore

/// Fixtures for the preview highlighting session — the whole pipeline
/// behind one door: language routing by extension (code / JSON /
/// markdown), viewport-scoped tokenization (only the asked window),
/// the immutable string-state ladder, and the huge-file guard. Keep in
/// sync with the consumer (Sources/Swim/Window/PreviewWindow.swift):
/// one tokens() call per draw over the visible window; the window maps
/// the token types onto its lexical color subset.
struct HighlightTests {

    /// Code routing: keywords and numbers tokenized as such — the same
    /// tokenizer output the editor colors (parity by construction).
    @Test func swiftKeywordsAndNumbers() {
        let s = Highlight.Session(text: "import Foundation\nlet n = 42\n", fileExt: "swift")
        #expect(s.lineCount == 3) // the trailing newline's empty line
        let line0 = sessionLine(s, 0)
        #expect(line0.contains { $0.type == "keyword" && word($0, s, 0) == "import" })
        let line1 = sessionLine(s, 1)
        #expect(line1.contains { $0.type == "keyword" && word($0, s, 1) == "let" })
        #expect(line1.contains { $0.type == "number" && word($0, s, 1) == "42" })
    }

    /// JSON routing: strings and numbers; JSON has no keywords — the
    /// punctuation stays plain by the preview's subset policy.
    @Test func jsonStringsAndNumbers() {
        let s = Highlight.Session(text: #"{"ключ": 42}"#, fileExt: "json")
        let line0 = sessionLine(s, 0)
        #expect(line0.contains { $0.type == "string" })
        #expect(line0.contains { $0.type == "number" })
        #expect(!line0.contains { $0.type == "keyword" })
    }

    /// Markdown routing: heading markers are keywords, fenced blocks
    /// are strings — the vocabulary is the preview's subset almost in
    /// full.
    @Test func markdownHeadingsAndFences() {
        let s = Highlight.Session(text: "# Title\n\ntext\n```swift\nimport X\n```\n", fileExt: "md")
        let line0 = sessionLine(s, 0)
        #expect(line0.contains { $0.type == "keyword" && $0.length == 1 }) // the # marker
        let fence = sessionLine(s, 3)
        #expect(fence.contains { $0.type == "string" })                    // ``` line
        let inside = sessionLine(s, 4)
        #expect(inside.contains { $0.type == "string" })                    // fence interior
    }

    /// The ladder inside the session: a multiline string opened ABOVE
    /// the asked window still colors the window's continuation lines —
    /// the state threads from line 0 through the viewport.
    @Test func multilineStringColorsWindowBelowItsOpener() {
        let s = Highlight.Session(text: "let s = \"\"\"\ninside one\ninside two\nclosed\"\"\"\nlet x = 1\n",
                                  fileExt: "swift")
        // Ask for a window that starts below the opener.
        let window = s.tokens(scrollY: 2, height: 2)
        let line2 = window[2] ?? []
        #expect(line2.contains { $0.type == "string" })
        let line3 = window[3] ?? []
        #expect(line3.contains { $0.type == "string" }) // the closing line is part of the string
        // The ladder was extended — a second window further down sees plain code.
        let line4 = s.tokens(scrollY: 4, height: 1)[4] ?? []
        #expect(line4.contains { $0.type == "keyword" && $0.length == 3 }) // let
    }

    /// The editor's huge-file guard, mirrored: past lineLimit the
    /// session gives no tokens — the preview renders plain, the ladder
    /// stays bounded.
    @Test func hugeFilesRenderPlain() {
        let big = String(repeating: "import Foundation\n", count: Highlight.lineLimit)
        let s = Highlight.Session(text: big, fileExt: "swift")
        #expect(s.tokens(scrollY: 0, height: 10).isEmpty)
    }

    /// Out-of-range windows give an empty map — the caller's row loop
    /// owns the bounds.
    @Test func outOfRangeWindowsEmpty() {
        let s = Highlight.Session(text: "a\nb\n", fileExt: "swift")
        #expect(s.tokens(scrollY: 5, height: 3).isEmpty)
        #expect(s.tokens(scrollY: -1, height: 3).isEmpty)
    }

    /// Line numbering parity with components(separatedBy:) — the
    /// SEARCH counts match numbers that way, and the highlight line
    /// must land on the same row the searcher meant.
    @Test func lineNumberingMatchesComponentsSemantics() {
        let s = Highlight.Session(text: "a\nb\n", fileExt: "txt")
        #expect(s.lineCount == 3)
        #expect(s.getLine(0) == "a")
        #expect(s.getLine(1) == "b")
        #expect(s.getLine(2) == "")
    }

    /// Unknown extensions keep the builtin lexical pass (strings,
    /// numbers, comments) — exactly the editor's behavior for
    /// plaintext: parity, not special-casing.
    @Test func unknownExtensionStillLexical() {
        let s = Highlight.Session(text: "note \"quoted\" done", fileExt: "txt")
        let line0 = sessionLine(s, 0)
        #expect(line0.contains { $0.type == "string" })
    }

    // --- helpers ---

    private func sessionLine(_ s: Highlight.Session, _ line: Int) -> [SemanticToken] {
        s.tokens(scrollY: line, height: 1)[line] ?? []
    }

    private func word(_ t: SemanticToken, _ s: Highlight.Session, _ line: Int) -> String {
        let chars = s.getLineChars(line)
        guard t.startChar + t.length <= chars.count else { return "" }
        return String(chars[t.startChar..<t.startChar + t.length])
    }
}
