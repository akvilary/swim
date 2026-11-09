import Testing
@testable import SwimCore

/// The shared spinner value — the frame table and the tick/wrap
/// policy. Keep in sync with the consumers
/// (Sources/Swim/Window/*: every SpinnerWindow conformance).
struct SpinnerTests {

    /// The table is the git pull/push sequence, unchanged: braille
    /// pin rotations, one cell each (BMP only — the plain tier's
    /// glyph budget rule).
    @Test func frameTableIsTheBrailleRotation() {
        #expect(Spinner.frames == ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
        // One BMP scalar each — single cell, nothing width-fragile.
        #expect(Spinner.frames.allSatisfy {
            String($0).unicodeScalars.count == 1 && $0.unicodeScalars.first!.value <= 0xFFFF
        })
        #expect(!Spinner.frames.isEmpty)
    }

    /// tick advances one frame and wraps at the table's size — a
    /// full cycle walks every glyph exactly once, in table order.
    @Test func tickAdvancesAndWraps() {
        var spinner = Spinner()
        #expect(spinner.glyph == Spinner.frames[0])
        var walked: [Character] = [spinner.glyph]
        for _ in 0..<(Spinner.frames.count * 2) {
            spinner.tick()
            walked.append(spinner.glyph)
        }
        #expect(Array(walked.prefix(Spinner.frames.count)) == Spinner.frames)
        #expect(Array(walked.dropFirst(Spinner.frames.count).prefix(Spinner.frames.count)) == Spinner.frames)
    }

    /// Two spinners are independent values — a window with two waits
    /// (the git log's list and diff) ticks one without moving the
    /// other, and no window shares frames with another.
    @Test func spinnersAreIndependent() {
        var a = Spinner()
        var b = Spinner()
        for _ in 0..<4 { a.tick() }
        #expect(a.glyph == Spinner.frames[4])
        #expect(b.glyph == Spinner.frames[0])
        #expect(a != b)
    }

    /// The counter wraps internally (never grows): a very long wait
    /// keeps cycling without overflow — the value after any whole
    /// number of cycles equals a fresh one.
    @Test func longRunStable() {
        var spinner = Spinner()
        var reference = Spinner()
        for _ in 0..<(Spinner.frames.count * 1000) { spinner.tick() }
        #expect(spinner == reference)
        for _ in 0..<3 { reference.tick() }
        for _ in 0..<3 { spinner.tick() }
        #expect(spinner == reference)
    }
}
