import Testing
@testable import SwimCore

/// Fixtures for the search-results tree builder — the full path chain
/// from the search root down to the match lines. The nodes are the
/// shared `FileTreeNode` (the same model the explorer's tree uses);
/// this builder fills the `search` payload only. Keep in sync with
/// the window's consumption (Sources/Swim/Window/SearchResultsWindow.swift):
/// the expansion keys are the nodes' absolute paths, the counts in
/// the rows are the subtree match totals folded at build, and the
/// dirs-before-files row order is `FileTree.flatten`'s partition
/// (pinned in FileTreeTests).
struct SearchTreeTests {

    private func match(_ path: String, _ line: Int) -> SearchResult {
        SearchResult(filePath: path, lineNumber: line, lineContent: "x", matchStart: 0, matchLength: 1)
    }

    /// Directories of a level, in build order.
    private func dirs(_ node: FileTreeNode) -> [FileTreeNode] {
        node.children.filter(\.isDirectory)
    }

    /// Files of a level, in build order.
    private func files(_ node: FileTreeNode) -> [FileTreeNode] {
        node.children.filter { !$0.isDirectory }
    }

    /// The tree of a small project: root → dirs/files, every
    /// intermediate level present, shared ancestors merged, counts
    /// folded bottom-up (the root's total equals the flat count —
    /// the plate and the tree can never disagree).
    @Test func fullChainFromRoot() {
        let root = SearchTree.build(results: [
            match("/repo/Sources/App/Application.swift", 1),
            match("/repo/Sources/App/Application.swift", 5),
            match("/repo/Sources/Core/Cell.swift", 3),
            match("/repo/README.md", 2),
        ], root: "/repo")!

        #expect(root.name == "repo")
        #expect(root.path == "/repo")
        #expect(root.search?.matchCount == 4)
        // Root children: directories and files sorted alphabetically
        // (dirs render first — FileTree.flatten's partition).
        #expect(dirs(root).map(\.name) == ["Sources"])
        #expect(files(root).map(\.name) == ["README.md"])
        // The whole intermediate chain exists — not just the file's
        // immediate parent (the old single-level grouping).
        let sources = dirs(root)[0]
        #expect(sources.path == "/repo/Sources")
        #expect(sources.search?.matchCount == 3)
        #expect(dirs(sources).map(\.name) == ["App", "Core"])
        #expect(files(sources).isEmpty)
        let app = dirs(sources)[0]
        #expect(app.path == "/repo/Sources/App")
        #expect(app.search?.matchCount == 2)
        #expect(files(app).map(\.name) == ["Application.swift"])
        #expect(files(app)[0].search?.results.map(\.lineNumber) == [1, 5])
        let core = dirs(sources)[1]
        #expect(core.path == "/repo/Sources/Core")
        #expect(core.search?.matchCount == 1)
        #expect(files(core).map(\.name) == ["Cell.swift"])
        #expect(files(root)[0].path == "/repo/README.md")
        #expect(files(root)[0].search?.results.map(\.lineNumber) == [2])
    }

    /// Same-named directories at different depths are distinct nodes
    /// with distinct paths — the old flat grouping collapsed them into
    /// one label.
    @Test func sameNamedDirsStayDistinct() {
        let root = SearchTree.build(results: [
            match("/repo/Core/a.swift", 1),
            match("/repo/Sources/Core/b.swift", 1),
        ], root: "/repo")!

        #expect(root.search?.matchCount == 2)
        #expect(dirs(root).map(\.name) == ["Core", "Sources"])
        #expect(dirs(root)[0].path == "/repo/Core")
        #expect(dirs(dirs(root)[1]).map(\.path) == ["/repo/Sources/Core"])
        #expect(files(dirs(root)[0]).map(\.name) == ["a.swift"])
        #expect(files(dirs(dirs(root)[1])[0]).map(\.name) == ["b.swift"])
    }

    /// Match lines within a file sort by line number regardless of the
    /// order the scanner produced them; the file's count is the
    /// results length.
    @Test func resultsSortedByLine() {
        let root = SearchTree.build(results: [
            match("/repo/a.swift", 30),
            match("/repo/a.swift", 3),
            match("/repo/a.swift", 11),
        ], root: "/repo")!
        #expect(files(root)[0].search?.results.map(\.lineNumber) == [3, 11, 30])
        #expect(files(root)[0].search?.matchCount == 3)
    }

