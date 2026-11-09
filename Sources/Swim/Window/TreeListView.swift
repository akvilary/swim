import Foundation
import SwimCore

/// Presentation side of the SwimCore `GitChangeClass`: the color a
/// file name gets in a tree — the shared git-decoration palette
/// (`Theme.stagedColor` / `Theme.unstagedColor`, green for additions),
/// the same constants as the editor gutter and the panel letters.
/// Directories are never marked, files only.
extension GitChangeClass {
    var color: Color {
        switch self {
        case .added: return Theme.green
        case .staged: return Theme.stagedColor
        case .unstaged: return Theme.unstagedColor
        }
    }
}

/// A window showing a tree through the shared `TreeListController` —
/// the connect-by-conforming surface for tree-wide services: the git
/// name-marks arrive through ONE door (the extension below), the same
/// doctrine as SpinnerWindow — Application drives every conformance
/// through one loop, a new tree window connects by conforming and
/// joining the list, not by growing the controller.
protocol TreeListWindow: AnyObject {
    /// The window's tree list (the shared component).
    var treeList: TreeListController { get }
    /// Window's own repaint flag — the marks are a draw-time lookup,
    /// so the only reaction owed is a repaint.
    var dirty: Bool { get set }
}

extension TreeListWindow {
    /// Receives the git name-coloring marks from the Application's
    /// background status fetch. Returns true when they changed (the
    /// caller re-renders); the tree model is untouched — coloring is
    /// a pure lookup at draw time, so lazy child loads and rescans
    /// pick the marks up for free.
    @discardableResult
    func setGitMarks(_ marks: [String: GitChangeClass]) -> Bool {
        guard treeList.setGitMarks(marks) else { return false }
        dirty = true
        return true
    }
}

/// The shared file-tree list machinery — everything below the domain:
/// the flattened rows (`FileTree.flatten`, SwimCore), the cursor, the
/// vertical scroll, the horizontal shift, the expansion mechanics and
/// the explorer-style navigation interactions (`TreeListNavigation`,
/// SwimCore). Owned by BOTH tree windows (the file explorer, the
/// search results); what a row MEANS — opening a file, revealing
/// match lines, loading children from disk — stays with each owner,
/// which keeps its tiny policy switch and calls these primitives.
///
/// Geometry is passed in per call (`visibleCount`, `width`): the
/// controller holds no window back-reference, so there is no
/// ownership cycle and no hidden coupling — a window computes
/// `height - its own header rows` and hands it over, the same
/// parameter discipline as the shared diff paint (DiffPaint.swift).
///
/// Rebuild discipline: the rows are rebuilt exactly once per dirty
/// flag, and every list-reading path (drawing, key handling, preview
/// lookups) goes through `ensureRows()` — so each consumer sees the
/// CURRENT list. Without this in the key handlers, a `j` after an
/// Enter-collapse would bound-check against the stale (longer) list
/// and could step the selection past the real end — an invisible,
/// silently drifting cursor.
final class TreeListController {

    /// The tree root; nil — the empty list. The root itself is never
    /// a row (FileTree.flatten yields its children at depth 0).
    var root: FileTreeNode? {
        didSet { invalidate() }
    }

    /// The listing filter (the explorer's `H`); nil — everything is
    /// visible. The closure must not capture the owning window —
    /// capture cycles are avoided by REPLACING the value (the `H`
    /// toggle installs a fresh self-contained closure), not by
    /// reading mutable window state through it.
    var filter: ((FileTreeNode) -> Bool)? {
        didSet { invalidate() }
    }

    private(set) var expansion = FileTreeExpansion()

    /// Git name-coloring marks by absolute path (SwimCore
    /// `GitChangeClass`), delivered by the Application's background
    /// status fetch. Keyed by path, not node identity: the dict
    /// survives tree rebuilds and lazy child loads untouched, and
    /// coloring is a pure lookup at draw time.
    private(set) var gitMarks: [String: GitChangeClass] = [:]

    private(set) var rows: [FileTree.Row] = []
    private(set) var selectedIndex: Int = 0
    private(set) var scrollOffset: Int = 0
    private(set) var horizontalOffset: Int = 0
    let horizontalStep = 4
    private var rowsDirty = true

