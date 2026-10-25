/// The file-explorer icon authority — three tiers behind one door,
/// selected once at startup (`SWIM_ICONS`, mono-aware) and immutable
/// for the process lifetime.
///
/// - **nf** (default): Nerd Font PUA glyphs, single cell, brand
///   colors. Three pins make them identical across machines: the
///   codepoints are from the stable NF v3 positions, the installer
///   ships a pinned Symbols Nerd Font Mono for terminals whose main
///   font lacks them (the terminal's own fallback picks it up), and
///   all NF families embed the same icon vectors per generation —
///   which font actually supplies the glyph does not change the art.
///   BMP-only by rule (U+E000...U+F8FF): astral PUA (nf-md, U+F0000+)
///   carries a separate class of width/encoding risks, and the
///   invariant test below keeps it out for good.
/// - **emoji**: curated emoji — every glyph is a real
///   Emoji_Presentation codepoint of EAW Wide (deterministic two
///   cells), never the fragile text-presentation class (⚡/⚙) that
///   renders as tofu or single-width on some terminals. Emoji ignore
///   color and NO_COLOR by nature, so this tier auto-degrades to
///   plain in mono.
/// - **plain**: geometric shapes from the app's existing glyph
///   budget (▸▾▪ and kin) — zero font dependence, the floor tier.
///
/// Colors are IconColor values, not the executable's Color type —
/// SwimCore keeps pure data; the boundary conversion happens at the
/// use site. Brand colors live HERE (the icon's own palette, the same
/// doctrine as Theme owning the Tokyo Night palette), and they ride
/// the ordinary ColorSupport degradation like any RGB color.
public struct IconColor: Equatable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// One icon: the glyph and its optional brand color (nil — paint with
/// the caller's text color, e.g. the selection-aware fg the explorer
/// already uses).
public struct IconDef: Equatable, Sendable {
    public let glyph: Character
    public let color: IconColor?

    public init(glyph: Character, color: IconColor? = nil) {
        self.glyph = glyph
        self.color = color
    }
}

public enum IconTier: Equatable, Sendable {
    case nf
    case emoji
    case plain
}

public extension IconTier {
    /// The SWIM_ICONS value resolved against the color capability:
    /// `plain` / `emoji` / `nf`, anything else (nil, empty, garbage)
    /// falls to the default `nf`. `emoji` cannot honor mono — emoji
    /// carry their own color and NO_COLOR must mean no color — so it
    /// degrades to plain.
    static func resolve(_ value: String?, support: ColorSupport) -> IconTier {
        switch value {
        case "plain": return .plain
        case "emoji": return support == .mono ? .plain : .emoji
        default: return .nf
        }
    }
}

public enum Icons {
    /// The three faces of one file type, keyed by lowercase extension.
    private struct Entry {
        let nf: IconDef
        let emoji: IconDef
        let plain: IconDef
    }

    private static func pua(_ v: UInt32) -> Character {
        Character(UnicodeScalar(v)!)
    }

    /// The default file icon: a generic file glyph (nf), a generic
    /// document — shared with txt, the precedent of 📋 shared by the
    /// config family — keeping the tier's two-cell alignment (emoji),
    /// a single space (plain).
    private static let defaultEntry = Entry(
        nf: IconDef(glyph: pua(0xF15B), color: IconColor(0x6D, 0x80, 0x86)),  // nf-fa-file
        emoji: IconDef(glyph: "📄"),
        plain: IconDef(glyph: " ")
    )

    /// Directory tint — Theme.blue's value (0x7aa2f7) pinned here as
    /// data: the explorer has always painted folders blue, and the
    /// table is the single place to change that now.
    private static let dirColor = IconColor(0x7A, 0xA2, 0xF7)

