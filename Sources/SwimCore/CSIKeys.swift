/// The CSI key-modifier protocol — the whole subject in one home, the
/// way Icons owns the row glyphs and Spinner the frames. Three parts:
/// the two WIRE FORMS a keypress with modifiers arrives in, the ENABLE
/// vocabulary (which protocol to speak per terminal class, and the
/// bytes that turn combos without a legacy byte, like Ctrl+Shift+Y,
/// into their own sequences), and the three-class terminal gate.
/// Parsers are STRICT: anything outside the documented forms — kitty's
/// ':'-subparameter dialects, garbage params, out-of-range codepoints
/// — fails to nil, so an unknown sequence never fires a key; it stays
/// absent instead of firing wrong.
///
/// Why TWO wire forms both live in the wild (xterm ctlseqs, "Alt and
/// Meta Keys"): stock xterm under modifyOtherKeys level 2 re-encodes
/// every MODIFIED key as `CSI 27;modifier;codepoint~` (its own
/// example: Shift+Tab sends `27;2;9~` rather than CSI Z), while the
/// CSI-u family (WezTerm, iTerm2, foot, VTE) answers the same enable
/// with `CSI codepoint;modifier u`. Level 2 does NOT touch unmodified
/// keys (that is level 3) — bare Esc/Tab/Enter/Backspace keep their
/// legacy bytes in xterm; the CSI-u bare forms mapped downstream are
/// the CSI-u family's quirks.
public struct CSIKey: Equatable, Sendable {
    public let codepoint: Int
    public let ctrl: Bool
    public let shift: Bool
    public let alt: Bool
    public let meta: Bool

    /// The CSI u form: params `codepoint[;modifier]`, modifier = 1 + the
    /// bitmask (shift 1, alt 2, ctrl 4, meta 8 — ctlseqs: "values range
    /// from 2 to 16"). Kitty's extended shapes (`121:120;6` alternate
    /// keys, `121;6:3` event types, trailing text codepoints) contain
    /// ':' and fail Int() — nil, by design.
    public init?(csiU params: String) {
        let parts = params.split(separator: ";", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let cp = Self.codepoint(parts[0]) else { return nil }
            self.init(codepoint: cp, modifierParam: 1)
        case 2:
            guard let cp = Self.codepoint(parts[0]),
                  let mods = Self.modifiers(parts[1]) else { return nil }
            self.init(codepoint: cp, modifierParam: mods)
        default:
            return nil
        }
    }

    /// The xterm modifyOtherKeys '~' form: params `27;modifier;codepoint`
    /// (the first component is the fixed legacy marker, not a tilde-code
    /// table entry — no collision with the `1`–`24` codes downstream).
    public init?(modifiedTilde params: String) {
        let parts = params.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "27",
              let mods = Self.modifiers(parts[1]),
              let cp = Self.codepoint(parts[2]) else { return nil }
        self.init(codepoint: cp, modifierParam: mods)
    }

    /// The Latin letter for letter codepoints, upper normalized to lower
    /// (terminals send the base key; some send uppercase — defensive both
    /// ways). Nil for non-letters (specials, digits, non-Latin).
    public var letter: Character? {
        let normalized = (65...90).contains(codepoint) ? codepoint + 32 : codepoint
        guard (97...122).contains(normalized) else { return nil }
        return Character(UnicodeScalar(normalized)!)
    }

    // MARK: - Internals

    private init?(codepoint: Int, modifierParam: Int) {
        guard (1...0x10FFFF).contains(codepoint), (1...16).contains(modifierParam) else { return nil }
        self.codepoint = codepoint
        let mods = modifierParam - 1
        shift = mods & 1 != 0
        alt = mods & 2 != 0
        ctrl = mods & 4 != 0
        meta = mods & 8 != 0
    }

    private static func codepoint(_ s: Substring) -> Int? {
        guard let v = Int(s), (1...0x10FFFF).contains(v) else { return nil }
        return v
    }

    private static func modifiers(_ s: Substring) -> Int? {
        guard let v = Int(s), (1...16).contains(v) else { return nil }
        return v
    }
}

