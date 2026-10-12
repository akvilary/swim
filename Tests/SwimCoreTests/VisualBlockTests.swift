import Testing
import SwimCore

func chars(_ s: String) -> [Character] { Array(s) }

/// VisualBlock — математика прямоугольного выделения в display-колонках.
/// Правило принадлежности: ПЕРЕСЕЧЕНИЕ клеток — графема затрагивается ⟺
/// её клетки пересекают [left, right); таб на грани раскалывается
/// (непокрытые клетки — пробелами), wide-глиф атомарен. Кейсы раскола
/// верифицированы по vim 8.2 / nvim 0.11 скриптами на живом редакторе.
@Suite struct VisualBlockTests {

    // MARK: - Span

    @Test func spanNormalizesSidesAndWidth() {
        let s = VisualBlock.Span(7, 3)
        #expect(s.left == 3 && s.right == 7)
        let degenerate = VisualBlock.Span(5, 5)
        #expect(degenerate.left == 5 && degenerate.right == 6)
    }

    // MARK: - Span.inclusive (оба угла инклюзивны)

    @Test func inclusiveSpanCursorRightOfAnchor() {
        // Ctrl+V + l: якорь 4, курсор 5 → клетки [4, 6)
        let s = VisualBlock.Span.inclusive(4, 5)
        #expect(s.left == 4 && s.right == 6)
    }

    @Test func inclusiveSpanCursorLeftOfAnchorKeepsBothCorners() {
        // Ctrl+V + h: якорь 4, курсор 3 → клетки [3, 5). Регрессия:
        // Span(anchor, cursor + 1) на курсоре левее якоря нормализовался
        // в [4, 5) — клетка курсора выпадала из выделения.
        let oneLeft = VisualBlock.Span.inclusive(4, 3)
        #expect(oneLeft.left == 3 && oneLeft.right == 5)
        // два h: курсор 2 → [2, 5) — обе угловые клетки в блоке
        let twoLeft = VisualBlock.Span.inclusive(4, 2)
        #expect(twoLeft.left == 2 && twoLeft.right == 5)
    }

    @Test func inclusiveSpanDegenerateAndFarCorners() {
        // совпадающие углы — одна клетка, как init(c, c)
        let same = VisualBlock.Span.inclusive(5, 5)
        #expect(same.left == 5 && same.right == 6)
        let far = VisualBlock.Span.inclusive(6, 0)
        #expect(far.left == 0 && far.right == 7)
    }

    // MARK: - blockGeometry (композиция «якорь + виртуальный угол»)

    @Test func blockGeometryAnchorAfterTabCursorLeft() {
        // Репро баги в самой композиции: якорь на 'f' строки "\tfoo"
        // (таб клетки 0-3, 'f' на клетке 4), угол после Ctrl+V+h на
        // клетке 3 — спан обязан накрыть обе клетки, строки — min/max.
        let g = VisualBlock.blockGeometry(anchorLine: 0, anchorCharCol: 1,
                                          cursorLine: 2, cursorBlockCol: 3,
                                          anchorChars: chars("\tfoo"), tabWidth: 4)
        #expect(g.rows == 0...2)
        #expect(g.span.left == 3 && g.span.right == 5)
    }

    @Test func blockGeometryCursorAboveAnchorRowsOrdered() {
        let g = VisualBlock.blockGeometry(anchorLine: 5, anchorCharCol: 0,
                                          cursorLine: 1, cursorBlockCol: 7,
                                          anchorChars: chars("abcdef"), tabWidth: 4)
        #expect(g.rows == 1...5)
        #expect(g.span.left == 0 && g.span.right == 8)
    }

    @Test func blockGeometryEmptyAnchorCharsAnchorsAtZero() {
        // нет буфера — якорная строка пуста, якорь в клетке 0 (паритет
        // прежнего guard'а displayColForChar)
        let g = VisualBlock.blockGeometry(anchorLine: 0, anchorCharCol: 9,
                                          cursorLine: 0, cursorBlockCol: 2,
                                          anchorChars: [], tabWidth: 4)
        #expect(g.span.left == 0 && g.span.right == 3)
    }

