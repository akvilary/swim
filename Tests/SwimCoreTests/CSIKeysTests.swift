import Testing
@testable import SwimCore

/// The CSI key-modifier protocol: the two wire forms, the modifier bit
/// math, the strict-garbage policy, the letter normalization, the
/// enable vocabulary and the terminal-class gate. Keep in sync with the
/// consumers (Sources/Swim/Core/Input.swift — decoding; Terminal.swift —
/// the enable/reset composition).
struct CSIKeysTests {

    // MARK: - Modifier bit math (param = 1 + bitmask: shift 1, alt 2, ctrl 4, meta 8)

    @Test func modifierBits() {
        // Crashes loudly if a documented form ever fails to parse —
        // that is the test's job here.
        func mods(_ param: Int) -> (shift: Bool, alt: Bool, ctrl: Bool, meta: Bool) {
            let key = CSIKey(csiU: "121;\(param)")!
            return (key.shift, key.alt, key.ctrl, key.meta)
        }
        #expect(mods(2) == (true, false, false, false))   // shift
        #expect(mods(3) == (false, true, false, false))   // alt
        #expect(mods(4) == (true, true, false, false))    // alt+shift
        #expect(mods(5) == (false, false, true, false))   // ctrl — the form every global Ctrl binding uses
        #expect(mods(6) == (true, false, true, false))    // ctrl+shift — the new combo's form
        #expect(mods(7) == (false, true, true, false))    // ctrl+alt
        #expect(mods(9) == (false, false, false, true))   // meta
        #expect(mods(16) == (true, true, true, true))     // everything — the documented ceiling
    }

    // MARK: - Wire forms

    /// CSI u: bare codepoints (the CSI-u family's specials) and the
    /// modified forms (the u-family's answer to the level-2 enable).
    @Test func csiUForm() {
        let bare = CSIKey(csiU: "13")
        #expect(bare?.codepoint == 13)
        #expect(bare?.ctrl == false && bare?.shift == false && bare?.alt == false && bare?.meta == false)

        let combo = CSIKey(csiU: "121;6")
        #expect(combo?.codepoint == 121)
        #expect(combo?.ctrl == true && combo?.shift == true)
        #expect(combo?.alt == false && combo?.meta == false)

        let ctrlO = CSIKey(csiU: "111;5")
        #expect(ctrlO?.ctrl == true && ctrlO?.shift == false)
        #expect(CSIKey(csiU: "9;2")?.shift == true)      // Shift+Tab's u-form source
    }

    /// The xterm 27-form: stock xterm's level-2 encoding (ctlseqs:
    /// Shift+Tab sends 27;2;9~ rather than CSI Z).
    @Test func modifiedTildeForm() {
        let combo = CSIKey(modifiedTilde: "27;6;121")
        #expect(combo?.codepoint == 121)
        #expect(combo?.ctrl == true && combo?.shift == true)

        #expect(CSIKey(modifiedTilde: "27;5;111")?.ctrl == true)
        #expect(CSIKey(modifiedTilde: "27;2;9")?.shift == true)
        // The level-3 bare form (modifier 1 = none): space as 27;1;32~
        let bareSpace = CSIKey(modifiedTilde: "27;1;32")
        #expect(bareSpace?.codepoint == 32)
        #expect(bareSpace?.ctrl == false && bareSpace?.shift == false)
    }

    // MARK: - Strictness: unknown shapes never fire

    @Test func garbageStaysNil() {
        // Malformed / empty parts
        #expect(CSIKey(csiU: "") == nil)
        #expect(CSIKey(csiU: ";5") == nil)
        #expect(CSIKey(csiU: "121;") == nil)
        #expect(CSIKey(csiU: "x;6") == nil)
        // kitty dialects: ':' subparameters (alternate keys, event types)
        #expect(CSIKey(csiU: "121:120;6") == nil)
        #expect(CSIKey(csiU: "121;6:3") == nil)
        // Trailing components (kitty text codepoints) and wrong counts
        #expect(CSIKey(csiU: "121;6;119") == nil)
        #expect(CSIKey(modifiedTilde: "27;6") == nil)
        #expect(CSIKey(modifiedTilde: "27;6;121;9") == nil)
        // Ranges: codepoint 0 / over Unicode; modifier 0 / over 16
        #expect(CSIKey(csiU: "0;5") == nil)
        #expect(CSIKey(csiU: "121;0") == nil)
        #expect(CSIKey(csiU: "121;17") == nil)
        #expect(CSIKey(csiU: "999999999999;5") == nil)
        // The tilde form's fixed marker
        #expect(CSIKey(modifiedTilde: "3;5;51") == nil)
        #expect(CSIKey(modifiedTilde: "1") == nil)
    }

    // MARK: - Letter normalization

