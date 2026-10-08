import Testing
import SwimCore

/// InputLine.window — the horizontal scroll window of a single-line
/// input surface, measured in TERMINAL CELLS: the tail rests in view,
/// the window slides only when the caret leaves it, and wide graphemes
/// (CJK, emoji — two cells) can never push the caret past the capacity.
@Suite struct InputLineTests {

    private func window(_ text: String, _ caret: Int, _ capacity: Int) -> InputLine.Window {
        InputLine.window(text: text, caret: caret, capacity: capacity)
    }

    @Test func emptyTextShowsNothing() {
        let w = window("", 0, 30)
        #expect(w.start == 0)
        #expect(w.visibleCount == 0)
        #expect(w.caretOffset == 0)
    }

    @Test func shortTextShowsHead() {
        #expect(window("abc", 0, 30).visibleCount == 3)
        #expect(window("abc", 2, 30).caretOffset == 2)
        #expect(window("abc", 3, 30).caretOffset == 3)
    }

    /// Typing at the end: the tail stays in view and the caret sits
    /// exactly one cell past the last displayed character.
    @Test func typingAtEndKeepsNewestCharactersVisible() {
        let w = window(String(repeating: "x", count: 60), 60, 30)
        #expect(w.start == 30)
        #expect(w.visibleCount == 30)
        #expect(w.visibleCells == 30)
        #expect(w.caretOffset == 30)
    }

    /// Home on an overflowing text reveals the head — the caret must
    /// not hide left of the window.
    @Test func homeOnOverflowRevealsHead() {
        #expect(window(String(repeating: "x", count: 60), 0, 30).start == 0)
    }

    /// The caret moving above the tail window slides the window to it.
    @Test func caretAboveWindowSlidesToCaret() {
        #expect(window(String(repeating: "x", count: 60), 29, 30).start == 29)
        #expect(window(String(repeating: "x", count: 60), 15, 30).start == 15)
    }

    /// Arrow moves within the tail window leave the window stable.
    @Test func caretInsideTailWindowKeepsTailStable() {
        let text = String(repeating: "x", count: 60)
        #expect(window(text, 30, 30).start == 30)
        #expect(window(text, 35, 30).start == 30)
        #expect(window(text, 45, 30).start == 30)
    }

    // MARK: - wide graphemes

    /// CJK graphemes are two cells each: a 4-cell window shows two of
    /// them, the caret past the pair lands at cell 4.
    @Test func wideGraphemesCountTwoCells() {
        let w = window("中文", 2, 4)
        #expect(w.visibleCount == 2)
        #expect(w.visibleCells == 4)
        #expect(w.caretOffset == 4)
    }

    /// A wide grapheme that would straddle the right edge is dropped
    /// whole: capacity 3 on two CJK chars shows one (2 cells) and
    /// leaves the third cell empty rather than slicing the glyph.
    @Test func wideGraphemeDroppedWholeAtEdge() {
        let w = window("中文", 2, 3)
        #expect(w.visibleCount == 1)
        #expect(w.visibleCells == 2)
        #expect(w.caretOffset == 2)
    }

    /// Mixed text: the window math is pure cells — "a中b" in 4 cells
    /// shows all three (1+2+1), the caret at the end sits at cell 4.
    @Test func mixedNarrowAndWide() {
        let w = window("a中b", 3, 4)
        #expect(w.start == 0)
        #expect(w.visibleCount == 3)
        #expect(w.visibleCells == 4)
        #expect(w.caretOffset == 4)
    }

    /// Home on overflowing wide text reveals the head with the caret
    /// at cell 0 — the wide tail is scrolled out, not sliced.
    @Test func homeOnWideOverflow() {
        let text = "a中中中中"
        let w = window(text, 0, 7)
        #expect(w.start == 0)
        #expect(w.visibleCount == 4)   // a + three CJK = 7 cells
        #expect(w.caretOffset == 0)
    }

    /// Emoji (multi-scalar grapheme) counts as its leading scalar's
    /// width — two cells: "a😀b" = 1+2+1 = 4 cells in a 5-cell window.
    @Test func emojiCountsTwoCells() {
        let w = window("a😀b", 3, 5)
        #expect(w.visibleCount == 3)
        #expect(w.visibleCells == 4)
        #expect(w.caretOffset == 4)
    }

    /// Degenerate: capacity 1 can never fit a wide grapheme — nothing
    /// is shown, but the caret still lands INSIDE the window (never
    /// past the capacity, never under a neighboring block).
    @Test func degenerateCapacityWithWideText() {
        let w = window("中", 1, 1)
        #expect(w.visibleCount == 0)
        #expect(w.caretOffset <= 1)
    }

    @Test func zeroCapacityCollapses() {
        #expect(window("abc", 2, 0).visibleCount == 0)
        #expect(window("abc", 2, -5).visibleCount == 0)
    }

    /// The contract itself, as a property, over narrow/wide mixes:
    /// the caret is always inside the window and never past the
    /// capacity; the visible text always fits.
    @Test func caretAlwaysVisibleInvariant() {
        let texts = [
            String(repeating: "x", count: 40),
            String(repeating: "中", count: 20),
            String(repeating: "a中", count: 15),
            "a😀b中c",
        ]
        for text in texts {
            let n = text.count
            for caret in 0...n {
                for capacity in [1, 2, 3, 5, 30] {
                    let w = InputLine.window(text: text, caret: caret, capacity: capacity)
                    #expect(w.caretOffset >= 0 && w.caretOffset <= capacity)
                    #expect(w.visibleCells >= 0 && w.visibleCells <= capacity)
                    #expect(w.start >= 0 && w.start <= n)
                    #expect(caret >= w.start && caret <= w.start + w.visibleCount)
                }
            }
        }
    }
}
