import Foundation

/// Visual-block (Ctrl+V) math: a rectangular selection lives in
/// display columns (terminal cells) and resolves against a line's
/// contents into a grapheme range. A pure stateless module — the
/// editor window feeds it lines (`PieceTable.getLineChars`) and
/// applies the result to the buffer; covered by tests
/// (Tests/SwimCoreTests/VisualBlockTests).
///
/// The membership rule — CELL INTERSECTION, uniform across
/// highlighting, yank and edits (behavior verified against vim 8.2 /
/// nvim 0.11 with scripts on the real editor): a grapheme is touched
/// by the block ⟺ its cells intersect [left, right). A tab cut by an
/// edge SPLITS — uncovered cells come back as spaces, the tail is
/// aligned the same way on every line; a wide glyph is atomic —
/// touched as a whole, its uncovered cells become spaces. Deliberate
/// deviations from vim in micro-cases (vim itself is inconsistent,
/// swim chooses uniformity): a block entirely inside a single tab is
/// ignored by vim — swim splits it; a block yank inside a single wide
/// glyph gives the whole glyph in vim — swim gives spaces for the
/// covered cells; the uncovered right part of a wide glyph vim does
/// not compensate (the tail shifts) — swim pads with a space, as for
/// tabs.
public enum VisualBlock {

    /// The block's bounds in display columns. The right one is exclusive.
    /// Width invariant: right >= left + 1 — a zero-width "block" is legal
    /// as the character under the cursor (Ctrl+V without a motion), but
    /// not as an empty set.
    public struct Span {
        public let left: Int
        public let right: Int

        /// Normalizes the pair (min/max) and builds the width up to 1.
        public init(_ a: Int, _ b: Int) {
            let lo = min(a, b)
            left = lo
            right = max(max(a, b), lo + 1)
        }

        /// An insertion point, not a selection: width 0, no normalization.
        /// At a grapheme boundary (as blockwise `p`/`P` places it — the
        /// real cursor's column) the slice is empty — pure insertion via
        /// rowPlan. A point INSIDE a glyph (tab/wide) that intersects
        /// cells yields a slice of that glyph — insertion splits it with
        /// spaces, as vim does with 've=block'.
        public static func point(_ col: Int) -> Span {
            Span(rawLeft: col, rawRight: col)
        }

        /// A selection span from two INCLUSIVE corner columns (anchor
        /// and cursor): [min, max + 1) — both corners in the block, as
        /// in vim (Ctrl+V + l and Ctrl+V + h give two cells). Adding
        /// "+1" to a corner BEFORE ordering is not allowed:
        /// init(anchor, cursor + 1) with the cursor left of the anchor
        /// gives [cursor + 1, anchor) — without both corners' cells.
        /// Width >= 1 by construction.
        public static func inclusive(_ a: Int, _ b: Int) -> Span {
            Span(rawLeft: min(a, b), rawRight: max(a, b) + 1)
        }

        private init(rawLeft: Int, rawRight: Int) {
            left = rawLeft
            right = rawRight
        }
    }

    /// Full block geometry from window state: rows + display span.
    /// The anchor arrives as a REAL position (a grapheme on the anchor
    /// line) and resolves to a display column against ITS OWN line's
    /// contents (each line has its own tab layout); the cursor corner
    /// is already a virtual cell. Both corners are inclusive
    /// (Span.inclusive), rows — min/max. The whole "anchor + corner →
    /// rectangle" composition lives here under tests; the window's
    /// blockRowsAndSpan is pure wiring (the "missing cell with
    /// Ctrl+V + h" regression lived precisely in this composition).
    public static func blockGeometry(anchorLine: Int, anchorCharCol: Int,
                                     cursorLine: Int, cursorBlockCol: Int,
                                     anchorChars: [Character], tabWidth: Int)
            -> (rows: ClosedRange<Int>, span: Span) {
        let anchorDisp = displayCol(ofCharIndex: anchorCharCol, chars: anchorChars, tabWidth: tabWidth)
        return (min(anchorLine, cursorLine)...max(anchorLine, cursorLine),
                Span.inclusive(anchorDisp, cursorBlockCol))
    }

    /// The display column where grapheme `charIndex` starts
    /// (a prefix sum of steps; charIndex is clamped to the line
    /// length — the "past the last character" position gives the
    /// line's full width).
    public static func displayCol(ofCharIndex charIndex: Int,
                                  chars: [Character], tabWidth: Int) -> Int {
        var col = 0
        for i in 0..<min(charIndex, chars.count) {
            col += chars[i].displayStep(atDisplayCol: col, tabWidth: tabWidth)
        }
        return col
    }

    /// The index of the first grapheme whose starting display column
    /// is >= target (line shorter than target — the line length:
    /// position past the tail). The boundary always lands on a
    /// grapheme start: a tab that began left of target is skipped
    /// entirely.
    public static func charIndex(atDisplayCol target: Int,
                                 chars: [Character], tabWidth: Int) -> Int {
        var col = 0
        for (i, ch) in chars.enumerated() {
            if col >= target { return i }
            col += ch.displayStep(atDisplayCol: col, tabWidth: tabWidth)
        }
        return chars.count
    }

