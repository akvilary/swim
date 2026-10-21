import Testing
@testable import SwimCore

/// Fixtures for the search-results tree builder — the full path chain
/// from the search root down to the match lines. Keep in sync with the
/// window's consumption (Sources/Swim/Window/SearchResultsWindow.swift):
/// the expansion keys are the nodes' absolute paths, the counts in the
/// rows are the subtree match totals folded at build, and files render
/// after directories at every level.
struct SearchTreeTests {

    private func match(_ path: String, _ line: Int) -> SearchResult {
        SearchResult(filePath: path, lineNumber: line, lineContent: "x", matchStart: 0, matchLength: 1)
    }

    /// The tree of a small project: root → dirs/files, every
    /// intermediate level present, shared ancestors merged, counts
    /// folded bottom-up (the root's total equals the flat count —
    /// the header and the root row can never disagree).
    @Test func fullChainFromRoot() {
        let root = SearchTree.build(results: [
            match("/repo/Sources/App/Application.swift", 1),
            match("/repo/Sources/App/Application.swift", 5),
            match("/repo/Sources/Core/Cell.swift", 3),
            match("/repo/README.md", 2),
        ], root: "/repo")!

        #expect(root.name == "repo")
        #expect(root.path == "/repo")
        #expect(root.matchCount == 4)
        // Root children: directories and files sorted alphabetically
        // (dirs render first — the explorer's ordering).
        #expect(root.dirs.map(\.name) == ["Sources"])
        #expect(root.files.map(\.name) == ["README.md"])
        // The whole intermediate chain exists — not just the file's
        // immediate parent (the old single-level grouping).
        let sources = root.dirs[0]
        #expect(sources.path == "/repo/Sources")
        #expect(sources.matchCount == 3)
        #expect(sources.dirs.map(\.name) == ["App", "Core"])
        #expect(sources.files.isEmpty)
        let app = sources.dirs[0]
        #expect(app.path == "/repo/Sources/App")
        #expect(app.matchCount == 2)
        #expect(app.files.map(\.name) == ["Application.swift"])
        #expect(app.files[0].results.map(\.lineNumber) == [1, 5])
        let core = sources.dirs[1]
        #expect(core.path == "/repo/Sources/Core")
        #expect(core.matchCount == 1)
        #expect(core.files.map(\.name) == ["Cell.swift"])
        #expect(root.files[0].path == "/repo/README.md")
        #expect(root.files[0].results.map(\.lineNumber) == [2])
    }

    /// Same-named directories at different depths are distinct nodes
    /// with distinct paths — the old flat grouping collapsed them into
    /// one label.
    @Test func sameNamedDirsStayDistinct() {
        let root = SearchTree.build(results: [
            match("/repo/Core/a.swift", 1),
            match("/repo/Sources/Core/b.swift", 1),
        ], root: "/repo")!

        #expect(root.matchCount == 2)
        #expect(root.dirs.map(\.name) == ["Core", "Sources"])
        #expect(root.dirs[0].path == "/repo/Core")
        #expect(root.dirs[1].dirs.map(\.path) == ["/repo/Sources/Core"])
        #expect(root.dirs[0].files.map(\.name) == ["a.swift"])
        #expect(root.dirs[1].dirs[0].files.map(\.name) == ["b.swift"])
    }

    /// Match lines within a file sort by line number regardless of the
    /// order the scanner produced them; the file's count is the
    /// computed results length.
    @Test func resultsSortedByLine() {
        let root = SearchTree.build(results: [
            match("/repo/a.swift", 30),
            match("/repo/a.swift", 3),
            match("/repo/a.swift", 11),
        ], root: "/repo")!
        #expect(root.files[0].results.map(\.lineNumber) == [3, 11, 30])
        #expect(root.files[0].matchCount == 3)
    }

    /// A root with a trailing slash builds the same chain — the join
    /// never produces "//" and the relative-prefix check still holds.
    @Test func trailingSlashRoot() {
        let root = SearchTree.build(results: [
            match("/repo/Sources/a.swift", 1),
        ], root: "/repo/")!
        #expect(root.path == "/repo")
        #expect(root.dirs.map(\.path) == ["/repo/Sources"])
        #expect(root.dirs[0].files.map(\.path) == ["/repo/Sources/a.swift"])
    }

    /// No matches — no tree (the window shows the empty state, not a
    /// bare root row with a zero); by the same rule, input whose every
    /// match was dropped (the root itself — see insert) collapses to
    /// nil: a non-nil tree always carries at least one match.
    @Test func emptyResultsGiveNoTree() {
        #expect(SearchTree.build(results: [], root: "/repo") == nil)
        #expect(SearchTree.build(results: [match("/repo", 1)], root: "/repo") == nil)
    }

    /// A match outside the root (impossible via the scanner, defensive
    /// for future callers) still lands in the tree — via its absolute
    /// components — instead of being silently dropped.
    @Test func outsideRootStillVisible() {
        let root = SearchTree.build(results: [
            match("/elsewhere/other/c.swift", 1),
        ], root: "/repo")!
        #expect(root.matchCount == 1)
        #expect(root.dirs.map(\.name) == ["elsewhere"])
        #expect(root.dirs[0].dirs.map(\.path) == ["/repo/elsewhere/other"])
        #expect(root.dirs[0].dirs[0].files.map(\.name) == ["c.swift"])
    }

    /// Exotic names — spaces, Cyrillic — survive as component names;
    /// only "/" splits.
    @Test func exoticNamesSurvive() {
        let root = SearchTree.build(results: [
            match("/repo/документы/заметки гайд.md", 7),
        ], root: "/repo")!
        #expect(root.dirs.map(\.name) == ["документы"])
        #expect(root.dirs[0].files.map(\.name) == ["заметки гайд.md"])
        #expect(root.dirs[0].files[0].results[0].lineNumber == 7)
    }
}
