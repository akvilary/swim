import Testing
import SwimCore

/// ColorSupport.detect — the environment's color verdict in
/// precedence order; xterm256Index — RGB folded into the 16-255
/// palette slots (cube vs gray ramp); ansi16Index — RGB folded into
/// the 16 system colors against the xterm reference palette.
@Suite struct ColorSupportTests {

    // MARK: - detect

    @Test func colortermNamingTruecolorWins() {
        #expect(ColorSupport.detect(colorterm: "truecolor", term: "xterm", noColor: nil) == .trueColor)
        #expect(ColorSupport.detect(colorterm: "Truecolor", term: "screen", noColor: nil) == .trueColor)
        #expect(ColorSupport.detect(colorterm: "24bit", term: nil, noColor: nil) == .trueColor)
        // the color-specific signal beats a TERM that looks dumber
        // (tmux's default TERM=screen with COLORTERM passed through)
        #expect(ColorSupport.detect(colorterm: "truecolor", term: "screen", noColor: nil) == .trueColor)
        #expect(ColorSupport.detect(colorterm: "truecolor", term: "dumb", noColor: nil) == .trueColor)
    }

    @Test func legacyColortermValuesAssertNothing() {
        // "yes"/"1" only ever meant "has colors" — TERM stays the authority
        #expect(ColorSupport.detect(colorterm: "yes", term: "xterm", noColor: nil) == .ansi16)
        #expect(ColorSupport.detect(colorterm: "1", term: "xterm-256color", noColor: nil) == .indexed256)
        #expect(ColorSupport.detect(colorterm: "", term: "xterm-256color", noColor: nil) == .indexed256)
    }

    @Test func directTermsAreTrueColor() {
        #expect(ColorSupport.detect(colorterm: nil, term: "xterm-direct", noColor: nil) == .trueColor)
        #expect(ColorSupport.detect(colorterm: nil, term: "kitty-direct", noColor: nil) == .trueColor)
    }

    @Test func term256SuffixMeans256() {
        #expect(ColorSupport.detect(colorterm: nil, term: "xterm-256color", noColor: nil) == .indexed256)
        #expect(ColorSupport.detect(colorterm: nil, term: "screen-256color", noColor: nil) == .indexed256)
        #expect(ColorSupport.detect(colorterm: nil, term: "tmux-256color", noColor: nil) == .indexed256)
    }

    @Test func plainAndMissingTermsFloorAt16() {
        #expect(ColorSupport.detect(colorterm: nil, term: "xterm", noColor: nil) == .ansi16)
        #expect(ColorSupport.detect(colorterm: nil, term: "alacritty", noColor: nil) == .ansi16)
        #expect(ColorSupport.detect(colorterm: nil, term: "linux", noColor: nil) == .ansi16)
        #expect(ColorSupport.detect(colorterm: nil, term: nil, noColor: nil) == .ansi16)
    }

    // MARK: - NO_COLOR / mono

    @Test func noColorDisablesColorRegardlessOfValue() {
        // no-color.org: present and non-empty — the value is
        // meaningless; "0" and "false" disable exactly like "1".
        #expect(ColorSupport.detect(colorterm: nil, term: "xterm-256color", noColor: "1") == .mono)
        #expect(ColorSupport.detect(colorterm: nil, term: "xterm-256color", noColor: "0") == .mono)
        #expect(ColorSupport.detect(colorterm: nil, term: "xterm", noColor: "false") == .mono)
        #expect(ColorSupport.detect(colorterm: nil, term: nil, noColor: " ") == .mono)
    }

    @Test func emptyNoColorIsInert() {
        // An empty string is the spec's single inert form — TERM rules.
        #expect(ColorSupport.detect(colorterm: nil, term: "xterm-256color", noColor: "") == .indexed256)
        #expect(ColorSupport.detect(colorterm: nil, term: "xterm", noColor: "") == .ansi16)
    }

    @Test func noColorBeatsEveryCapabilitySignal() {
        // The user's final word: even a truecolor terminal stays mono.
        #expect(ColorSupport.detect(colorterm: "truecolor", term: "xterm-256color", noColor: "1") == .mono)
        #expect(ColorSupport.detect(colorterm: nil, term: "xterm-direct", noColor: "yes") == .mono)
    }

    @Test func dumbTerminalIsMono() {
        // TERM=dumb declares no capabilities at all — color codes of
        // any level would be noise, exactly like NO_COLOR.
        #expect(ColorSupport.detect(colorterm: nil, term: "dumb", noColor: nil) == .mono)
    }

    // MARK: - xterm256Index

    @Test func exactCubeColorsMapToTheirOwnIndex() {
        // 16 + 36r + 6g + b over the [0, 95, 135, 175, 215, 255] levels
        #expect(xterm256Index(r: 0, g: 0, b: 0) == 16)
        #expect(xterm256Index(r: 255, g: 0, b: 0) == 196)
        #expect(xterm256Index(r: 95, g: 135, b: 175) == 67)
        #expect(xterm256Index(r: 255, g: 255, b: 255) == 231)
    }

    @Test func offLevelColorsSnapToTheNearestCubeEntry() {
        #expect(xterm256Index(r: 96, g: 134, b: 176) == 67)
    }

    @Test func midGraysLandInTheRampNotTheCube() {
        // (128,128,128): ramp 244 (level 128) beats the cube's nearest
        // (135,135,135) = 188 — the ramp exists precisely for these
        #expect(xterm256Index(r: 128, g: 128, b: 128) == 244)
        #expect(xterm256Index(r: 8, g: 8, b: 8) == 232)
        #expect(xterm256Index(r: 238, g: 238, b: 238) == 255)
    }

    @Test func themeColorsFoldToPinnedIndices() {
        // Tokyo Night Storm literals (Theme lives in the executable
        // target; SwimCore tests pin the values):
        // bg 0x24283b — a dark navy → gray ramp level 48 = 236
        #expect(xterm256Index(r: 0x24, g: 0x28, b: 0x3b) == 236)
        // fg 0xc0caf5 — a pale blue → cube (175, 215, 255) = 153
        #expect(xterm256Index(r: 0xc0, g: 0xca, b: 0xf5) == 153)
        // red 0xf7768e — a soft red → cube (255, 135, 135) = 210
        #expect(xterm256Index(r: 0xf7, g: 0x76, b: 0x8e) == 210)
    }

    // MARK: - ansi16Index

    @Test func referencePaletteColorsMapToThemselves() {
        #expect(ansi16Index(r: 0, g: 0, b: 0) == 0)
        #expect(ansi16Index(r: 205, g: 0, b: 0) == 1)
        #expect(ansi16Index(r: 0, g: 0, b: 238) == 4)
        #expect(ansi16Index(r: 229, g: 229, b: 229) == 7)
        #expect(ansi16Index(r: 127, g: 127, b: 127) == 8)
        #expect(ansi16Index(r: 255, g: 0, b: 0) == 9)
        #expect(ansi16Index(r: 255, g: 255, b: 255) == 15)
    }

    @Test func saturatedColorsPreferTheirBrights() {
        // theme blue 0x7aa2f7 is far past blue's (0,0,238) saturation —
        // bright blue (92,92,255) is the nearest system color
        #expect(ansi16Index(r: 0x7a, g: 0xa2, b: 0xf7) == 12)
    }

    @Test func themeBackgroundFoldsToBlack() {
        // 0x24283b is a near-black navy: black (0,0,0) beats every
        // other system color, bright black (127,127,127) included
        #expect(ansi16Index(r: 0x24, g: 0x28, b: 0x3b) == 0)
    }
}
