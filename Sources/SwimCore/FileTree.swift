import Foundation

/// THE single file-tree node — the one model both tree surfaces (the
/// file explorer and the search results) are built from. The
/// structural core (name/path/isDirectory/children) is the tree
/// itself; the two payload blocks are per-consumer facts, present
/// only on the trees that use them:
///
/// - `listing` — the explorer's listing state (lazy-load mark,
///   git-ignore verdict, dot-visibility), taken when the parent
///   directory is loaded and cached until it is rescanned. Nil on
///   search-built nodes: a search tree is a finished snapshot, it has
///   no listing mechanics.
/// - `search` — the search tree's payload (a file leaf's match lines,
///   a directory's folded subtree total). Nil on explorer-built
///   nodes.
///
/// Nil is "not applicable", never "false": only the owning consumer
/// and its builder read a payload block. The one deliberate
/// cross-reader is `FileTree.flatten`, which reads `search.results`
/// to interleave match rows — that interleaving is the shared
/// mechanism making both trees one thing (see its doc comment).
///
/// A class on purpose: the explorer mutates nodes in place (a lazy
/// child load fills `children` of an existing node — no copy-and-
/// write-back dance), while search-built trees are simply never
/// mutated after `SearchTree.build`. Not Sendable for the same
/// reason the old nodes were not: trees live on the main thread;
/// background work passes the value-type `[SearchResult]` instead.
public final class FileTreeNode {
    public let name: String
    /// Absolute path — the identity for expansion keys, git marks,
    /// preview lookups and reveal walks.
    public let path: String
    public let isDirectory: Bool
    /// Subdirectories and files together, in any order the builder
    /// produced — `FileTree.flatten` partitions them dirs-first by
    /// construction, so builders owe no ordering discipline.
    public var children: [FileTreeNode] = []

    public var listing: ListingFlags?
    public var search: SearchPayload?

    public init(name: String, path: String, isDirectory: Bool, listing: ListingFlags? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.listing = listing
    }
}

/// The explorer's per-entry listing facts, captured at listing time
/// and cached until the directory is rescanned (`:fe reset`,
/// create/delete/rename). The explorer's `H` filter reads them at
/// flatten time, so re-filtering is in-memory — no rescan.
public struct ListingFlags: Equatable, Sendable {
    /// The node's `children` have been read from disk (a directory
    /// stub from a fresh listing carries `false` until first expand).
    public var isLoaded: Bool
    /// Covered by a git ignore rule (everything under an ignored
    /// directory inherits the flag — git never re-includes inside an
    /// excluded subtree).
    public var isIgnored: Bool
    /// Dot-prefixed name.
    public var isHidden: Bool

    public init(isLoaded: Bool = false, isIgnored: Bool = false, isHidden: Bool = false) {
        self.isLoaded = isLoaded
        self.isIgnored = isIgnored
        self.isHidden = isHidden
    }
}

/// The search tree's payload: a file leaf's match lines (sorted by
/// line number by `SearchTree.build`) and the node's match total —
/// the subtree sum for a directory (folded once at build), the
/// results count for a file.
public struct SearchPayload {
    public var results: [SearchResult] = []
    public var matchCount: Int = 0

    public init(results: [SearchResult] = [], matchCount: Int = 0) {
        self.results = results
        self.matchCount = matchCount
    }
}

/// Expansion state for a `FileTreeNode` tree — keys are the nodes'
/// absolute paths, NOT flags on the nodes. Keyed state survives tree
/// rebuilds: the explorer's rescans and the search's re-queries
/// produce fresh nodes, and a directory that comes back re-expanded
/// stays expanded for the results that return. A key whose node went
/// away matches nothing — harmless; it waits for the node's return.
///
/// Collapsing wipes the subtree's expansion MEMORY (`collapse` purges
/// every deeper key): re-expanding opens the node fresh — its
/// children collapsed — instead of restoring the previous depth.
public struct FileTreeExpansion {
    public private(set) var dirs: Set<String> = []
    public private(set) var files: Set<String> = []

    public init() {}

    public func isExpanded(_ node: FileTreeNode) -> Bool {
        node.isDirectory ? dirs.contains(node.path) : files.contains(node.path)
    }

