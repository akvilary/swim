import SwimCore
import Foundation

/// Подсистема выделения редактора — вся механика трёх visual-режимов
/// (`.visual` charwise, `.visualLine` linewise, `.visualBlock`
/// blockwise) в одном месте, extension'ом EditorWindow. Разделение
/// ответственности:
/// - СОСТОЯНИЕ — per-tab в EditorBuffer (якорь `visualStartLine/Col`,
///   виртуальная колонка блока `visualBlockCol`, режим); extension
///   хранит ничего;
/// - ГЕОМЕТРИЯ — `VisualSelection`: режим определяет только проекцию
///   «якорь + курсор → геометрия», все операторы потребляют одно
///   значение, резолвенное один раз на операцию;
/// - ЧИСТАЯ МАТЕМАТИКА (display-колонки, срезы, пересборка строк) —
///   SwimCore/VisualBlock.swift, тестируется;
/// - ПРИМЕНЕНИЕ — континуальные правки напрямую в PieceTable,
///   многострочные — через `applyBlockEdit` (один контигуальный
///   replace, модель undo не меняется);
/// - ИНВАРИАНТЫ: завершающие операторы (`y`/`d`/`x`/вставка поверх)
///   сами выходят в normal; `H`/`L`-shift режим сознательно сохраняет;
///   `cursorCol` всегда реален (в блоке — граница графемы на/после
///   виртуальной колонки).
/// Движение режимов НЕ объединено — у каждого физически своя семантика
/// (клэмп графем / только строки / виртуальные клетки).
extension EditorWindow {

    // MARK: - Геометрия

    /// Разрешённая геометрия выделения — общая валюта всех visual-режимов.
    enum VisualSelection {
        case charwise(startLine: Int, startCol: Int, endLine: Int, endCol: Int)
        case linewise(ClosedRange<Int>)
        case blockwise(rows: ClosedRange<Int>, span: VisualBlock.Span)
    }

    var isVisualMode: Bool {
        mode == .visual || mode == .visualLine || mode == .visualBlock
    }

    /// Проекция «якорь + курсор → геометрия» текущего режима.
    func visualSelection() -> VisualSelection? {
        switch mode {
        case .visual:
            let (startLine, startCol, endLine, endCol) = visualRange()
            return .charwise(startLine: startLine, startCol: startCol,
                             endLine: endLine, endCol: endCol)
        case .visualLine:
            let (startLine, endLine) = visualLineRange()
            return .linewise(startLine...endLine)
        case .visualBlock:
            let (rows, span) = blockRowsAndSpan()
            return .blockwise(rows: rows, span: span)
        default:
            return nil
        }
    }

    func visualRange() -> (startLine: Int, startCol: Int, endLine: Int, endCol: Int) {
        if visualStartLine < cursorLine || (visualStartLine == cursorLine && visualStartCol < cursorCol) {
            return (visualStartLine, visualStartCol, cursorLine, cursorCol)
        }
        return (cursorLine, cursorCol, visualStartLine, visualStartCol)
    }

    func visualLineRange() -> (startLine: Int, endLine: Int) {
        if visualStartLine <= cursorLine {
            return (visualStartLine, cursorLine)
        }
        return (cursorLine, visualStartLine)
    }

    /// Строки и display-границы текущего блока — чистая проводка
    /// per-tab состояния в тестируемую VisualBlock.blockGeometry:
    /// реальный якорь (графема якорной строки, `?? []` без буфера —
    /// паритет прежнего guard'а: якорь в клетке 0) + виртуальный угол
    /// (клетки) → строки min/max + спан с инклюзивными углами.
    /// Математики здесь не остаётся — регрессия «пропущенная клетка
    /// при Ctrl+V + h» жила в этой композиции, теперь она в SwimCore
    /// под тестами. Колонки — в клетках терминала, поэтому строки с
    /// табами и wide-символами дают честный прямоугольник.
    func blockRowsAndSpan() -> (rows: ClosedRange<Int>, span: VisualBlock.Span) {
        let anchorChars = buffer?.getLineChars(visualStartLine) ?? []
        return VisualBlock.blockGeometry(anchorLine: visualStartLine,
                                         anchorCharCol: visualStartCol,
                                         cursorLine: cursorLine,
                                         cursorBlockCol: visualBlockCol,
                                         anchorChars: anchorChars,
                                         tabWidth: tabWidth)
    }