    /// A root with a trailing slash builds the same chain — the join
    /// never produces "//" and the relative-prefix check still holds.
    @Test func trailingSlashRoot() {
        let root = SearchTree.build(results: [
            match("/repo/Sources/a.swift", 1),
        ], root: "/repo/")!
        #expect(root.path == "/repo")
        #expect(dirs(root).map(\.path) == ["/repo/Sources"])
        #expect(files(dirs(root)[0]).map(\.path) == ["/repo/Sources/a.swift"])
    }

    /// No matches — no tree (the window shows the empty state, not a
    /// bare root row with a zero); by the same rule, input whose every
    /// match was dropped (the root itself — see insert) collapses to
    /// nil: a non-nil tree always carries at least one match.
    @Test func emptyResultsGiveNoTree() {
        #expect(SearchTree.build(results: [], root: "/repo") == nil)
        #expect(SearchTree.build(results: [match("/repo", 1)], root: "/repo") == nil)
    }

    /// An emptied branch collapses on rebuild: directories exist only
    /// on paths to matched files, so a file whose last match went away
    /// takes its whole ancestor chain with it — no empty directories
    /// can exist in a built tree, by construction. This is what the
    /// per-file freshness rebuild relies on: dropping one file's
    /// results shrinks the branch, no pruning pass needed.
    @Test func emptiedBranchCollapsesOnRebuild() {
        let full = SearchTree.build(results: [
            match("/repo/A/x.swift", 1),
            match("/repo/B/y.swift", 1),
            match("/repo/B/z.swift", 1),
        ], root: "/repo")!
        #expect(dirs(full).map(\.name) == ["A", "B"])
        #expect(dirs(full)[0].search?.matchCount == 1)

        let bothInBGone = SearchTree.build(results: [match("/repo/A/x.swift", 1)], root: "/repo")!
        #expect(dirs(bothInBGone).map(\.name) == ["A"])          // B collapsed entirely
        #expect(bothInBGone.search?.matchCount == 1)

        #expect(SearchTree.build(results: [], root: "/repo") == nil) // everything emptied
    }

    /// A match outside the root (impossible via the scanner, defensive
    /// for future callers) still lands in the tree — via its absolute
    /// components — instead of being silently dropped.
    @Test func outsideRootStillVisible() {
        let root = SearchTree.build(results: [
            match("/elsewhere/other/c.swift", 1),
        ], root: "/repo")!
        #expect(root.search?.matchCount == 1)
        #expect(dirs(root).map(\.name) == ["elsewhere"])
        #expect(dirs(dirs(root)[0]).map(\.path) == ["/repo/elsewhere/other"])
        #expect(files(dirs(dirs(root)[0])[0]).map(\.name) == ["c.swift"])
    }

    /// Exotic names — spaces, Cyrillic — survive as component names;
    /// only "/" splits.
    @Test func exoticNamesSurvive() {
        let root = SearchTree.build(results: [
            match("/repo/документы/заметки гайд.md", 7),
        ], root: "/repo")!
        #expect(dirs(root).map(\.name) == ["документы"])
        #expect(files(dirs(root)[0]).map(\.name) == ["заметки гайд.md"])
        #expect(files(dirs(root)[0])[0].search?.results[0].lineNumber == 7)
    }

    /// A search rooted at the FILESYSTEM ROOT builds the same chain —
    /// the check/cut/split convention is coherent there by construction
    /// (`TreePath.remainder`'s cut is one character, not two; the old
    /// hand-rolled pair `hasPrefix(rootPath + "/")` beside
    /// `dropFirst(rootPath.count + 1)` cancelled itself out into the
    /// absolute-components branch instead — same tree by accident,
    /// now by construction).
    @Test func fileSystemRootBuilds() {
        let root = SearchTree.build(results: [match("/a/b/c.swift", 1)], root: "/")!
        #expect(root.path == "/")
        #expect(root.search?.matchCount == 1)
        #expect(dirs(root).map(\.path) == ["/a"])
        #expect(dirs(dirs(root)[0]).map(\.path) == ["/a/b"])
        #expect(files(dirs(dirs(root)[0])[0]).map(\.path) == ["/a/b/c.swift"])
    }

    /// Search-built nodes carry no listing payload — a search tree is
    /// a finished snapshot with no explorer listing mechanics (nil is
    /// "not applicable", never "false": FileTreeNode's contract).
    @Test func searchNodesCarryNoListingPayload() {
        let root = SearchTree.build(results: [match("/repo/a.swift", 1)], root: "/repo")!
        #expect(root.listing == nil)
        #expect(files(root)[0].listing == nil)
        #expect(root.search != nil)
    }
}
