/// Terminal color capability — what the terminal can render, and the
/// RGB degradation that follows from it. The theme is RGB throughout;
/// a terminal without truecolor support either drops `38;2;...`
/// sequences silently (tmux/screen without Tc, 16-color consoles) or
/// garbles them, so every `.rgb` color is folded to the terminal's
/// level before serialization: truecolor passes through, 256-color
/// terminals get the nearest xterm palette entry, 16-color ones the
/// nearest system color.
///
/// Pure module: detection takes the environment VALUES (no
/// ProcessInfo inside — the caller in main.swift owns the
/// environment), the mappers are plain functions on RGB channels.
public enum ColorSupport: Equatable, Sendable {
    case trueColor
    case indexed256
    case ansi16
}

public extension ColorSupport {
    /// The environment's verdict, in precedence order:
    ///
    /// 1. `COLORTERM` naming truecolor (the values terminals actually
    ///    set: "truecolor" and "24bit") — the color-specific signal,
    ///    it wins even over a TERM that looks dumber (COLORTERM=truecolor
    ///    under tmux's default TERM=screen is the classic combo).
    ///    Legacy filler values ("yes", "1") assert nothing beyond TERM
    ///    and are ignored.
    /// 2. A `*-direct` TERM (xterm-direct, kitty-direct...) — the
    ///    terminfo family whose capability IS 24-bit.
    /// 3. A `*-256color` TERM — the xterm 256-palette.
    /// 4. Anything else, including nil and "dumb" — the 16 system
    ///    colors: the floor every color terminal can render.
    static func detect(colorterm: String?, term: String?) -> ColorSupport {
        if let colorterm {
            let c = colorterm.lowercased()
            if c.contains("truecolor") || c.contains("24bit") {
                return .trueColor
            }
        }
        guard let term else { return .ansi16 }
        let t = term.lowercased()
        if t.contains("direct") { return .trueColor }
        if t.contains("256color") { return .indexed256 }
        return .ansi16
    }
}

/// The xterm 256-palette's color cube channel levels: indices 16-231
/// are 16 + 36r + 6g + b over these six levels per channel, 232-255
/// are the 24-step gray ramp 8 + 10i. Levels shared by the mappers
/// below; private to this file.
private let cubeLevels: [UInt8] = [0, 95, 135, 175, 215, 255]

/// Nearest cube level for one channel: its palette index and the level
/// value itself.
private func nearestCubeLevel(_ channel: UInt8) -> (index: Int, level: UInt8) {
    var best = 0
    for i in 1..<cubeLevels.count where abs(Int(channel) - Int(cubeLevels[i])) < abs(Int(channel) - Int(cubeLevels[best])) {
        best = i
    }
    return (best, cubeLevels[best])
}

/// RGB → the nearest xterm-256 palette index, 16...255. The 16 system
/// slots (0-15) are deliberately skipped: they are the terminal
/// theme's, not the palette's — mapping into them would let a user
/// theme silently override the degradation. Candidates are the cube
/// entry (each channel snapped to its nearest level) and the gray
/// ramp entry; Euclidean distance decides — mid-grays land in the
/// ramp, saturated colors in the cube.
public func xterm256Index(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
    let rc = nearestCubeLevel(r), gc = nearestCubeLevel(g), bc = nearestCubeLevel(b)
    let cubeIndex = 16 + 36 * rc.index + 6 * gc.index + bc.index
    let cubeDistance = squaredDistance(r, g, b, rc.level, gc.level, bc.level)

    var grayIndex = 232
    var grayDistance = Int.max
    for i in 0..<24 {
        let level = UInt8(8 + 10 * i)
        let d = squaredDistance(r, g, b, level, level, level)
        if d < grayDistance {
            grayDistance = d
            grayIndex = 232 + i
        }
    }

    return grayDistance < cubeDistance ? UInt8(grayIndex) : UInt8(cubeIndex)
}

/// The 16 system colors as the xterm reference palette renders them.
/// The terminal's actual 0-15 are user-themeable (this is a feature —
/// Tokyo Night recolors them too); the reference values are the
/// neutral best guess any RGB→16 folding can make.
private let systemPalette: [(r: UInt8, g: UInt8, b: UInt8)] = [
    (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
    (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
    (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
    (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
]

/// RGB → the nearest of the 16 system colors, 0...15 (indices match
/// the Color enum's named cases: 0-7 the base colors, 8-15 their
/// brights). Euclidean distance; ties go to the lower index.
public func ansi16Index(r: UInt8, g: UInt8, b: UInt8) -> Int {
    var best = 0
    var bestDistance = Int.max
    for (i, c) in systemPalette.enumerated() {
        let d = squaredDistance(r, g, b, c.r, c.g, c.b)
        if d < bestDistance {
            bestDistance = d
            best = i
        }
    }
    return best
}

private func squaredDistance(_ r1: UInt8, _ g1: UInt8, _ b1: UInt8, _ r2: UInt8, _ g2: UInt8, _ b2: UInt8) -> Int {
    let dr = Int(r1) - Int(r2), dg = Int(g1) - Int(g2), db = Int(b1) - Int(b2)
    return dr * dr + dg * dg + db * db
}