    /// Records the node as expanded (a no-op when it already is).
    public mutating func expand(_ node: FileTreeNode) {
        if node.isDirectory { dirs.insert(node.path) } else { files.insert(node.path) }
    }

    /// Removes the node's key and — for a directory — every deeper
    /// key: the collapse-time memory wipe (see the type comment).
    public mutating func collapse(_ node: FileTreeNode) {
        if node.isDirectory {
            dirs.remove(node.path)
            purge(below: node.path)
        } else {
            files.remove(node.path)
        }
    }

    /// Drops every key strictly below `path` — the descendant
    /// convention in one place (`TreePath.isDescendant`: a sibling
    /// sharing a name prefix — `/a` vs `/ab` — is never swept).
    public mutating func purge(below path: String) {
        dirs = dirs.filter { !TreePath.isDescendant($0, of: path) }
        files = files.filter { !TreePath.isDescendant($0, of: path) }
    }
}

/// The shared flatten: a `FileTreeNode` tree + its expansion state →
/// the flat visible row list both windows navigate. Pure and
/// dependency-free; tested in Tests/SwimCoreTests/FileTreeTests.swift.
///
/// - The ROOT itself is never a row — its children sit at depth 0.
///   One rule for both trees: the explorer's top level is the working
///   directory's contents, the search tree's top level is the same,
///   with no extra "project root" row above it.
/// - Directories come before files at every level (a stable partition
///   of `children`, done HERE — the invariant holds by construction,
///   not by builder discipline).
/// - A directory's children appear only while it is expanded; a
///   FILE's match lines (`search.results`) appear only while the FILE
///   is expanded — one mechanism: a branch of either kind reveals
///   what it contains. The explorer's files carry no `search`
///   payload, so they never expand; the search's rows below a file
///   are match lines at the file's depth + 1.
/// - The optional `filter` skips a node together with its whole
///   subtree (the explorer's `H` listing filter: hidden/ignored
///   entries). Skipping a node removes its children too — the
///   parent-before-children order the navigation policy
///   (`TreeListNavigation`) proves its invariants over holds in every
///   filter mode.
public enum FileTree {

    /// One visible row: a tree node at its indent depth, or a search
    /// match line nested under its (expanded) file node.
    public enum Row {
        case node(FileTreeNode, depth: Int)
        case match(SearchResult, depth: Int)

        public var depth: Int {
            switch self {
            case .node(_, let depth), .match(_, let depth): return depth
            }
        }
    }

    public static func flatten(
        root: FileTreeNode,
        expansion: FileTreeExpansion,
        filter: ((FileTreeNode) -> Bool)? = nil
    ) -> [Row] {
        var rows: [Row] = []
        emitChildren(of: root, depth: 0, into: &rows, expansion: expansion, filter: filter)
        return rows
    }

    /// One level: directories first (stable within each kind), then
    /// files — recursion happens only through expanded branches.
    private static func emitChildren(
        of node: FileTreeNode,
        depth: Int,
        into rows: inout [Row],
        expansion: FileTreeExpansion,
        filter: ((FileTreeNode) -> Bool)?
    ) {
        for child in node.children where child.isDirectory {
            emit(child, depth: depth, into: &rows, expansion: expansion, filter: filter)
        }
        for child in node.children where !child.isDirectory {
            emit(child, depth: depth, into: &rows, expansion: expansion, filter: filter)
        }
    }

    private static func emit(
        _ node: FileTreeNode,
        depth: Int,
        into rows: inout [Row],
        expansion: FileTreeExpansion,
        filter: ((FileTreeNode) -> Bool)?
    ) {
        guard filter?(node) ?? true else { return }
        rows.append(.node(node, depth: depth))
        if node.isDirectory {
            guard expansion.dirs.contains(node.path) else { return }
            emitChildren(of: node, depth: depth + 1, into: &rows, expansion: expansion, filter: filter)
        } else if expansion.files.contains(node.path) {
            for result in node.search?.results ?? [] {
                rows.append(.match(result, depth: depth + 1))
            }
        }
    }
}