    /// Срез блока на строке (графемный диапазон, nil — строка блока не
    /// касается) — чистое разрешение VisualBlock над содержимым строки.
    /// Без буфера — деградирует в пустой срез ([], nil), а не падает:
    /// внутренний метод с force-unwrap был бы миной будущему вызывающему.
    func blockSlice(line: Int, span: VisualBlock.Span) -> (chars: [Character], range: Range<Int>?) {
        guard let buf = buffer else { return ([], nil) }
        let chars = buf.getLineChars(line)
        return (chars, VisualBlock.charRange(chars, span: span, tabWidth: tabWidth))
    }

    // MARK: - Переходы режимов

    /// Единая матрица переходов между visual-режимами (v/V/Ctrl+V из
    /// normal и из любого visual). Якорные правила:
    /// - из normal якорь = позиция курсора (visual/блок — line+col,
    ///   visualLine — только line);
    /// - visual ↔ block: якорь сохраняется (общая точка входа);
    /// - visualLine → visual/block: col-якорь = колонка курсора (у
    ///   построчного выделения своей колонки нет), line-якорь
    ///   сохраняется;
    /// - блок → visual/visualLine: ничего — курсор уже реален
    ///   (syncCursorToBlockCol держит границу графемы).
    /// Переход в блок инициализирует виртуальную колонку от реального
    /// курсора.
    ///
    /// Осознанное отличие от vim: повторный ключ СВОЕГО вида в vim
    /// завершает режим (:h v_v — таблица переходов), swim его
    /// игнорирует — выделение живёт до Esc/оператора (решение
    /// проекта, см. ARCHITECTURE.md).
    func switchVisualMode(to target: WindowMode) {
        switch target {
        case .visual:
            switch mode {
            case .normal: visualStartLine = cursorLine; visualStartCol = cursorCol
            case .visualLine: visualStartCol = cursorCol
            default: break // из visual/блока — якорь уже есть
            }
            mode = .visual
        case .visualLine:
            if mode == .normal { visualStartLine = cursorLine }
            mode = .visualLine
        case .visualBlock:
            switch mode {
            case .normal: visualStartLine = cursorLine; visualStartCol = cursorCol
            case .visualLine: visualStartCol = cursorCol
            default: break // из visual — якорь сохраняется
            }
            // Угол блока: из normal — фактическая позиция курсора (свежая
            // сессия, якорь = угол, как Ctrl+V в vim); из visual/visualLine —
            // ЛИПКИЙ curswant (desiredCol, display-клетки): колонка пережила
            // v/V-промежуток и вертикальные ходы, середина таба/wide-глифа
            // не съезжает на следующую границу графемы (vim-паритет,
            // верифицировано: ^V h v ^V d == ^V h d).
            let fromVisual = mode == .visual || mode == .visualLine
            mode = .visualBlock
            visualBlockCol = fromVisual
                ? desiredCol
                : displayColForChar(line: cursorLine, charCol: cursorCol)
        default: break
        }
    }

    // MARK: - Движение блока

    /// Блоковое вертикальное движение: строка клэмпится по буферу
    /// (фантомная строка легальна — вклад пуст, прямоугольник не
    /// сжимается), виртуальная колонка не трогается. Включая пейджинг —
    /// общей дельтой pageDelta, мимо moveVertically (клэмп графем).
    func moveBlockVertically(_ delta: Int) {
        guard let buf = buffer else { return }
        cursorLine = min(max(cursorLine + delta, 0), max(0, buf.lineCount - 1))
    }

    /// Реальная позиция для виртуальной колонки: граница первой
    /// графемы на/после visualBlockCol (≤ длины строки). Держит
    /// инвариант «cursorCol всегда реален» для рендера каретки,
    /// статус-бара и всех остальных потребителей. curswant (desiredCol,
    /// display-клетки) синхронизируется той же ВИРТУАЛЬНОЙ колонкой —
    /// не реальным cursorCol: раунд-трип Ctrl+V → v → Ctrl+V обязан
    /// вернуть угол в середину таба/wide-глифа, где он стоял (vim
    /// держит curswant; вход в блок из visual берёт desiredCol).
    func syncCursorToBlockCol() {
        guard let buf = buffer else { return }
        cursorCol = VisualBlock.charIndex(atDisplayCol: visualBlockCol,
                                          chars: buf.getLineChars(cursorLine),
                                          tabWidth: tabWidth)
        desiredCol = visualBlockCol
    }

