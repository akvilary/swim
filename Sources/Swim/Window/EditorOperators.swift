//
//  EditorOperators.swift
//  Swim
//
//  Operator-pending механика normal-режима (vim): взведённый оператор
//  (d/y/c) + движение → действие над диапазоном. Диспетчер handleNormal
//  (EditorWindow.swift) маршрутизирует в порядке gPrefix → operator-
//  pending → обычные команды — при взведённом операторе обычные ветки
//  недостижимы, движение не может «проехать мимо» оператора (баг
//  прошлого: dw двигал курсор). Диапазоны и назначения — чистый
//  SwimCore.NormalMotion (тестируется); здесь только применение:
//  yank/delete/change одним undo-шагом, курсор и регистры.
//

import SwimCore

extension EditorWindow {

    // MARK: - Диспетчер operator-pending

    /// Ключ при взведённом операторе. Удвоение (dd/yy/cc) — linewise на
    /// N строк; `g` взводит g-префикс движения (`dgg`); движения —
    /// аргументы оператора; прочий ключ — смерть последовательности
    /// (false → defer-сброс хвоста handleNormal, как ошибка vim).
    /// Слот оператора не берётся явно: сброс делает хвостовой defer.
    func handleOperatorPending(_ key: Key, keepPending: inout Bool) -> Bool {
        switch key {
        case .escape:
            // Тихий abort (vim: ESC в operator-pending) — потреблён
            return true
        case .char("g"):
            // dgg/ygg/cgg: g-префикс, под оператором валидно только `gg`
            pending.armGPrefix()
            keepPending = true
            return true
        case .char("d"):
            guard pending.op == .d else { return false }
            applyLinewise(op: .d, count: pending.takeCount() ?? 1)
        case .char("y"):
            guard pending.op == .y else { return false }
            applyLinewise(op: .y, count: pending.takeCount() ?? 1)
        case .char("c"):
            guard pending.op == .c else { return false }
            applyLinewise(op: .c, count: pending.takeCount() ?? 1)
        default:
            guard let armed = pending.op, let motion = Self.normalMotion(for: key) else {
                return false
            }
            applyOperator(armed, motion: motion, count: pending.takeCount())
        }
        return true
    }

    /// Ключ → движение normal-режима (та же таблица работает перемещением
    /// в normal и аргументом оператора в operator-pending). `gg` приходит
    /// через g-префикс (handleGPrefix), здесь только одиночные клавиши.
    /// Enter — linewise вниз (vim: d<CR> == dj); в plain-режиме .enter
    /// сюда не доходит (не наш ключ) — поведение обычного Enter не меняется.
    static func normalMotion(for key: Key) -> NormalMotion? {
        switch key {
        case .char("h"), .left: return .left
        case .char("j"), .down: return .down
        case .char("k"), .up: return .up
        case .char("l"), .right: return .right
        case .char("w"): return .wordForward
        case .char("b"): return .wordBackward
        case .char("e"): return .wordEnd
        case .char("$"), .end: return .endOfLine
        case .char("0"), .home: return .bol
        case .char("G"): return .fileEnd
        case .enter: return .down
        default: return nil
        }
    }

    // MARK: - Применение операторов

    /// Оператор + движение со счётом (nil — счёта не было; дефолты
    /// движений — в NormalMotion.destination): диапазон от NormalMotion,
    /// действие по категории. Пустой диапазон — no-op (`c` просто
    /// входит в insert).
    func applyOperator(_ op: NormalPending.Op, motion: NormalMotion, count: Int?) {
        guard let buf = buffer else { return }
        var m = motion
        if op == .c, case .wordForward = motion, cursorOnNonBlank(buf) {
            m = .wordEnd // vim i_cw: cw на не-бланке ведёт себя как ce
        }
        let dest = NormalMotion.destination(of: m, in: buf, line: cursorLine, col: cursorCol, count: count)
        guard let range = NormalMotion.operatorRange(cursorLine: cursorLine, cursorCol: cursorCol,
                                                     destination: dest, in: buf) else {
            if op == .c { mode = .insert }
            return
        }
        switch range {
        case .linewise(let lower, let upper):
            applyLinewiseRange(op, lower: lower, upper: upper)
        case .charwise(let startLine, let startCol, let endLine, let endCol):
            applyCharwiseRange(op, startLine: startLine, startCol: startCol, endLine: endLine, endCol: endCol)
        }
    }

    /// Удвоенный оператор (dd/yy/cc) — linewise на N строк от курсора.
    func applyLinewise(op: NormalPending.Op, count: Int) {
        guard let buf = buffer else { return }
        let last = max(0, buf.lineCount - 1)
        applyLinewiseRange(op, lower: cursorLine, upper: min(cursorLine + count - 1, last))
    }

