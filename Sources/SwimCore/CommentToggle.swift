/// The pure half of the visual-mode `/` — toggling line comments over
/// a selection. The effectful half lives in EditorWindow
/// (`toggleCommentInSelection`), which resolves the selection's rows,
/// applies the plan as one contiguous replace, and owns undo/LSP.
///
/// SEMANTICS (fixed with the project, pinned by tests):
///
/// - DIRECTION — the FIRST line of the selection always decides: it
///   carries the comment token at the anchor → `.remove` for all,
///   otherwise → `.add` for all. A blank first line can never carry a
///   token, so it means `.add` — no scanning for "the first line that
///   could decide"; the literal first line is the decider.
/// - LEADING BLANKS (empty or whitespace-only) are ignored in both
///   directions: the operation starts at the first non-blank line.
///   A SHORT but non-blank line is NOT blank — at a column anchor it
///   participates and gets the padded marker, and it can be the
///   decider (it has no content at the column, hence no token → add).
/// - ADD touches only lines that do not already carry the token at the
///   anchor (never a double marker); REMOVE strips the token plus one
///   following space when present. Removal is deliberately
///   conservative: alignment spaces the writer may have placed before
///   the marker, and the padding a previous blockwise add introduced,
///   stay (pressing again is stable from the second cycle — nothing
///   accumulates).
/// - BLANK LINES in the middle/end: at the indent anchor they never
///   receive a marker (VS Code behavior); at a column anchor they do,
///   padded to the column — the rectangle's marker column stays
///   continuous (vim-commentary behavior), by explicit product choice.
/// - ANCHORS: `.indent` (charwise/linewise visual) — ONE marker column
///   for the whole selection: the LEFTMOST non-blank position among
///   its lines (whitespace graphemes counted; blank lines contribute
///   nothing, already-marked lines count so new markers align with the
///   standing ones). No line's content starts left of the column by
///   construction — the marker never splits code — and deeper lines
///   keep their indent riding AFTER the marker, so the
///   comment→uncomment round trip is byte-exact; blank lines never
///   receive a marker. A column anchor (blockwise visual) — the marker
///   lands at the rectangle's left edge in display cells, on the first
///   grapheme boundary at/after the column, short lines padded with
///   spaces — the same insertion rule as blockwise paste
///   (VisualBlock.rowPlan with a point span).
///
/// Token detection is syntax-blind by design (a `//` inside a string
/// literal is still a marker as far as line comments go) — the same
/// blindness as VS Code, vim-commentary, and every other swim operator
/// (`d`/`x`/`y` do not parse syntax either).
public enum CommentToggle {

    /// Where the marker goes — the visual mode's geometry, reduced to
    /// the one fact the planner needs.
    public enum Anchor: Equatable, Sendable {
        /// v/V: ONE marker column for the whole selection — the
        /// leftmost non-blank position among its lines.
        case indent
        /// Ctrl+V: the rectangle's left edge, in display cells
        /// (terminal cells, tab layout per line), with the tab width
        /// for the display math.
        case column(_ column: Int, tabWidth: Int)
    }

    /// What the first line decided for the whole selection.
    public enum Direction: Equatable, Sendable {
        case add
        case remove
    }

    /// One line's outcome: the new content (terminator excluded), the
    /// marker position in it (graphemes — the editor's cursor unit),
    /// and whether anything changed. Unchanged lines carry their
    /// original text so the executor can reassemble a whole span.
    public struct LinePlan: Equatable, Sendable {
        public let text: String
        public let editAt: Int
        public let changed: Bool
    }

    /// The whole selection's outcome: the direction the first line
    /// chose plus one plan per input line, index-aligned.
    public struct SelectionPlan: Equatable, Sendable {
        public let direction: Direction
        public let plans: [LinePlan]
    }

