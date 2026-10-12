import Testing
import SwimCore

/// NormalMotion — назначения движений и нормализация операторных
/// диапазонов: vim-категории (exclusive/inclusive/linewise), сортировка
/// назад-идущих, adjustment «exclusive-конец в начале строки → конец
/// предыдущей строки», clamp'ы и пустые диапазоны.
@Suite struct NormalMotionTests {
    private func dest(_ m: NormalMotion, _ text: String,
                      line: Int = 0, col: Int = 0, count: Int? = nil) -> NormalMotion.Destination {
        NormalMotion.destination(of: m, in: PieceTable(text: text), line: line, col: col, count: count)
    }

    private func range(_ text: String, cursorLine: Int, cursorCol: Int,
                       _ m: NormalMotion, count: Int? = nil) -> NormalMotion.OperatorRange? {
        let buf = PieceTable(text: text)
        let d = NormalMotion.destination(of: m, in: buf, line: cursorLine, col: cursorCol, count: count)
        return NormalMotion.operatorRange(cursorLine: cursorLine, cursorCol: cursorCol,
                                          destination: d, in: buf)
    }

    // MARK: - Назначения

    @Test func leftRightClamp() {
        #expect(dest(.left, "hello", col: 2).col == 1)
        #expect(dest(.left, "hello", col: 1, count: 5).col == 0)
        #expect(dest(.right, "hello", col: 1).col == 2)
        #expect(dest(.right, "hello", col: 3, count: 9).col == 4)
        #expect(dest(.right, "hello", col: 4, count: 2).col == 4)
        // one-past-end (после вертикального перемещения) — без движения
        #expect(dest(.right, "hello", col: 5, count: 1).col == 5)
    }

    @Test func upDownClamp() {
        #expect(dest(.down, "a\nb\nc", line: 1, col: 1).line == 2)
        #expect(dest(.down, "a\nb\nc", line: 1, col: 1, count: 9).line == 2)
        #expect(dest(.up, "a\nb\nc", line: 2).line == 1)
        #expect(dest(.up, "a\nb\nc", line: 1, count: 9).line == 0)
    }

    @Test func wordMotionsWithCount() {
        #expect(dest(.wordForward, "aa bb cc dd", col: 0).col == 3)
        #expect(dest(.wordForward, "aa bb cc dd", col: 0, count: 3).col == 9)
        #expect(dest(.wordBackward, "aa bb cc dd", col: 9).col == 6)
        #expect(dest(.wordEnd, "aa bb cc dd", col: 4).col == 7) // хвост bb → конец cc
        // через строки
        #expect(dest(.wordForward, "foo\nbar", col: 0) == NormalMotion.Destination(line: 1, col: 0, kind: .exclusive))
    }

    @Test func endOfLineWithCountSpansLines() {
        #expect(dest(.endOfLine, "foo\nbar", col: 0).col == 2)
        let d = dest(.endOfLine, "foo\nbar", col: 0, count: 2)
        #expect(d.line == 1 && d.col == 2)
    }

    @Test func fileStartFileEndWithCount() {
        let text = "a\nb\nc"
        // Без счёта — дефолты (vim G → последняя, gg → первая); счёт
        // задаёт строку 1-based: 1G — тоже первая
        #expect(dest(.fileEnd, text).line == 2)
        #expect(dest(.fileEnd, text, count: 2).line == 1)
        #expect(dest(.fileEnd, text, count: 1).line == 0)
        #expect(dest(.fileStart, text, line: 2).line == 0)
        #expect(dest(.fileStart, text, line: 2, count: 2).line == 1)
        // Защитный clamp публичного API: count ≤ 0 реальный ввод не
        // даёт, но и -1-строкой он не должен становиться
        #expect(dest(.fileEnd, text, count: 0).line == 0)
        #expect(dest(.fileStart, text, count: -3).line == 0)
    }

    // MARK: - Linewise диапазоны

