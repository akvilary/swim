import Testing
@testable import SwimCore

/// Regression fixtures for the `for-each-ref` listing parser — every
/// entry shape the branch picker consumes. Keep in sync with the
/// picker's refresh (Sources/Swim/Window/GitBranchesWindow.swift): the
/// empty-but-present HEAD field on non-current branches is the subtle
/// part.
struct BranchListTests {
    @Test func currentBranchMarked() {
        // git's own committerdate-descending order arrives verbatim —
        // one branch per line, fields NUL-separated within the line.
        let output = "main\02 hours ago\0*\ndev\03 days ago\0\nfix/typos\0last week\0\n"
        #expect(BranchList.parse(output) == [
            BranchList.Entry(name: "main", lastCommit: "2 hours ago", isCurrent: true),
            BranchList.Entry(name: "dev", lastCommit: "3 days ago", isCurrent: false),
            BranchList.Entry(name: "fix/typos", lastCommit: "last week", isCurrent: false),
        ])
    }

    @Test func emptyOutput() {
        #expect(BranchList.parse("").isEmpty)
    }

    @Test func malformedLinesSkipped() {
        // Too few fields (a truncated tail of a still-running command)
        // must not crash the picker nor corrupt the entries around it.
        let output = "main\0now\0*\nbroken-short-line\0\ndev\0now\0\n"
        let entries = BranchList.parse(output)
        #expect(entries.map(\.name) == ["main", "dev"])
    }

    @Test func rawNamesSurvive() {
        // refname:short keeps exotic names raw: no quoting, no escapes.
        let output = "feature/юникод-ветка\02 hours ago\0\n"
        #expect(BranchList.parse(output).first?.name == "feature/юникод-ветка")
    }

    @Test func paddedHeadField() {
        // Some git versions pad the empty HEAD field with a space —
        // only a literal "*" marks the current branch.
        let output = "main\0now\0 \ndev\0now\0*\n"
        let entries = BranchList.parse(output)
        #expect(entries[0].isCurrent == false)
        #expect(entries[1].isCurrent == true)
    }

    // --- the query selector (matchPattern) ---

    @Test func plainQueryContainsPattern() {
        // `**/` crosses path components (WM_PATHNAME would keep a lone
        // `*` inside one segment and miss nested branches).
        #expect(BranchList.matchPattern(for: "fix") == "refs/heads/**/*fix*")
    }

    @Test func blankQueryHasNoSelector() {
        #expect(BranchList.matchPattern(for: "") == nil)
        #expect(BranchList.matchPattern(for: "   ") == nil)
    }

    @Test func globSpecialsEscapedLiterally() {
        // A query may contain wildmatch metacharacters; a branch name
        // never can — they must match literally, not as wildcards.
        #expect(BranchList.matchPattern(for: "a*b?c[d\\e") == "refs/heads/**/*a\\*b\\?c\\[d\\\\e*")
    }

    @Test func slashQueryKeepsBoundaries() {
        // The query's slash stays literal: "feature/t" must keep
        // matching "feature/two-fix" across the component boundary.
        #expect(BranchList.matchPattern(for: "feature/t") == "refs/heads/**/*feature/t*")
    }
}