    @Test func blockGeometryEndToEndYankBothCorners() {
        // Сквозной пайплайн репро: blockGeometry → charRange → blockText
        let line = "    abcd"
        let g = VisualBlock.blockGeometry(anchorLine: 0, anchorCharCol: 4,
                                          cursorLine: 0, cursorBlockCol: 3,
                                          anchorChars: chars(line), tabWidth: 4)
        let r = VisualBlock.charRange(chars(line), span: g.span, tabWidth: 4)
        #expect(VisualBlock.blockText(rows: [(chars(line), r)], span: g.span, tabWidth: 4) == " a")
    }

    // MARK: - Регрессия: полный пайплайн блока при курсоре левее якоря

    @Test func regressionBlockLeftOfAnchorYanksBothCells() {
        // Репро баги: строка с отступом, якорь на 'a' (дисплей-колонка 4),
        // Ctrl+V, h — курсорная клетка (пробел на колонке 3) обязана
        // попадать в блок вместе с якорной 'a'. Старый спан
        // init(4, 3+1) давал [4, 5) — yank возвращал "a" вместо " a".
        let line = "    abcd"
        let span = VisualBlock.Span.inclusive(4, 3)
        let r = VisualBlock.charRange(chars(line), span: span, tabWidth: 4)
        #expect(r == 3..<5)
        #expect(VisualBlock.blockText(rows: [(chars(line), r)], span: span, tabWidth: 4) == " a")
        // два h — три клетки: [2, 5) = "  a"
        let wider = VisualBlock.Span.inclusive(4, 2)
        let r2 = VisualBlock.charRange(chars(line), span: wider, tabWidth: 4)
        #expect(VisualBlock.blockText(rows: [(chars(line), r2)], span: wider, tabWidth: 4) == "  a")
    }

    @Test func regressionBlockLeftOfAnchorDeletePlan() {
        // Удаление того же блока: срез обеих клеток уходит, хвост цел —
        // правки тоже видят обе угловые клетки, не только подсветка.
        let plan = VisualBlock.rowPlan(chars: chars("    abcd"), span: .inclusive(4, 3),
                                       range: 3..<5, replacement: "", tabWidth: 4)
        #expect(plan.text == "   bcd")
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
        // "\tx": таб стартует на 0; блок [0,2) — таб покрыт с начала — входит
        let r = VisualBlock.charRange(chars("\tx"), span: .init(0, 2), tabWidth: 4)
        #expect(r == 0..<1)
        // блок [1,3): грань ВНУТРИ таба [0,4) — пересечение клеток есть,
        // таб затронут (расколется в rowPlan; прежнее правило стартовой
        // клетки давало nil)
        #expect(VisualBlock.charRange(chars("\tx"), span: .init(1, 3), tabWidth: 4) == 0..<1)
    }

    @Test func charRangePointSpanAtGlyphStartIsNil() {
        // Инвариант блокового p/P: точка вставки ставится на границу
        // графем — среза нет, чистая вставка. Точка ВНУТРИ таба даёт
        // срез (вставка раскалывает глиф, как vim при 've=block').
        // "a\tz": a [0,1), таб [1,4), z [4,5)
        #expect(VisualBlock.charRange(chars("a\tz"), span: .point(0), tabWidth: 4) == nil)
        #expect(VisualBlock.charRange(chars("a\tz"), span: .point(1), tabWidth: 4) == nil)
        #expect(VisualBlock.charRange(chars("a\tz"), span: .point(4), tabWidth: 4) == nil)
        #expect(VisualBlock.charRange(chars("a\tz"), span: .point(5), tabWidth: 4) == nil)
        #expect(VisualBlock.charRange(chars("a\tz"), span: .point(2), tabWidth: 4) == 1..<2)
    }

    // MARK: - Раскол табов и wide-глифов на гранях (vim-верифицировано)

    @Test func splitTabLeftEdgeDelete() {
        // vim: "\tqrs", блок [2,4): левая грань внутри таба [0,4) —
        // левая часть пробелами, покрытая удалена, хвост цел
        let plan = VisualBlock.rowPlan(chars: chars("\tqrs"), span: .init(2, 4),
                                       range: 0..<1, replacement: "", tabWidth: 4)
        #expect(plan.text == "  qrs")
        #expect(plan.caret == 2)
    }