    @Test func linewiseOrderedBothDirections() {
        #expect(range("a\nb\nc", cursorLine: 1, cursorCol: 1, .fileEnd)
                == .linewise(lower: 1, upper: 2))
        #expect(range("a\nb\nc", cursorLine: 1, cursorCol: 1, .fileStart)
                == .linewise(lower: 0, upper: 1))
        #expect(range("a\nb\nc", cursorLine: 1, cursorCol: 1, .down)
                == .linewise(lower: 1, upper: 2))
        #expect(range("a\nb\nc", cursorLine: 1, cursorCol: 1, .up)
                == .linewise(lower: 0, upper: 1))
        // dj на последней строке — clamp в однострочный диапазон (как dd)
        #expect(range("a\nb\nc", cursorLine: 2, cursorCol: 0, .down)
                == .linewise(lower: 2, upper: 2))
        // d2j — три строки (курсор + две вниз)
        #expect(range("a\nb\nc\nd", cursorLine: 1, cursorCol: 0, .down, count: 2)
                == .linewise(lower: 1, upper: 3))
    }

    // MARK: - Charwise диапазоны

    @Test func exclusiveForward() {
        // dw на первом слове: "foo " (с хвостовым пробелом, как vim)
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .wordForward)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 4))
        // d0 — от курсора до начала строки
        #expect(range("foo bar", cursorLine: 0, cursorCol: 5, .bol)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 5))
    }

    @Test func inclusivePlusOne() {
        // de — слово без пробела; d$ — вся строка без терминатора
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .wordEnd)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 3))
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .endOfLine)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 7))
        // dl — один символ (l exclusive, vim: dl == x)
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .right)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 1))
        // d3l — три символа
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .right, count: 3)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 3))
    }

    @Test func backwardOrdered() {
        // db из середины слова: b идёт на начало ТЕКУЩЕГО слова,
        // exclusive до курсора — удаляется "b" (vim)
        #expect(range("foo bar", cursorLine: 0, cursorCol: 5, .wordBackward)
                == .charwise(startLine: 0, startCol: 4, endLine: 0, endCol: 5))
        // db с пробела перед словом — на начало предыдущего слова
        #expect(range("foo bar", cursorLine: 0, cursorCol: 3, .wordBackward)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 3))
        // dh — один символ слева (exclusive)
        #expect(range("foo bar", cursorLine: 0, cursorCol: 3, .left)
                == .charwise(startLine: 0, startCol: 2, endLine: 0, endCol: 3))
    }

    // MARK: - Adjustment: exclusive-конец в начале строки

    @Test func dwAcrossNewlineKeepsIt() {
        // dw на последнем слове строки: назначение — BOL следующей,
        // конец переносится на EOL текущей: перевод строки сохраняется
        #expect(range("foo bar\nbaz", cursorLine: 0, cursorCol: 4, .wordForward)
                == .charwise(startLine: 0, startCol: 4, endLine: 0, endCol: 7))
    }

    @Test func dbAtBOLKeepsNewline() {
        // db на BOL: конец (курсор) в колонке 0 → vim :h exclusive
        // правило 1 — конец переносится на конец предыдущей строки,
        // диапазон НЕ включает терминатор: удаляется слово, строки
        // не склеиваются
        #expect(range("foo bar\nbaz", cursorLine: 1, cursorCol: 0, .wordBackward)
                == .charwise(startLine: 0, startCol: 4, endLine: 0, endCol: 7))
    }

    @Test func dwOnLastWordOfBuffer() {
        // Хвост буфера с переводом: unclamped w доходит до фантомной
        // строки, adjustment возвращает конец на EOL — слово целиком
        #expect(range("ab cd\n", cursorLine: 0, cursorCol: 3, .wordForward)
                == .charwise(startLine: 0, startCol: 3, endLine: 0, endCol: 5))
        #expect(range("ab cd", cursorLine: 0, cursorCol: 3, .wordForward)
                == .charwise(startLine: 0, startCol: 3, endLine: 0, endCol: 5))
    }

    // MARK: - Пустые диапазоны

    @Test func emptyRangesAreNil() {
        // dh в колонке 0
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .left) == nil)
        // dl на one-past-end (паритет с x)
        #expect(range("foo bar", cursorLine: 0, cursorCol: 7, .right) == nil)
        // d0 в колонке 0
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .bol) == nil)
        // db на самом первом слове буфера
        #expect(range("foo bar", cursorLine: 0, cursorCol: 0, .wordBackward) == nil)
        // dw на последнем слове однострочного буфера без перевода —
        // НЕ пустой: слово удаляется целиком (unclamped + adjustment
        // здесь не нужен, конец и так за словом)
        #expect(range("foo", cursorLine: 0, cursorCol: 0, .wordForward)
                == .charwise(startLine: 0, startCol: 0, endLine: 0, endCol: 3))
    }

    @Test func multilineCharwiseViaCountedDollar() {
        // d2$ — от курсора до конца следующей строки (включая перевод
        // первой: байтовый диапазон сквозной)
        #expect(range("foo\nbar", cursorLine: 0, cursorCol: 0, .endOfLine, count: 2)
                == .charwise(startLine: 0, startCol: 0, endLine: 1, endCol: 3))
    }
}