    /// Cell ranges of a line's graphemes: [i] = [start, end) in
    /// display cells (tab — up to the next tab stop, wide —
    /// 2 cells, combining — 0). The single source for membership
    /// (intersection with [left, right)), tab splitting in rowPlan,
    /// and highlighting.
    public static func glyphCells(_ chars: [Character], tabWidth: Int) -> [(start: Int, end: Int)] {
        var out: [(start: Int, end: Int)] = []
        out.reserveCapacity(chars.count)
        var col = 0
        for ch in chars {
            let step = ch.displayStep(atDisplayCol: col, tabWidth: tabWidth)
            out.append((col, col + step))
            col += step
        }
        return out
    }

    /// The range of a line's graphemes touched by the block: the
    /// grapheme's cells intersect [left, right) — tabs/wide cut by an
    /// edge are included (split/taken whole, see the rule in the
    /// module header). nil — no intersections (the line is empty,
    /// ended left of the edge, or lies entirely past the right one).
    public static func charRange(_ chars: [Character], span: Span,
                                 tabWidth: Int) -> Range<Int>? {
        let cells = glyphCells(chars, tabWidth: tabWidth)
        var lo = 0
        while lo < cells.count, !(cells[lo].start < span.right && cells[lo].end > span.left) {
            lo += 1
        }
        var hi = cells.count
        while hi > lo, !(cells[hi - 1].start < span.right && cells[hi - 1].end > span.left) {
            hi -= 1
        }
        return lo < hi ? lo..<hi : nil
    }

    /// Blockwise yank text: each line's contribution — slice graphemes
    /// fully covered by the block go as-is; partially covered ones
    /// (an edge inside a glyph) — as SPACES of the covered cells (vim
    /// yanks the visible cell strip, not the characters). A nil slice —
    /// an empty contribution; lines are joined with "\n" without a
    /// trailing break, short lines are NOT padded to the block width
    /// (padding appears at paste time).
    public static func blockText(rows: [(chars: [Character], range: Range<Int>?)],
                                 span: Span, tabWidth: Int) -> String {
        rows.map { row in
            guard let r = row.range else { return "" }
            let cells = glyphCells(row.chars, tabWidth: tabWidth)
            var s = ""
            for i in r {
                let c = cells[i]
                if c.start >= span.left && c.end <= span.right {
                    s += String(row.chars[i])
                } else {
                    s += String(repeating: " ", count: min(c.end, span.right) - max(c.start, span.left))
                }
            }
            return s
        }.joined(separator: "\n")
    }

    /// An edit plan for one block line: new contents, the "past the
    /// replacement" caret point, and the bounds of the replaced range
    /// (in line graphemes — for conversion to bytes).
    /// - Slice exists: text = prefix + replacement + suffix, caret —
    ///   past the replacement. Glyphs cut by edges split: their cells
    ///   outside the block come back as spaces — into the prefix (the
    ///   left straddler) and the suffix (the right one), tabs and wide
    ///   alike; the tail aligns to the block's left edge on every line
    ///   (vim parity, verified: "\tqrs" [2,4) → "  qrs", "x\tz"
    ///   [1,3) → "x z", "中x" [1,3) → " ").
    /// - No slice (the line falls short of the block): insertion at
    ///   the first grapheme boundary at/after the left edge, with the
    ///   line padded with spaces up to the column if needed (the
    ///   blockwise insertion rule — short lines are padded to the
    ///   target column, like curswant in vim); the line tail
    ///   (characters past the right edge) is preserved.
    public struct RowPlan {
        public let text: String
        public let caret: Int
        /// The replaced range (nil — pure insertion).
        public let range: Range<Int>?
        /// The insertion point in graphemes for a line without a slice.
        public let insertAt: Int
    }

    public static func rowPlan(chars: [Character], span: Span,
                               range: Range<Int>?, replacement: String,
                               tabWidth: Int) -> RowPlan {
        if let r = range {
            let cells = glyphCells(chars, tabWidth: tabWidth)
            var prefix = String(chars[..<r.lowerBound])
            if cells[r.lowerBound].start < span.left {
                prefix += String(repeating: " ", count: span.left - cells[r.lowerBound].start)
            }
            var suffix = String(chars[r.upperBound...])
            if cells[r.upperBound - 1].end > span.right {
                suffix = String(repeating: " ", count: cells[r.upperBound - 1].end - span.right) + suffix
            }
            return RowPlan(text: prefix + replacement + suffix,
                           caret: prefix.count + replacement.count,
                           range: r,
                           insertAt: r.lowerBound)
        }
        let at = charIndex(atDisplayCol: span.left, chars: chars, tabWidth: tabWidth)
        let before = displayCol(ofCharIndex: at, chars: chars, tabWidth: tabWidth)
        let pad = max(0, span.left - before)
        let head = String(chars[..<at]) + String(repeating: " ", count: pad)
        return RowPlan(text: head + replacement + String(chars[at...]),
                       caret: head.count + replacement.count,
                       range: nil,
                       insertAt: at)
    }
}