    /// Receives the git name-coloring marks. Returns true when they
    /// changed (the caller re-renders); the tree model is untouched —
    /// coloring is a pure lookup at draw time, so lazy child loads
    /// and rescans pick the marks up for free.
    @discardableResult
    func setGitMarks(_ marks: [String: GitChangeClass]) -> Bool {
        guard marks != gitMarks else { return false }
        gitMarks = marks
        return true
    }

    // MARK: - Expansion mechanics

    func isExpanded(_ node: FileTreeNode) -> Bool {
        expansion.isExpanded(node)
    }

    /// Expands the node when collapsed (a no-op when already
    /// expanded — `l` never collapses).
    @discardableResult
    func expand(_ node: FileTreeNode) -> Bool {
        guard !expansion.isExpanded(node) else { return false }
        expansion.expand(node)
        invalidate()
        return true
    }

    /// Enter on a branch: collapsed expands, expanded collapses (the
    /// collapse wipes the subtree's expansion memory —
    /// `FileTreeExpansion.collapse`).
    @discardableResult
    func toggle(_ node: FileTreeNode) -> Bool {
        if expansion.isExpanded(node) {
            expansion.collapse(node)
        } else {
            expansion.expand(node)
        }
        invalidate()
        return true
    }

    // MARK: - Rows

    /// Flags the rows as stale: after a domain mutation the owning
    /// window performed itself (a lazy child load into the tree, a
    /// rescan, an external expansion change such as a reveal walk).
    func invalidate() {
        rowsDirty = true
    }

    /// Rebuilds the rows when stale (see the class comment for the
    /// once-per-flag discipline) and clamps the selection into the
    /// rebuilt list — the universal safety; window policies that want
    /// an anchor (path, file) call `selectFirst`/`select` right after.
    func ensureRows() {
        guard rowsDirty else { return }
        rows = root.map { FileTree.flatten(root: $0, expansion: expansion, filter: filter) } ?? []
        rowsDirty = false
        selectedIndex = rows.isEmpty ? 0 : min(selectedIndex, rows.count - 1)
    }

    /// The selected row (nil — empty list or out of range).
    var selectedRow: FileTree.Row? {
        ensureRows()
        guard selectedIndex < rows.count else { return nil }
        return rows[selectedIndex]
    }

    // MARK: - Cursor

    /// j/k by `delta` (−1/+1): clamped to the list, the view follows.
    @discardableResult
    func move(_ delta: Int, visibleCount: Int) -> Bool {
        ensureRows()
        guard !rows.isEmpty else { return false }
        let next = min(max(0, selectedIndex + delta), rows.count - 1)
        guard next != selectedIndex else { return false }
        selectedIndex = next
        ensureVisible(visibleCount: visibleCount)
        return true
    }

    /// `g` — the first row, the view to the top.
    @discardableResult
    func jumpToFirst(visibleCount: Int) -> Bool {
        select(0, visibleCount: visibleCount)
    }

    /// `G` — the last row.
    @discardableResult
    func jumpToLast(visibleCount: Int) -> Bool {
        ensureRows()
        guard !rows.isEmpty else { return false }
        let last = rows.count - 1
        guard selectedIndex != last else { return false }
        select(last, visibleCount: visibleCount)
        return true
    }

    /// Absolute select, clamped into the list, the view follows —
    /// the restore primitive for window selection policies (anchors
    /// after a rebuild). Returns whether the index moved (the view
    /// correction alone — an already-selected row scrolled out of
    /// sight — is not a move, but the scroll still fixes itself).
    @discardableResult
    func select(_ index: Int, visibleCount: Int) -> Bool {
        ensureRows()
        let target = rows.isEmpty ? 0 : min(max(0, index), rows.count - 1)
        let moved = target != selectedIndex
        selectedIndex = target
        ensureVisible(visibleCount: visibleCount)
        return moved
    }

    /// Selects the first row passing `predicate` (the anchor-restore
    /// lookup). Returns whether one was found; not found — the
    /// selection is untouched (the caller applies its clamp policy).
    @discardableResult
    func selectFirst(where predicate: (FileTree.Row) -> Bool, visibleCount: Int) -> Bool {
        ensureRows()
        guard let idx = rows.firstIndex(where: predicate) else { return false }
        select(idx, visibleCount: visibleCount)
        return true
    }

