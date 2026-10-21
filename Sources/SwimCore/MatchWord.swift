/// The whole word a search match lives in — the search tree's match
/// rows show this word (the match colored inside it) instead of a
/// character window of the pre-match text, which read as a rootless
/// fragment cut mid-word. A word is an identifier segment: letters,
/// digits and `_` — everything else (spaces, brackets, quotes, dots,
/// operators, punctuation) bounds it, so `Theme.bgHighlight` matching
/// "High" shows `bgHighlight` with `High` colored. Unicode letters
/// belong to words: Cyrillic and CJK text reads as words, not
/// fragments.
///
/// Pure and side-effect-free, unit-testable in isolation
/// (Tests/SwimCoreTests/MatchWordTests.swift); the consumer is
/// SearchResultsWindow's match rows.
public enum MatchWord {

    public static func isDelimiter(_ c: Character) -> Bool {
        !(c.isLetter || c.isNumber || c == "_")
    }

    /// The span [start, end) of the word containing the match, grown
    /// from the match outward to the nearest delimiters (clamped to
    /// the line), under a total budget: the span NEVER exceeds
    /// `max(matchLength, maxCells)` cells and ALWAYS contains the full
    /// match — a pathological single-word line (minified output) must
    /// not build cells nobody can see, and the row clips at the window
    /// edge long before the cap matters. The RIGHT side grows first —
    /// under right-edge clipping the match then sits toward the row's
    /// visible left. A match that itself contains delimiters (a
    /// multi-word query) keeps them inside — only the ends extend.
    public static func span(
        chars: [Character],
        matchStart: Int,
        matchLength: Int,
        maxCells: Int = .max
    ) -> (start: Int, end: Int) {
        let from = max(0, min(matchStart, chars.count))
        let length = max(0, matchLength)
        var end = min(chars.count, from + length)
        var start = from
        let budget = max(length, maxCells)
        while end < chars.count, !isDelimiter(chars[end]), end + 1 - from <= budget { end += 1 }
        while start > 0, !isDelimiter(chars[start - 1]), end - (start - 1) <= budget { start -= 1 }
        return (start, end)
    }
}