    // MARK: - Обработчики клавиш

    func handleVisual(_ key: Key) -> Bool {
        switch key {
        case .escape: mode = .normal
        case .char("h"), .left: moveCursorLeft()
        case .char("j"), .down: moveCursorDown()
        case .char("k"), .up: moveCursorUp()
        case .char("l"), .right: moveCursorRight()
        case .ctrl("j"), .ctrlDown, .pageDown: pageCursorDown()
        case .ctrl("k"), .ctrlUp, .pageUp: pageCursorUp()
        case .char("y"): yankSelection()
        case .char("d"), .char("x"): deleteSelection()
        case .char("V"): switchVisualMode(to: .visualLine)
        case .ctrl("v"): switchVisualMode(to: .visualBlock)
        default: return false
        }
        if !isVerticalKey(key, insertMode: false) { syncDesiredCol() }
        dirty = true
        return true
    }

    func handleVisualLine(_ key: Key) -> Bool {
        switch key {
        case .escape: mode = .normal
        case .char("j"), .down: moveCursorDown()
        case .char("k"), .up: moveCursorUp()
        case .ctrl("j"), .ctrlDown, .pageDown: pageCursorDown()
        case .ctrl("k"), .ctrlUp, .pageUp: pageCursorUp()
        case .char("y"): yankSelection()
        case .char("d"), .char("x"): deleteSelection()
        case .char("H"), .shiftLeft: shiftVisualLines(by: -indentSize())
        case .char("L"), .shiftRight: shiftVisualLines(by: indentSize())
        case .char("v"): switchVisualMode(to: .visual)
        case .ctrl("v"): switchVisualMode(to: .visualBlock)
        default: return false
        }
        if !isVerticalKey(key, insertMode: false) { syncDesiredCol() }
        dirty = true
        return true
    }

    /// Visual-block (Ctrl+V): прямоугольное выделение в display-колонках.
    /// Курсорный угол — ВИРТУАЛЬНАЯ колонка (не клэмпится по длине
    /// строки): блок не сжимается на коротких, пустых и фантомной
    /// строках. Операции — семантика пересечения (см. yankSelection/
    /// deleteSelection/replaceSelectionWithPaste). Известные
    /// ограничения против vim (осознанные, см. ARCHITECTURE.md): нет
    /// `A`/`I`/`c`, нет `$`-растяжения и `o`-обмена углов.
    func handleVisualBlock(_ key: Key) -> Bool {
        switch key {
        case .escape: mode = .normal
        case .char("h"), .left: visualBlockCol = max(0, visualBlockCol - 1)
        case .char("l"), .right: visualBlockCol += 1
        case .char("j"), .down: moveBlockVertically(1)
        case .char("k"), .up: moveBlockVertically(-1)
        case .ctrl("j"), .ctrlDown, .pageDown: moveBlockVertically(pageDelta)
        case .ctrl("k"), .ctrlUp, .pageUp: moveBlockVertically(-pageDelta)
        case .char("y"): yankSelection()
        case .char("d"), .char("x"): deleteSelection()
        case .char("v"): switchVisualMode(to: .visual)
        case .char("V"): switchVisualMode(to: .visualLine)
        default: return false
        }
        if mode == .visualBlock {
            syncCursorToBlockCol()
            // Блоковое движение сознательно мимо moveVertically (клэмп
            // графем ломал бы виртуальный угол) — но её скролл мимо не
            // должен идти: подтягиваем видимость по ОБЕИМ осям после
            // каждого движения (ensureCursorVisible в block-режиме
            // читает виртуальную колонку угла и строку курсора).
            ensureCursorVisible()
        }
        dirty = true
        return true
    }

    // MARK: - Операторы (завершающие: сами выходят в normal)

