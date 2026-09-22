import Testing
@testable import SwimCore

/// Regression fixtures for the hunk-line parser — the exact shapes the
/// editor git gutter meets in `git diff --unified=0 [--cached]` output.
/// Keep in sync with the gutter's expectations: only NEW-file numbers
/// are collected (0-based), deletions contribute nothing.
struct HunkLinesTests {
    private func lines(_ diff: String) -> [Substring] {
        diff.split(separator: "\n", omittingEmptySubsequences: false)
    }

    @Test func plainAdditionHunks() {
        // `-u0` output: two hunks, additions only. `+1,3` → 0..2,
        // countless `+10` → single line 9.
        let diff = """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -0,0 +1,3 @@
            +a
            +b
            +c
            @@ -10 +10 @@
            +x
            """
        #expect(HunkLines.changedLines(lines(diff)) == Set([0, 1, 2, 9]))
    }

    @Test func newFileNumbersFromOne() {
        let diff = """
            diff --git a/new b/new
            new file mode 100644
            --- /dev/null
            +++ b/new
            @@ -0,0 +1,2 @@
            +one
            +two
            """
        #expect(HunkLines.changedLines(lines(diff)) == Set([0, 1]))
    }

    @Test func pureDeletionCoversNothing() {
        // `-a,3 +c,0`: the removed lines have no new-file numbers.
        let diff = """
            @@ -5,3 +4,0 @@
            -x
            -y
            -z
            """
        #expect(HunkLines.changedLines(lines(diff)).isEmpty)
    }

    @Test func headersWithFunctionContext() {
        // `@@ ... @@ fn name` — the counters still parse.
        let diff = """
            @@ -12,7 +12,9 @@ func example() {
            +added
            """
        #expect(HunkLines.changedLines(lines(diff)) == Set(11...19))
    }

    @Test func combinedMergeAndContentLinesIgnored() {
        // `@@@` headers (two parents) never match the strict `@@ ` shape;
        // content lines carry a marker first, so a literal `@@ -1 +1 @@`
        // inside the text is not a header. The combined hunk contributes
        // nothing — honest empty over wrong numbers.
        let diff = """
            @@@ -1,1 -1,1 +1,1 @@@
            ++resolved
            +@@ -1 +1 @@
            """
        #expect(HunkLines.changedLines(lines(diff)).isEmpty)
    }

    @Test func renameWithoutEditsIsEmpty() {
        // `-M` rename with identical content: no hunks at all.
        let diff = """
            diff --git a/old b/new
            similarity index 100%
            rename from old
            rename to new
            """
        #expect(HunkLines.changedLines(lines(diff)).isEmpty)
    }

    @Test func multipleFilesAccumulate() {
        let diff = """
            diff --git a/a b/a
            --- a/a
            +++ b/a
            @@ -1 +1 @@
            +y
            diff --git a/b b/b
            --- a/b
            +++ b/b
            @@ -2,1 +2,2 @@
            +r
            +r2
            """
        #expect(HunkLines.changedLines(lines(diff)) == Set([0, 1, 2]))
    }
}
