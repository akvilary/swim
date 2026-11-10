import Testing
@testable import Swim

/// The end-to-end dialect regression: ONE physical key — Ctrl+Shift+Y —
/// in the two wire spellings that actually arrive (WezTerm under
/// modifyOtherKeys level 2: the 27-form with the UPPERCASE codepoint
/// and the shift bit stripped, straight from termwiz's encoder; the
/// kitty family: the u-form with the unshifted codepoint and the bit
/// explicit) — must parse to ONE Key. Before the implied-shift
/// reconstruction the WezTerm spelling collapsed into `.ctrl("y")`,
/// and the commit-message copy fired the branch-name copy instead.
struct KeyCsiDialectTests {

    @Test func ctrlShiftYIsOneKeyAcrossDialects() {
        // WezTerm: termwiz KeyCode::encode — normalize_shift_to_upper_case
        // ('y'+SHIFT → 'Y'), the SHIFT strip, the 27-form under mok=2
        #expect(Key.csiKey(params: "27;5;89", final: UInt8(ascii: "~")) == .ctrlShift("y"))
        // kitty / Alacritty ≥ 0.13: the spec's unshifted codepoint + bit
        #expect(Key.csiKey(params: "121;6", final: UInt8(ascii: "u")) == .ctrlShift("y"))
        // The same spellings for plain Ctrl+Y stay the plain key — the
        // branch-name copy is untouched in every terminal
        #expect(Key.csiKey(params: "27;5;121", final: UInt8(ascii: "~")) == .ctrl("y"))
        #expect(Key.csiKey(params: "121;5", final: UInt8(ascii: "u")) == .ctrl("y"))
    }

    /// WezTerm's uppercase dialect also carries the shift-only spelling:
    /// a bare `89u`/`89;1u` is Shift+Y (caps lock reads the same) — the
    /// insurance branch answers the uppercase char, not a dead key.
    @Test func shiftOnlyUppercaseDialect() {
        #expect(Key.csiKey(params: "89;1", final: UInt8(ascii: "u")) == .char("Y"))
        #expect(Key.csiKey(params: "89", final: UInt8(ascii: "u")) == .char("Y"))
    }
}
