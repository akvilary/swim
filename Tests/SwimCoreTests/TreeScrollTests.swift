import Testing
@testable import SwimCore

/// Fixtures for the horizontal snap math — rule C, the parent anchor:
/// keep the offset while the parent-anchored picture (the parent's
/// indent through the attention row's end) fits the window entirely;
/// otherwise jump so the parent sits at the left edge (name HEADS stay
/// readable, tails clip). A degenerate window decides nothing.
/// TreeListController feeds the anchors and ends; this pins the rule.
struct TreeScrollTests {

    /// The parent picture fully visible — at the anchor's edge, left
    /// of it (extra context), and in the middle — not a single cell of
    /// movement.
    @Test func fullyVisibleStays() {
        // anchor 4: picture 4..10 fits from offset 0 (extra context);
        // picture 4..12 fits at offsets 2..4.
        #expect(TreeScroll.snapOffset(current: 0, width: 10, anchor: 4, end: 10) == 0)
        #expect(TreeScroll.snapOffset(current: 2, width: 10, anchor: 4, end: 12) == 2)
        #expect(TreeScroll.snapOffset(current: 4, width: 10, anchor: 4, end: 12) == 4)
        #expect(TreeScroll.snapOffset(current: 0, width: 22, anchor: 0, end: 15) == 0)
    }

    /// The tail of the parent picture is cut → the parent anchor (the
    /// HEAD of the content wins, not a minimal shift, not the tail).
    @Test func tailCutJumpsToParentAnchor() {
        #expect(TreeScroll.snapOffset(current: 0, width: 10, anchor: 4, end: 15) == 4)
        #expect(TreeScroll.snapOffset(current: 3, width: 10, anchor: 2, end: 14) == 2)
    }

    /// The head is cut — the view parked RIGHT of the anchor (the
    /// stale-offset collapse hole): the attention row might fit there,
    /// but the parent picture does not → the anchor pulls it back.
    @Test func staleRightOffsetAnchors() {
        #expect(TreeScroll.snapOffset(current: 7, width: 10, anchor: 2, end: 8) == 2)
        #expect(TreeScroll.snapOffset(current: 6, width: 22, anchor: 4, end: 26) == 4)
        #expect(TreeScroll.snapOffset(current: 100, width: 10, anchor: 0, end: 8) == 0)
    }

    /// The picture is wider than the window — no offset shows it
    /// whole, so it never counts as visible: the parent anchor always
    /// wins, from any side (the long-name case: heads readable, tails
    /// clip).
    @Test func widerThanWindowAlwaysAnchors() {
        #expect(TreeScroll.snapOffset(current: 0, width: 5, anchor: 2, end: 10) == 2)
        #expect(TreeScroll.snapOffset(current: 3, width: 5, anchor: 2, end: 10) == 2)
        #expect(TreeScroll.snapOffset(current: 9, width: 5, anchor: 2, end: 10) == 2)
    }

    /// A top-level attention arrives with a negative-equivalent anchor
    /// (depth 0 → (0-1)·2) — clamped home to zero.
    @Test func anchorClampsToZero() {
        #expect(TreeScroll.snapOffset(current: 5, width: 10, anchor: -2, end: 6) == 0)
    }

    /// Hostile input stays total: a negative current is never
    /// "visible" against an anchor ≥ 0 — the anchor applies, and the
    /// result is never negative.
    @Test func negativeCurrentIsTotal() {
        #expect(TreeScroll.snapOffset(current: -3, width: 10, anchor: 4, end: 12) == 4)
    }

    /// A degenerate window (width ≤ 0 — the boot state before the
    /// first layout) decides NOTHING: the offset waits for real
    /// geometry. This no-op is the horizontal half of the
    /// `swim <file>` boot fix — a zero-width snap once scrolled the
    /// view past the end of every row.
    @Test func degenerateWindowDecidesNothing() {
        #expect(TreeScroll.snapOffset(current: 0, width: 0, anchor: 4, end: 9) == 0)
        #expect(TreeScroll.snapOffset(current: 7, width: -5, anchor: 4, end: 9) == 7)
    }

    /// A degenerate span (end ≤ anchor — nothing to show past the
    /// anchor) decides nothing either.
    @Test func degenerateSpanDecidesNothing() {
        #expect(TreeScroll.snapOffset(current: 3, width: 10, anchor: 4, end: 4) == 3)
    }
}
