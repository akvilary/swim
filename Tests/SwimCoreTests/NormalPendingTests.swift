import Testing
import SwimCore

/// NormalPending — аккумулятор отложенной последовательности
/// normal-режима, vim-модель: счёт до оператора + оператор + счёт
/// после + g-префикс, явное потребление, умножение счётов, один сброс.
@Suite struct NormalPendingTests {

    // MARK: - Слоты счёта

    @Test func digitAccumulatesBeforeOperator() {
        var p = NormalPending()
        let a = p.appendDigit(2)
        let b = p.appendDigit(0)
        #expect(a && b)
        #expect(p.count == 20)
    }

    @Test func leadingZeroIsNotADigit() {
        var p = NormalPending()
        let bare = p.appendDigit(0)
        #expect(!bare)
        #expect(p.isEmpty)
        // но после первой цифры 0 продолжает счёт
        p.appendDigit(1)
        let cont = p.appendDigit(0)
        #expect(cont)
        #expect(p.count == 10)
    }

    @Test func digitAfterOperatorGoesToOpCount() {
        // d3d: оператор взведён — цифры копятся в opCount, count не тронут
        var p = NormalPending()
        p.arm(.d)
        p.appendDigit(3)
        #expect(p.count == nil && p.opCount == 3)
        p.appendDigit(0)
        #expect(p.opCount == 30)
    }

    @Test func bareZeroAfterOperatorIsNotADigit() {
        // d0: 0 после оператора — движение, а не счёт
        var p = NormalPending()
        p.arm(.d)
        let bare = p.appendDigit(0)
        #expect(!bare)
        #expect(p.opCount == nil)
        // но d10d — 0 продолжает начатый счёт
        p.appendDigit(1)
        let cont = p.appendDigit(0)
        #expect(cont)
        #expect(p.opCount == 10)
    }

    @Test func countIsCapped() {
        var p = NormalPending()
        for _ in 0..<10 { p.appendDigit(9) }
        #expect(p.count == NormalPending.countCap)
    }

    // MARK: - Умножение счётов (vim: 2d3w = 6)

    @Test func takeCountMultipliesBothSides() {
        var p = NormalPending()
        p.appendDigit(2)
        p.arm(.d)
        p.appendDigit(3)
        let product = p.takeCount()
        #expect(product == 6)
        // слот оператора живёт до хвостового defer — isEmpty тут ложен
        #expect(p.count == nil && p.opCount == nil && p.op == .d)
    }

    @Test func takeCountSingleSides() {
        var p = NormalPending()
        let none = p.takeCount()
        #expect(none == nil)
        p.appendDigit(5)
        let five = p.takeCount()
        #expect(five == 5)
        p.arm(.y)
        p.appendDigit(7)
        let seven = p.takeCount()
        #expect(seven == 7)
        #expect(p.count == nil && p.opCount == nil)
    }

    @Test func takeCountClearsAfterTake() {
        var p = NormalPending()
        p.appendDigit(7)
        _ = p.takeCount()
        #expect(p.count == nil && p.opCount == nil)
    }

    // MARK: - Операторы

    @Test func armReplacesPreviousOp() {
        var p = NormalPending()
        p.arm(.y)
        p.arm(.d)
        #expect(p.op == .d)
    }

    @Test func opSlotSurvivesCountTake() {
        // Взведённый оператор не вытесняется потреблением счёта —
        // слот умирает только на defer/reset потребителя
        var p = NormalPending()
        p.arm(.c)
        p.appendDigit(2)
        _ = p.takeCount()
        #expect(p.op == .c && p.count == nil)
    }

    // MARK: - g-префикс

    @Test func gPrefixIndependentOfOperator() {
        // dgg: d взведён, потом g — оба живут одновременно
        var p = NormalPending()
        p.arm(.d)
        p.armGPrefix()
        #expect(p.op == .d && p.gPrefix)
        let firstTake = p.takeGPrefix()
        #expect(firstTake)
        #expect(!p.gPrefix && p.op == .d)
        let secondTake = p.takeGPrefix()
        #expect(!secondTake)
    }

    @Test func countSurvivesArm() {
        // 20gg: счёт копится до g-взведения и живёт до потребления
        var p = NormalPending()
        p.appendDigit(2); p.appendDigit(0)
        p.armGPrefix()
        #expect(p.count == 20 && p.gPrefix)
        _ = p.takeGPrefix()
        let n = p.takeCount()
        #expect(n == 20)
        #expect(p.isEmpty)
    }

    @Test func opCountSurvivesGPrefixUnderOperator() {
        // d5gg: счёт между d и gg копится, пока взведены и d, и g
        var p = NormalPending()
        p.arm(.d)
        p.armGPrefix()
        p.appendDigit(5)
        #expect(p.opCount == 5 && p.op == .d && p.gPrefix)
    }

    // MARK: - Сброс

    @Test func resetClearsEverything() {
        var p = NormalPending()
        p.appendDigit(3)
        p.arm(.d)
        p.armGPrefix()
        p.appendDigit(2)
        p.reset()
        #expect(p.isEmpty)
    }
}
