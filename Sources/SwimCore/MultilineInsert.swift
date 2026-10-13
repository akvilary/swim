/// Where the editing cursor lands after a multiline string is inserted
/// at a position — counted in the editor's units: whole lines down, and
/// grapheme clusters ("characters", the cursor's column unit — never
/// bytes: a CJK or emoji tail is 2+ bytes but one column-step) past the
/// start of the final line. Pure math over the inserted text only; the
/// caller adds the delta to its own (line, col).
public enum MultilineInsert {

    public static func cursorDelta(for text: String) -> (lines: Int, tailCols: Int) {
        // Line breaks are counted at the SCALAR level: in Swift CRLF is
        // a single grapheme, and the Character == "\n" comparison misses
        // it (a latent bug exposed by CRLF registers: cursorDelta of
        // "\r\n" text returned lines=0). The tail is counted in
        // graphemes — cursor columns are grapheme-based.
        var lines = 0
        var lastNL: String.Index? = nil
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx].unicodeScalars.contains(where: { $0 == "\n" }) {
                lines += 1
                lastNL = idx
            }
            idx = text.index(after: idx)
        }
        guard let last = lastNL else { return (0, text.count) }
        return (lines, text.distance(from: text.index(after: last), to: text.endIndex))
    }

    /// Whether the text ends with a line break — at the SCALAR level:
    /// in Swift CRLF is ONE grapheme, and `hasSuffix("\n")` is false
    /// for CRLF text (a latent bug masked while linewise yanks
    /// normalized terminators to LF; exposed by CRLF registers:
    /// paste degraded to charwise and tore lines apart mid-line).
    /// The single linewise sniffing point for all of the editor's
    /// paste paths.
    public static func endsWithLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.last == "\n"
    }
}
