import Foundation

/// Движение normal-режима — vim-модель: одно и то же движение в
/// normal-режиме двигает курсор, а взведённому оператору (d/y/c,
/// operator-pending) задаёт диапазон действия. Категоризация vim:
/// - exclusive — диапазон БЕЗ конечной позиции (`w`, `b`, `0`, `h`);
/// - inclusive — включая конечную позицию (`e`, `$`, `l`);
/// - linewise — целыми строками (`j`, `k`, `gg`, `G`).
///
/// Чистая логика без курсорного состояния: потребитель (EditorWindow)
/// передаёт позицию курсора и счёт, получает назначение; применение
/// оператора получает нормализованный диапазон. Математика диапазонов
/// (сортировка концов назад-идущих движений, vim adjustment
/// «exclusive-конец в начале строки → конец предыдущей строки» — без
/// него `dw` на последнем слове строки склеивал бы строки) — здесь же
/// и тестируется. Line-индексы обязан clamp'ить в 0…lineCount-1 ДО
/// обращения к PieceTable.lineStart/lineEnd: вне диапазона те молча
/// возвращают 0/totalLength — верная бухгалтерия при неверном
/// диапазоне (класс баги, пойманный стресс-тестом delete).
public enum NormalMotion: Equatable {
    case left, right, up, down
    case wordForward, wordBackward, wordEnd
    case endOfLine, bol
    case fileStart, fileEnd

    public enum Kind: Equatable {
        /// h/l — exclusive в operator-контексте (vim): `dl` = один
        /// символ = `x`, `[курсор, курсор+1)`.
        case exclusive, inclusive, linewise
    }

    /// Назначение движения: строка/колонка (0-based, char-индексы) и
    /// vim-категория. Для `up`/`down` колонка носительна только для
    /// диапазонов — обычное перемещение применяет sticky-колонку
    /// (desiredCol) само окно.
    public struct Destination: Equatable {
        public let line: Int
        public let col: Int
        public let kind: Kind

        public init(line: Int, col: Int, kind: Kind) {
            self.line = line
            self.col = col
            self.kind = kind
        }
    }

    /// Нормализованный диапазон оператора. charwise-конец EXCLUSIVE —
    /// колонка первого символа ЗА диапазоном (единая конвенция с
    /// visual-выделениями). Пустой диапазон — nil: потребитель no-op
    /// (а `c` просто входит в insert).
    public enum OperatorRange: Equatable {
        case linewise(lower: Int, upper: Int)
        case charwise(startLine: Int, startCol: Int, endLine: Int, endCol: Int)
    }

    /// Назначение движения от позиции курсора со счётом. count == nil —
    /// счёта не было вовсе: для движений это 1, для `gg`/`G` — их
    /// дефолты (первая/последняя строка; vim различает `G` и `1G`).
    /// Word-примитивы применяются счёт раз; `endOfLine` (`$`) спускается
    /// на count-1 строк вниз — всё как в vim.
    public static func destination(of motion: NormalMotion, in buffer: PieceTable,
                                   line: Int, col: Int, count: Int?) -> Destination {
        let last = max(0, buffer.lineCount - 1)
        let l = min(max(0, line), last)
        let n = count ?? 1
        switch motion {
        case .left:
            return Destination(line: l, col: max(0, col - n), kind: .exclusive)
        case .right:
            // one-past-end (col == len, вертикальные перемещения) — без
            // движения: `dl` в этой позиции no-op, паритет с `x`
            let len = buffer.lineCharLength(line: l)
            if col >= len { return Destination(line: l, col: col, kind: .exclusive) }
            return Destination(line: l, col: min(col + n, max(0, len - 1)), kind: .exclusive)
        case .up:
            return Destination(line: max(0, l - n), col: col, kind: .linewise)
        case .down:
            return Destination(line: min(last, l + n), col: col, kind: .linewise)
        case .wordForward, .wordBackward, .wordEnd:
            let len = buffer.lineCharLength(line: l)
            var off = buffer.lineStart(line: l)
                + buffer.charToByteOffsetInLine(line: l, charIndex: min(col, len))
            for _ in 0..<n {
                off = motion == .wordForward ? buffer.wordForwardUnclamped(from: off)
                    : motion == .wordBackward ? buffer.wordBackward(from: off)
                    : buffer.wordEnd(from: off)
            }
            let (nl, byteCol) = buffer.offsetToLineCol(off)
            let destCol = buffer.byteToCharOffsetInLine(line: nl, byteOffset: byteCol)
            return Destination(line: nl, col: destCol,
                               kind: motion == .wordEnd ? .inclusive : .exclusive)
        case .endOfLine:
            let target = min(last, l + n - 1)
            return Destination(line: target,
                               col: max(0, buffer.lineCharLength(line: target) - 1),
                               kind: .inclusive)
        case .bol:
            return Destination(line: l, col: 0, kind: .exclusive)
        case .fileStart:
            return Destination(line: max(0, count.map { min($0 - 1, last) } ?? 0), col: 0, kind: .linewise)
        case .fileEnd:
            return Destination(line: max(0, count.map { min($0 - 1, last) } ?? last), col: 0, kind: .linewise)
        }
    }

    /// Диапазон оператора [курсор … назначение] по vim-категории:
    /// - linewise — целые строки от min до max включительно;
    /// - charwise — упорядоченная пара концов; inclusive-конец
    ///   переводится в exclusive-форму (+1 колонка);
    /// - adjustment: exclusive-конец в (line > 0, col 0) — конец
    ///   предыдущей строки, БЕЗ терминатора (vim :h exclusive
    ///   правило 1). Оба поведения одним правилом: `dw` на последнем
    ///   слове строки и `db` на BOL сохраняют перевод строки.
    /// Пустой диапазон — nil.
    public static func operatorRange(cursorLine: Int, cursorCol: Int,
                                     destination: Destination,
                                     in buffer: PieceTable) -> OperatorRange? {
        let last = max(0, buffer.lineCount - 1)
        let cl = min(max(0, cursorLine), last)
        if destination.kind == .linewise {
            return .linewise(lower: min(cl, destination.line),
                             upper: max(cl, destination.line))
        }
        var start = (line: cl, col: cursorCol)
        var end: (line: Int, col: Int)
        let exclusive: Bool
        switch destination.kind {
        case .exclusive:
            end = (destination.line, destination.col)
            exclusive = true
        case .inclusive:
            // +1 в exclusive-форму; clamp — one-past-end `l` (dl там
            // no-op) не должен давать колонку за пределами строки
            end = (destination.line,
                   min(destination.col + 1, buffer.lineCharLength(line: destination.line)))
            exclusive = false
        case .linewise:
            return nil
        }
        if (end.line, end.col) < (start.line, start.col) {
            swap(&start, &end)
        }
        if exclusive, end.line > 0, end.col == 0 {
            end = (end.line - 1, buffer.lineCharLength(line: end.line - 1))
        }
        guard (start.line, start.col) < (end.line, end.col) else { return nil }
        return .charwise(startLine: start.line, startCol: start.col,
                         endLine: end.line, endCol: end.col)
    }
}
