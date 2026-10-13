import Testing
import SwimCore

func chars(_ s: String) -> [Character] { Array(s) }

/// VisualBlock — the math of a rectangular selection in display columns.
/// Membership rule: cell INTERSECTION — a grapheme is affected ⟺
/// its cells intersect [left, right); a tab straddling an edge splits
/// (uncovered cells become spaces), a wide glyph is atomic. The split
/// cases were verified against vim 8.2 / nvim 0.11 with scripts on a live editor.
@Suite struct VisualBlockTests {

    // MARK: - Span

    @Test func spanNormalizesSidesAndWidth() {
        let s = VisualBlock.Span(7, 3)
        #expect(s.left == 3 && s.right == 7)
        let degenerate = VisualBlock.Span(5, 5)
        #expect(degenerate.left == 5 && degenerate.right == 6)
    }

    // MARK: - Span.inclusive (both corners inclusive)

    @Test func inclusiveSpanCursorRightOfAnchor() {
        // Ctrl+V + l: anchor 4, cursor 5 → cells [4, 6)
        let s = VisualBlock.Span.inclusive(4, 5)
        #expect(s.left == 4 && s.right == 6)
    }

    @Test func inclusiveSpanCursorLeftOfAnchorKeepsBothCorners() {
        // Ctrl+V + h: anchor 4, cursor 3 → cells [3, 5). Regression:
        // Span(anchor, cursor + 1) with the cursor left of the anchor
        // normalized to [4, 5) — the cursor's cell fell out of the selection.
        let oneLeft = VisualBlock.Span.inclusive(4, 3)
        #expect(oneLeft.left == 3 && oneLeft.right == 5)
        // two h's: cursor 2 → [2, 5) — both corner cells in the block
        let twoLeft = VisualBlock.Span.inclusive(4, 2)
        #expect(twoLeft.left == 2 && twoLeft.right == 5)
    }

    @Test func inclusiveSpanDegenerateAndFarCorners() {
        // coinciding corners — a single cell, like init(c, c)
        let same = VisualBlock.Span.inclusive(5, 5)
        #expect(same.left == 5 && same.right == 6)
        let far = VisualBlock.Span.inclusive(6, 0)
        #expect(far.left == 0 && far.right == 7)
    }

    // MARK: - blockGeometry ("anchor + virtual corner" composition)

    @Test func blockGeometryAnchorAfterTabCursorLeft() {
        // Repro of a bug in the composition itself: the anchor on 'f' of "\tfoo"
        // (tab cells 0-3, 'f' on cell 4), the corner after Ctrl+V+h on
        // cell 3 — the span must cover both cells, rows via min/max.
        let g = VisualBlock.blockGeometry(anchorLine: 0, anchorCharCol: 1,
                                          cursorLine: 2, cursorBlockCol: 3,
                                          anchorChars: chars("\tfoo"), tabWidth: 4)
        #expect(g.rows == 0...2)
        #expect(g.span.left == 3 && g.span.right == 5)
    }

    @Test func blockGeometryCursorAboveAnchorRowsOrdered() {
        let g = VisualBlock.blockGeometry(anchorLine: 5, anchorCharCol: 0,
                                          cursorLine: 1, cursorBlockCol: 7,
                                          anchorChars: chars("abcdef"), tabWidth: 4)
        #expect(g.rows == 1...5)
        #expect(g.span.left == 0 && g.span.right == 8)
    }

    @Test func blockGeometryEmptyAnchorCharsAnchorsAtZero() {
        // no buffer — the anchor line is empty, the anchor at cell 0 (parity
        // with displayColForChar's old guard)
        let g = VisualBlock.blockGeometry(anchorLine: 0, anchorCharCol: 9,
                                          cursorLine: 0, cursorBlockCol: 2,
                                          anchorChars: [], tabWidth: 4)
        #expect(g.span.left == 0 && g.span.right == 3)
    }

    @Test func blockGeometryEndToEndYankBothCorners() {
        // End-to-end pipeline repro: blockGeometry → charRange → blockText
        let line = "    abcd"
        let g = VisualBlock.blockGeometry(anchorLine: 0, anchorCharCol: 4,
                                          cursorLine: 0, cursorBlockCol: 3,
                                          anchorChars: chars(line), tabWidth: 4)
        let r = VisualBlock.charRange(chars(line), span: g.span, tabWidth: 4)
        #expect(VisualBlock.blockText(rows: [(chars(line), r)], span: g.span, tabWidth: 4) == " a")
    }