    /// Yank текущего выделения — единая точка для всех visual-режимов:
    /// геометрия резолвится один раз, тип регистра следует виду
    /// (charwise/linewise — обычный, blockwise — прямоугольный).
    /// Вырожденное выделение (пустой вклад — якорь и курсор за EOL)
    /// регистр НЕ затирает: пустой yank не должен уничтожать
    /// предыдущее содержимое (класс: v на one-past-end + y).
    func yankSelection() {
        guard let sel = visualSelection() else { return }
        switch sel {
        case .charwise(let startLine, let startCol, let endLine, let endCol):
            guard let buf = buffer else { return }
            let startOffset = buf.lineStart(line: startLine)
                + buf.charToByteOffsetInLine(line: startLine, charIndex: startCol)
            let endOffset = buf.lineStart(line: endLine)
                + buf.charToByteOffsetInLine(line: endLine, charIndex: endCol + 1)
            let text = buf.getText(range: startOffset..<min(endOffset, buf.totalLength))
            if !text.isEmpty { yank(text) }
        case .linewise(let lines):
            guard let buf = buffer else { return }
            var text = ""
            for line in lines {
                text += buf.getLine(line) + registerTerminator(after: line)
            }
            if !text.isEmpty { yank(text) }
        case .blockwise(let rows, let span):
            guard buffer != nil else { return }
            let text = VisualBlock.blockText(rows: rows.map { blockSlice(line: $0, span: span) },
                                          span: span, tabWidth: tabWidth)
            if !text.isEmpty { yank(text, blockwise: true) }
        }
        mode = .normal
    }

    /// Терминатор строки для сборки linewise-регистра: исходный файл
    /// даёт исходные терминаторы (CRLF-файл — CRLF-регистр, round-trip
    /// `p` не перекрашивает строки файла в LF), но у последней строки
    /// без завершающего перевода принудительно "\n" — тип регистра
    /// снифается по хвосту, linewise-яанк обязан оставаться linewise
    /// (vim-parity на `p`), иначе вставка деградирует до charwise.
    func registerTerminator(after line: Int) -> String {
        let t = lineTerminator(after: line)
        return t.isEmpty ? "\n" : t
    }

    /// Yank байтового диапазона с linewise-гарантией (удаления):
    /// содержимое заканчивается переводом строки, даже когда удалённый
    /// span кончался на последней строке файла без терминатора —
    /// регистр удаления обязан вставляться построчно, как в vim.
    func yankLinewiseRegister(_ text: String) {
        yank(MultilineInsert.endsWithLineBreak(text) ? text : text + "\n")
    }

    /// Удаление текущего выделения — единая точка для всех visual-режимов.
    /// Charwise/linewise — континуальный delete (один undo-шаг);
    /// blockwise — applyBlockEdit (построчная пересборка, той же
    /// undo-моделью). Удалённое — в yank-регистр (тип следует виду:
    /// charwise/linewise — обычный, blockwise — прямоугольный; пустой
    /// вклад регистр не затирает). Курсор — на начале выделения и
    /// прокручивается в видимость (якорь мог уехать за верх экрана,
    /// пока выделение тянули вниз).
    func deleteSelection() {
        guard let sel = visualSelection(), let buf = buffer else { return }
        switch sel {
        case .charwise(let startLine, let startCol, let endLine, let endCol):
            let startOffset = buf.lineStart(line: startLine)
                + buf.charToByteOffsetInLine(line: startLine, charIndex: startCol)
            let endOffset = buf.lineStart(line: endLine)
                + buf.charToByteOffsetInLine(line: endLine, charIndex: endCol + 1)
            let len = min(endOffset, buf.totalLength) - startOffset
            guard len > 0 else { mode = .normal; return }
            let deletedText = buf.getText(range: startOffset..<(startOffset + len))
            yank(deletedText)
            buf.delete(at: startOffset, length: len)
            recordAction(offset: startOffset, deleted: deletedText, inserted: "")
            cursorLine = startLine; cursorCol = startCol
        case .linewise(let lines):
            let start = buf.lineStart(line: lines.lowerBound)
            let end = buf.lineEnd(line: lines.upperBound)
            let len = end - start
            guard len > 0 else { mode = .normal; return }
            let deletedText = buf.getText(range: start..<min(end, buf.totalLength))
            yankLinewiseRegister(deletedText)
            buf.delete(at: start, length: len)
            recordAction(offset: start, deleted: deletedText, inserted: "")
            cursorLine = min(lines.lowerBound, max(0, buf.lineCount - 1))
            cursorCol = 0
        case .blockwise(let rows, let span):
            // Удалённый блок — в регистр (blockwise, vim-parity `vd`+`p`):
            // ДО правки — applyBlockEdit пересобирает строки, срезов
            // потом не будет. Пустой вклад (блок целиком за EOL)
            // регистр не затирает.
            let text = VisualBlock.blockText(rows: rows.map { blockSlice(line: $0, span: span) },
                                          span: span, tabWidth: tabWidth)
            if !text.isEmpty { yank(text, blockwise: true) }
            _ = applyBlockEdit(rows: rows, span: span, replacement: { _, _ in "" })
        }
        mode = .normal
        ensureCursorVisible()
    }