    @Test func letterNormalization() {
        #expect(CSIKey(csiU: "121;6")?.letter == "y")   // lowercase wire form
        #expect(CSIKey(csiU: "89;6")?.letter == "y")    // uppercase — defensive
        #expect(CSIKey(csiU: "13")?.letter == nil)      // specials
        #expect(CSIKey(csiU: "127")?.letter == nil)
        #expect(CSIKey(csiU: "1050;5")?.letter == nil)  // Cyrillic 'К' — not Latin
    }

    // MARK: - Implied shift: the two dialects of Shift+letters

    /// WezTerm folds the shift into the codepoint and strips the bit
    /// (termwiz: normalize_shift_to_upper_case + the SHIFT removal) —
    /// its Ctrl+Shift+Y arrives as `27;5;89~` under the level-2 enable.
    /// The kitty-family spec mandates the opposite (`121;6u` — "It
    /// must not be CSI 65;modifiers u"). One physical key, two
    /// spellings, one parse: an uppercase Latin base implies shift, or
    /// the combo collapses into plain ctrl+y (the WezTerm bug).
    @Test func impliedShiftFromUppercaseBase() {
        // WezTerm's wire form — the bug's exact bytes
        let wez = CSIKey(modifiedTilde: "27;5;89")!
        #expect(wez.ctrl && wez.shift && wez.letter == "y")
        // The kitty-family dialect — untouched, the bit is explicit
        let kitty = CSIKey(csiU: "121;6")!
        #expect(kitty.ctrl && kitty.shift && kitty.letter == "y")
        // Idempotent: uppercase WITH the explicit bit — the same key
        #expect(CSIKey(csiU: "89;6")?.ctrl == true)
        #expect(CSIKey(csiU: "89;6")?.shift == true)
        // Shift-only spellings (caps lock reports as shift too)
        #expect(CSIKey(csiU: "89;1")?.shift == true)
        #expect(CSIKey(csiU: "89")?.shift == true)
        #expect(CSIKey(csiU: "89;1")?.ctrl == false)
        // Non-Latin uppercase is NOT promoted: Cyrillic 'К' stays
        // bitless — letter nil, the key never fires rather than firing
        // wrong (the base-layout key is kitty ':' dialect, rejected)
        let cyr = CSIKey(csiU: "1050;5")
        #expect(cyr?.shift == false && cyr?.letter == nil)
        // Lowercase bases never trigger the rule — plain ctrl stays plain
        #expect(CSIKey(modifiedTilde: "27;5;121")?.shift == false)
        #expect(CSIKey(csiU: "121;5")?.shift == false)
    }

    // MARK: - Enable vocabulary: pinned byte-exact against ctlseqs

    /// Escape bytes are invisible in review — the spec forms live HERE.
    @Test func protocolBytesMatchTheSpec() {
        #expect(CSIKey.modifyOtherKeysEnable == "\u{1b}[>4;2m")
        // The kitty LOAD form (vim's): set EXACTLY the disambiguate flag
        #expect(CSIKey.kittyDisambiguateEnable == "\u{1b}[=1;1u")
        // XTSMODKEYS reset (second param omitted) + kitty unload
        #expect(CSIKey.keyProtocolReset == "\u{1b}[>4;m\u{1b}[=0;1u")
    }

    // MARK: - The three-class terminal gate

    @Test func protocolGate() {
        // The kitty-protocol family: kitty itself and Alacritty (which
        // has no modifyOtherKeys — the kitty protocol is its only path)
        #expect(CSIKey.protocolMode(term: "alacritty", kittyWindowIdSet: false) == .kittyDisambiguate)
        #expect(CSIKey.protocolMode(term: "alacritty-direct", kittyWindowIdSet: false) == .kittyDisambiguate)
        #expect(CSIKey.protocolMode(term: "xterm-kitty", kittyWindowIdSet: false) == .kittyDisambiguate)
        // Renamed TERM — the env fingerprint still identifies kitty
        #expect(CSIKey.protocolMode(term: "xterm-256color", kittyWindowIdSet: true) == .kittyDisambiguate)
        // The modifyOtherKeys family: xterm, WezTerm, iTerm2, foot,
        // unknown names, empty TERM
        #expect(CSIKey.protocolMode(term: "xterm-256color", kittyWindowIdSet: false) == .modifyOtherKeys)
        #expect(CSIKey.protocolMode(term: "", kittyWindowIdSet: false) == .modifyOtherKeys)
        // Multiplexers absorb the sequences at their own layer; dumb is dumb
        #expect(CSIKey.protocolMode(term: "tmux-256color", kittyWindowIdSet: false) == .none)
        #expect(CSIKey.protocolMode(term: "screen.xterm-256color", kittyWindowIdSet: false) == .none)
        #expect(CSIKey.protocolMode(term: "dumb", kittyWindowIdSet: false) == .none)
    }
}
