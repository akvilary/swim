import Testing
@testable import SwimCore

/// Regression fixtures for the diff gutter parser — every format quirk the
/// panel can meet in `git diff` / `git show` output. Keep in sync with the
/// panel's expectations: raw diff text is never mutated, only annotated.
struct DiffGutterTests {
    private func assertParse(
        _ diff: String,
        _ expect: [DiffGutter.Entry],
        width expectWidth: Int? = nil
    ) {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        let parsed = DiffGutter.parse(lines)
        #expect(parsed.entries == expect)
        if let expectWidth {
            #expect(parsed.width == expectWidth)
        }
    }

    private func entry(_ num: Int?, add: Bool = false, del: Bool = false) -> DiffGutter.Entry {
        DiffGutter.Entry(num: num, add: add, del: del)
    }

    @Test func messageLinesAreNotDiffContent() {
        // `git show`: commit body lines are raw text — a leading +/-/space
        // must not be numbered or counted (counters still at zero).
        assertParse("""
            commit abc123
            Author: A <a@a>
                +1 fixed typo
                -see docs
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -10,3 +10,4 @@
             context
            -old
            +new
            +extra
            """, [
            entry(nil), entry(nil), entry(nil), entry(nil), entry(nil), entry(nil), entry(nil), entry(nil),
            entry(10), entry(11, del: true), entry(11, add: true), entry(12, add: true),
        ], width: 4)
    }

    @Test func combinedMergeHunksGetNoNumbers() {
        // `diff --cc` (git show of a merge): `@@@` headers carry two
        // parents and content lines have two marker columns — the
        // two-counter model does not apply, so the gutter stays blank.
        assertParse("""
            commit b5790
            Merge: 4bb 3c9
            diff --cc f.txt
            --- a/f.txt
            +++ b/f.txt
            @@@ -1,1 -1,1 +1,1 @@@
            - main
             -side
            ++resolved
            """, [
            entry(nil), entry(nil), entry(nil), entry(nil), entry(nil), entry(nil),
            entry(nil), entry(nil), entry(nil),
        ])
    }

    @Test func untrackedDiffNumbersAdditionsFromOne() {
        // `git diff --no-index /dev/null file`: @@ -0,0 +1,N @@, every
        // content line is an addition numbered from 1.
        assertParse("""
            diff --git a/f b/f
            new file mode 100644
            --- /dev/null
            +++ b/f
            @@ -0,0 +1,3 @@
            +a
            +b
            +c
            """, [
            entry(nil), entry(nil), entry(nil), entry(nil), entry(nil),
            entry(1, add: true), entry(2, add: true), entry(3, add: true),
        ])
    }

    @Test func multiFileDiffHeadersBetweenHunks() {
        // The second file's ---/+++ arrive while still "in a hunk" — they
        // must not consume the counters; the next @@ reseeds them.
        assertParse("""
            diff --git a/a b/a
            --- a/a
            +++ b/a
            @@ -1 +1 @@
            -x
            +y
            diff --git a/b b/b
            --- a/b
            +++ b/b
            @@ -2 +2 @@
            -q
            +r
            """, [
            entry(nil), entry(nil), entry(nil), entry(nil),
            entry(1, del: true), entry(1, add: true),
            entry(nil), entry(nil), entry(nil), entry(nil),
            entry(2, del: true), entry(2, add: true),
        ])
    }

    @Test func noNewlineMarkerAndCountlessHunks() {
        // `\ No newline...` is a marker, not content; `@@ -5 +5 @@` has
        // no counts (count = 1 implied) and still seeds the counters.
        assertParse("""
            @@ -5 +5 @@
            -old without newline
            \\ No newline at end of file
            +new
            """, [
            entry(nil),
            entry(5, del: true), entry(nil), entry(5, add: true),
        ])
    }

    @Test func widthFollowsLargestNumber() {
        // Editor formula: max(4, digits + 2) — a 4-digit line number
        // widens the gutter to 6.
        var lines: [String] = ["@@ -1,0 +1,1200 @@"]
        for n in 1...1200 { lines.append("+line\(n)") }
        let parsed = DiffGutter.parse(lines)
        #expect(parsed.width == 6)
        #expect(parsed.entries.last == DiffGutter.Entry(num: 1200, add: true))
    }
}
