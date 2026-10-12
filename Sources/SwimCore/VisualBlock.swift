import Foundation

/// Математика visual-block (Ctrl+V): прямоугольное выделение живёт в
/// display-колонках (клетках терминала), а по содержимому строки
/// разрешается в диапазон графем. Чистый модуль без состояния —
/// окно-редактор кормит его строками (`PieceTable.getLineChars`) и
/// применяет результат к буферу; тестируется
/// (Tests/SwimCoreTests/VisualBlockTests).
///
/// Правило принадлежности — ПЕРЕСЕЧЕНИЕ КЛЕТОК, единое для подсветки,
/// yank и правок (поведение верифицировано по vim 8.2 / nvim 0.11
/// скриптами на реальном редакторе): графема затрагивается блоком ⟺
/// её клетки пересекают [left, right). Таб, разрезанный гранью,
/// РАСКАЛЫВАЕТСЯ — непокрытые клетки возвращаются пробелами, хвост
/// выравнивается одинаково на всех строках; wide-глиф атомарен —
/// затрагивается целиком, его непокрытые клетки — пробелами.
/// Осознанные отличия от vim в микрослучаях (vim сам непоследовательен,
/// swim выбирает единообразие): блок целиком внутри одного таба vim
/// игнорирует — swim раскалывает; yank блока внутри одного wide-глифа
/// vim даёт весь глиф — swim даёт пробелы покрытых клеток; непокрытую
/// правую часть wide-глифа vim не компенсирует (хвост съезжает) —
/// swim паддит пробелом, как и для табов.
public enum VisualBlock {

    /// Границы блока в display-колонках. Правая — исключающая.
    /// Инвариант ширины: right >= left + 1 — «блок» нулевой ширины
    /// легален как символ под курсором (Ctrl+V без движения), но не
    /// как пустое множество.
    public struct Span {
        public let left: Int
        public let right: Int

        /// Нормализует пару (min/max) и достраивает ширину до 1.
        public init(_ a: Int, _ b: Int) {
            let lo = min(a, b)
            left = lo
            right = max(max(a, b), lo + 1)
        }

        /// Точка вставки, не выделение: ширина 0, без нормализации.
        /// На границе графем (как ставит блоковый `p`/`P` — колонка
        /// реального курсора) срез пуст — чистая вставка через rowPlan.
        /// Точка ВНУТРИ глифа (tab/wide) при пересечении клеток даёт
        /// срез этого глифа — вставка раскалывает его пробелами, как
        /// vim при 've=block'.
        public static func point(_ col: Int) -> Span {
            Span(rawLeft: col, rawRight: col)
        }

        /// Спан выделения по двум ИНКЛЮЗИВНЫМ углам-колонкам (якорь и
        /// курсор): [min, max + 1) — оба угла в блоке, как в vim
        /// (Ctrl+V + l и Ctrl+V + h дают две клетки). Прибавлять «+1»
        /// к углу ДО упорядочивания нельзя: init(anchor, cursor + 1)
        /// при курсоре левее якоря даёт [cursor + 1, anchor) — без
        /// клеток обоих углов. Ширина >= 1 по построению.
        public static func inclusive(_ a: Int, _ b: Int) -> Span {
            Span(rawLeft: min(a, b), rawRight: max(a, b) + 1)
        }

        private init(rawLeft: Int, rawRight: Int) {
            left = rawLeft
            right = rawRight
        }
    }

    /// Полная геометрия блока из состояния окна: строки + display-спан.
    /// Якорь приходит РЕАЛЬНОЙ позицией (графема на якорной строке) и
    /// разрешается в display-колонку по содержимому СВОЕЙ строки (у
    /// каждой строки своя раскладка табов); курсорный угол — уже
    /// виртуальной клеткой. Оба угла инклюзивны (Span.inclusive),
    /// строки — min/max. Вся композиция «якорь + угол → прямоугольник»
    /// живёт здесь под тестами; оконный blockRowsAndSpan — чистая
    /// проводка (регрессия «пропущенная клетка при Ctrl+V + h» жила
    /// именно в этой композиции).
    public static func blockGeometry(anchorLine: Int, anchorCharCol: Int,
                                     cursorLine: Int, cursorBlockCol: Int,
                                     anchorChars: [Character], tabWidth: Int)
            -> (rows: ClosedRange<Int>, span: Span) {
        let anchorDisp = displayCol(ofCharIndex: anchorCharCol, chars: anchorChars, tabWidth: tabWidth)
        return (min(anchorLine, cursorLine)...max(anchorLine, cursorLine),
                Span.inclusive(anchorDisp, cursorBlockCol))
    }

