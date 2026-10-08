#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import SwimCore

/// Ширина символа в клетках терминала (`displayWidth`) и wide-таблица
/// Unicode East Asian Width живут в SwimCore (CharWidth.swift) —
/// единый авторитет для рендерера, панелей и скролла поверхностей
/// ввода; тестируется в Tests/SwimCoreTests.

enum Color: Equatable {
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
        case .rgb(let r, let g, let b): return "\u{1b}[\(base + 8);2;\(r);\(g);\(b)m"
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