    /// Вставка поверх выделения (bracketed paste в любом visual-режиме —
    /// vim visual `p`): заменяемое — в yank-регистр (+OSC 52), вставленное
    /// занимает его место, вся замена — один undo-шаг. Charwise —
    /// континуальная замена; linewise — построчная; blockwise — срезы
    /// первых min(строк блока, строк вставки) строк (остальной блок не
    /// трогается — консервативнее vim, который чистит весь блок; см.
    /// ARCHITECTURE.md). Завершающий оператор.
    func replaceSelectionWithPaste(_ text: String) {
        guard let buf = buffer, !text.isEmpty, let sel = visualSelection() else { return }
        switch sel {
        case .charwise(let startLine, let startCol, let endLine, let endCol):
            let startOffset = buf.lineStart(line: startLine)
                + buf.charToByteOffsetInLine(line: startLine, charIndex: startCol)
            let endOffset = min(buf.lineStart(line: endLine)
                + buf.charToByteOffsetInLine(line: endLine, charIndex: endCol + 1),
                buf.totalLength)
            replaceContiguousRange(startOffset..<endOffset, with: text,
                                   anchorLine: startLine, anchorCol: startCol)
        case .linewise(let lines):
            let startOffset = buf.lineStart(line: lines.lowerBound)
            let endOffset = min(buf.lineEnd(line: lines.upperBound), buf.totalLength)
            replaceContiguousRange(startOffset..<endOffset, with: text,
                                   anchorLine: lines.lowerBound, anchorCol: 0)
        case .blockwise(let rows, let span):
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let n = min(rows.count, lines.count)
            let target = rows.lowerBound..<(rows.lowerBound + n)
            // Заменяемый блок — в регистр ДО правки (срезов после не
            // будет); пустой вклад регистр не затирает (вставка "\n"
            // поверх блока целиком за EOL — правка no-op).
            let replaced = VisualBlock.blockText(rows: target.map { blockSlice(line: $0, span: span) },
                                               span: span, tabWidth: tabWidth)
            if !replaced.isEmpty { yank(replaced, blockwise: true) }
            // До смены режима: applyBlockEdit внутри синхронизирует
            // виртуальную колонку и зовёт ensureCursorVisible, пока
            // режим ещё block.
            _ = applyBlockEdit(rows: rows.lowerBound...(rows.lowerBound + n - 1), span: span,
                               replacement: { offset, _ in lines[offset] })
        }
        mode = .normal
        ensureCursorVisible()
    }

    /// Континуальная замена диапазона вставкой — общее тело charwise- и
    /// linewise-веток «вставки поверх»: заменяемое — в yank-регистр
    /// (как visual `d`), вся замена — один undo-шаг, курсор — по
    /// правилам `p` (linewise-вставка с trailing-"\n" — на первой
    /// вставленной строке, иначе — за последним вставленным символом).
    private func replaceContiguousRange(_ range: Range<Int>, with text: String,
                                        anchorLine: Int, anchorCol: Int) {
        guard let buf = buffer else { return }
        let deleted = buf.getText(range: range)
        if !deleted.isEmpty { yank(deleted) }
        buf.delete(at: range.lowerBound, length: range.upperBound - range.lowerBound)
        buf.insert(text, at: range.lowerBound)
        recordAction(offset: range.lowerBound, deleted: deleted, inserted: text)
        if MultilineInsert.endsWithLineBreak(text) {
            cursorLine = min(anchorLine, max(0, buf.lineCount - 1))
            cursorCol = 0
        } else {
            let delta = MultilineInsert.cursorDelta(for: text)
            cursorLine = min(anchorLine + delta.lines, max(0, buf.lineCount - 1))
            cursorCol = delta.lines > 0 ? delta.tailCols : anchorCol + delta.tailCols
        }
    }