    /// Display-колонка, с которой начинается графема `charIndex`
    /// (префиксная сумма шагов; charIndex клэмпится по длине строки —
    /// позиция «за последним символом» даёт полную ширину строки).
    public static func displayCol(ofCharIndex charIndex: Int,
                                  chars: [Character], tabWidth: Int) -> Int {
        var col = 0
        for i in 0..<min(charIndex, chars.count) {
            col += chars[i].displayStep(atDisplayCol: col, tabWidth: tabWidth)
        }
        return col
    }

    /// Индекс первой графемы, чья стартовая display-колонка >= target
    /// (строка короче target — длина строки: позиция за хвостом).
    /// Граница всегда попадает на старт графемы: таб, начавшийся левее
    /// target, пропускается целиком.
    public static func charIndex(atDisplayCol target: Int,
                                 chars: [Character], tabWidth: Int) -> Int {
        var col = 0
        for (i, ch) in chars.enumerated() {
            if col >= target { return i }
            col += ch.displayStep(atDisplayCol: col, tabWidth: tabWidth)
        }
        return chars.count
    }

    /// Клеточные диапазоны графем строки: [i] = [start, end) в
    /// display-клетках (таб — до следующей позиции табуляции, wide —
    /// 2 клетки, комбинирующие — 0). Единый источник для принадлежности
    /// (пересечение с [left, right)), раскола табов в rowPlan и
    /// подсветки.
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

    /// Диапазон графем строки, затрагиваемых блоком: клетки графемы
    /// пересекают [left, right) — таб/wide, разрезанные гранью, входят
    /// (раскалываются/берутся целиком, см. правило в шапке модуля).
    /// nil — пересечений нет (строка пуста, кончилась левее грани или
    /// целиком за правой).
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

    /// Текст блокового yank: вклад каждой строки — графемы среза,
    /// полностью покрытые блоком, идут как есть; частично покрытые
    /// (грань внутри глифа) — ПРОБЕЛАМИ покрытых клеток (vim янкает
    /// видимую клеточную полосу, не символы). nil-срез — пустой вклад;
    /// строки соединены «\n» без хвостового перевода, короткие строки
    /// НЕ паддятся до ширины блока (паддинг появляется на вставке).
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

    /// План правки одной строки блока: новое содержимое, точка
    /// «за заменой» для курсора и границы заменяемого диапазона
    /// (в графемах строки — для перевода в байты).
    /// - Срез есть: text = префикс + replacement + суффикс, caret — за
    ///   replacement. Глифы, разрезанные гранями, раскалываются: их
    ///   клетки вне блока возвращаются пробелами — в префикс (левый
    ///   straddler) и суффикс (правый), табы и wide одинаково; хвост
    ///   выравнивается на левую грань блока на каждой строке (vim-
    ///   паритет, верифицировано: "\tqrs" [2,4) → "  qrs", "x\tz"
    ///   [1,3) → "x z", "中x" [1,3) → " ").
    /// - Среза нет (строка не дотягивается до блока): вставка в первую
    ///   границу графем на/после левой грани, при необходимости строка
    ///   дополняется пробелами до колонки (правило блоковой вставки —
    ///   короткие строки паддятся до целевой колонки, как curswant в
    ///   vim); хвост строки (символы за правой гранью) сохраняется.
    public struct RowPlan {
        public let text: String
        public let caret: Int
        /// Заменяемый диапазон (nil — чистая вставка).
        public let range: Range<Int>?
        /// Точка вставки в графемах для строки без среза.
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
