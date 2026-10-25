import Foundation
import Testing
import SwimCore

/// Icons — the explorer's three-tier icon authority: resolve (the
/// SWIM_ICONS verdict, mono-aware), table completeness (every tier
/// serves every key), and the class invariants that keep each tier
/// safe: nf glyphs stay inside BMP PUA at one cell (astral
/// nf-md codepoints are a width/encoding risk class, banned), emoji
/// stay inside the Emoji_Presentation/EAW-Wide block at exactly two
/// cells (the ⚡/⚙ text-presentation tofu class, banned), plain stays
/// within the app's vetted geometric budget at one cell.
@Suite struct IconsTests {

    // MARK: - resolve

    @Test func resolveDefaultsToNF() {
        #expect(IconTier.resolve(nil, support: .trueColor) == .nf)
        #expect(IconTier.resolve("", support: .indexed256) == .nf)
        #expect(IconTier.resolve("nf", support: .trueColor) == .nf)
        #expect(IconTier.resolve("garbage", support: .trueColor) == .nf)
    }

    @Test func resolveExplicitTiers() {
        #expect(IconTier.resolve("plain", support: .trueColor) == .plain)
        #expect(IconTier.resolve("emoji", support: .trueColor) == .emoji)
        #expect(IconTier.resolve("emoji", support: .indexed256) == .emoji)
    }

    @Test func emojiDegradesToPlainUnderNoColor() {
        // emoji carry their own color; NO_COLOR must mean no color
        #expect(IconTier.resolve("emoji", support: .mono) == .plain)
        // nf survives mono: a monochrome glyph painted by fg — the
        // color dies through ColorSupport, the shape stays
        #expect(IconTier.resolve("nf", support: .mono) == .nf)
    }

    // MARK: - the tier invariants

    @Test func nfGlyphsAreBMPPuaSingleCell() {
        for glyph in Icons.allGlyphs(tier: .nf) {
            let v = glyph.unicodeScalars.first!.value
            #expect(v >= 0xE000 && v <= 0xF8FF, "nf glyph must stay in BMP PUA, got U+\(String(v, radix: 16))")
            #expect(glyph.unicodeScalars.count == 1, "nf glyph must be a single scalar")
            #expect(glyph.displayWidth == 1, "nf glyph must take exactly one cell")
        }
    }

    @Test func emojiGlyphsArePresentationWideTwoCells() {
        for glyph in Icons.allGlyphs(tier: .emoji) {
            let v = glyph.unicodeScalars.first!.value
            #expect(v >= 0x1F300 && v <= 0x1FAFF, "emoji glyph must be a real emoji-presentation codepoint, got U+\(String(v, radix: 16))")
            #expect(glyph.unicodeScalars.count == 1, "emoji glyph must be a single scalar")
            #expect(glyph.displayWidth == 2, "emoji glyph must take exactly two cells")
        }
    }

    @Test func plainGlyphsStayInTheVettedBudget() {
        let budget: Set<Character> = ["▸", "▾", "◆", "◇", "▪", "□", "●", "○", " "]
        for glyph in Icons.allGlyphs(tier: .plain) {
            #expect(budget.contains(glyph), "plain glyph \(glyph) is outside the vetted geometric budget")
            #expect(glyph.displayWidth == 1, "plain glyph must take exactly one cell")
        }
    }

    // MARK: - table behavior

    @Test func everyTierServesEveryKnownExtension() {
        let keys = ["swift", "js", "ts", "py", "rs", "go", "dart", "md", "json",
                    "yaml", "yml", "toml", "txt", "lock", "gitignore", "dockerignore",
                    "sh", "bash", "css", "scss", "html"]
        for key in keys {
            for tier in [IconTier.nf, .emoji, .plain] {
                let def = Icons.file(key, tier: tier)
                #expect(!String(def.glyph).trimmingCharacters(in: .whitespaces).isEmpty,
                        "\(key) must have a real glyph in tier \(tier)")
            }
        }
    }

    @Test func lookupIsCaseInsensitiveAndUnknownFallsBack() {
        #expect(Icons.file("SWIFT", tier: .nf) == Icons.file("swift", tier: .nf))
        #expect(Icons.file("", tier: .nf) == Icons.file("weird", tier: .nf))
        #expect(Icons.file("yml", tier: .nf) == Icons.file("yaml", tier: .nf))
        #expect(Icons.file("bash", tier: .nf) == Icons.file("sh", tier: .nf))
    }

    @Test func dotfilesResolveThroughTheName() {
        // the inherited dead-entry bug pinned dead: NSString
        // pathExtension gives "" for ".gitignore", so the naming
        // policy routes bare dotfiles through the name minus the dot
        #expect(Icons.fileIcon(forName: ".gitignore", tier: .nf) == Icons.file("gitignore", tier: .nf))
        #expect(Icons.fileIcon(forName: ".dockerignore", tier: .nf) == Icons.file("gitignore", tier: .nf))
        #expect(Icons.fileIcon(forName: ".hidden", tier: .nf) == Icons.file("", tier: .nf))
    }

    @Test func namesUseTheLastExtension() {
        #expect(Icons.fileIcon(forName: "a.swift", tier: .nf) == Icons.file("swift", tier: .nf))
        #expect(Icons.fileIcon(forName: "a.b.swift", tier: .nf) == Icons.file("swift", tier: .nf))
        #expect(Icons.fileIcon(forName: "Makefile", tier: .nf) == Icons.file("", tier: .nf))
        #expect(Icons.fileIcon(forName: "SWIFT.STE", tier: .nf) == Icons.file("ste", tier: .nf))
    }

    @Test func pinnedCodepoints() {
        // The identity pins — changing a glyph is a conscious act that
        // must come through this test (the codepoints are verified
        // against Symbols Nerd Font Mono v3.5.1).
        #expect(Icons.file("swift", tier: .nf).glyph == Character(UnicodeScalar(0xE755)!))
        #expect(Icons.file("rs", tier: .nf).glyph == Character(UnicodeScalar(0xE68B)!))
        #expect(Icons.directory(expanded: false, tier: .nf).glyph == Character(UnicodeScalar(0xF07B)!))
        #expect(Icons.directory(expanded: true, tier: .nf).glyph == Character(UnicodeScalar(0xF07C)!))
        #expect(Icons.file("rs", tier: .emoji).glyph == "🦀")
        #expect(Icons.file("js", tier: .emoji).glyph == "🔶")
        #expect(Icons.directory(expanded: false, tier: .plain).glyph == "▸")
    }

    @Test func brandColors() {
        #expect(Icons.file("swift", tier: .nf).color == IconColor(0xF0, 0x51, 0x38))
        #expect(Icons.file("ts", tier: .nf).color == IconColor(0x31, 0x78, 0xC6))
        // the directory tint is Theme.blue's value, pinned as data
        #expect(Icons.directory(expanded: false, tier: .nf).color == IconColor(0x7A, 0xA2, 0xF7))
        // emoji are self-colored; plain paints with the caller's fg
        #expect(Icons.file("swift", tier: .emoji).color == nil)
        #expect(Icons.file("swift", tier: .plain).color == nil)
    }
}
