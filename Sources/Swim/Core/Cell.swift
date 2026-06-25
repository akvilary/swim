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
    /// Ширина символа в клетках терминала (детерминированная, без зависимости от локали —
    /// в отличие от libc-wcwidth, которая в C-локали считает кириллицу/CJK невидимыми):
    /// 0 — управляющие (C0/C1) и нуль-ширинные (комбинирующие метки, ZWJ/ZWNJ и т.п.);
    /// 1 — обычные (латиница, кириллица, ...);
    /// 2 — wide (CJK, эмодзи — см. `isWide`, таблица Unicode East Asian Width).
    /// Графемный кластер оцениваем по первому скаляру: Swift уже склеил базовый символ
    /// с модификаторами/комбинирующими в один `Character`, поэтому ZWJ-эмодзи-последовательности
    /// корректно получают ширину 2.
    var displayWidth: Int {
        guard let scalar = unicodeScalars.first else { return 0 }
        let v = scalar.value
        if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) { return 0 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        return isWide ? 2 : 1
    }

    /// Wide-диапазоны Unicode East Asian Width (отсортированы по возрастанию).
    /// Бинарный поиск по таблице вместо цепочки `if` — O(log n) (~6 сравнений).
    private static let wideRanges: [(low: UInt32, high: UInt32)] = [
        (0x1100, 0x115F), (0x231A, 0x231B), (0x2329, 0x232A), (0x23E9, 0x23EC),
        (0x23F0, 0x23F0), (0x23F3, 0x23F3), (0x25FD, 0x25FE), (0x2614, 0x2615),
        (0x2648, 0x2653), (0x267F, 0x267F), (0x2693, 0x269A), (0x26A1, 0x26A1),
        (0x26AA, 0x26AB), (0x26BD, 0x26BF), (0x26C4, 0x26CD), (0x26CF, 0x26E1),
        (0x26E8, 0x26FF), (0x2702, 0x27B0), (0x2B1B, 0x2B55), (0x2E80, 0x303E),
        (0x3040, 0x3247), (0x3250, 0x4DBF), (0x4E00, 0x9FFF), (0xA960, 0xA97C),
        (0xAC00, 0xD7A3), (0xF900, 0xFAFF), (0xFE10, 0xFE19), (0xFE30, 0xFE6B),
        (0xFF01, 0xFF60), (0xFFE0, 0xFFE6), (0x1F000, 0x1F02F), (0x1F0A0, 0x1F0FF),
        (0x1F100, 0x1F1AD), (0x1F1E6, 0x1F6FF), (0x1F700, 0x1F77F), (0x1F780, 0x1F7FF),
        (0x1F800, 0x1F8FF), (0x1F900, 0x1F9FF), (0x1FA00, 0x1FA6F), (0x1FA70, 0x1FAFF),
        (0x20000, 0x10FFFF),
    ]

    var isWide: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let v = scalar.value
        if v <= 0x7F { return false }
        var lo = 0, hi = Character.wideRanges.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let r = Character.wideRanges[mid]
            if v < r.low { hi = mid - 1 }
            else if v > r.high { lo = mid + 1 }
            else { return true }
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
