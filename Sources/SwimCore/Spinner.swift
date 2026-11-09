/// The braille spinner every background wait animates — the ONE
/// frame sequence and tick policy in the app, owned here the way
/// Icons owns the row glyphs (a window draws, the core defines).
/// Five windows had grown their own copy of the table and the
/// `frame % count` arithmetic before this; a value type per wait
/// (a window with two independent waits owns two) ends the
/// duplication without sharing mutable state across windows.
///
/// A spinner is a frame counter plus the pin-rotation table: every
/// tick advances one frame, `glyph` reads the table at the frame —
/// the git pull/push look (CommandWindow), the terminal prompt, the
/// branch/log/panel loads, the search scan. The counter wraps at
/// the table's size inside `tick`, so it can never overflow a
/// long-lived process; `glyph` needs no defensive modulo of its own.
/// The table stays internal on purpose — the public surface is
/// `glyph` and `tick()` only, so no window can reach the frames to
/// hand-roll the indexing this type retired. No reset API either:
/// the cycle simply continues across waits (a mid-rotation start is
/// invisible), there is nothing to reset.
public struct Spinner: Equatable, Sendable {
    /// The frame table — braille pin rotations, single cell each,
    /// BMP codepoints (the plain tier's glyph budget rule: nothing
    /// astral, nothing width-fragile).
    static let frames: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private var frame: Int = 0

    public init() {}

    /// The glyph for the current frame.
    public var glyph: Character { Self.frames[frame] }

    /// One ~100ms tick (the SpinnerWindow cadence): advance and
    /// wrap. Mutating — each window's spinner is its own value.
    public mutating func tick() {
        frame = (frame + 1) % Self.frames.count
    }
}
