import Testing
@testable import SwimCore

/// Fixtures for the shared file-tree flatten — the row list both tree
/// windows (the explorer, the search results) are built from. The
/// invariants here are the ones the navigation policy
/// (TreeListNavigation) proves its walks over: parent always before
/// children, a child only under an expanded branch, depth = one past
/// the parent. Keep in sync with the consumers
/// (Sources/Swim/Window/TreeListView.swift and the two windows).
struct FileTreeTests {

    private func dir(_ name: String, _ path: String, children: [FileTreeNode] = []) -> FileTreeNode {
        let node = FileTreeNode(name: name, path: path, isDirectory: true)
        node.children = children
        return node
    }

    private func file(_ name: String, _ path: String, results: [SearchResult] = []) -> FileTreeNode {
        let node = FileTreeNode(name: name, path: path, isDirectory: false)
        node.search = SearchPayload(results: results, matchCount: results.count)
        return node
    }

    private func match(_ path: String, _ line: Int) -> SearchResult {
        SearchResult(filePath: path, lineNumber: line, lineContent: "x", matchStart: 0, matchLength: 1)
    }

    /// The root itself is never a row — its children sit at depth 0,
    /// their children at depth 1 (the single topology rule for the
    /// explorer and the search results alike: the top level is the
    /// root's CONTENT, no extra "project root" row above it).
    @Test func rootNeverARow() {
        let root = dir("repo", "/repo", children: [
            dir("Sources", "/repo/Sources", children: [
                dir("App", "/repo/Sources/App"),
            ]),
            file("README.md", "/repo/README.md"),
        ])
        var expansion = FileTreeExpansion()
        expansion.expand(root.children[0]) // Sources

        let rows = FileTree.flatten(root: root, expansion: expansion)
        #expect(rows.map(\.depth) == [0, 1, 0])
        guard case .node(let sources, _) = rows[0], case .node(let app, _) = rows[1] else {
            Issue.record("expected node rows"); return
        }
        #expect(sources.path == "/repo/Sources")
        #expect(app.path == "/repo/Sources/App")
    }

    /// Directories before files at every level, BY CONSTRUCTION — the
    /// builder handed the children over interleaved and the flatten's
    /// stable partition still yields every directory ahead of every
    /// file, each kind keeping its given order.
    @Test func dirsBeforeFilesByConstruction() {
        let root = dir("repo", "/repo", children: [
            file("a.md", "/repo/a.md"),
            dir("Zeta", "/repo/Zeta"),
            file("b.md", "/repo/b.md"),
            dir("Alpha", "/repo/Alpha"),
        ])

        let rows = FileTree.flatten(root: root, expansion: FileTreeExpansion())
        #expect(rows.map { nodePath($0) } == ["/repo/Zeta", "/repo/Alpha", "/repo/a.md", "/repo/b.md"])
    }

    /// A collapsed directory emits no subtree; expanding reveals it at
    /// depth + 1. Files (without a search payload) never expand.
    @Test func expansionGatesRecursion() {
        let inner = dir("Inner", "/repo/D/Inner", children: [file("x.swift", "/repo/D/Inner/x.swift")])
        let root = dir("repo", "/repo", children: [
            dir("D", "/repo/D", children: [inner]),
        ])

        let collapsed = FileTree.flatten(root: root, expansion: FileTreeExpansion())
        #expect(collapsed.map { nodePath($0) } == ["/repo/D"])

        var expansion = FileTreeExpansion()
        expansion.expand(root.children[0])
        let expanded = FileTree.flatten(root: root, expansion: expansion)
        #expect(expanded.map { nodePath($0) } == ["/repo/D", "/repo/D/Inner"])
        #expect(expanded.map(\.depth) == [0, 1])
    }

    /// A FILE with search results expands the same way a directory
    /// does — into its match lines, at the file's depth + 1, in the
    /// order the payload carries; an unexpanded file emits none.
    @Test func matchRowsUnderExpandedFile() {
        let f = file("a.swift", "/repo/a.swift", results: [
            match("/repo/a.swift", 3),
            match("/repo/a.swift", 30),
        ])
        let root = dir("repo", "/repo", children: [f])

        let collapsed = FileTree.flatten(root: root, expansion: FileTreeExpansion())
        #expect(collapsed.count == 1)

        var expansion = FileTreeExpansion()
        expansion.expand(f)
        let rows = FileTree.flatten(root: root, expansion: expansion)
        #expect(rows.count == 3)
        #expect(rows[0].depth == 0)
        #expect(rows[1].depth == 1)
        #expect(rows[2].depth == 1)
        guard case .match(let first, _) = rows[1], case .match(let second, _) = rows[2] else {
            Issue.record("expected match rows"); return
        }
        #expect(first.lineNumber == 3)
        #expect(second.lineNumber == 30)
    }