    /// Zeroes cursor, scroll and horizontal offset — a fresh
    /// navigation session (a new search landing).
    func reset() {
        selectedIndex = 0
        scrollOffset = 0
        horizontalOffset = 0
        invalidate()
    }

    // MARK: - Scroll

    func ensureVisible(visibleCount: Int) {
        scrollOffset = Window.clampedScroll(
            selectedIndex: selectedIndex, scrollOffset: scrollOffset, visibleCount: visibleCount)
    }

    /// Left/Right: shifts the view `delta` cells (the step is
    /// `horizontalStep`), clamped by the WIDEST VISIBLE ROW — measured
    /// through `rowWidth`, the caller's cell pipeline: the built row's
    /// cell count IS the row's terminal width (the single width
    /// authority — a bound hand-computed per row kind would drift
    /// from what is actually drawn).
    @discardableResult
    func shiftHorizontally(
        _ delta: Int,
        width: Int,
        visibleCount: Int,
        rowWidth: (FileTree.Row) -> Int
    ) -> Bool {
        ensureRows()
        let maxOffset = max(0, maxVisibleRowLength(visibleCount: visibleCount, rowWidth: rowWidth) - width + 1)
        let next = max(0, min(horizontalOffset + delta, maxOffset))
        guard next != horizontalOffset else { return false }
        horizontalOffset = next
        return true
    }

    /// The widest visible row's width in cells — the horizontal bound
    /// both the manual shift and the snaps clamp by (everything past
    /// the widest row's end is blank). Shared by shiftHorizontally and
    /// applySnap.
    private func maxVisibleRowLength(
        visibleCount: Int,
        rowWidth: (FileTree.Row) -> Int
    ) -> Int {
        var maxLen = 0
        for idx in scrollOffset..<min(scrollOffset + visibleCount, rows.count) {
            maxLen = max(maxLen, rowWidth(rows[idx]))
        }
        return maxLen
    }

    func resetHorizontalOffset() {
        horizontalOffset = 0
    }

    // MARK: - Horizontal view anchoring (TreeScroll — the rule-C snaps)

    /// After Enter's toggle at `index`: the branch EXPANDED → anchor
    /// the strip of rows it now owns below it; COLLAPSED → anchor the
    /// branch's own row (the same treatment `h` gives its target —
    /// collapsing must not leave the view parked past the shrunken
    /// rows' ends). The direction is read from the expansion state
    /// AFTER the toggle, here and once — windows never decide it.
    /// Returns whether the view moved (the caller folds it into its
    /// dirty flag).
    @discardableResult
    func snapToggle(
        at index: Int,
        width: Int,
        visibleCount: Int,
        rowWidth: (FileTree.Row) -> Int
    ) -> Bool {
        ensureRows()
        guard index >= 0, index < rows.count else { return false }
        if case .node(let node, _) = rows[index], expansion.isExpanded(node) {
            return snap(toStripBelow: index, width: width, visibleCount: visibleCount, rowWidth: rowWidth)
        }
        return snap(toRow: index, width: width, visibleCount: visibleCount, rowWidth: rowWidth)
    }

    /// After `l`'s expand/descend at `index`: anchor the strip of rows
    /// the branch owns below it — its children, and (when those were
    /// expanded before) their subtrees; the strip ends at the first
    /// row not deeper than the branch.
    @discardableResult
    func snapToChildren(
        ofRow index: Int,
        width: Int,
        visibleCount: Int,
        rowWidth: (FileTree.Row) -> Int
    ) -> Bool {
        snap(toStripBelow: index, width: width, visibleCount: visibleCount, rowWidth: rowWidth)
    }

    /// After a collapse, a reveal, or a selection-restoring rebuild:
    /// anchor the single row the cursor lands on — the horizontal
    /// counterpart of ensureVisible.
    @discardableResult
    func snapToRow(
        _ index: Int,
        width: Int,
        visibleCount: Int,
        rowWidth: (FileTree.Row) -> Int
    ) -> Bool {
        snap(toRow: index, width: width, visibleCount: visibleCount, rowWidth: rowWidth)
    }

