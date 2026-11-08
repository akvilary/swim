/// The tree's STRING path-key conventions — one home for the tiny
/// conventions the file-tree domain (FileTree/SearchTree + the two
/// tree windows) keys its nodes, expansions and reveal walks by.
/// Four pure functions, no Foundation, no state.
///
/// Why NOT Foundation's normalizers, deliberately:
/// - `NSString.standardizingPath` / `resolvingSymlinksInPath` resolve
///   symlinks — the tree lives in the STARTING DIRECTORY's symlink
///   view while the git name-marks are keyed in the repo-root-resolved
///   coordinate system, and the two sides are already reconciled by
///   doctrine (see the explorer's marks section in ARCHITECTURE.md);
///   auto-resolving here would double-resolve and silently part the
///   keys from the marks.
/// - `URL` round-trips percent-encode: `URL.path` decodes `%XX`, and
///   string keys built through NSString vs URL.path would part for
///   any exotic name (spaces, Cyrillic — the cases SearchTreeTests
///   pins).
/// - There is nothing to normalize: tree paths are CONSTRUCTED from
///   directory listings (clean components, no `.`/`..`), and the only
///   user-typed paths (the explorer's create/delete/rename) are
///   REJECTED by policy when unsafe — an error, never a rewrite.
///
/// Dependency-free and side-effect-free; tested in
/// Tests/SwimCoreTests/TreePathTests.swift.
public enum TreePath {

    /// "<parent>/<component>" without doubling the slash at the
    /// filesystem root: `join("/", "a")` → `"/a"`, `join("/repo/",
    /// "src")` → `"/repo/src"`.
    public static func join(_ parent: String, _ component: String) -> String {
        parent.hasSuffix("/") ? parent + component : parent + "/" + component
    }

    /// A chain base: trailing slashes off (`"/repo//"` → `"/repo"`),
    /// the filesystem root `"/"` itself intact, an empty string
    /// passes through.
    public static func normalizedRoot(_ root: String) -> String {
        var path = root
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Strictly below `parent` (a proper descendant): the prefix is
    /// `parent + "/"`, so a sibling sharing a name prefix (`/a` vs
    /// `/ab`) never matches, and equality never matches. A trailing
    /// slash on `parent` is tolerated (normalized first). The
    /// filesystem-root edge is correct BY CONSTRUCTION:
    /// `isDescendant("/a", of: "/")` → true, `isDescendant("/", of:
    /// "/")` → false (the naive `"/" + "/"` prefix would match
    /// neither correctly).
    public static func isDescendant(_ path: String, of parent: String) -> Bool {
        let base = normalizedRoot(parent)
        if base == "/" {
            // Everything absolute is below the fs root except itself.
            return path.count > 1 && path.hasPrefix("/")
        }
        return path.hasPrefix(base + "/")
    }

    /// The components of `path` strictly below `parent`; nil when
    /// `path` is not a descendant (equality included). The check, the
    /// cut and the split are ONE convention — the arithmetic cannot
    /// disagree with the predicate it came from (a hand-rolled
    /// `hasPrefix(parent + "/")` beside a `dropFirst(parent.count +
    /// 1)` cancels itself out at the filesystem root: the prefix
    /// `"//"` never matches, so the cut's off-by-one never ran —
    /// coherent here by construction instead).
    public static func remainder(of path: String, under parent: String) -> [String]? {
        guard isDescendant(path, of: parent) else { return nil }
        let base = normalizedRoot(parent)
        let cut = base == "/" ? 1 : base.count + 1
        return path.dropFirst(cut).split(separator: "/").map(String.init)
    }
}