    // MARK: - Блоковое применение

    /// Блоковый `p`/`P`: строки blockwise-регистра вставляются в
    /// display-колонку курсора на последовательные строки (короткие
    /// строки дополняются пробелами до колонки), одним undo-шагом.
    /// Строки за концом буфера не создаются — ограничение v1
    /// (см. ARCHITECTURE.md).
    func pasteBlock() {
        guard let buf = buffer else { return }
        let lines = yankBuffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return }
        let lastRow = min(cursorLine + lines.count - 1, buf.lineCount - 1)
        guard lastRow >= cursorLine else { return }
        let col = displayColForChar(line: cursorLine, charCol: cursorCol)
        _ = applyBlockEdit(rows: cursorLine...lastRow, span: .point(col),
                           replacement: { offset, _ in lines[offset] })
    }

    /// Общий исполнитель блоковых правок: пересобирает строки ОДНИМ
    /// контигуальным replace построчным span-ом (lineStart первой
    /// изменённой .. lineEnd последней; вставка = пересобранные строки,
    /// каждая со своим исходным терминатором; неизменённые строки между
    /// границами пересобираются тождественно) — модель undo не меняется,
    /// действие остаётся тройкой (offset, deleted, inserted).
    /// `replacement(offset, range)` получает смещение строки внутри
    /// блока и её срез; nil — «строку не менять»; строка без среза с
    /// пустой заменой тоже не меняется. Курсор — на первой изменённой
    /// строке, за вставленным текстом (для удаления — на месте начала
    /// среза). Возвращает false, когда менять нечего.
    @discardableResult
    func applyBlockEdit(rows: ClosedRange<Int>, span: VisualBlock.Span,
                        replacement: (Int, Range<Int>?) -> String?) -> Bool {
        guard let buf = buffer, !rows.isEmpty else { return false }
        let t = tabWidth

        // План каждой строки: nil — тождественная пересборка (строка
        // без изменений в середине span-а остаётся байт-в-байт).
        var plans: [(line: Int, plan: VisualBlock.RowPlan?)] = []
        plans.reserveCapacity(rows.count)
        var firstChanged = -1
        var lastChanged = -1
        for (offset, line) in rows.enumerated() {
            let (chars, range) = blockSlice(line: line, span: span)
            var plan: VisualBlock.RowPlan? = nil
            if let repl = replacement(offset, range), !(range == nil && repl.isEmpty) {
                plan = VisualBlock.rowPlan(chars: chars, span: span, range: range,
                                           replacement: repl, tabWidth: t)
            }
            if plan != nil {
                if firstChanged < 0 { firstChanged = offset }
                lastChanged = offset
            }
            plans.append((line, plan))
        }
        guard firstChanged >= 0 else { return false }

        let firstLine = plans[firstChanged].line
        let lastLine = plans[lastChanged].line
        let firstPlan = plans[firstChanged].plan!
        let startOffset = buf.lineStart(line: firstLine)
        let endOffset = min(buf.lineEnd(line: lastLine), buf.totalLength)

        let deletedText = endOffset > startOffset ? buf.getText(range: startOffset..<endOffset) : ""
        // Пересборка всех строк между первым и последним изменением,
        // каждая со СВОИМ терминатором (lineEnd включает терминатор
        // последней). Разделитель — по индексу, а не по непустоте
        // накопленного: пересобранная строка может быть и пустой.
        var insertedText = ""
        for entry in plans[firstChanged...lastChanged] {
            insertedText += (entry.plan?.text ?? buf.getLine(entry.line))
                + lineTerminator(after: entry.line)
        }
        if endOffset > startOffset {
            buf.delete(at: startOffset, length: endOffset - startOffset)
        }
        if !insertedText.isEmpty {
            buf.insert(insertedText, at: startOffset)
        }
        recordAction(offset: startOffset, deleted: deletedText, inserted: insertedText)

        cursorLine = firstLine
        cursorCol = min(firstPlan.caret, buf.lineCharLength(line: firstLine))
        // Блоковая правка ставит РЕАЛЬНЫЙ курсор — виртуальная колонка
        // следует за ним (ensureCursorVisible ниже читает её в block-режиме);
        // curswant — той же клеткой.
        visualBlockCol = displayColForChar(line: firstLine, charCol: cursorCol)
        desiredCol = visualBlockCol
        ensureCursorVisible()
        return true
    }

    /// Терминатор строки ("\n", "\r\n" или "" у последней строки файла
    /// без завершающего перевода) — по байтовому зазору между концом
    /// контента и началом следующей строки; исходный буфер, звать до
    /// мутации.
    func lineTerminator(after line: Int) -> String {
        guard let buf = buffer else { return "\n" }
        let contentEnd = buf.lineStart(line: line) + buf.getLine(line).utf8.count
        let nextStart = buf.lineStart(line: line + 1)
        guard contentEnd < nextStart else { return "" }
        return nextStart - contentEnd == 2 ? "\r\n" : "\n"
    }

    // MARK: - Построчный сдвиг (visualLine, режим сохраняет)

    /// Shifts the visual-line selection by the per-language indent width:
    /// positive indents, negative outdents (removes at most |delta| leading
    /// spaces per line). Applied as a single undo action; the selection and
    /// mode are kept so the shift can be repeated.
    func shiftVisualLines(by delta: Int) {
        guard let buf = buffer else { return }
        let (startLine, rawEndLine) = visualLineRange()
        // The phantom empty line after a trailing newline (its start sits
        // at totalLength) is a buffer artifact, not content — vim's visual
        // line selection never includes it; shifting it would rewrite the
        // file's trailing-newline structure. A selection consisting of the
        // phantom alone (cursor on the last empty line) shifts nothing.
        var endLine = rawEndLine
        if buf.lineStart(line: endLine) == buf.totalLength {
            if endLine == startLine { return }
            endLine -= 1
        }
        var newLines = [String]()
        var changed = false
        var cursorDelta = 0
        for line in startLine...endLine {
            let content = buf.getLine(line)
            if delta > 0 {
                newLines.append(String(repeating: " ", count: delta) + content)
                changed = true
                if line == cursorLine { cursorDelta = delta }
            } else {
                var spaces = 0
                for c in content { if c == " " { spaces += 1 } else { break } }
                let remove = min(spaces, -delta)
                newLines.append(String(content.dropFirst(remove)))
                if remove > 0 {
                    changed = true
                    if line == cursorLine { cursorDelta = -remove }
                }
            }
        }
        guard changed else { return }
        let start = buf.lineStart(line: startLine)
        let end = buf.lineEnd(line: endLine)
        let deletedText = buf.getText(range: start..<min(end, buf.totalLength))
        // Each line is rebuilt with its own terminator — "\n" or "\r\n"
        // (the byte-gap detection lives in lineTerminator; the phantom
        // empty line after a trailing newline is handled there too).
        var insertedText = ""
        for (i, content) in newLines.enumerated() {
            insertedText += content + lineTerminator(after: startLine + i)
        }
        buf.delete(at: start, length: end - start)
        buf.insert(insertedText, at: start)
        recordAction(offset: start, deleted: deletedText, inserted: insertedText)
        cursorCol = min(max(0, cursorCol + cursorDelta), buf.lineCharLength(line: cursorLine))
        syncDesiredCol()
        ensureCursorVisible()
    }

    // MARK: - Подсветка

    /// Диспетчер подсветки: одна точка входа из update(), геометрия
    /// резолвится один раз, ветки красят каждую свою форму.
    func drawVisualSelection(lnWidth: Int) {
        guard let sel = visualSelection() else { return }
        switch sel {
        case .charwise(let startLine, let startCol, let endLine, let endCol):
            drawCharwiseHighlight(startLine: startLine, startCol: startCol,
                                  endLine: endLine, endCol: endCol, lnWidth: lnWidth)
        case .linewise(let lines):
            drawLinewiseHighlight(lines: lines)
        case .blockwise(let rows, let span):
            drawBlockwiseHighlight(rows: rows, span: span, lnWidth: lnWidth)
        }
    }

    /// Экранная строка выделения (nil — вне вьюпорта).
    private func selectionScreenRow(_ lineNum: Int) -> Int? {
        let screenRow = lineNum - scrollY + contentTop
        return (screenRow >= contentTop && screenRow < height) ? screenRow : nil
    }

    /// Покраска клеток текстовой области в цвет выделения — общий
    /// внутренний цикл charwise- и блоковой подсветки.
    private func paintSelectionCells(screenRow: Int, dispFrom: Int, dispTo: Int, lnWidth: Int) {
        guard dispFrom < dispTo else { return }
        for sc in (dispFrom - scrollX)..<(dispTo - scrollX) {
            guard sc >= 0 && sc + lnWidth < width else { continue }
            var cell = getCell(screenRow, lnWidth + sc)
            cell.bg = Theme.visualBg
            setCell(screenRow, lnWidth + sc, cell)
        }
    }

    private func drawCharwiseHighlight(startLine: Int, startCol: Int,
                                       endLine: Int, endCol: Int, lnWidth: Int) {
        guard let buf = buffer else { return }
        for lineNum in startLine...endLine {
            guard let screenRow = selectionScreenRow(lineNum) else { continue }
            let lineEnd = max(0, buf.lineCharLength(line: lineNum) - 1)
            let colStart = (lineNum == startLine) ? startCol : 0
            let colEnd = (lineNum == endLine) ? min(endCol, lineEnd) : lineEnd
            let startDisp = displayColForChar(line: lineNum, charCol: colStart)
            let endDisp = displayColForChar(line: lineNum, charCol: min(colEnd + 1, buf.lineCharLength(line: lineNum)))
            paintSelectionCells(screenRow: screenRow, dispFrom: startDisp, dispTo: endDisp, lnWidth: lnWidth)
        }
    }

    /// Построчная подсветка красит ВСЮ строку, включая гуттер, —
    /// геометрия выделения не ограничена колонками.
    private func drawLinewiseHighlight(lines: ClosedRange<Int>) {
        for lineNum in lines {
            guard let screenRow = selectionScreenRow(lineNum) else { continue }
            for col in 0..<width {
                var cell = getCell(screenRow, col)
                cell.bg = Theme.visualBg
                setCell(screenRow, col, cell)
            }
        }
    }

    /// Прямоугольная подсветка блока — ровно то, что затрагивают
    /// правки: правило пересечения клеток (VisualBlock), раскола
    /// «красится, но не оперируется» больше не существует. Таб красится
    /// ПОКРЫТЫМИ клетками (раскалывается — клетки таба независимы в
    /// cell-буфере, рендерер рисует их пробелами), прочие глифы —
    /// целиком (атомарны, операции их тоже берут целиком, даже если
    /// клетки выходят за грань). Пустые клетки за концом строки внутри
    /// полосы красятся и далее — прямоугольник читается на коротких
    /// строках.
    private func drawBlockwiseHighlight(rows: ClosedRange<Int>, span: VisualBlock.Span,
                                        lnWidth: Int) {
        guard let buf = buffer else { return }
        for lineNum in rows {
            guard let screenRow = selectionScreenRow(lineNum) else { continue }
            let chars = buf.getLineChars(lineNum)
            let cells = VisualBlock.glyphCells(chars, tabWidth: tabWidth)
            for (i, ch) in chars.enumerated() {
                let c = cells[i]
                guard c.start < span.right && c.end > span.left else { continue }
                if ch == "\t" {
                    paintSelectionCells(screenRow: screenRow,
                                        dispFrom: max(c.start, span.left),
                                        dispTo: min(c.end, span.right), lnWidth: lnWidth)
                } else {
                    paintSelectionCells(screenRow: screenRow, dispFrom: c.start, dispTo: c.end,
                                        lnWidth: lnWidth)
                }
            }
            let lineEnd = cells.last?.end ?? 0
            if lineEnd < span.right {
                paintSelectionCells(screenRow: screenRow, dispFrom: max(span.left, lineEnd),
                                    dispTo: span.right, lnWidth: lnWidth)
            }
        }
    }
}
