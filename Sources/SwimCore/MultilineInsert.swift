/// Where the editing cursor lands after a multiline string is inserted
/// at a position — counted in the editor's units: whole lines down, and
/// grapheme clusters ("characters", the cursor's column unit — never
/// bytes: a CJK or emoji tail is 2+ bytes but one column-step) past the
/// start of the final line. Pure math over the inserted text only; the
/// caller adds the delta to its own (line, col).
public enum MultilineInsert {

    public static func cursorDelta(for text: String) -> (lines: Int, tailCols: Int) {
        guard let lastNL = text.lastIndex(of: "\n") else {
            return (0, text.count)
        }
        let lines = text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        return (lines, text.distance(from: text.index(after: lastNL), to: text.endIndex))
    }
}
