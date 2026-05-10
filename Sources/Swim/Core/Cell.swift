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

    var ansiFG: String {
        switch self {
        case .default: return "\u{1b}[39m"
        case .black: return "\u{1b}[30m"
        case .red: return "\u{1b}[31m"
        case .green: return "\u{1b}[32m"
        case .yellow: return "\u{1b}[33m"
        case .blue: return "\u{1b}[34m"
        case .magenta: return "\u{1b}[35m"
        case .cyan: return "\u{1b}[36m"
        case .white: return "\u{1b}[37m"
        case .brightBlack: return "\u{1b}[90m"
        case .brightRed: return "\u{1b}[91m"
        case .brightGreen: return "\u{1b}[92m"
        case .brightYellow: return "\u{1b}[93m"
        case .brightBlue: return "\u{1b}[94m"
        case .brightMagenta: return "\u{1b}[95m"
        case .brightCyan: return "\u{1b}[96m"
        case .brightWhite: return "\u{1b}[97m"
        case .rgb(let r, let g, let b): return "\u{1b}[38;2;\(r);\(g);\(b)m"
        }
    }

    var ansiBG: String {
        switch self {
        case .default: return "\u{1b}[49m"
        case .black: return "\u{1b}[40m"
        case .red: return "\u{1b}[41m"
        case .green: return "\u{1b}[42m"
        case .yellow: return "\u{1b}[43m"
        case .blue: return "\u{1b}[44m"
        case .magenta: return "\u{1b}[45m"
        case .cyan: return "\u{1b}[46m"
        case .white: return "\u{1b}[47m"
        case .brightBlack: return "\u{1b}[100m"
        case .brightRed: return "\u{1b}[101m"
        case .brightGreen: return "\u{1b}[102m"
        case .brightYellow: return "\u{1b}[103m"
        case .brightBlue: return "\u{1b}[104m"
        case .brightMagenta: return "\u{1b}[105m"
        case .brightCyan: return "\u{1b}[106m"
        case .brightWhite: return "\u{1b}[107m"
        case .rgb(let r, let g, let b): return "\u{1b}[48;2;\(r);\(g);\(b)m"
        }
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