    /// Linewise-действие над диапазоном строк. Фантомная строка
    /// (start == totalLength) — артефакт буфера, не контент (та же
    /// политика, что shiftVisualLines): Ndd/Nyy/dj/dG, заезжающие на
    /// неё, не тянут её в диапазон и регистр (vim: 3dd на
    /// предпоследней строке даёт двухстрочный регистр). Yank — с
    /// терминаторами исходного файла (CRLF-round-trip, linewise-
    /// гарантия последней строки без перевода). Delete/change — один
    /// buf.delete + один undo-шаг; `cc` пере-вставляет отступ первой
    /// строки тем же шагом (vim auto-indent). Пустой диапазон
    /// (курсор на фантоме) — честный no-op без undo-записи.
    func applyLinewiseRange(_ op: NormalPending.Op, lower: Int, upper: Int) {
        guard let buf = buffer else { return }
        let last = max(0, buf.lineCount - 1)
        let lo = min(max(0, lower), last)
        var hi = min(max(lo, upper), last)
        if hi > lo, buf.lineStart(line: hi) == buf.totalLength {
            hi -= 1
        }
        var registerText = ""
        for line in lo...hi {
            registerText += buf.getLine(line) + registerTerminator(after: line)
        }
        if op == .y {
            yankLinewiseRegister(registerText)
            return // yy не двигает курсор (vim)
        }
        let start = buf.lineStart(line: lo)
        let end = min(buf.lineEnd(line: hi), buf.totalLength)
        guard end > start else {
            if op == .c { mode = .insert }
            return
        }
        yankLinewiseRegister(registerText)
        let deletedText = buf.getText(range: start..<end)
        let indent = op == .c ? Self.lineIndent(buf, line: lo) : ""
        buf.delete(at: start, length: end - start)
        if !indent.isEmpty { buf.insert(indent, at: start) }
        recordAction(offset: start, deleted: deletedText, inserted: indent)
        cursorLine = min(lo, max(0, buf.lineCount - 1))
        cursorCol = indent.count
        syncDesiredCol()
        if op != .c {
            cursorCol = 0
            desiredCol = 0
        } else {
            mode = .insert
        }
        ensureCursorVisible()
    }

    /// Charwise-действие над диапазоном (конец exclusive, в char-колонках;
    /// сквозные диапазоны через переводы строк — d2$/de — байтами).
    func applyCharwiseRange(_ op: NormalPending.Op, startLine: Int, startCol: Int,
                            endLine: Int, endCol: Int) {
        guard let buf = buffer else { return }
        let startOffset = buf.lineStart(line: startLine)
            + buf.charToByteOffsetInLine(line: startLine, charIndex: startCol)
        let endOffset = buf.lineStart(line: endLine)
            + buf.charToByteOffsetInLine(line: endLine, charIndex: endCol)
        let len = endOffset - startOffset
        guard len > 0 else {
            if op == .c { mode = .insert }
            return
        }
        let deletedText = buf.getText(range: startOffset..<endOffset)
        yank(deletedText)
        if op == .y {
            // yank не двигает курсор (vim): yb/y0/yh оставляют его на месте
            return
        }
        buf.delete(at: startOffset, length: len)
        recordAction(offset: startOffset, deleted: deletedText, inserted: "")
        // d/c: курсор на начало удалённого диапазона (db возвращает
        // курсор к началу слова — vim)
        cursorLine = startLine
        cursorCol = startCol
        syncDesiredCol()
        if op == .c { mode = .insert }
        ensureCursorVisible()
    }

    // MARK: - Правки со счётом

    /// `x` со счётом (vim-parity: удалённое идёт в yank-регистр и
    /// OSC 52) — N графем от курсора, без выхода за конец строки.
    func deleteCharsAtCursor(_ count: Int) {
        guard let buf = buffer else { return }
        let chars = buf.getLineChars(cursorLine)
        guard cursorCol < chars.count else { return }
        let endCol = min(cursorCol + max(1, count), chars.count)
        let startOff = buf.lineStart(line: cursorLine)
            + buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
        let endOff = buf.lineStart(line: cursorLine)
            + buf.charToByteOffsetInLine(line: cursorLine, charIndex: endCol)
        let len = endOff - startOff
        guard len > 0 else { return }
        let deletedText = buf.getText(range: startOff..<endOff)
        yank(deletedText)
        buf.delete(at: startOff, length: len)
        recordAction(offset: startOff, deleted: deletedText, inserted: "")
    }

    /// Применение движения как перемещения курсора (normal, без
    /// оператора). Вертикальные j/k идут мимо — moveVertically с
    /// sticky-колонкой (desiredCol) в handlePlainNormal.
    func moveByMotion(_ motion: NormalMotion, count: Int?) {
        guard let buf = buffer else { return }
        let dest = NormalMotion.destination(of: motion, in: buf,
                                            line: cursorLine, col: cursorCol, count: count)
        cursorLine = dest.line
        cursorCol = dest.col
        ensureCursorVisible()
    }

    // MARK: - Вспомогательные

    private func cursorOnNonBlank(_ buf: PieceTable) -> Bool {
        let chars = buf.getLineChars(cursorLine)
        guard cursorCol < chars.count else { return false }
        let c = chars[cursorCol]
        return c != " " && c != "\t"
    }

    private static func lineIndent(_ buf: PieceTable, line: Int) -> String {
        var indent = ""
        for c in buf.getLineChars(line) {
            if c == " " || c == "\t" { indent.append(c) } else { break }
        }
        return indent
    }
}
