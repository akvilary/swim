import Testing
import SwimCore

/// NormalPending — аккумулятор отложенной последовательности
/// normal-режима: счёт + префикс-оператор, один слот (last-wins),
/// явное потребление, один сброс.
@Suite struct NormalPendingTests {

    @Test func digitAccumulates() {
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

    @Test func armReplacesPreviousOp() {
        var p = NormalPending()
        p.arm(.y)
        p.arm(.d)
        #expect(p.op == .d)
        let tookY = p.takeOp(.y)
        #expect(!tookY)
        let tookD = p.takeOp(.d)
        #expect(tookD)
        #expect(p.op == nil)
    }

    @Test func takeOpOnlyItsOwn() {
        var p = NormalPending()
        p.arm(.g)
        let tookD = p.takeOp(.d)
        #expect(!tookD)
        #expect(p.op == .g)
    }

    @Test func takeCountReturnsNilWhenEmptyAndClearsAfterTake() {
        var p = NormalPending()
        let none = p.takeCount()
        #expect(none == nil)
        #expect(p.isEmpty)
        p.appendDigit(7)
        let seven = p.takeCount()
        #expect(seven == 7)
        #expect(p.count == nil)
    }

    @Test func countSurvivesArm() {
        // 20gg: счёт копится до g-взведения и живёт до потребления
        var p = NormalPending()
        p.appendDigit(2); p.appendDigit(0)
        p.arm(.g)
        #expect(p.count == 20 && p.op == .g)
        let tookG = p.takeOp(.g)
        #expect(tookG)
        let n = p.takeCount()
        #expect(n == 20)
        #expect(p.isEmpty)
    }

    @Test func resetClearsEverything() {
        var p = NormalPending()
        p.appendDigit(3)
        p.arm(.d)
        p.reset()
        #expect(p.isEmpty)
    }
}
