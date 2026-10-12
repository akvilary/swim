import Foundation

/// Математика visual-block (Ctrl+V): прямоугольное выделение живёт в
/// display-колонках (клетках терминала), а по содержимому строки
/// разрешается в диапазон графем. Чистый модуль без состояния —
/// окно-редактор кормит его строками (`PieceTable.getLineChars`) и
/// применяет результат к буферу; тестируется
/// (Tests/SwimCoreTests/VisualBlockTests).
///
/// Правило принадлежности — единое для подсветки, yank и правок:
/// символ принадлежит блоку тогда и только тогда, когда его СТАРТОВАЯ
/// display-колонка лежит в [left, right). Таб, начавшийся левее левой
/// грани, в блок не входит; wide-символ, начавшийся на right-1, входит
/// целиком — его клетки могут выйти за правую грань, клеточный
/// прямоугольник обязан красить глиф целиком.
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

        /// Точка вставки, не выделение: ширина 0, без нормализации —
        /// charRange на таком спане всегда nil (чистая вставка через
        /// rowPlan, левая грань задаёт колонку). Блоковый `p`/`P`.
        public static func point(_ col: Int) -> Span {
            Span(rawLeft: col, rawRight: col)
        }

        private init(rawLeft: Int, rawRight: Int) {
            left = rawLeft
            right = rawRight
        }
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

    /// Диапазон графем строки, принадлежащих блоку: lo — первый старт
    /// >= left, hi — первый старт >= right. nil — в полосу не стартовал
    /// ни один символ (строка пуста, кончилась левее грани, или все
    /// её символы на границе начинаются вне полосы).
    public static func charRange(_ chars: [Character], span: Span,
                                 tabWidth: Int) -> Range<Int>? {
        let lo = charIndex(atDisplayCol: span.left, chars: chars, tabWidth: tabWidth)
        let hi = charIndex(atDisplayCol: span.right, chars: chars, tabWidth: tabWidth)
        return lo < hi ? lo..<hi : nil
    }

    /// Текст блокового yank: вклад каждой строки (nil-срез — пустой
    /// вклад), строки соединены «\n», без хвостового перевода — как
    /// charwise-регистр. Пустые строки сохраняются: блок высотой 3 с
    /// пустой серединой даёт три строки.
    public static func blockText(rows: [(chars: [Character], range: Range<Int>?)]) -> String {
        rows.map { row in
            guard let r = row.range else { return "" }
            return String(row.chars[r])
        }.joined(separator: "\n")
    }

    /// План правки одной строки блока: новое содержимое, точка
    /// «за заменой» для курсора и границы заменяемого диапазона
    /// (в графемах строки — для перевода в байты).
    /// - Срез есть: text = префикс + replacement + суффикс, caret — за
    ///   replacement.
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
            let prefix = String(chars[..<r.lowerBound])
            let suffix = String(chars[r.upperBound...])
            return RowPlan(text: prefix + replacement + suffix,
                           caret: r.lowerBound + replacement.count,
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
