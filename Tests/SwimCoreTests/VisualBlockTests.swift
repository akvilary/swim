import Testing
import SwimCore

func chars(_ s: String) -> [Character] { Array(s) }

/// VisualBlock — математика прямоугольного выделения в display-колонках.
/// Правило принадлежности: символ в блоке ⟺ его стартовая display-колонка
/// в [left, right); границы блока нормализуются (min/max, ширина >= 1).
@Suite struct VisualBlockTests {

    // MARK: - Span

    @Test func spanNormalizesSidesAndWidth() {
        let s = VisualBlock.Span(7, 3)
        #expect(s.left == 3 && s.right == 7)
        let degenerate = VisualBlock.Span(5, 5)
        #expect(degenerate.left == 5 && degenerate.right == 6)
    }

    // MARK: - displayCol / charIndex

    @Test func displayColPlainASCII() {
        #expect(VisualBlock.displayCol(ofCharIndex: 3, chars: chars("abcdef"), tabWidth: 4) == 3)
        #expect(VisualBlock.displayCol(ofCharIndex: 0, chars: chars("abcdef"), tabWidth: 4) == 0)
    }

    @Test func displayColBeyondEndIsFullWidth() {
        #expect(VisualBlock.displayCol(ofCharIndex: 100, chars: chars("abc"), tabWidth: 4) == 3)
    }

    @Test func displayColExpandsTabs() {
        // "a\tb" при tabWidth 4: a(0), tab -> 4, b на 4
        #expect(VisualBlock.displayCol(ofCharIndex: 2, chars: chars("a\tb"), tabWidth: 4) == 4)
    }

    @Test func charIndexAtDisplayColBoundary() {
        #expect(VisualBlock.charIndex(atDisplayCol: 2, chars: chars("abcd"), tabWidth: 4) == 2)
        // за концом строки — позиция за хвостом
        #expect(VisualBlock.charIndex(atDisplayCol: 9, chars: chars("ab"), tabWidth: 4) == 2)
    }

    @Test func charIndexSkipsTabStraddlingTarget() {
        // "a\tb": tab занимает клетки 1..3; target 3 попадает ВНУТРЬ таба —
        // граница уходит на следующий за ним символ (индекс 2), сам таб
        // (старт на 1 < 3) в блок не входит.
        #expect(VisualBlock.charIndex(atDisplayCol: 3, chars: chars("a\tb"), tabWidth: 4) == 2)
    }

    @Test func charIndexWideCharStraddle() {
        // "a中b": 中 занимает клетки 1..2, b на 2; target 2 — старт b.
        #expect(VisualBlock.charIndex(atDisplayCol: 2, chars: chars("a中b"), tabWidth: 4) == 2)
    }

    // MARK: - charRange

    @Test func charRangePlainBlock() {
        let r = VisualBlock.charRange(chars("abcdefgh"), span: .init(2, 5), tabWidth: 4)
        #expect(r == 2..<5)
    }

    @Test func charRangeSingleCellBlock() {
        // вырожденный блок [c, c+1) — символ под курсором
        let r = VisualBlock.charRange(chars("abc"), span: .init(1, 1), tabWidth: 4)
        #expect(r == 1..<2)
    }

    @Test func charRangeShortLineIsNil() {
        #expect(VisualBlock.charRange(chars("ab"), span: .init(5, 8), tabWidth: 4) == nil)
        #expect(VisualBlock.charRange(chars(""), span: .init(0, 3), tabWidth: 4) == nil)
    }

    @Test func charRangeRightBeyondEndClamps() {
        // правая грань за концом строки — до хвоста
        let r = VisualBlock.charRange(chars("abcd"), span: .init(2, 20), tabWidth: 4)
        #expect(r == 2..<4)
    }

    @Test func charRangeTabInsideBlockIncludedWhole() {
        // "\tx": таб стартует на 0; блок [0,2) — таб входит (старт 0 ∈ [0,2))
        let r = VisualBlock.charRange(chars("\tx"), span: .init(0, 2), tabWidth: 4)
        #expect(r == 0..<1)
        // блок [1,3): таб стартует на 0 — НЕ входит; x стартует на 4 — тоже
        #expect(VisualBlock.charRange(chars("\tx"), span: .init(1, 3), tabWidth: 4) == nil)
    }