/// Which key-modifier protocol a terminal speaks — the honest model of
/// the three classes that exist in the wild (the gate in `CSIKey`
/// picks one; the enable bytes live beside it).
public enum KeyProtocolMode: Equatable, Sendable {
    /// No extended-key protocol: tmux/screen (absorb the sequences at
    /// their own layer) and dumb.
    case none
    /// xterm's modifyOtherKeys level 2 — the xterm/WezTerm/iTerm2/
    /// foot/VTE family.
    case modifyOtherKeys
    /// The kitty keyboard protocol with disambiguate-only flags —
    /// kitty itself and Alacritty >= 0.13.
    case kittyDisambiguate
}

public extension CSIKey {
    /// XTSMODKEYS enable, level 2 — `CSI > 4 ; 2 m` (ctlseqs). The level
    /// where ALL modifiers apply to encoded keys: Ctrl+Shift+letter
    /// arrives as its own sequence (xterm: the 27-form; the CSI-u
    /// family: the u-form) instead of collapsing into the Ctrl byte.
    /// Level 3 (unmodified keys too) is deliberately NOT requested.
    /// Pinned byte-exact by tests — escape bytes are invisible in
    /// review; a typo here dies in CI, not in a user's terminal.
    static let modifyOtherKeysEnable = "\u{1b}[>4;2m"

    /// The kitty keyboard protocol, disambiguate-only — `CSI = 1 ; 1 u`
    /// (vim's form: LOAD flags, mode 1 = set EXACTLY these flags).
    /// Flag 1 disambiguates: Esc/Enter/Tab/Backspace and modifier
    /// combos without a legacy byte (Ctrl+Shift+letter) arrive as
    /// their own CSI u sequences; ctrl+letters and modified arrows use
    /// their established encodings. Deliberately NOT set: event types
    /// (flag 2 — the `:`-suffix dialect the strict parsers reject) and
    /// all-keys-as-escapes (flag 8 — would re-encode plain text). LOAD,
    /// not PUSH: replace semantics — a deterministic state that also
    /// clears flags another app left pushed, and no stack depth to
    /// manage (Alacritty's own stack had an unbounded-growth bug).
    /// Pinned byte-exact by tests.
    static let kittyDisambiguateEnable = "\u{1b}[=1;1u"

    /// The teardown pair, written unconditionally: the XTSMODKEYS reset
    /// (`CSI > 4 m` — second parameter omitted = reset to the resource
    /// default) AND the kitty-protocol unload (`CSI = 0 ; 1 u`) — vim's
    /// defensive double reset ("t_TI from xterm may already have been
    /// used"). Cheap bytes that heal a key-protocol leak left by ANY
    /// app — a crashed previous run, a user's global config — and are
    /// ignored as unknown CSI by everything else. Not gated by what was
    /// enabled: the reset must be unconditional to heal.
    static let keyProtocolReset = "\u{1b}[>4;m\u{1b}[=0;1u"

    /// Which key-modifier protocol this terminal speaks.
    ///
    /// - `kittyDisambiguate` — the kitty-protocol family: kitty itself
    ///   (sets KITTY_WINDOW_ID even under a renamed TERM) and Alacritty
    ///   (has no modifyOtherKeys at all — its changelog never mentions
    ///   one; the kitty protocol, added in 0.13.0, is its only
    ///   extended-key path).
    /// - `none` — tmux/screen (absorb the sequences at their own layer)
    ///   and dumb.
    /// - `modifyOtherKeys` — everything else: the xterm/WezTerm/iTerm2/
    ///   foot family, unknown names, empty TERM (an unknown terminal
    ///   simply ignores the enable — honest absence of the feature,
    ///   never breakage).
    static func protocolMode(term: String, kittyWindowIdSet: Bool) -> KeyProtocolMode {
        if kittyWindowIdSet || term.hasPrefix("xterm-kitty") || term.hasPrefix("alacritty") {
            return .kittyDisambiguate
        }
        if term.hasPrefix("tmux") || term.hasPrefix("screen") { return .none }
        if term == "dumb" { return .none }
        return .modifyOtherKeys
    }
}