    /// The anchor law, ONE formula for every case: the PARENT of the
    /// attention sits at the left edge — the parent directory's icon
    /// and name first, the attention one indent in. Clamped home at
    /// the top level (depth 0 → 0).
    private func parentAnchor(attentionDepth: Int) -> Int {
        max(0, (attentionDepth - 1) * 2)
    }

    /// The anchor strip below `index`: contiguous rows deeper than the
    /// branch, intersected with the vertical viewport — "make readable
    /// what is on screen". The intersection also keeps the strip's end
    /// within the manual-shift bound (maxVisibleRowLength walks the
    /// same window), so a subsequent Right can never jump left. An
    /// empty intersection (an empty branch, or the strip entirely
    /// below the viewport) is a no-op.
    private func snap(
        toStripBelow index: Int,
        width: Int,
        visibleCount: Int,
        rowWidth: (FileTree.Row) -> Int
    ) -> Bool {
        ensureRows()
        guard index >= 0, index < rows.count else { return false }
        let branchDepth = rows[index].depth
        let viewportTop = scrollOffset
        let viewportBottom = min(scrollOffset + max(0, visibleCount), rows.count)
        var end = 0
        var found = false
        var i = index + 1
        while i < viewportBottom, rows[i].depth > branchDepth {
            if i >= viewportTop {
                found = true
                end = max(end, rowWidth(rows[i]))
            }
            i += 1
        }
        guard found else { return false }
        // The attention is the strip (one deeper than the branch): the
        // anchor is the branch's own level.
        return applySnap(
            anchor: parentAnchor(attentionDepth: branchDepth + 1),
            end: end,
            width: width, visibleCount: visibleCount, rowWidth: rowWidth)
    }

    private func snap(
        toRow index: Int,
        width: Int,
        visibleCount: Int,
        rowWidth: (FileTree.Row) -> Int
    ) -> Bool {
        ensureRows()
        guard index >= 0, index < rows.count else { return false }
        return applySnap(
            anchor: parentAnchor(attentionDepth: rows[index].depth),
            end: rowWidth(rows[index]),
            width: width, visibleCount: visibleCount, rowWidth: rowWidth)
    }

    /// The pure rule applies, with the anchor pre-clamped by the
    /// manual-shift bound: when the content is short relative to the
    /// depth, the clamp pulls the anchor further LEFT — more context
    /// than the parent, never less, and never right of the widest
    /// visible row's tail (a later manual Right continues from a
    /// consistent offset). The visibility check is the ANCHOR'S OWN
    /// picture — the parent's indent through the attention's end — so
    /// an offset parked right of the parent can never satisfy it: the
    /// parent is on screen after every snap, keep or jump.
    private func applySnap(
        anchor: Int,
        end: Int,
        width: Int,
        visibleCount: Int,
        rowWidth: (FileTree.Row) -> Int
    ) -> Bool {
        let bound = max(0, maxVisibleRowLength(visibleCount: visibleCount, rowWidth: rowWidth) - width + 1)
        let clampedAnchor = min(anchor, bound)
        let next = TreeScroll.snapOffset(current: horizontalOffset, width: width, anchor: clampedAnchor, end: end)
        guard next != horizontalOffset else { return false }
        horizontalOffset = next
        return true
    }

    // MARK: - Explorer-style interactions

    /// The descend after an expand (Enter/`l`): the selection moves
    /// onto the branch's first child — the row right below one depth
    /// deeper (`TreeListNavigation.firstChild`); a collapsed-again
    /// branch has no such row, the selection stays.
    @discardableResult
    func descendToFirstChild(visibleCount: Int) -> Bool {
        ensureRows()
        guard let child = TreeListNavigation.firstChild(
            rowCount: rows.count,
            selectedIndex: selectedIndex,
            depthAt: { rows[$0].depth }
        ) else { return false }
        selectedIndex = child
        ensureVisible(visibleCount: visibleCount)
        return true
    }

