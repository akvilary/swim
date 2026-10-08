import Testing
import SwimCore

/// CharWidth — the single authority on how many terminal cells a
/// grapheme occupies (moved verbatim from Core/Cell.swift so both the
/// renderer side and the input-line scroll policy share one table).
@Suite struct CharWidthTests {

    /// A typed parameter gives every string literal an unambiguous
    /// Character context — keeps the #expect macro expansion simple.
    private func width(_ c: Character) -> Int { c.displayWidth }
    private func isWide(_ c: Character) -> Bool { c.isWide }

    @Test func narrowScriptsAreOneCell() {
        #expect(width("a") == 1)
        #expect(width("Z") == 1)
        #expect(width("п") == 1)   // Cyrillic — the libc-wcwidth C-locale trap
        #expect(width("й") == 1)
        #expect(width(" ") == 1)
        #expect(width(".") == 1)
    }

    @Test func cjkIsTwoCells() {
        #expect(width("中") == 2)
        #expect(width("文") == 2)
        #expect(width("あ") == 2)  // Hiragana
        #expect(width("한") == 2)  // Hangul
        #expect(width("ｆ") == 2)  // Fullwidth form (U+FF46)
    }

    @Test func emojiIsTwoCells() {
        #expect(width("😀") == 2)
        #expect(width("⌚") == 2)  // U+231A — emoji-presentation by EAW
        #expect(width("🇺🇦") == 2) // flag: regional-indicator pair, one grapheme
    }

    @Test func zeroWidthGraphemes() {
        #expect(width("\u{0301}") == 0)  // combining acute — a mark on its own
        #expect(width("\u{200D}") == 0)  // ZWJ — format character
        #expect(width("\u{0}") == 0)     // C0 control
        #expect(width("\u{7F}") == 0)    // DEL
    }

    @Test func combiningMarkJoinsItsBase() {
        // e + combining acute is ONE grapheme in Swift — width of the base.
        #expect(width("e\u{0301}") == 1)
        // 中 + combining mark stays wide.
        #expect(width("中\u{0301}") == 2)
    }

    @Test func isWideMatchesTheTable() {
        let fullwidthEdge = Character(UnicodeScalar(0xFF60)!)   // fullwidth reverse solidus — last of its range
        let halfwidthEdge = Character(UnicodeScalar(0xFF61)!)   // halfwidth ideographic stop — first after it
        #expect(!isWide("a"))
        #expect(isWide("中"))
        #expect(fullwidthEdge.isWide)
        #expect(!halfwidthEdge.isWide)
    }
}