    /// The filter skips a node TOGETHER WITH ITS SUBTREE — a filtered
    /// directory's children are unreachable even though they pass the
    /// predicate themselves (the explorer's `H` semantics: hidden and
    /// ignored entries vanish as whole branches, preserving the
    /// parent-before-children order the navigation walks rely on).
    @Test func filterSkipsNodeAndSubtree() {
        let root = dir("repo", "/repo", children: [
            dir("build", "/repo/build", children: [
                dir("nested", "/repo/build/nested", children: [file("keep.swift", "/repo/build/nested/keep.swift")]),
            ]),
            file("App.swift", "/repo/App.swift"),
        ])

        let rows = FileTree.flatten(root: root, expansion: FileTreeExpansion()) { $0.path != "/repo/build" }
        #expect(rows.map { nodePath($0) } == ["/repo/App.swift"])
    }

    /// Collapsing a directory wipes the expansion MEMORY below it —
    /// every deeper key leaves the sets — while sibling keys survive.
    /// Re-expanding opens the node fresh: the child that was expanded
    /// before the collapse comes back collapsed.
    @Test func collapsePurgesSubtreeMemory() {
        let child = dir("Child", "/repo/Parent/Child")
        let parent = dir("Parent", "/repo/Parent", children: [child])
        let sibling = dir("Sibling", "/repo/Sibling")
        let root = dir("repo", "/repo", children: [parent, sibling])

        var expansion = FileTreeExpansion()
        expansion.expand(parent)
        expansion.expand(child)
        expansion.expand(sibling)
        #expect(expansion.isExpanded(parent) && expansion.isExpanded(child) && expansion.isExpanded(sibling))

        expansion.collapse(parent)
        #expect(!expansion.isExpanded(parent))
        #expect(!expansion.isExpanded(child))       // memory wiped below
        #expect(expansion.isExpanded(sibling))      // untouched

        expansion.expand(parent)                    // fresh re-expand
        #expect(!expansion.isExpanded(child))       // the child stays collapsed
    }

    /// The purge prefix is `path + "/"` — a sibling sharing a name
    /// prefix ("/a" vs "/ab") is never swept by "/a"'s collapse.
    @Test func purgePrefixIsPathComponentWise() {
        let a = dir("a", "/repo/a")
        let ab = dir("ab", "/repo/ab")
        let root = dir("repo", "/repo", children: [a, ab])

        var expansion = FileTreeExpansion()
        expansion.expand(ab)
        expansion.purge(below: a.path)
        #expect(expansion.isExpanded(ab))
    }

    /// An empty root flattens to nothing; a nil filter shows every
    /// node (the explorer's `H`-on mode passes exactly that).
    @Test func emptyRootAndNilFilter() {
        #expect(FileTree.flatten(root: dir("repo", "/repo"), expansion: FileTreeExpansion()).isEmpty)

        let root = dir("repo", "/repo", children: [file("x", "/repo/x")])
        #expect(FileTree.flatten(root: root, expansion: FileTreeExpansion()).count == 1)
        #expect(FileTree.flatten(root: root, expansion: FileTreeExpansion(), filter: { _ in true }).count == 1)
    }

    /// Nodes without a `search` payload expand to nothing — the
    /// explorer's files carry none, so a stray file key in the
    /// expansion set is inert.
    @Test func fileWithoutPayloadNeverExpands() {
        let f = FileTreeNode(name: "plain", path: "/repo/plain", isDirectory: false)
        let root = dir("repo", "/repo", children: [f])
        var expansion = FileTreeExpansion()
        expansion.expand(f)
        #expect(FileTree.flatten(root: root, expansion: expansion).count == 1)
    }

    private func nodePath(_ row: FileTree.Row) -> String {
        guard case .node(let node, _) = row else { return "<match>" }
        return node.path
    }
}
