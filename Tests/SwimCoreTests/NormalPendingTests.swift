import Testing
import SwimCore

/// NormalPending — the accumulator of a pending normal-mode
/// sequence, vim-style: count before the operator + operator + count
/// after + g-prefix, explicit consumption, count multiplication, one reset.
@Suite struct NormalPendingTests {

    // MARK: - Count slots

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
        // but after the first digit, 0 continues the count
        p.appendDigit(1)
        let cont = p.appendDigit(0)
        #expect(cont)
        #expect(p.count == 10)
    }

    @Test func digitAfterOperatorGoesToOpCount() {
        // d3d: the operator is armed — digits accumulate in opCount, count untouched
        var p = NormalPending()
        p.arm(.d)
        p.appendDigit(3)
        #expect(p.count == nil && p.opCount == 3)
        p.appendDigit(0)
        #expect(p.opCount == 30)
    }

    @Test func bareZeroAfterOperatorIsNotADigit() {
        // d0: 0 after an operator is a motion, not a count
        var p = NormalPending()
        p.arm(.d)
        let bare = p.appendDigit(0)
        #expect(!bare)
        #expect(p.opCount == nil)
        // but d10d — 0 continues the count already started
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

    // MARK: - Count multiplication (vim: 2d3w = 6)

    @Test func takeCountMultipliesBothSides() {
        var p = NormalPending()
        p.appendDigit(2)
        p.arm(.d)
        p.appendDigit(3)
        let product = p.takeCount()
        #expect(product == 6)
        // the operator slot lives until the trailing defer — isEmpty is false here
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

    // MARK: - Operators

    @Test func armReplacesPreviousOp() {
        var p = NormalPending()
        p.arm(.y)
        p.arm(.d)
        #expect(p.op == .d)
    }

    @Test func opSlotSurvivesCountTake() {
        // An armed operator is not displaced by consuming the count —
        // the slot dies only on the consumer's defer/reset
        var p = NormalPending()
        p.arm(.c)
        p.appendDigit(2)
        _ = p.takeCount()
        #expect(p.op == .c && p.count == nil)
    }

    // MARK: - g-prefix

    @Test func gPrefixIndependentOfOperator() {
        // dgg: d is armed, then g — both live at the same time
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
        // 20gg: the count accumulates before g is armed and lives until consumed
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
        // d5gg: the count between d and gg accumulates while both d and g are armed
        var p = NormalPending()
        p.arm(.d)
        p.armGPrefix()
        p.appendDigit(5)
        #expect(p.opCount == 5 && p.op == .d && p.gPrefix)
    }

    // MARK: - Reset

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
