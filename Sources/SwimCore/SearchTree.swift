import Foundation

/// One match of the project search: the file's path, the 1-based line
/// number, the full line text, and the match span (Character offsets
/// within the line). Pure data shared by the background scanner
/// (Swim's SearchResultsWindow) and the tree model below.
public struct SearchResult: Equatable {
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
/// tree rooted at the working directory, one node per path component —
/// the full chain root → … → directory → file → match lines. A file
/// nested several levels deep produces its whole ancestor chain
/// (shared ancestors merge into one node), not the old single-level
/// "immediate parent → file" grouping that hid the path from the root.
///
/// Nodes are read-only after `build` (the tree is a finished snapshot;
/// expansion state does NOT live here — the window keys it by node
/// paths so it survives rebuilds across searches). Dependency-free
/// and side-effect-free so it is unit-testable in isolation
/// (Tests/SwimCoreTests/SearchTreeTests.swift); the consumer is
/// SearchResultsWindow.
public enum SearchTree {

    /// A directory level — one path component between the search root
    /// and the matched files; the root itself is one of these (name —
    /// the root's last path component). Children: nested directories
    /// first, then files, each alphabetical — the explorer's ordering;
    /// the window renders dirs before files. `matchCount` is the
    /// subtree total, folded once at build.
    public final class DirNode {
        public let name: String
        /// Absolute path of the level — the expansion key, and the
        /// preview path basis for files below it.
        public let path: String
        public internal(set) var dirs: [DirNode] = []
        public internal(set) var files: [FileNode] = []
        public internal(set) var matchCount: Int = 0

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    /// A matched file — a leaf carrying its match lines, sorted by
    /// line number. `matchCount` is computed: a stored copy would be a
    /// second field to keep in sync with `results`.
    public final class FileNode {
        public let name: String
        public let path: String
        public internal(set) var results: [SearchResult] = []
        public var matchCount: Int { results.count }

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    /// Builds the tree of `results` under `root`; nil when there is
    /// nothing to show (no matches — no tree, not an empty root row;
    /// input whose every match was dropped — see `insert` — collapses
    /// to nil by the same rule: a non-nil tree always carries at
    /// least one match). Insertion is dictionary-indexed by absolute
    /// path (paths are unique), so the build is O(total results),
    /// like the old dictionary grouping it replaces — no sibling-list
    /// scans.
    public static func build(results: [SearchResult], root: String) -> DirNode? {
        guard !results.isEmpty else { return nil }
        let rootPath = normalizedRoot(root)
        let rootName = (rootPath as NSString).lastPathComponent
        let rootNode = DirNode(name: rootName.isEmpty ? rootPath : rootName, path: rootPath)
        var dirByPath = [rootPath: rootNode]
        var fileByPath: [String: FileNode] = [:]
        for result in results {
            insert(result, into: rootNode, rootPath: rootPath, dirByPath: &dirByPath, fileByPath: &fileByPath)
        }
        finalize(rootNode)
        return rootNode.matchCount > 0 ? rootNode : nil
    }

    /// Lays one result into the tree: walks/creates the directory
    /// chain of its path relative to the root, then appends the match
    /// to the file node (created on first sight). A path outside the
    /// root — unreachable via the enumerator (it builds paths from the
    /// same base string), defensive for future callers — still lands
    /// in the tree via its absolute components: every match is
    /// visible, none silently dropped.
    private static func insert(
        _ result: SearchResult,
        into root: DirNode,
        rootPath: String,
        dirByPath: inout [String: DirNode],
        fileByPath: inout [String: FileNode]
    ) {
        let parts: [String]
        if result.filePath.hasPrefix(rootPath + "/") {
            parts = result.filePath.dropFirst(rootPath.count + 1)
                .split(separator: "/").map(String.init)
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
            path = join(path, component)
            if let existing = dirByPath[path] {
                dir = existing
            } else {
                let node = DirNode(name: component, path: path)
                dirByPath[path] = node
                dir.dirs.append(node)
                dir = node
            }
        }
        let filePath = join(path, fileName)
        if let existing = fileByPath[filePath] {
            existing.results.append(result)
        } else {
            let node = FileNode(name: fileName, path: filePath)
            fileByPath[filePath] = node
            node.results.append(result)
            dir.files.append(node)
        }
    }

    /// Sorts every level (directories and files alphabetical; the
    /// window renders directories first) and folds the subtree match
    /// counts bottom-up. Returns the subtree total of `dir`.
    @discardableResult
    private static func finalize(_ dir: DirNode) -> Int {
        dir.dirs.sort { $0.name < $1.name }
        dir.files.sort { $0.name < $1.name }
        for file in dir.files {
            file.results.sort { $0.lineNumber < $1.lineNumber }
        }
        var total = dir.files.reduce(0) { $0 + $1.results.count }
        for child in dir.dirs {
            total += finalize(child)
        }
        dir.matchCount = total
        return total
    }

    /// "<parent>/<component>", without doubling the slash at the
    /// filesystem root.
    private static func join(_ parent: String, _ component: String) -> String {
        parent.hasSuffix("/") ? parent + component : parent + "/" + component
    }

    /// The root as a chain base: trailing slashes off (a "//" join
    /// would break the relative-prefix check), "/" itself intact.
    private static func normalizedRoot(_ root: String) -> String {
        var path = root
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
