import Testing
@testable import SwimCore

/// Fixtures for the match-row word extraction — the shapes the search
/// tree's match rows render: the match colored inside its whole word,
/// bounded by spaces, brackets, quotes, dots, punctuation. Keep in
/// sync with the consumer (Sources/Swim/Window/SearchResultsWindow.swift).
struct MatchWordTests {

    private func span(_ line: String, _ match: String) -> (start: Int, end: Int) {
        let chars = Array(line)
        let range = line.range(of: match)!
        let start = line.distance(from: line.startIndex, to: range.lowerBound)
        return MatchWord.span(chars: chars, matchStart: start, matchLength: match.count)
    }

    private func word(_ line: String, _ match: String) -> String {
        let chars = Array(line)
        let s = span(line, match)
        return String(chars[s.start..<s.end])
    }

    /// The match inside a word: the whole word shows, the match's ends
    /// extend to the word's boundaries.
    @Test func matchInsideWordExpandsToWholeWord() {
        #expect(word("let backgroundColor = x", "Color") == "backgroundColor")
        #expect(word("Theme.bgHighlight", "High") == "bgHighlight")   // dot bounds
        #expect(word("x = bgHighlight", "bgHighlight") == "bgHighlight") // whole word == match
    }

    /// Boundaries: spaces, brackets, quotes, operators, punctuation —
    /// the identifier segment is the word.
    @Test func delimitersBoundTheWord() {
        #expect(word("call(bgHighlight)", "High") == "bgHighlight")
        #expect(word("arr[b_KEY]", "KEY") == "b_KEY")
        #expect(word("s = \"quoted\"", "uot") == "quoted")
        #expect(word("a,bHighlight;c", "High") == "bHighlight")
        #expect(word("a+bHighlight-c", "High") == "bHighlight")
    }

    /// The word at the line's edges — expansion clamps to the line.
    @Test func lineEdgesClamp() {
        #expect(word("wordStart = 1", "word") == "wordStart")
        #expect(word("x = tailWord", "Word") == "tailWord")
        #expect(word("solo", "olo") == "solo")
    }

    /// A multi-word match keeps its inner delimiters — only the ENDS
    /// extend to the surrounding words' boundaries.
    @Test func multiWordMatchKeepsInnerDelimiters() {
        #expect(word("x = foo bar; y", "foo bar") == "foo bar")
    }

    /// Unicode letters belong to words: Cyrillic and CJK read as
    /// words, not fragments.
    @Test func unicodeLettersAreWordChars() {
        #expect(word("привет_мир = 1", "мир") == "привет_мир")
        #expect(word("println(\"こんにwidentokenは\")", "widentoken") == "こんにwidentokenは")
    }

    /// The total budget: a pathological single-word line (minified
    /// output) caps the span at maxCells, the match ALWAYS inside; a
    /// deep match spends the budget on the word's head around it. The
    /// row clips at the window edge long before the cap matters.
    @Test func budgetCapsGiantWordsAndKeepsTheMatchInside() {
        let line = String(repeating: "a", count: 1000)
        let chars = Array(line)
        // Match at the word's head: right grows to the budget, left has nowhere.
        let head = MatchWord.span(chars: chars, matchStart: 0, matchLength: 3, maxCells: 40)
        #expect(head.start == 0 && head.end == 40)
        // A deep match: the span grows right first (visible under right
        // clipping), the match stays inside, the total stays ≤ budget.
        let deep = MatchWord.span(chars: chars, matchStart: 900, matchLength: 3, maxCells: 40)
        #expect(deep.start == 900 && deep.end == 940)
        #expect(deep.start <= 900 && 903 <= deep.end)
        // A match longer than the budget: the match itself always fits.
        let long = MatchWord.span(chars: chars, matchStart: 0, matchLength: 60, maxCells: 40)
        #expect(long.start == 0 && long.end == 60)
    }
}
