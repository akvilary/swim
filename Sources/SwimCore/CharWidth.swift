/// Character widths in terminal cells — the single authority for
/// everything that draws text into the cell buffer and computes
/// columns: the renderer (wideContinuation cells), the editor/explorer
/// (their own passes), and the horizontal scrolling of input surfaces
/// (`InputLine`). Lives in SwimCore — pure logic with no dependencies,
/// covered by tests (Tests/SwimCoreTests/CharWidthTests).
extension Character {
    /// The character's width in terminal cells (deterministic, independent of locale —
    /// unlike libc-wcwidth, which in the C locale treats Cyrillic/CJK as invisible):
    /// 0 — control (C0/C1) and zero-width (combining marks, ZWJ/ZWNJ etc.);
    /// 1 — ordinary (Latin, Cyrillic, ...);
    /// 2 — wide (CJK, emoji — see `isWide`, the Unicode East Asian Width table).
    /// A grapheme cluster is measured by its first scalar: Swift has already glued the
    /// base character with modifiers/combining marks into a single `Character`, so ZWJ
    /// emoji sequences correctly get width 2.
    public var displayWidth: Int {
        guard let scalar = unicodeScalars.first else { return 0 }
        let v = scalar.value
        if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) { return 0 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        return isWide ? 2 : 1
    }

    /// The display-column step when the character is emitted on a line
    /// at position `col`: tab — up to the next tabstop boundary (width
    /// depends on position), wide — 2, zero-width (combining, ZWJ) — 0,
    /// everything else — 1. The single authority for column arithmetic:
    /// line rendering, horizontal scrolling, and visual-block (SwimCore.
    /// VisualBlock) compute steps only through it.
    public func displayStep(atDisplayCol col: Int, tabWidth: Int) -> Int {
        if self == "\t" { return tabWidth - (col % tabWidth) }
        let w = displayWidth
        return w > 0 ? w : 0
    }

    /// Wide ranges of Unicode East Asian Width (sorted in ascending order).
    /// Binary search over the table instead of an `if` chain — O(log n) (~6 comparisons).
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

    public var isWide: Bool {
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
