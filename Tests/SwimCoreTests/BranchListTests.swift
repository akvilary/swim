import Testing
@testable import SwimCore

/// Regression fixtures for the `for-each-ref` listing parser — every
/// entry shape the branch picker consumes. Keep in sync with the
/// picker's refresh (Sources/Swim/Window/GitBranchesWindow.swift): the
/// empty-but-present HEAD field on non-current branches and the
/// remote-entry semantics (locals-only blank query, DWIM switch) are
/// the subtle parts.
struct BranchListTests {

    private func entry(_ name: String, _ date: String, current: Bool = false, remote: Bool = false)
        -> BranchList.Entry
    {
        BranchList.Entry(name: name, lastCommit: date, isCurrent: current, isRemote: remote)
    }

    /// The literal line builder — refname:short, committerdate, HEAD,
    /// full refname, NUL-separated, as the picker's format asks git.
    private func line(_ short: String, _ date: String, _ head: String, _ refname: String) -> String {
        short + "\0" + date + "\0" + head + "\0" + refname
    }

    @Test func currentBranchMarked() {
        // git's own committerdate-descending order arrives verbatim —
        // one ref per line, fields NUL-separated within the line.
        let output = [
            line("main", "2 hours ago", "*", "refs/heads/main"),
            line("dev", "3 days ago", "", "refs/heads/dev"),
            line("fix/typos", "last week", "", "refs/heads/fix/typos"),
        ].joined(separator: "\n")
        #expect(BranchList.parse(output) == [
            entry("main", "2 hours ago", current: true),
            entry("dev", "3 days ago"),
            entry("fix/typos", "last week"),
        ])
    }

    @Test func emptyOutput() {
        #expect(BranchList.parse("").isEmpty)
    }

    @Test func malformedLinesSkipped() {
        // Too few fields (a truncated tail of a still-running command)
        // must not crash the picker nor corrupt the entries around it.
        let output = line("main", "now", "*", "refs/heads/main")
            + "\nbroken-short-line\0\n"
            + line("dev", "now", "", "refs/heads/dev") + "\n"
        #expect(BranchList.parse(output).map(\.name) == ["main", "dev"])
    }

    @Test func rawNamesSurvive() {
        // refname:short keeps exotic names raw: no quoting, no escapes.
        let output = line("feature/юникод-ветка", "2 hours ago", "", "refs/heads/feature/юникод-ветка")
        #expect(BranchList.parse(output).first?.name == "feature/юникод-ветка")
    }

    @Test func paddedHeadField() {
        // Some git versions pad the empty HEAD field with a space —
        // only a literal "*" marks the current branch.
        let output = line("main", "now", " ", "refs/heads/main") + "\n"
            + line("dev", "now", "*", "refs/heads/dev") + "\n"
        let entries = BranchList.parse(output)
        #expect(entries[0].isCurrent == false)
        #expect(entries[1].isCurrent == true)
    }

    // --- remote entries ---

    @Test func remoteEntriesFlaggedAndOrderPreserved() {
        // Locals and remotes arrive interleaved in git's committerdate
        // order — the parser keeps the order verbatim, flagging the
        // remote-tracking refs.
        let output = [
            line("origin/feature-x", "1 hour ago", "", "refs/remotes/origin/feature-x"),
            line("main", "2 hours ago", "*", "refs/heads/main"),
            line("upstream/hotfix", "3 days ago", "", "refs/remotes/upstream/hotfix"),
        ].joined(separator: "\n")
        let entries = BranchList.parse(output)
        #expect(entries.map(\.name) == ["origin/feature-x", "main", "upstream/hotfix"])
        #expect(entries.map(\.isRemote) == [true, false, true])
    }

    @Test func remoteHeadPointerExcluded() {
        // refs/remotes/<remote>/HEAD is the remote's symref to its
        // default branch — a duplicate, not a branch; excluded. A
        // hypothetical deeper HEAD-named ref is a branch and stays.
        let output = [
            line("origin/HEAD", "now", "", "refs/remotes/origin/HEAD"),
            line("origin/main", "now", "", "refs/remotes/origin/main"),
            line("origin/feature/HEAD", "now", "", "refs/remotes/origin/feature/HEAD"),
        ].joined(separator: "\n")
        #expect(BranchList.parse(output).map(\.name) == ["origin/main", "origin/feature/HEAD"])
    }

    @Test func localTwinSuppressesItsRemote() {
        // A local branch in the results makes its remote counterparts
        // redundant: Enter on the local row is the same switch the
        // remote row would DWIM into; D on the local row already
        // covers the remote side. The local keeps its place and order.
        let output = [
            line("origin/feature-x", "1 hour ago", "", "refs/remotes/origin/feature-x"),
            line("feature-x", "2 hours ago", "", "refs/heads/feature-x"),
            line("origin/other", "3 days ago", "", "refs/remotes/origin/other"),
        ].joined(separator: "\n")
        #expect(BranchList.parse(output) == [
            entry("feature-x", "2 hours ago"),
            entry("origin/other", "3 days ago", remote: true),
        ])
    }

    @Test func remoteOnlyKeepsEveryRemote() {
        // No local twin — the name lives on several remotes: distinct
        // refs, a real choice; all stay, in git's order.
        let output = [
            line("upstream/x", "1 hour ago", "", "refs/remotes/upstream/x"),
            line("origin/x", "2 hours ago", "", "refs/remotes/origin/x"),
        ].joined(separator: "\n")
        #expect(BranchList.parse(output).map(\.name) == ["upstream/x", "origin/x"])
    }

    // --- the query selectors (matchPatterns) ---

    @Test func blankQueryListsLocalsOnly() {
        // The unfiltered table is the working set — locals only.
        #expect(BranchList.matchPatterns(for: "") == ["refs/heads/"])
        #expect(BranchList.matchPatterns(for: "   ") == ["refs/heads/"])
    }

    @Test func queryReachesIntoRemotes() {
        // A fetched branch without a local counterpart is exactly what
        // a search is for: both namespaces, same contains-match.
        #expect(BranchList.matchPatterns(for: "fix") == [
            "refs/heads/**/*fix*",
            "refs/remotes/**/*fix*",
        ])
    }

    @Test func globSpecialsEscapedLiterally() {
        // A query may contain wildmatch metacharacters; a branch name
        // never can — they must match literally, not as wildcards.
        #expect(BranchList.matchPatterns(for: "a*b?c[d\\e") == [
            "refs/heads/**/*a\\*b\\?c\\[d\\\\e*",
            "refs/remotes/**/*a\\*b\\?c\\[d\\\\e*",
        ])
    }

    @Test func slashQueryKeepsBoundaries() {
        // The query's slash stays literal: "origin/f" matches
        // "origin/feature-x" (and "x/origin/f...") across component
        // boundaries.
        #expect(BranchList.matchPatterns(for: "origin/f") == [
            "refs/heads/**/*origin/f*",
            "refs/remotes/**/*origin/f*",
        ])
    }
}
