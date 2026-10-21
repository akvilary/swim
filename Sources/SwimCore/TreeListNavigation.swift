/// Navigation policy for a flattened tree list — the pure half of the
/// explorer-style keys, shared by FileExplorerWindow and
/// SearchResultsWindow:
///
/// - `collapseTarget` — the row `h` acts on: the selected row's PARENT
///   branch — the nearest row above one depth shallower — or the
///   selected row itself at the top level. The selection moves there;
///   the caller collapses it when it is expanded (it always is for a
///   nested row: an unexpanded branch emits no children, so the row
///   under the cursor would not exist).
///
///   Why the nearest shallower row IS the parent, no `isDirectory`-style
///   check needed: both flatten orders (the explorer's
///   `flattenRecursive`, the search tree's `appendDir`) emit a branch
///   before its children, and a child of depth `d` is emitted only under
///   an expanded branch of depth `d - 1`. Everything between the row and
///   that branch is elder siblings' subtrees — depth ≥ `d` — so the
///   FIRST row above at depth `d - 1` is exactly the parent, and by
///   construction it is a branch (files/leaves never emit children). The
///   explorer's old inline walker carried a redundant `isDirectory`
///   check for the same walk; this policy is behavior-identical to it.
///   The explorer's listing filter (`H`, hidden/ignored entries) skips
///   an entry together with its subtree, so the parent-before-children
///   order holds in every filter mode.
///
/// - `firstChild` — the row Enter/`l` descend to after an expand: the
///   row right below the branch when it is exactly one depth deeper.
///   A collapse leaves no such row — the selection stays on the branch.
///
/// Dependency-free and side-effect-free so it is unit-testable in
/// isolation (Tests/SwimCoreTests/TreeListNavigationTests.swift).
public enum TreeListNavigation {

    /// The row index `h` should act on for `selectedIndex` in a flat
    /// tree listing of `rowCount` rows whose per-row depths are read
    /// through `depthAt` (read-only during the walk — the caller's list
    /// is not mutated). Bounds-safe: an out-of-range selection is
    /// returned unchanged, matching the callers' guards.
    public static func collapseTarget(rowCount: Int, selectedIndex: Int, depthAt: (Int) -> Int) -> Int {
        guard selectedIndex >= 0, selectedIndex < rowCount else { return selectedIndex }
        let depth = depthAt(selectedIndex)
        guard depth > 0 else { return selectedIndex }
        var idx = selectedIndex - 1
        while idx >= 0 {
            if depthAt(idx) == depth - 1 { return idx }
            idx -= 1
        }
        // Unreachable by the flatten invariant (a depth ≥ 1 row always
        // has its parent above); the self-fallback keeps the policy
        // total for hostile input instead of trapping.
        return selectedIndex
    }

    /// The row an expand descends to: the row right below the branch
    /// when it is exactly one depth deeper — its first visible child;
    /// nil when there is none (the branch collapsed back, or nothing
    /// sits below). Bounds-safe: out-of-range input gives nil.
    public static func firstChild(rowCount: Int, selectedIndex: Int, depthAt: (Int) -> Int) -> Int? {
        guard selectedIndex >= 0, selectedIndex < rowCount else { return nil }
        let next = selectedIndex + 1
        guard next < rowCount else { return nil }
        return depthAt(next) == depthAt(selectedIndex) + 1 ? next : nil
    }
}
