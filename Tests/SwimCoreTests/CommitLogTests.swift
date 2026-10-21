import Testing
@testable import SwimCore

/// Regression fixtures for the git log window's listing parser — every
/// line shape the window consumes. Keep in sync with the log window's
/// refresh (Sources/Swim/Window/GitLogWindow.swift): the
/// first-pipe-only split (a subject with pipes keeps them) and the
/// verbatim short hash (git scales its width) are the subtle parts.
struct CommitLogTests {

    /// The literal line builder — `%h|%s`, as the window's format
    /// asks git.
    private func line(_ hash: String, _ subject: String) -> String {
        hash + "|" + subject
    }

    @Test func parsesRows() {
        // git's own order arrives verbatim — one commit per line.
        let output = [
            line("7087586", "UPPER Case Subject"),
            line("425c6e7", "fix(x): pipe | in [subject] (test)"),
        ].joined(separator: "\n")
        #expect(CommitLog.parse(output) == [
            CommitLog.Entry(hash: "7087586", subject: "UPPER Case Subject"),
            CommitLog.Entry(hash: "425c6e7", subject: "fix(x): pipe | in [subject] (test)"),
        ])
    }

    @Test func emptyOutput() {
        #expect(CommitLog.parse("").isEmpty)
    }

    @Test func malformedLinesSkipped() {
        // Too few fields (a truncated tail) must not crash the window
        // nor corrupt the entries around it. A line without any pipe
        // at all is not a commit row.
        let output = line("abc1234", "first")
            + "\nnot-a-commit-row\n"
            + line("def5678", "second") + "\n"
        #expect(CommitLog.parse(output).map(\.hash) == ["abc1234", "def5678"])
    }

    @Test func pipeInsideSubjectStays() {
        // maxSplits: 1 — only the FIRST pipe separates; the hash is
        // hex and never contains one, everything after it is subject.
        let output = line("425c6e7", "left | middle | right")
        #expect(CommitLog.parse(output).first?.subject == "left | middle | right")
    }

    @Test func emptySubject() {
        // An empty-message commit: the row renders as a bare hash.
        #expect(CommitLog.parse("abc1234|") == [CommitLog.Entry(hash: "abc1234", subject: "")])
    }

    @Test func leadingPipeInSubjectStays() {
        // The character right after the separating pipe is subject
        // content, even when it is another pipe.
        #expect(CommitLog.parse("abc1234||x").first?.subject == "|x")
    }
}
