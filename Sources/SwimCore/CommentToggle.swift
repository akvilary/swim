/// The pure half of the visual-mode `/` — toggling line comments over
/// a selection. The effectful half lives in EditorWindow
/// (`toggleCommentInSelection`), which resolves the selection's rows,
/// applies the plan as one contiguous replace, and owns undo/LSP.
///
/// SEMANTICS (fixed with the project, pinned by tests):
///
/// - DIRECTION — the FIRST NON-BLANK line of the selection decides:
///   it carries the comment token at the anchor → `.remove` for all,
///   otherwise → `.add` for all. A blank line carries no marker and
///   must not decide (under nesting a blank decider would stack a new
///   layer on every press and the untoggle would never fire); an
///   all-blank selection has no decider — the honest no-op.
/// - LEADING BLANKS (empty or whitespace-only) are ignored in both
///   directions: the operation starts at the first non-blank line.
///   A SHORT but non-blank line is NOT blank — at a column anchor it
///   participates and gets the padded marker, and it can be the
///   decider (it has no content at the column, hence no token → add).
/// - ADD — NO EXCEPTIONS: every non-blank line of the selection ends
///   up with the token at the ONE shared column. A line already
///   commented elsewhere is not skipped and its marker is not moved —
///   it NESTS (one more token inserted at the shared column on top,
///   the line's own marker and indent untouched below). The inserted
///   token+space pair is exactly what REMOVE strips at the line's
///   first non-blank — the outer marker — so an untoggle restores the
///   former state byte-for-byte at the indent anchor (the column
///   anchor keeps the short-line padding caveat), a previously
///   commented line included. REMOVE strips the token plus one
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
        /// v (a selection starting mid-line on a content line): the
        /// FIRST line is column-anchored at the selection's start
        /// column — only the selected part (from there to the line's
        /// end) becomes the comment; every other covered line is whole
        /// and rides the indent machinery. Behaves as `column` in the
        /// primitives; `plan` decides per line which anchor applies. A
        /// selection starting on a blank line degrades to `indent`
        /// inside the planner (its start column lives in whitespace).
        case partial(_ column: Int, tabWidth: Int)
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
        case .column(let column, let tabWidth), .partial(let column, let tabWidth):
            return VisualBlock.charIndex(atDisplayCol: column, chars: chars, tabWidth: tabWidth)
        }
    }

    /// Does the line carry the token AT the anchor (the content from
    /// the anchor position starts with it)? The single detection
    /// primitive: the direction decision and the REMOVE pass read the
    /// same predicate, so they cannot drift apart. `starts(with:)` —
    /// lazy, allocation-free (a tail shorter than the token is simply
    /// not a prefix). The column-family add may have inserted ONE
    /// leading space (the marker glued to code) — the pair is detected
    /// together; at the indent anchor this never fires (the anchor
    /// position is non-blank by definition).
    static func isMarked(_ chars: [Character], token: [Character], anchor: Anchor) -> Bool {
        let i = anchorIndex(chars, anchor)
        if chars[i...].starts(with: token) { return true }
        return i < chars.count && chars[i] == " " && chars[(i + 1)...].starts(with: token)
    }

    /// The whole-selection plan. The direction comes from the FIRST
    /// NON-BLANK line (a blank line carries no marker — under nesting a
    /// blank decider would stack a layer on every press and the
    /// untoggle would never fire; the first non-blank line keeps the
    /// toggle a universal involution). ADD leaves no exceptions: every
    /// non-blank line receives the token at the shared column, an
    /// already-commented one NESTED (a second marker on top — its own
    /// marker and indent untouched); REMOVE strips the token plus one
    /// following space at each line's anchor — exactly the outer
    /// marker, so an untoggle restores the former state byte-for-byte
    /// at the indent anchor (the column anchor keeps the short-line
    /// padding caveat).
    public static func plan(lines: [String], token: String, anchor: Anchor) -> SelectionPlan {
        // Degenerate inputs never crash a public entry point (the
        // editor cannot produce them — a ClosedRange yields at least
        // one line, the token comes from the syntax table — but a
        // future caller or fixture can): an empty selection has no
        // decider, an empty token marks nothing and must remove
        // nothing (an always-matching empty prefix would otherwise
        // strip a space).
        let tokenChars = Array(token)
        guard !lines.isEmpty, !tokenChars.isEmpty else {
            return SelectionPlan(direction: .add,
                                 plans: lines.map {
                                     LinePlan(text: $0, editAt: 0, changed: false)
                                 })
        }
        let lineChars = lines.map { Array($0) }

        // The ignored leading blank run — blank lines neither receive
        // a marker nor decide the direction; the operation starts at
        // the first non-blank line.
        var start = 0
        while start < lineChars.count, isBlank(lineChars[start]) { start += 1 }
        // No decider (all blank) — nothing applicable in either
        // direction; the honest no-op.
        guard start < lineChars.count else {
            return SelectionPlan(direction: .add,
                                 plans: lines.map {
                                     LinePlan(text: $0, editAt: 0, changed: false)
                                 })
        }
        // The v-selection's partial anchor: when the selection STARTS
        // on a content line (start == 0 — no leading blanks), that one
        // line is column-anchored at the selection's start column
        // (only the selected part — from there to the line's end —
        // becomes the comment); every other covered line is whole and
        // rides the indent machinery. A selection starting on a blank
        // line degrades to pure indent — its start column lives in
        // whitespace and means nothing.
        let partialActive: Bool
        if case .partial = anchor, start == 0 { partialActive = true } else { partialActive = false }
        func effective(_ i: Int) -> Anchor {
            if partialActive && i == 0 { return anchor }
            if case .partial = anchor { return .indent }
            return anchor
        }

        let direction: Direction =
            isMarked(lineChars[start], token: tokenChars, anchor: effective(start)) ? .remove : .add

        // The indent anchor's shared marker column — the LEFTMOST
        // non-blank position among the selection's WHOLE lines, counted
        // in whitespace graphemes (uniform space or tab indentation
        // aligns visually). Blank lines contribute nothing; the partial
        // line is excluded (it is not whole — its marker column is the
        // selection's start, its indent does not constrain the rest);
        // already marked lines count (their marker position IS their
        // first non-blank) — so a nested marker never lands right of
        // the standing one and the column is never left of any content:
        // the marker never splits code, deeper lines keep their indent
        // riding AFTER the marker.
        var indentMarkerCol = Int.max
        for i in start..<lineChars.count
        where !isBlank(lineChars[i]) && !(partialActive && i == 0) {
            indentMarkerCol = min(indentMarkerCol, firstNonBlank(lineChars[i]))
        }
        if indentMarkerCol == Int.max {
            indentMarkerCol = 0 // no whole lines — unused by a partial-only plan
        }

        var plans: [LinePlan] = []
        plans.reserveCapacity(lines.count)
        for (i, chars) in lineChars.enumerated() {
            let lineAnchor = effective(i)
            let unchanged = LinePlan(text: lines[i],
                                     editAt: anchorIndex(chars, lineAnchor), changed: false)
            // The leading blank run is inert in both directions.
            guard i >= start else { plans.append(unchanged); continue }
            switch direction {
            case .add:
                // NO EXCEPTIONS: a line already carrying the token is
                // not skipped — it NESTS (the token inserted at the
                // shared column on top; its own marker and indent
                // stay). The marker/token+space pair inserted here is
                // exactly what the remove pass strips at the line's
                // first non-blank — the untoggle restores the line
                // byte-for-byte (indent anchor; a padded short line at
                // a column anchor keeps its padding).
                guard !isBlank(chars) || anchorIsColumn(lineAnchor)
                else { plans.append(unchanged); continue }
                plans.append(add(chars, token: token,
                                 anchor: lineAnchor, markerCol: indentMarkerCol))
            case .remove:
                guard isMarked(chars, token: tokenChars, anchor: lineAnchor)
                else { plans.append(unchanged); continue }
                plans.append(remove(chars, tokenChars: tokenChars, anchor: lineAnchor))
            }
        }
        return SelectionPlan(direction: direction, plans: plans)
    }

    static func anchorIsColumn(_ anchor: Anchor) -> Bool {
        switch anchor {
        case .column, .partial: return true
        case .indent: return false
        }
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
        case .column(let column, let tabWidth), .partial(let column, let tabWidth):
            let i = anchorIndex(chars, anchor)
            // Spaces around the marker, PAIRED with what remove strips
            // (the fuzz campaign pins the pairing): ONE leading space
            // when the marker would glue to code on its left (never
            // two — an existing separator stays; never at the line's
            // end or over padding — there is no left neighbor); the
            // trailing space UNCONDITIONALLY mid-line (the indent
            // anchor's doctrine: an unconditional insert pairs with an
            // unconditional strip — a conditional one is ambiguous
            // against the original text and loses bytes on the round
            // trip), absent at the line's end. The one honest wart: a
            // tail starting with whitespace takes a double space.
            let trailingSpace = i < chars.count
            let leadingSpace = i > 0 && i < chars.count
                && chars[i - 1] != " " && chars[i - 1] != "\t"
            var replacement = leadingSpace ? " " + token : token
            if trailingSpace { replacement += " " }
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
    /// REMOVE the token from one marked line: strip the token, the ONE
    /// leading space of the column-family pair when it sits at the
    /// anchor (the add inserted it against code; at the indent anchor
    /// the anchor position is non-blank — the branch never fires), and
    /// ONE trailing space when it is not the line's last character —
    /// the exact mirror of the add's unconditional-mid-line rule. Hand-
    /// written forms normalize into the pair (documented class, stable
    /// from the second cycle); nothing before the anchor and nothing
    /// beyond the pair is touched.
    static func remove(_ chars: [Character], tokenChars: [Character], anchor: Anchor) -> LinePlan {
        let b = anchorIndex(chars, anchor)
        var lead = 0
        if b < chars.count, chars[b] == " ", chars[(b + 1)...].starts(with: tokenChars) {
            lead = 1
        }
        let t = b + lead
        var drop = tokenChars.count
        if t + drop < chars.count, chars[t + drop] == " ", t + drop + 1 < chars.count {
            drop += 1
        }
        let text = String(chars[..<b]) + String(chars[(t + drop)...])
        return LinePlan(text: text, editAt: b, changed: true)
    }
}