    // MARK: - Regression: the full block pipeline with the cursor left of the anchor

    @Test func regressionBlockLeftOfAnchorYanksBothCells() {
        // Repro of the bug: an indented line, the anchor on 'a' (display column 4),
        // Ctrl+V, h — the cursor's cell (the space at column 3) must
        // land in the block together with the anchor's 'a'. The old span
        // init(4, 3+1) gave [4, 5) — yank returned "a" instead of " a".
        let line = "    abcd"
        let span = VisualBlock.Span.inclusive(4, 3)
        let r = VisualBlock.charRange(chars(line), span: span, tabWidth: 4)
        #expect(r == 3..<5)
        #expect(VisualBlock.blockText(rows: [(chars(line), r)], span: span, tabWidth: 4) == " a")
        // two h's — three cells: [2, 5) = "  a"
        let wider = VisualBlock.Span.inclusive(4, 2)
        let r2 = VisualBlock.charRange(chars(line), span: wider, tabWidth: 4)
        #expect(VisualBlock.blockText(rows: [(chars(line), r2)], span: wider, tabWidth: 4) == "  a")
    }

    @Test func regressionBlockLeftOfAnchorDeletePlan() {
        // Deleting the same block: both cells' slice goes, the tail stays intact —
        // edits see both corner cells too, not just the highlight.
        let plan = VisualBlock.rowPlan(chars: chars("    abcd"), span: .inclusive(4, 3),
                                       range: 3..<5, replacement: "", tabWidth: 4)
        #expect(plan.text == "   bcd")
    }

    // MARK: - displayCol / charIndex

    @Test func displayColPlainASCII() {
        #expect(VisualBlock.displayCol(ofCharIndex: 3, chars: chars("abcdef"), tabWidth: 4) == 3)
        #expect(VisualBlock.displayCol(ofCharIndex: 0, chars: chars("abcdef"), tabWidth: 4) == 0)
    }

    @Test func displayColBeyondEndIsFullWidth() {
        #expect(VisualBlock.displayCol(ofCharIndex: 100, chars: chars("abc"), tabWidth: 4) == 3)
    }

    @Test func displayColExpandsTabs() {
        // "a\tb" with tabWidth 4: a(0), tab -> 4, b at 4
        #expect(VisualBlock.displayCol(ofCharIndex: 2, chars: chars("a\tb"), tabWidth: 4) == 4)
    }

    @Test func charIndexAtDisplayColBoundary() {
        #expect(VisualBlock.charIndex(atDisplayCol: 2, chars: chars("abcd"), tabWidth: 4) == 2)
        // past the line's end — the position after the tail
        #expect(VisualBlock.charIndex(atDisplayCol: 9, chars: chars("ab"), tabWidth: 4) == 2)
    }

    @Test func charIndexSkipsTabStraddlingTarget() {
        // "a\tb": the tab occupies cells 1..3; target 3 lands INSIDE the tab —
        // the boundary moves to the character after it (index 2), the tab
        // itself (start at 1 < 3) is not in the block.
        #expect(VisualBlock.charIndex(atDisplayCol: 3, chars: chars("a\tb"), tabWidth: 4) == 2)
    }

    @Test func charIndexWideCharStraddle() {
        // "a中b": 中 occupies cells 1..2, b at 2; target 2 — b's start.
        #expect(VisualBlock.charIndex(atDisplayCol: 2, chars: chars("a中b"), tabWidth: 4) == 2)
    }

    // MARK: - charRange

    @Test func charRangePlainBlock() {
        let r = VisualBlock.charRange(chars("abcdefgh"), span: .init(2, 5), tabWidth: 4)
        #expect(r == 2..<5)
    }

    @Test func charRangeSingleCellBlock() {
        // a degenerate block [c, c+1) — the character under the cursor
        let r = VisualBlock.charRange(chars("abc"), span: .init(1, 1), tabWidth: 4)
        #expect(r == 1..<2)
    }

    @Test func charRangeShortLineIsNil() {
        #expect(VisualBlock.charRange(chars("ab"), span: .init(5, 8), tabWidth: 4) == nil)
        #expect(VisualBlock.charRange(chars(""), span: .init(0, 3), tabWidth: 4) == nil)
    }

