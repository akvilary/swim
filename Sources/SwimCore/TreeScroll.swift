/// The horizontal snap math of the tree lists — ONE pure rule shared by
/// both tree windows (through TreeListController), the horizontal twin
/// of the vertical ensureVisible doctrine. The law ("rule C" — the
/// parent anchor):
///
/// - The view does not move while the PARENT-ANCHORED PICTURE — the
///   parent directory's indent through the end of the attention row —
///   is fully visible at the current offset ("if it doesn't fit" is
///   the only trigger). Keeping the offset therefore GUARANTEES the
///   parent is on screen; the check can never be satisfied by a stale
///   right-shifted offset that shows the attention row but cuts the
///   parent (the hole this shape closes: the span is the anchor's own
///   picture, so an offset right of the anchor fails the check by
///   construction).
/// - When it does not fit, the view jumps so the PARENT of the
///   attention sits at the left edge — the parent directory's icon and
///   name first, the attention one indent in: NAME HEADS stay readable
///   (tails clip when names are longer than the window — the head is
///   the recognizable half), and "where we are" is always on screen.
///   A picture wider than the window never counts as visible, so the
///   long-name case always lands on the anchor.
/// - A degenerate window (width ≤ 0 — a window not yet laid out, the
///   boot state) decides nothing: the offset waits for real geometry.
///   (This no-op is load-bearing: the boot reveal used to run against
///   0×0 windows and scrolled the view past the end of the content.)
///
/// The caller pre-clamps the anchor by the manual-shift bound (the
/// widest visible row — see TreeListController), keeping a later
/// manual Right from jumping left; the function guards it ≥ 0 itself.
///
/// Dependency-free and side-effect-free; tested in
/// Tests/SwimCoreTests/TreeScrollTests.swift.
public enum TreeScroll {

    /// Keeps `current` while the parent-anchored picture — `anchor`
    /// (the parent indent) through `end` (the attention row's last
    /// cell) — fits a window `width` cells wide; otherwise returns
    /// `anchor` (clamped ≥ 0). Total for any input: a non-positive
    /// width or a degenerate `end` decides nothing; a negative current
    /// is never returned.
    public static func snapOffset(current: Int, width: Int, anchor: Int, end: Int) -> Int {
        guard width > 0 else { return current }
        let home = max(0, current)
        let a = max(0, anchor)
        guard end > a else { return home }
        // The picture fits ⟺ its head is inside (current ≤ anchor) and
        // its tail is inside (current + width ≥ end). A picture wider
        // than the window empties the interval — the anchor wins by
        // construction.
        if home <= a, home + width >= end {
            return home
        }
        return a
    }
}
