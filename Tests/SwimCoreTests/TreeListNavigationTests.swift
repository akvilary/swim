import Testing
@testable import SwimCore

/// Fixtures for the shared tree-list navigation policy — the shapes
/// both consumers (FileExplorerWindow, SearchResultsWindow) feed it:
/// the `h` collapse target (nested chains, elder siblings' subtrees
/// between the row and its parent, top-level rows) and the Enter/`l`
/// first-child descend. Keep in sync with the windows' key handlers.
struct TreeListNavigationTests {

    private func collapseTarget(_ depths: [Int], _ selected: Int) -> Int {
        TreeListNavigation.collapseTarget(rowCount: depths.count, selectedIndex: selected) { depths[$0] }
    }

    private func firstChild(_ depths: [Int], _ selected: Int) -> Int? {
        TreeListNavigation.firstChild(rowCount: depths.count, selectedIndex: selected) { depths[$0] }
    }

    // --- collapse target (`h`) ---

    /// A nested row targets the nearest shallower row above — its
    /// parent branch; everything between belongs to elder siblings'
    /// subtrees (depth ≥ the row's own).
    @Test func nestedRowTargetsParent() {
        // Tree: A(0) → B(1) → C(2); B's elder sibling B0(1) with its
        // own child sits between C and B.
        let depths = [0, 1, 2, 1, 2, 0, 1]
        // indices:  0  1  2  3  4  5  6
        // A(0), B0(1), C0(2), B(1), C(2), D(0), E(1)
        #expect(collapseTarget(depths, 4) == 3) // C(2) → its parent B(1)
        #expect(collapseTarget(depths, 2) == 1) // C0(2) → its parent B0(1)
        #expect(collapseTarget(depths, 6) == 5) // E(1) → its parent D(0)
    }

    /// A top-level row targets itself — there is no row above it; the
    /// caller collapses it when expanded, else the press is a no-op.
    @Test func topLevelTargetsSelf() {
        let depths = [0, 1, 0]
        #expect(collapseTarget(depths, 0) == 0)
        #expect(collapseTarget(depths, 2) == 2)
        // The search tree has a root row at depth 0 with content from
        // depth 1: a first-level row targets the root, the root
        // targets itself.
        #expect(collapseTarget([0, 1, 2, 1], 1) == 0)
        #expect(collapseTarget([0, 1, 2, 1], 3) == 0)
    }

    /// The walk skips same-depth and deeper rows of preceding
    /// siblings — the first SHALLOWER row wins, not the nearest
    /// directory-looking one.
    @Test func walkSkipsDeeperAndSameDepthRows() {
        // A(0), B(1), C(2), D(2), E(1) — cursor on E: rows above at
        // depth 2 (C, D) and 1 (B) must all be skipped for A(0).
        let depths = [0, 1, 2, 2, 1]
        #expect(collapseTarget(depths, 4) == 0)
    }

    /// Bounds and degenerate input: out-of-range selection and an
    /// empty list return the selection unchanged — the policy stays
    /// total, the callers' guards own the rest.
    @Test func collapseBoundsAndEmptyListsSafe() {
        #expect(collapseTarget([], 0) == 0)
        #expect(collapseTarget([0, 1], -1) == -1)
        #expect(collapseTarget([0, 1], 5) == 5)
    }

    // --- first child (Enter/`l` descend) ---

    /// An expanded branch descends onto the row right below it — its
    /// first child, one depth deeper.
    @Test func descendLandsOnFirstChild() {
        let depths = [0, 1, 2, 1, 0]
        #expect(firstChild(depths, 0) == 1) // root → first dir
        #expect(firstChild(depths, 1) == 2) // dir → its file
    }

    /// A branch whose next row is NOT one deeper has no visible child:
    /// a leaf followed by its parent's next sibling, or the last row
    /// of the list — nil, the selection stays on the branch.
    @Test func noChildWhenNextRowNotDeeper() {
        #expect(firstChild([0, 1, 2, 1], 2) == nil) // leaf file, uncle below
        #expect(firstChild([0, 1, 2], 2) == nil)    // last row of the list
        #expect(firstChild([0], 0) == nil)          // single row
    }

    /// Bounds-safe: out-of-range selection gives nil.
    @Test func descendBoundsSafe() {
        #expect(firstChild([0, 1], -1) == nil)
        #expect(firstChild([0, 1], 7) == nil)
    }
}