    @Test func charRangeRightBeyondEndClamps() {
        // the right edge past the line's end — up to the tail
        let r = VisualBlock.charRange(chars("abcd"), span: .init(2, 20), tabWidth: 4)
        #expect(r == 2..<4)
    }

    @Test func charRangeTabInsideBlockIncludedWhole() {
        // "\tx": the tab starts at 0; block [0,2) — the tab is covered from its start — included
        let r = VisualBlock.charRange(chars("\tx"), span: .init(0, 2), tabWidth: 4)
        #expect(r == 0..<1)
        // block [1,3): the edge INSIDE the tab [0,4) — the cells intersect,
        // the tab is affected (it will split in rowPlan; the old starting-cell
        // rule gave nil)
        #expect(VisualBlock.charRange(chars("\tx"), span: .init(1, 3), tabWidth: 4) == 0..<1)
    }

    @Test func charRangePointSpanAtGlyphStartIsNil() {
        // Invariant of block p/P: the insertion point is placed on a grapheme
        // boundary — no slice, a pure insert. A point INSIDE a tab yields
        // a slice (the insert splits the glyph, like vim with 've=block').
        // "a\tz": a [0,1), tab [1,4), z [4,5)
        #expect(VisualBlock.charRange(chars("a\tz"), span: .point(0), tabWidth: 4) == nil)
        #expect(VisualBlock.charRange(chars("a\tz"), span: .point(1), tabWidth: 4) == nil)
        #expect(VisualBlock.charRange(chars("a\tz"), span: .point(4), tabWidth: 4) == nil)
        #expect(VisualBlock.charRange(chars("a\tz"), span: .point(5), tabWidth: 4) == nil)
        #expect(VisualBlock.charRange(chars("a\tz"), span: .point(2), tabWidth: 4) == 1..<2)
    }

    // MARK: - Splitting tabs and wide glyphs at edges (vim-verified)

    @Test func splitTabLeftEdgeDelete() {
        // vim: "\tqrs", block [2,4): the left edge inside the tab [0,4) —
        // the left part becomes spaces, the covered part is deleted, the tail intact
        let plan = VisualBlock.rowPlan(chars: chars("\tqrs"), span: .init(2, 4),
                                       range: 0..<1, replacement: "", tabWidth: 4)
        #expect(plan.text == "  qrs")
        #expect(plan.caret == 2)
    }

    @Test func splitTabRightEdgeDelete() {
        // vim: "x\tz", block [1,3): the right edge inside the tab [1,4) —
        // the right part becomes a space in the suffix
        let plan = VisualBlock.rowPlan(chars: chars("x\tz"), span: .init(1, 3),
                                       range: 1..<2, replacement: "", tabWidth: 4)
        #expect(plan.text == "x z")
    }

    @Test func splitTabBothEdgesUniformDeviation() {
        // block [1,3) entirely INSIDE the tab [0,4): vim leaves the line
        // alone (no-op), swim splits uniformly — both parts become spaces
        let plan = VisualBlock.rowPlan(chars: chars("\tq"), span: .init(1, 3),
                                       range: 0..<1, replacement: "", tabWidth: 4)
        #expect(plan.text == "  q")
    }

    @Test func wideStraddlingEdgesDeleteWhole() {
        // vim: "中x", block [1,3): 中 (cells 0-1) is atomic — deleted
        // whole, the uncovered cell becomes a space
        let plan = VisualBlock.rowPlan(chars: chars("中x"), span: .init(1, 3),
                                       range: 0..<2, replacement: "", tabWidth: 4)
        #expect(plan.text == " ")
        // vim: "ab中c", block [1,3): the right edge inside 中 (2-3) — vim
        // doesn't compensate the tail ("ac", a one-cell shift); swim pads
        // with a space, uniform with tabs
        let p2 = VisualBlock.rowPlan(chars: chars("ab中c"), span: .init(1, 3),
                                     range: 1..<3, replacement: "", tabWidth: 4)
        #expect(p2.text == "a c")
    }

