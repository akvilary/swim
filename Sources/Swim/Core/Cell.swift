#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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

extension Character {
    var isWide: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let v = scalar.value
        if v <= 0x7F { return false }
        if v >= 0x1100 {
            if v <= 0x115F { return true }
            if v >= 0x231A && v <= 0x231B { return true }
            if v >= 0x2329 && v <= 0x232A { return true }
            if v >= 0x23E9 && v <= 0x23EC { return true }
            if v == 0x23F0 { return true }
            if v == 0x23F3 { return true }
            if v >= 0x25FD && v <= 0x25FE { return true }
            if v >= 0x2614 && v <= 0x2615 { return true }
            if v >= 0x2648 && v <= 0x2653 { return true }
            if v == 0x267F { return true }
            if v >= 0x2693 && v <= 0x269A { return true }
            if v >= 0x26A1 { return true }
            if v >= 0x26AA && v <= 0x26AB { return true }
            if v >= 0x26BD && v <= 0x26BF { return true }
            if v >= 0x26C4 && v <= 0x26CD { return true }
            if v >= 0x26CF && v <= 0x26E1 { return true }
            if v >= 0x26E8 && v <= 0x26FF { return true }
            if v >= 0x2702 && v <= 0x27B0 { return true }
            if v >= 0x2B1B && v <= 0x2B55 { return true }
            if v >= 0x2E80 && v <= 0x303E { return true }
            if v >= 0x3040 && v <= 0x3247 { return true }
            if v >= 0x3250 && v <= 0x4DBF { return true }
            if v >= 0x4E00 && v <= 0x9FFF { return true }
            if v >= 0xA960 && v <= 0xA97C { return true }
            if v >= 0xAC00 && v <= 0xD7A3 { return true }
            if v >= 0xF900 && v <= 0xFAFF { return true }
            if v >= 0xFE10 && v <= 0xFE19 { return true }
            if v >= 0xFE30 && v <= 0xFE6B { return true }
            if v >= 0xFF01 && v <= 0xFF60 { return true }
            if v >= 0xFFE0 && v <= 0xFFE6 { return true }
            if v >= 0x1F000 && v <= 0x1F02F { return true }
            if v >= 0x1F0A0 && v <= 0x1F0FF { return true }
            if v >= 0x1F100 && v <= 0x1F1AD { return true }
            if v >= 0x1F1E6 && v <= 0x1F6FF { return true }
            if v >= 0x1F700 && v <= 0x1F77F { return true }
            if v >= 0x1F780 && v <= 0x1F7FF { return true }
            if v >= 0x1F800 && v <= 0x1F8FF { return true }
            if v >= 0x1F900 && v <= 0x1F9FF { return true }
            if v >= 0x1FA00 && v <= 0x1FA6F { return true }
            if v >= 0x1FA70 && v <= 0x1FAFF { return true }
            if v >= 0x20000 { return true }
        }
        return false
    }
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