    /// A line with no code: empty or nothing but spaces/tabs. Such
    /// lines never carry a marker at the indent anchor, are skipped by
    /// the ADD pass there, and form the ignored leading run at both
    /// anchors.
    static func isBlank(_ chars: [Character]) -> Bool {
        chars.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// The first non-blank grapheme index (== chars.count for a blank
    /// line) — the indent anchor's marker position.
    static func firstNonBlank(_ chars: [Character]) -> Int {
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        return i
    }

    /// The grapheme index the anchor points at: first non-blank for
    /// `.indent`, the first grapheme boundary at/after the display
    /// column for `.column` (a tab straddling the column is skipped
    /// whole — the marker cannot split it; parity with blockwise
    /// paste).
    static func anchorIndex(_ chars: [Character], _ anchor: Anchor) -> Int {
        switch anchor {
        case .indent:
            return firstNonBlank(chars)
        case .column(let column, let tabWidth):
            return VisualBlock.charIndex(atDisplayCol: column, chars: chars, tabWidth: tabWidth)
        }
    }

    /// Does the line carry the token AT the anchor (the content from
    /// the anchor position starts with it)? The single detection
    /// primitive: the direction decision and the REMOVE pass read the
    /// same predicate, so they cannot drift apart. `starts(with:)` —
    /// lazy, allocation-free (a tail shorter than the token is simply
    /// not a prefix).
    static func isMarked(_ chars: [Character], token: [Character], anchor: Anchor) -> Bool {
        let i = anchorIndex(chars, anchor)
        return chars[i...].starts(with: token)
    }

    /// The whole-selection plan. The direction comes from `lines[0]`
    /// (blank ⇒ add — a blank line never carries a token), then every
    /// line is processed with that one direction; lines already in the
    /// target state are left alone.
    public static func plan(lines: [String], token: String, anchor: Anchor) -> SelectionPlan {
        // Degenerate inputs never crash a public entry point (the
        // editor cannot produce them — a ClosedRange yields at least
        // one line, the token comes from the syntax table — but a
        // future caller or fixture can): an empty selection has no
        // decider, an empty token marks nothing and must remove
        // nothing (an always-matching empty prefix would otherwise
        // strip a space).
        let tokenChars = Array(token)
        guard let firstChars = lines.first.map({ Array($0) }), !tokenChars.isEmpty else {
            return SelectionPlan(direction: .add,
                                 plans: lines.map {
                                     LinePlan(text: $0, editAt: 0, changed: false)
                                 })
        }
        let lineChars = lines.map { Array($0) }
        let direction: Direction =
            isMarked(firstChars, token: tokenChars, anchor: anchor) ? .remove : .add

        // The ignored leading blank run — the operation starts at the
        // first non-blank line (both anchors; blank first lines decided
        // "add" but receive nothing themselves).
        var start = 0
        while start < lineChars.count, isBlank(lineChars[start]) { start += 1 }

        // The indent anchor's shared marker column — the LEFTMOST
        // non-blank position among the selection's lines, counted in
        // whitespace graphemes (uniform space or tab indentation
        // aligns visually). Blank lines contribute nothing; already
        // marked lines count — so new markers align with the ones
        // already standing. No line's content starts left of the
        // column by construction (it IS the leftmost), so the marker
        // never splits code, and deeper lines keep their indent riding
        // AFTER the marker (the round trip stays byte-exact).
        var indentMarkerCol = Int.max
        for i in start..<lineChars.count where !isBlank(lineChars[i]) {
            indentMarkerCol = min(indentMarkerCol, firstNonBlank(lineChars[i]))
        }
        if indentMarkerCol == Int.max { indentMarkerCol = 0 } // all blank — unused

        var plans: [LinePlan] = []
        plans.reserveCapacity(lines.count)
        for (i, chars) in lineChars.enumerated() {
            let unchanged = LinePlan(text: lines[i], editAt: anchorIndex(chars, anchor), changed: false)
            // The leading blank run is inert in both directions.
            guard i >= start else { plans.append(unchanged); continue }
            switch direction {
            case .add:
                guard !isBlank(chars) || anchorIsColumn(anchor),
                      !isMarked(chars, token: tokenChars, anchor: anchor)
                else { plans.append(unchanged); continue }
                plans.append(add(chars, token: token,
                                 anchor: anchor, markerCol: indentMarkerCol))
            case .remove:
                guard isMarked(chars, token: tokenChars, anchor: anchor)
                else { plans.append(unchanged); continue }
                plans.append(remove(chars, tokenChars: tokenChars, anchor: anchor))
            }
        }
        return SelectionPlan(direction: direction, plans: plans)
    }

    static func anchorIsColumn(_ anchor: Anchor) -> Bool {
        if case .column = anchor { return true }
        return false
    }

    /// ADD one line: insert the token (plus one space) at the anchor.
    /// At the indent anchor the position is ONE SHARED COLUMN for the
    /// whole selection — the leftmost non-blank position among its
    /// lines (`markerCol`): the column is the minimum by construction,
    /// so this line's content starts at or right of it (its leading
    /// whitespace up to the column is all whitespace) and its deeper
    /// indent rides AFTER the marker — one vertical column, round trip
    /// byte-exact, never a marker inside code. The space after the
    /// token is unconditional there: the remove pass drops exactly
    /// token + one space, so the shifted whitespace returns
    /// byte-for-byte.
    /// At a column anchor the insertion rides the tested blockwise
    /// rule: boundary at/after the column, short lines padded up to it
    /// (VisualBlock.rowPlan over a point span).
    static func add(_ chars: [Character], token: String,
                    anchor: Anchor, markerCol: Int) -> LinePlan {
        switch anchor {
        case .indent:
            // markerCol <= this line's first non-blank position (it is
            // the minimum over the set including this line), so the
            // slice below is provably whitespace — never splits code.
            let head = String(chars[..<markerCol])
            let text = head + token + " " + String(chars[markerCol...])
            return LinePlan(text: text, editAt: head.count, changed: true)
        case .column(let column, let tabWidth):
            let i = anchorIndex(chars, anchor)
            // The space after the token only when real content follows
            // at the insertion point — a whitespace neighbor or the
            // line's end takes the bare token (no trailing space).
            let nextDemandsSpace = i < chars.count && chars[i] != " " && chars[i] != "\t"
            let replacement = nextDemandsSpace ? token + " " : token
            let rowPlan = VisualBlock.rowPlan(chars: chars, span: .point(column),
                                              range: nil, replacement: replacement,
                                              tabWidth: tabWidth)
            return LinePlan(text: rowPlan.text, editAt: rowPlan.caret - replacement.count,
                            changed: true)
        }
    }

    /// REMOVE the token from one marked line: drop the token and one
    /// following space when present. Nothing before the anchor and
    /// nothing beyond the marker is touched — conservative by design
    /// (hand-written alignment and a previous add's padding survive).
    static func remove(_ chars: [Character], tokenChars: [Character], anchor: Anchor) -> LinePlan {
        let i = anchorIndex(chars, anchor)
        var drop = tokenChars.count
        if i + drop < chars.count, chars[i + drop] == " " { drop += 1 }
        let text = String(chars[..<i]) + String(chars[(i + drop)...])
        return LinePlan(text: text, editAt: i, changed: true)
    }
}
