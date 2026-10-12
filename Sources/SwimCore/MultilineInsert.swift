/// Where the editing cursor lands after a multiline string is inserted
/// at a position — counted in the editor's units: whole lines down, and
/// grapheme clusters ("characters", the cursor's column unit — never
/// bytes: a CJK or emoji tail is 2+ bytes but one column-step) past the
/// start of the final line. Pure math over the inserted text only; the
/// caller adds the delta to its own (line, col).
public enum MultilineInsert {

    public static func cursorDelta(for text: String) -> (lines: Int, tailCols: Int) {
        // Переводы строк считаются на уровне СКАЛЯРОВ: в Swift CRLF —
        // одна графема, и сравнение Character == "\n" пропускает её
        // (латентный баг, вскрытый CRLF-регистрами: cursorDelta
        // "\r\n"-текста давал lines=0). Хвост считается в графемах —
        // курсорные колонки графемные.
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

    /// Текст завершается переводом строки — на уровне СКАЛЯРОВ: в
    /// Swift CRLF — ОДНА графема, и `hasSuffix("\n")` для CRLF-текста
    /// ложен (латентный баг, замаскированный, пока linewise-янки
    /// нормализовали терминаторы в LF; вскрыт CRLF-регистрами:
    /// вставка деградировала в charwise и рвала строки посреди).
    /// Единая точка linewise-снифа для всех paste-путей редактора.
    public static func endsWithLineBreak(_ text: String) -> Bool {
        text.unicodeScalars.last == "\n"
    }
}
