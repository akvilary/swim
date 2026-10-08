/// Horizontal scroll policy for a single-line input surface (the
/// branch filter/name prompt, the search query, the terminal prompt,
/// the status bar's command line): WHICH part of the text is visible
/// and WHERE the caret lands — measured in TERMINAL CELLS, so wide
/// graphemes (CJK, emoji — two cells each, per `Character.displayWidth`)
/// cannot push the caret past the surface's edge or under a neighboring
/// block.
///
/// The resting window shows the text's tail — typing at the end keeps
/// the newest characters in view; the window slides left only when the
/// caret moves above it (Home on an overflowing text reveals the head
/// instead of hiding the caret left of the window). A wide character
/// that would straddle the right edge is dropped from the window
/// whole — a cell of background may show before the edge instead of a
/// sliced glyph.
///
/// Pure and stateless — a function of (text, caret, capacity) only:
/// the drawing pass and the caret-render pass derive the same window
/// and can never disagree. Tested in Tests/SwimCoreTests.
public enum InputLine {
    /// One horizontal window into a single-line input surface.
    public struct Window {
        /// Grapheme index of the first visible character.
        public let start: Int
        /// How many characters from `start` are visible — the longest
        /// run that fits `capacity` cells.
        public let visibleCount: Int
        /// Cells the visible text occupies (≤ capacity; can be one
        /// less when the next character is wide and would not fit).
        public let visibleCells: Int
        /// The caret's column, in cells, from the window's first cell —
        /// the caller adds its prompt width to get the screen column.
        public let caretOffset: Int
    }

    /// Contract (with `caret` inside `0...text.count`): `0 <=
    /// caretOffset <= capacity`, `start <= caret <= start +
    /// visibleCount` — the caret is always inside the window, exactly
    /// one cell past its character when typing at the end.
    public static func window(text: String, caret: Int, capacity: Int) -> Window {
        let chars = Array(text)
        let n = chars.count
        guard capacity > 0, n > 0 else {
            return Window(start: min(max(0, caret), n), visibleCount: 0, visibleCells: 0, caretOffset: 0)
        }
        // Prefix cell sums: prefix[i] = cells of chars[0..<i].
        var prefix = [Int](repeating: 0, count: n + 1)
        for i in 0..<n {
            prefix[i + 1] = prefix[i] + max(1, chars[i].displayWidth)
        }
        func cells(_ from: Int, _ to: Int) -> Int { prefix[to] - prefix[from] }

        let clampedCaret = min(max(0, caret), n)
        // Resting position: the longest tail that fits.
        var start = 0
        for i in stride(from: n, through: 1, by: -1) {
            if cells(i - 1, n) <= capacity { start = i - 1 } else { break }
        }
        // Slide left: the caret above the window pulls it to the caret.
        if clampedCaret < start { start = clampedCaret }
        // Slide right: a degenerate case (capacity 1 with wide
        // characters around) can leave the caret past the window even
        // at the resting tail — drop left characters until the caret
        // fits; in the absurd extreme nothing is shown and the caret
        // sits at the window's origin, still never past `capacity`.
        while start < clampedCaret, cells(start, clampedCaret) > capacity {
            start += 1
        }

        var visibleCount = 0
        while start + visibleCount < n, cells(start, start + visibleCount + 1) <= capacity {
            visibleCount += 1
        }
        return Window(
            start: start,
            visibleCount: visibleCount,
            visibleCells: cells(start, start + visibleCount),
            caretOffset: cells(start, clampedCaret))
    }
}