    @Test func splitTabRightEdgeDelete() {
        // vim: "x\tz", блок [1,3): правая грань внутри таба [1,4) —
        // правая часть пробелом в суффиксе
        let plan = VisualBlock.rowPlan(chars: chars("x\tz"), span: .init(1, 3),
                                       range: 1..<2, replacement: "", tabWidth: 4)
        #expect(plan.text == "x z")
    }

    @Test func splitTabBothEdgesUniformDeviation() {
        // блок [1,3) целиком ВНУТРИ таба [0,4): vim не трогает строку
        // (no-op), swim раскалывает единообразно — обе части пробелами
        let plan = VisualBlock.rowPlan(chars: chars("\tq"), span: .init(1, 3),
                                       range: 0..<1, replacement: "", tabWidth: 4)
        #expect(plan.text == "  q")
    }

    @Test func wideStraddlingEdgesDeleteWhole() {
        // vim: "中x", блок [1,3): 中 (клетки 0-1) атомарен — удаляется
        // целиком, непокрытая клетка пробелом
        let plan = VisualBlock.rowPlan(chars: chars("中x"), span: .init(1, 3),
                                       range: 0..<2, replacement: "", tabWidth: 4)
        #expect(plan.text == " ")
        // vim: "ab中c", блок [1,3): правая грань внутри 中 (2-3) — vim
        // хвост не компенсирует ("ac", съезд на клетку); swim паддит
        // пробелом единообразно с табами
        let p2 = VisualBlock.rowPlan(chars: chars("ab中c"), span: .init(1, 3),
                                     range: 1..<3, replacement: "", tabWidth: 4)
        #expect(p2.text == "a c")
    }

    @Test func yankPartialGlyphsAsSpaces() {
        // vim: "\tqrs", блок [2,5): частично покрытый таб — пробелы
        // покрытых клеток, полностью покрытая q — как есть
        let text = VisualBlock.blockText(rows: [(chars("\tqrs"), 0..<2)],
                                         span: .init(2, 5), tabWidth: 4)
        #expect(text == "  q")
        // vim: "中x", блок [1,4): частично покрытый 中 — пробел покрытой
        // клетки (хвостовой ve-паддинг vim не повторяем — артефакт ve)
        let w = VisualBlock.blockText(rows: [(chars("中x"), 0..<2)],
                                      span: .init(1, 4), tabWidth: 4)
        #expect(w == " x")
    }

    @Test func yankBlockInsideWideGlyphDeviation() {
        // vim: блок [1,2) целиком внутри 中 (клетки 0-1) даёт весь глиф;
        // swim единообразно — пробел покрытой клетки
        let text = VisualBlock.blockText(rows: [(chars("中中"), 0..<1)],
                                         span: .init(1, 2), tabWidth: 4)
        #expect(text == " ")
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
        // спан [1,4) покрывает оба среза целиком (X на 1, XY на 2-3) —
        // полностью покрытые графемы идут как есть
        let text = VisualBlock.blockText(rows: [
            (chars: chars("abXYc"), range: 2..<4),
            (chars: chars("qXr"), range: 1..<2),
            (chars: chars("zz"), range: nil),
        ], span: .init(1, 4), tabWidth: 4)
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

    @Test func rowPlanNilSliceShortTabLinePadsToColumn() {
        // nil-срез при пересечении клеток означает «строка кончилась
        // левее блока» (клетки континуальны, хвоста за блоком быть не
        // может): "a\tz" (a 0, таб 1-3, z 4, ширина 5), блок [6,8) —
        // вставка за хвостом с паддингом до колонки 6
        let plan = VisualBlock.rowPlan(chars: chars("a\tz"), span: .init(6, 8),
                                       range: nil, replacement: "X", tabWidth: 4)
        #expect(plan.text == "a\tz X")
        #expect(plan.caret == 5)
        #expect(plan.insertAt == 3)
    }

    @Test func rowPlanUnicodeReplacements() {
        // замена с много-байтовыми графемами: caret считается в графемах
        let plan = VisualBlock.rowPlan(chars: chars("a中c"), span: .init(1, 3),
                                       range: 1..<2, replacement: "文字", tabWidth: 4)
        #expect(plan.text == "a文字c")
        #expect(plan.caret == 3)
    }
}