    private static func nf(_ cp: UInt32, hex: UInt32) -> IconDef {
        IconDef(glyph: pua(cp),
                color: IconColor(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF)))
    }

    private static let table: [String: Entry] = [
        "swift": Entry(
            nf: nf(0xE755, hex: 0xF05138),   // nf-seti-swift
            emoji: IconDef(glyph: "🐦"),
            plain: IconDef(glyph: "◆")),
        "js": Entry(
            nf: nf(0xE60C, hex: 0xF7DF1E),   // nf-seti-javascript
            emoji: IconDef(glyph: "🔶"),
            plain: IconDef(glyph: "◇")),
        "ts": Entry(
            nf: nf(0xE628, hex: 0x3178C6),   // nf-seti-typescript
            emoji: IconDef(glyph: "🔷"),
            plain: IconDef(glyph: "◇")),
        "py": Entry(
            nf: nf(0xE606, hex: 0xFFBC03),   // nf-seti-python
            emoji: IconDef(glyph: "🐍"),
            plain: IconDef(glyph: "◆")),
        "rs": Entry(
            nf: nf(0xE68B, hex: 0xDEA584),   // nf-seti-rust
            emoji: IconDef(glyph: "🦀"),
            plain: IconDef(glyph: "◆")),
        "go": Entry(
            nf: nf(0xE627, hex: 0x00ADD8),   // nf-seti-go
            emoji: IconDef(glyph: "🔵"),
            plain: IconDef(glyph: "◆")),
        "dart": Entry(
            nf: nf(0xE798, hex: 0x0175C2),   // nf-dev-dart
            emoji: IconDef(glyph: "🎯"),
            plain: IconDef(glyph: "◆")),
        "md": Entry(
            nf: nf(0xF48A, hex: 0xDDDDDD),   // nf-oct-markdown
            emoji: IconDef(glyph: "📝"),
            plain: IconDef(glyph: "▪")),
        "json": Entry(
            nf: nf(0xE60B, hex: 0xCBCB41),   // nf-seti-json
            emoji: IconDef(glyph: "📋"),
            plain: IconDef(glyph: "□")),
        "yaml": Entry(
            nf: nf(0xE8EB, hex: 0xD70000),   // nf-seti-yaml
            emoji: IconDef(glyph: "📋"),
            plain: IconDef(glyph: "□")),
        "toml": Entry(
            nf: nf(0xE6B2, hex: 0x9C4221),   // nf-seti-toml
            emoji: IconDef(glyph: "📋"),
            plain: IconDef(glyph: "□")),
        "txt": Entry(
            nf: nf(0xF0F6, hex: 0x89E051),   // nf-fa-file_text — BMP replacement for the astral nf-md text icon
            emoji: IconDef(glyph: "📄"),
            plain: IconDef(glyph: "▪")),
        "lock": Entry(
            nf: nf(0xE672, hex: 0xBBBBBB),   // nf-dev-lock
            emoji: IconDef(glyph: "🔒"),
            plain: IconDef(glyph: "●")),
        "gitignore": Entry(
            nf: nf(0xE702, hex: 0xF14E32),   // nf-dev-git — also dockerignore
            emoji: IconDef(glyph: "🙈"),
            plain: IconDef(glyph: "○")),
        "sh": Entry(
            nf: nf(0xE795, hex: 0x4EAA25),   // nf-seti-shell — also bash
            emoji: IconDef(glyph: "📜"),
            plain: IconDef(glyph: "◆")),
        "css": Entry(
            nf: nf(0xE6B8, hex: 0x663399),   // nf-seti-css
            emoji: IconDef(glyph: "🎨"),
            plain: IconDef(glyph: "◇")),
        "scss": Entry(
            nf: nf(0xE603, hex: 0xCD6799),   // nf-seti-sass
            emoji: IconDef(glyph: "🎨"),
            plain: IconDef(glyph: "◇")),
        "html": Entry(
            nf: nf(0xE736, hex: 0xE44D26),   // nf-dev-html5
            emoji: IconDef(glyph: "🌐"),
            plain: IconDef(glyph: "◇")),
    ]

    /// Aliases: extension families sharing one entry.
    private static let aliases: [String: String] = [
        "yml": "yaml",
        "bash": "sh",
        "dockerignore": "gitignore",
    ]

    /// The icon for a file extension (case-insensitive; empty or
    /// unknown extensions get the default entry).
    public static func file(_ ext: String, tier: IconTier) -> IconDef {
        let key = ext.lowercased()
        let resolved = aliases[key].map { table[$0] } ?? table[key]
        let entry = resolved ?? defaultEntry
        switch tier {
        case .nf: return entry.nf
        case .emoji: return entry.emoji
        case .plain: return entry.plain
        }
    }

    /// The icon for a FILE NAME — the naming policy in one place: the
    /// text after the last dot that is not the name's first character.
    /// That last clause is the dotfile repair: NSString.pathExtension
    /// (and the old emoji switch over it) returns "" for ".gitignore",
    /// so the gitignore entry never fired — bare dotfiles resolve
    /// through the name minus its leading dot instead.
    public static func fileIcon(forName name: String, tier: IconTier) -> IconDef {
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return file(String(name[name.index(after: dot)...]), tier: tier)
        }
        if name.hasPrefix("."), name.count > 1 {
            return file(String(name.dropFirst()), tier: tier)
        }
        return file(name, tier: tier)
    }

    /// The directory icon: expanded vs collapsed, per tier.
    public static func directory(expanded: Bool, tier: IconTier) -> IconDef {
        switch tier {
        case .nf:
            // nf-fa-folder / nf-fa-folder_open — BMP, single cell
            return expanded
                ? IconDef(glyph: pua(0xF07C), color: dirColor)
                : IconDef(glyph: pua(0xF07B), color: dirColor)
        case .emoji:
            return IconDef(glyph: expanded ? "📂" : "📁")
        case .plain:
            // the app's own tree language (the search results arrows)
            return IconDef(glyph: expanded ? "▾" : "▸")
        }
    }

    /// Every glyph of a tier, for the invariant tests (and for the
    /// font-coverage check script): files, default and directories.
    public static func allGlyphs(tier: IconTier) -> [Character] {
        var glyphs = table.values.map { entry in
            switch tier {
            case .nf: return entry.nf.glyph
            case .emoji: return entry.emoji.glyph
            case .plain: return entry.plain.glyph
            }
        }
        glyphs.append(contentsOf: [file("", tier: tier).glyph,
                                   directory(expanded: false, tier: tier).glyph,
                                   directory(expanded: true, tier: tier).glyph])
        return glyphs
    }
}
