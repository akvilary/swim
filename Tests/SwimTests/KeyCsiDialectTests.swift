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

    /// A re-encoded Shift+printable answers its uppercased char: WezTerm's
    /// level-2 enable re-encodes every modified key, but its shift strip
    /// is ASCII-only — a Shift+Cyrillic (any non-ASCII letter) keeps the
    /// bit and rides the 27-form. THE capital-letter regression: before
    /// the scalar path, Shift+Б parsed to nil and insert mode dropped it.
    @Test func shiftPrintableInsertsTheCapital() {
        // WezTerm's two spellings — the layout's unshifted key, the GUI's
        // shifted text — and the same pair in the u-form dialect
        #expect(Key.csiKey(params: "27;2;1073", final: UInt8(ascii: "~")) == .char("Б")) // 'б'+shift
        #expect(Key.csiKey(params: "27;2;1041", final: UInt8(ascii: "~")) == .char("Б")) // 'Б'+shift
        #expect(Key.csiKey(params: "1073;2", final: UInt8(ascii: "u")) == .char("Б"))
        #expect(Key.csiKey(params: "1041;2", final: UInt8(ascii: "u")) == .char("Б"))
        // Any non-ASCII alphabet, not just Cyrillic
        #expect(Key.csiKey(params: "27;2;233", final: UInt8(ascii: "~")) == .char("É"))
        // A multi-char uppercase keeps its base (ß uppercases to "SS")
        #expect(Key.csiKey(params: "27;2;223", final: UInt8(ascii: "~")) == .char("ß"))
        // Bonus heal: Shift+Space (a space is not punct/upper — the bit survives)
        #expect(Key.csiKey(params: "27;2;32", final: UInt8(ascii: "~")) == .char(" "))
        // Controls stay nil — never fire rather than fire wrong
        #expect(Key.csiKey(params: "27;2;7", final: UInt8(ascii: "~")) == nil)
        // Latin insurance unchanged in the tilde spelling too
        #expect(Key.csiKey(params: "27;2;121", final: UInt8(ascii: "~")) == .char("Y"))
    }
}