    /// The explorer-style `h`: the key acts on the selected row's
    /// PARENT branch — the nearest row above one depth shallower
    /// (`TreeListNavigation.collapseTarget`), or the row itself at
    /// the top level. The selection moves there; an expanded target
    /// collapses (with the subtree memory wipe), a collapsed one is
    /// left alone — remove, never insert; expanding is Enter/`l`'s
    /// job.
    @discardableResult
    func collapseUp(visibleCount: Int) -> Bool {
        ensureRows()
        guard selectedIndex < rows.count else { return false }
        let target = TreeListNavigation.collapseTarget(
            rowCount: rows.count,
            selectedIndex: selectedIndex
        ) { rows[$0].depth }
        selectedIndex = target
        if case .node(let node, _) = rows[target], expansion.isExpanded(node) {
            expansion.collapse(node)
            invalidate()
        }
        ensureVisible(visibleCount: visibleCount)
        return true
    }
}

extension Window {

    /// The shared tree-row cell pipeline — THE tree row look,
    /// established by the file explorer: depth indent (two cells a
    /// level), one space, the tier icon (SwimCore `Icons` —
    /// directories open/closed by expansion, files typed by name; the
    /// brand color where the tier defines one, otherwise the row's
    /// base fg), one space, the name (directories blue+bold; a file
    /// the caller's `markFg` — the git name-coloring — else the
    /// selection-aware base). Both tree windows build their node rows
    /// through this one function: identical look by construction, and
    /// the built cells' count is the row's terminal width — the width
    /// authority the horizontal scroll clamps against.
    static func fileTreeRowCells(
        node: FileTreeNode,
        depth: Int,
        expanded: Bool,
        selected: Bool,
        markFg: Color?
    ) -> [Cell] {
        let hl = Cell.highlight(selected, tint: Theme.bgHighlight, base: Theme.bgDark)
        let bg = hl.bg
        let baseFg: Color = selected ? Theme.fg : Theme.fgDark
        let iconFg: Color = node.isDirectory ? Theme.blue : baseFg
        // Git name coloring, files only: a new/untracked file is
        // green, a fully staged change blue, any unstaged change
        // teal. The mark wins over the selection text color — the
        // row background already marks the selection; directories
        // and clean files keep the base colors.
        let nameFg: Color
        if node.isDirectory {
            nameFg = Theme.blue
        } else if let markFg {
            nameFg = markFg
        } else {
            nameFg = baseFg
        }

        let iconDef = node.isDirectory
            ? Icons.directory(expanded: expanded, tier: IconSet.tier)
            : Icons.fileIcon(forName: node.name, tier: IconSet.tier)
        let iconColor = iconDef.color.map { Color.rgb(r: $0.r, g: $0.g, b: $0.b) } ?? iconFg

        var cells: [Cell] = Array(repeating: Cell.colored(" ", fg: baseFg, bg: bg), count: depth * 2)
        cells.append(Cell.colored(" ", fg: iconFg, bg: bg))
        cells += textCells(String(iconDef.glyph), fg: iconColor, bg: bg, bold: node.isDirectory)
        cells.append(Cell.colored(" ", fg: iconFg, bg: bg))
        cells += textCells(node.name, fg: nameFg, bg: bg, bold: node.isDirectory)
        return cells
    }

    /// Draws the visible slice of a tree list below the window's own
    /// header rows (`contentTop` — 1 header row in the explorer, the
    /// 2-row plate in the search results): the shared row loop both
    /// windows delegate to. `rowCells` builds one row's cells — node
    /// rows go through `fileTreeRowCells` (plus the window's own
    /// trailing runs), match rows through the search's word builder;
    /// the highlight policy is one place (`Cell.highlight`: the tint
    /// while color exists, reverse video in mono).
    func drawTreeListRows(
        list: TreeListController,
        contentTop: Int,
        rowCells: (FileTree.Row, _ isSelected: Bool) -> [Cell]
    ) {
        list.ensureRows()
        let visibleCount = max(0, height - contentTop)
        for row in 0..<visibleCount {
            let idx = list.scrollOffset + row
            guard idx < list.rows.count else { break }
            let isSelected = idx == list.selectedIndex
            let hl = Cell.highlight(isSelected, tint: Theme.bgHighlight, base: Theme.bgDark)
            let fillFg: Color = isSelected ? Theme.fg : Theme.fgDark
            drawCells(
                rowCells(list.rows[idx], isSelected),
                row: row + contentTop,
                offset: list.horizontalOffset,
                fillFg: fillFg,
                fillBg: hl.bg,
                reverse: hl.reverse
            )
        }
    }
}