    @Test func yankPartialGlyphsAsSpaces() {
        // vim: "\tqrs", block [2,5): a partially covered tab — spaces
        // for the covered cells, the fully covered q — as is
        let text = VisualBlock.blockText(rows: [(chars("\tqrs"), 0..<2)],
                                         span: .init(2, 5), tabWidth: 4)
        #expect(text == "  q")
        // vim: "中x", block [1,4): partially covered 中 — a space for the
        // covered cell (we don't reproduce vim's trailing ve-padding — a ve artifact)
        let w = VisualBlock.blockText(rows: [(chars("中x"), 0..<2)],
                                      span: .init(1, 4), tabWidth: 4)
        #expect(w == " x")
    }

    @Test func yankBlockInsideWideGlyphDeviation() {
        // vim: block [1,2) entirely inside 中 (cells 0-1) yields the whole glyph;
        // swim, uniform — a space for the covered cell
        let text = VisualBlock.blockText(rows: [(chars("中中"), 0..<1)],
                                         span: .init(1, 2), tabWidth: 4)
        #expect(text == " ")
    }

    @Test func charRangeWideCharStartingAtRightMinusOneIncluded() {
        // "a中b": block [1,2) — 中 starts at 1, included WHOLE (cells 1..2),
        // despite the right cell crossing the edge
        let r = VisualBlock.charRange(chars("a中b"), span: .init(1, 2), tabWidth: 4)
        #expect(r == 1..<2)
        // block [0,1): 中 starts at 1 — not included
        #expect(VisualBlock.charRange(chars("a中b"), span: .init(0, 1), tabWidth: 4) == 0..<1)
    }

    // MARK: - blockText (yank)

    @Test func blockTextJoinsRowsWithNewline() {
        // span [1,4) covers both slices whole (X at 1, XY at 2-3) —
        // fully covered graphemes go as is
        let text = VisualBlock.blockText(rows: [
            (chars: chars("abXYc"), range: 2..<4),
            (chars: chars("qXr"), range: 1..<2),
            (chars: chars("zz"), range: nil),
        ], span: .init(1, 4), tabWidth: 4)
        #expect(text == "XY\nX\n")
    }

    // MARK: - rowPlan (edits)

    @Test func rowPlanDeleteSlice() {
        let plan = VisualBlock.rowPlan(chars: chars("abcdef"), span: .init(2, 5),
                                       range: 2..<5, replacement: "", tabWidth: 4)
        #expect(plan.text == "abf")
        #expect(plan.caret == 2)
    }

    @Test func rowPlanReplaceSlice() {
        let plan = VisualBlock.rowPlan(chars: chars("abcdef"), span: .init(2, 5),
                                       range: 2..<5, replacement: "Z", tabWidth: 4)
        #expect(plan.text == "abZf")
        #expect(plan.caret == 3)
    }

    @Test func rowPlanWholeLineSlice() {
        let plan = VisualBlock.rowPlan(chars: chars("abc"), span: .init(0, 9),
                                       range: 0..<3, replacement: "", tabWidth: 4)
        #expect(plan.text == "")
        #expect(plan.caret == 0)
    }

    @Test func rowPlanNilSliceShortLinePadsToColumn() {
        // the line "ab" is shorter than column 5: padded with three spaces, insert at the tail
        let plan = VisualBlock.rowPlan(chars: chars("ab"), span: .init(5, 8),
                                       range: nil, replacement: "X", tabWidth: 4)
        #expect(plan.text == "ab   X")
        #expect(plan.caret == 6)
        #expect(plan.insertAt == 2)
    }

    @Test func rowPlanNilSliceShortTabLinePadsToColumn() {
        // a nil slice with intersecting cells means "the line ended
        // left of the block" (cells are contiguous, there can be no tail
        // past the block): "a\tz" (a 0, tab 1-3, z 4, width 5), block [6,8) —
        // insert past the tail with padding up to column 6
        let plan = VisualBlock.rowPlan(chars: chars("a\tz"), span: .init(6, 8),
                                       range: nil, replacement: "X", tabWidth: 4)
        #expect(plan.text == "a\tz X")
        #expect(plan.caret == 5)
        #expect(plan.insertAt == 3)
    }

    @Test func rowPlanUnicodeReplacements() {
        // replacement with multi-byte graphemes: the caret is counted in graphemes
        let plan = VisualBlock.rowPlan(chars: chars("a中c"), span: .init(1, 3),
                                       range: 1..<2, replacement: "文字", tabWidth: 4)
        #expect(plan.text == "a文字c")
        #expect(plan.caret == 3)
    }
}
