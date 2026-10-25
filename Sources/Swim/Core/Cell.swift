#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import SwimCore

/// Character width in terminal cells (`displayWidth`) and the Unicode
/// East Asian Width wide table live in SwimCore (CharWidth.swift) —
/// a single authority for the renderer, panels and input-surface
/// scrolling; tested in Tests/SwimCoreTests.

enum Color: Equatable {
    /// The terminal's color capability for this process: how `.rgb`
    /// colors serialize — truecolor (`38;2;...`), the nearest xterm-256
    /// index (`38;5;n`) or the nearest of the 16 system colors.
    /// Written once in main.swift from the environment, before any
    /// rendering or background work exists, and immutable for the rest
    /// of the process lifetime — the AppLocale doctrine. The default
    /// is the historical behavior: truecolor.
    nonisolated(unsafe) static var outputSupport: ColorSupport = .trueColor

    case `default`
    case black
    case red
    case green
    case yellow
    case blue
    case magenta
    case cyan
    case white
    case brightBlack
    case brightRed
    case brightGreen
    case brightYellow
    case brightBlue
    case brightMagenta
    case brightCyan
    case brightWhite
    case rgb(r: UInt8, g: UInt8, b: UInt8)

    private func ansiCode(base: Int) -> String {
        // Mono (NO_COLOR / dumb): no color is asserted at all — the
        // one exception is the reset-to-default code, which clears
        // whatever color state the alternate screen inherited rather
        // than claiming a color.
        if Color.outputSupport == .mono {
            if case .default = self { return "\u{1b}[\(base + 9)m" }
            return ""
        }
        switch self {
        case .default: return "\u{1b}[\(base + 9)m"
        case .black: return "\u{1b}[\(base)m"
        case .red: return "\u{1b}[\(base + 1)m"
        case .green: return "\u{1b}[\(base + 2)m"
        case .yellow: return "\u{1b}[\(base + 3)m"
        case .blue: return "\u{1b}[\(base + 4)m"
        case .magenta: return "\u{1b}[\(base + 5)m"
        case .cyan: return "\u{1b}[\(base + 6)m"
        case .white: return "\u{1b}[\(base + 7)m"
        case .brightBlack: return "\u{1b}[\(base + 60)m"
        case .brightRed: return "\u{1b}[\(base + 61)m"
        case .brightGreen: return "\u{1b}[\(base + 62)m"
        case .brightYellow: return "\u{1b}[\(base + 63)m"
        case .brightBlue: return "\u{1b}[\(base + 64)m"
        case .brightMagenta: return "\u{1b}[\(base + 65)m"
        case .brightCyan: return "\u{1b}[\(base + 66)m"
        case .brightWhite: return "\u{1b}[\(base + 67)m"
        case .rgb(let r, let g, let b):
            switch Color.outputSupport {
            case .trueColor: return "\u{1b}[\(base + 8);2;\(r);\(g);\(b)m"
            case .indexed256: return "\u{1b}[\(base + 8);5;\(xterm256Index(r: r, g: g, b: b))m"
            case .ansi16:
                // 0-7 ride the base codes (30-37 fg / 40-47 bg),
                // 8-15 the +60 brights (90-97 fg / 100-107 bg) — the
                // same arithmetic the named bright cases use above.
                let i = ansi16Index(r: r, g: g, b: b)
                return i < 8 ? "\u{1b}[\(base + i)m" : "\u{1b}[\(base + 60 + i - 8)m"
            case .mono: return "" // unreachable — the mono guard above returns first
            }
        }
    }

    var ansiFG: String { ansiCode(base: 30) }
    var ansiBG: String { ansiCode(base: 40) }
}

struct Cell: Equatable {
    var char: Character
    var fg: Color
    var bg: Color
    var bold: Bool
    var dim: Bool
    var underline: Bool
    var reverse: Bool
    var wideContinuation: Bool

    static let blank = Cell(char: " ", fg: .default, bg: .default, bold: false, dim: false, underline: false, reverse: false, wideContinuation: false)

    static func colored(_ char: Character, fg: Color = .default, bg: Color = .default, bold: Bool = false, dim: Bool = false, underline: Bool = false, reverse: Bool = false) -> Cell {
        Cell(char: char, fg: fg, bg: bg, bold: bold, dim: dim, underline: underline, reverse: reverse, wideContinuation: false)
    }
}

extension Cell {
    /// The informational-highlight policy — the single point where a
    /// highlight (selection, cursor row, active row/tab, match line)
    /// decides how it is shown: the tint background while color
    /// exists, reverse video in mono (NO_COLOR / dumb), where no tint
    /// can be drawn yet the distinction must survive. Decorative tints
    /// (panel chrome, prompt plates) bypass this and simply lose their
    /// tint in mono.
    static func highlight(_ on: Bool, tint: Color, base: Color) -> (bg: Color, reverse: Bool) {
        guard on else { return (base, false) }
        return Color.outputSupport == .mono ? (.default, true) : (tint, false)
    }
}
