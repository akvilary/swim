import Foundation

/// One match of the project search: the file's path, the 1-based line
/// number, the full line text, and the match span (Character offsets
/// within the line). Pure data shared by the background scanner
/// (Swim's SearchResultsWindow) and the tree model below.
public struct SearchResult: Equatable, Sendable {
    public let filePath: String
    public let lineNumber: Int
    public let lineContent: String
    public let matchStart: Int
    public let matchLength: Int

    public init(filePath: String, lineNumber: Int, lineContent: String, matchStart: Int, matchLength: Int) {
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.lineContent = lineContent
        self.matchStart = matchStart
        self.matchLength = matchLength
    }
}

/// Pure builder of the search-results tree: flat `[SearchResult]` → a
/// `FileTreeNode` tree rooted at the working directory, one node per
/// path component — the full chain root → … → directory → file →
/// match lines. A file nested several levels deep produces its whole
/// ancestor chain (shared ancestors merge into one node), not the old
/// single-level "immediate parent → file" grouping that hid the path
/// from the root.
///
/// The nodes are the shared file-tree model (FileTreeNode — the same
/// type the explorer's tree uses); this builder fills only the search
/// payload block (`search`: the file leaves' match lines and the
/// directories' folded subtree totals) and leaves `listing` nil — a
/// search tree is a finished snapshot, read-only after `build`
/// (expansion state does NOT live on the tree; the window keys it by
/// node paths in `FileTreeExpansion` so it survives rebuilds across
/// searches). Dependency-free and side-effect-free so it is
/// unit-testable in isolation (Tests/SwimCoreTests/SearchTreeTests.swift);
/// the consumer is SearchResultsWindow.
public enum SearchTree {

    /// Builds the tree of `results` under `root`; nil when there is
    /// nothing to show (no matches — no tree, not an empty root row;
    /// input whose every match was dropped — see `insert` — collapses
    /// to nil by the same rule: a non-nil tree always carries at
    /// least one match). Insertion is dictionary-indexed by absolute
    /// path (paths are unique), so the build is O(total results),
    /// like the old dictionary grouping it replaces — no sibling-list
    /// scans.
    public static func build(results: [SearchResult], root: String) -> FileTreeNode? {
        guard !results.isEmpty else { return nil }
        let rootPath = TreePath.normalizedRoot(root)
        let rootName = (rootPath as NSString).lastPathComponent
        let rootNode = FileTreeNode(name: rootName.isEmpty ? rootPath : rootName, path: rootPath, isDirectory: true)
        var dirByPath = [rootPath: rootNode]
        var fileByPath: [String: FileTreeNode] = [:]
        for result in results {
            insert(result, into: rootNode, rootPath: rootPath, dirByPath: &dirByPath, fileByPath: &fileByPath)
        }
        finalize(rootNode)
        return (rootNode.search?.matchCount ?? 0) > 0 ? rootNode : nil
    }

    /// Lays one result into the tree: walks/creates the directory
    /// chain of its path relative to the root, then appends the match
    /// to the file node (created on first sight). The check, the cut
    /// and the split below `rootPath` are ONE convention
    /// (`TreePath.remainder` — coherent at the filesystem root too).
    /// A path outside the root — unreachable via the enumerator (it
    /// builds paths from the same base string), defensive for future
    /// callers — still lands in the tree via its absolute components:
    /// every match is visible, none silently dropped.
    private static func insert(
        _ result: SearchResult,
        into root: FileTreeNode,
        rootPath: String,
        dirByPath: inout [String: FileTreeNode],
        fileByPath: inout [String: FileTreeNode]
    ) {
        let parts: [String]
        if let under = TreePath.remainder(of: result.filePath, under: rootPath) {
            parts = under
        } else if result.filePath == rootPath {
            // The root itself as a match — unreachable via the scanner
            // (the enumerator yields the root's CONTENTS, never the
            // root), and a match at the root has no chain below the
            // root to live in: dropped rather than fabricating one.
            return
        } else {
            parts = result.filePath.split(separator: "/").map(String.init)
        }
        guard let fileName = parts.last else { return }
        var dir = root
        var path = rootPath
        for component in parts.dropLast() {
            path = TreePath.join(path, component)
            if let existing = dirByPath[path] {
                dir = existing
            } else {
                let node = FileTreeNode(name: component, path: path, isDirectory: true)
                dirByPath[path] = node
                dir.children.append(node)
                dir = node
            }
        }
        let filePath = TreePath.join(path, fileName)
        if let existing = fileByPath[filePath] {
            existing.search?.results.append(result)
        } else {
            let node = FileTreeNode(name: fileName, path: filePath, isDirectory: false)
            node.search = SearchPayload()
            fileByPath[filePath] = node
            node.search?.results.append(result)
            dir.children.append(node)
        }
    }

    /// Sorts every level's children alphabetically (the flatten's
    /// dirs-first partition — FileTree — then keeps each kind in this
    /// order) and the file leaves' match lines by line number, then
    /// folds the subtree match counts bottom-up into each directory's
    /// `search.matchCount` (a file's is its results count). Returns
    /// the subtree total of `dir`.
    @discardableResult
    private static func finalize(_ dir: FileTreeNode) -> Int {
        dir.children.sort { $0.name < $1.name }
        var total = 0
        for child in dir.children {
            if child.isDirectory {
                total += finalize(child)
            } else {
                child.search?.results.sort { $0.lineNumber < $1.lineNumber }
                let count = child.search?.results.count ?? 0
                child.search?.matchCount = count
                total += count
            }
        }
        dir.search = SearchPayload(results: [], matchCount: total)
        return total
    }
}