    @Test func charRangeWideCharStartingAtRightMinusOneIncluded() {
        // "a中b": блок [1,2) — 中 стартует на 1, входит ЦЕЛИКОМ (клетки 1..2),
        // несмотря на выход правой клетки за грань
        let r = VisualBlock.charRange(chars("a中b"), span: .init(1, 2), tabWidth: 4)
        #expect(r == 1..<2)
        // блок [0,1): 中 стартует на 1 — не входит
        #expect(VisualBlock.charRange(chars("a中b"), span: .init(0, 1), tabWidth: 4) == 0..<1)
    }

    // MARK: - blockText (yank)

    @Test func blockTextJoinsRowsWithNewline() {
        let text = VisualBlock.blockText(rows: [
            (chars: chars("abXYc"), range: 2..<4),
            (chars: chars("qXr"), range: 1..<2),
            (chars: chars("zz"), range: nil),
        ])
        #expect(text == "XY\nX\n")
    }

    // MARK: - rowPlan (правки)

    @Test func rowPlanDeleteSlice() {
        let plan = VisualBlock.rowPlan(chars: chars("abcdef"), span: .init(2, 5),
                                       range: 2..<5, replacement: "", tabWidth: 4)
        #expect(plan.text == "abf")
        #expect(plan.caret == 2)
    }

    @Test func rowPlanReplaceSlice() {
        let plan = VisualBlock.rowPlan(chars: chars("abcdef"), span: .init(2, 5),
                                       range: 2..<5, replacement: "Z", tabWidth: 4)
        #expect(plan.text == "abZf")
        #expect(plan.caret == 3)
    }

    @Test func rowPlanWholeLineSlice() {
        let plan = VisualBlock.rowPlan(chars: chars("abc"), span: .init(0, 9),
                                       range: 0..<3, replacement: "", tabWidth: 4)
        #expect(plan.text == "")
        #expect(plan.caret == 0)
    }

    @Test func rowPlanNilSliceShortLinePadsToColumn() {
        // строка "ab" короче колонки 5: паддинг тремя пробелами, вставка в хвост
        let plan = VisualBlock.rowPlan(chars: chars("ab"), span: .init(5, 8),
                                       range: nil, replacement: "X", tabWidth: 4)
        #expect(plan.text == "ab   X")
        #expect(plan.caret == 6)
        #expect(plan.insertAt == 2)
    }

    @Test func rowPlanNilSliceKeepsTailPastRightEdge() {
        // строка длиннее блока, но срез пуст (символы за правой гранью):
        // "a     zzz" (a, 5 пробелов, zzz — z стартует на 6); блок [2,5) —
        // пробелы 1..4 стартуют в [2,5) — срез НЕ пуст. Собираем честно:
        // строка "ab|zzz" (zzz со стартом 3), блок [3,3)→[3,4) — z входит;
        // а вот блок [1,3): срез = индексы 1..1 (b)… правая грань 3 — первый
        // старт >= 3 это z (индекс 2). Проверяем вставку при nil-срезе
        // строкой, где НИ один символ не стартует в полосе:
        // "a\tz" tabWidth 4: a(0), tab(1..3), z(4). Блок [2,3): стартов в
        // полосе нет → nil; вставка паддится до колонки 2, хвост (z) цел.
        let plan = VisualBlock.rowPlan(chars: chars("a\tz"), span: .init(2, 3),
                                       range: nil, replacement: "X", tabWidth: 4)
        // граница вставки — старт z (индекс 2, колонка 4): паддинга не надо
        // (4 >= 2), вставка ПЕРЕД z, хвост сохранён
        #expect(plan.text == "a\tXz")
        #expect(plan.caret == 3)
        #expect(plan.insertAt == 2)
    }

    @Test func rowPlanUnicodeReplacements() {
        // замена с много-байтовыми графемами: caret считается в графемах
        let plan = VisualBlock.rowPlan(chars: chars("a中c"), span: .init(1, 3),
                                       range: 1..<2, replacement: "文字", tabWidth: 4)
        #expect(plan.text == "a文字c")
        #expect(plan.caret == 3)
    }
}
