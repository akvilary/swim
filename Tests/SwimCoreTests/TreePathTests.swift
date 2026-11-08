import Testing
@testable import SwimCore

/// Fixtures for the tree's string path-key conventions — the one home
/// of join/normalize/descendant/remainder. The edge cases here are
/// load-bearing: the `/a` vs `/ab` sibling prefix (purge below a
/// directory must never sweep a same-named sibling), the filesystem
/// root (where a naive `parent + "/"` prefix degenerates to `"//"`),
/// and the check-vs-cut coherence of `remainder`.
struct TreePathTests {

    /// The join never doubles the slash — at the fs root, on a parent
    /// that already ends with one, or in the ordinary case.
    @Test func joinNeverDoublesSlash() {
        #expect(TreePath.join("/repo", "src") == "/repo/src")
        #expect(TreePath.join("/", "a") == "/a")
        #expect(TreePath.join("/repo/", "src") == "/repo/src")
    }

    /// A chain base: trailing slashes collapse, the fs root survives,
    /// the empty string passes through.
    @Test func normalizedRootTrimsTrailingSlashes() {
        #expect(TreePath.normalizedRoot("/repo/") == "/repo")
        #expect(TreePath.normalizedRoot("/repo//") == "/repo")
        #expect(TreePath.normalizedRoot("/") == "/")
        #expect(TreePath.normalizedRoot("") == "")
        #expect(TreePath.normalizedRoot("/repo") == "/repo")
    }

    /// Strictly below: equality never matches, a sibling sharing a
    /// name prefix never matches, a trailing slash on the parent is
    /// tolerated, and the fs-root edge is correct both ways.
    @Test func descendantIsStrictAndPrefixWise() {
        #expect(TreePath.isDescendant("/repo/a", of: "/repo"))
        #expect(!TreePath.isDescendant("/repo", of: "/repo"))          // equality
        #expect(!TreePath.isDescendant("/repo/ab", of: "/repo/a"))     // sibling name prefix
        #expect(TreePath.isDescendant("/repo/a", of: "/repo/"))        // trailing slash tolerated
        #expect(TreePath.isDescendant("/a/b", of: "/"))                // fs root: strictly below
        #expect(TreePath.isDescendant("/a", of: "/"))
        #expect(!TreePath.isDescendant("/", of: "/"))                   // fs root: not below itself
        #expect(!TreePath.isDescendant("/elsewhere/x", of: "/repo"))
    }

    /// The check, the cut and the split agree — including the fs root
    /// (cut is ONE character there; the old check+dropFirst pair
    /// cancelled itself out into a different branch instead).
    @Test func remainderCutsCoherently() {
        #expect(TreePath.remainder(of: "/repo/Sources/a.swift", under: "/repo") == ["Sources", "a.swift"])
        #expect(TreePath.remainder(of: "/repo/a", under: "/repo/") == ["a"])
        #expect(TreePath.remainder(of: "/a/b/c.swift", under: "/") == ["a", "b", "c.swift"])
        #expect(TreePath.remainder(of: "/repo", under: "/repo") == nil)
        #expect(TreePath.remainder(of: "/elsewhere/x", under: "/repo") == nil)
        // Exotic names survive as components — only "/" splits.
        #expect(TreePath.remainder(of: "/repo/документы/заметки гайд.md", under: "/repo")
                == ["документы", "заметки гайд.md"])
    }
}
