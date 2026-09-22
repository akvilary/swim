import Testing
@testable import SwimCore

/// Regression fixtures for the `--porcelain -z` parser and the change
/// classification — every entry shape swim consumes. Keep in sync with
/// the two consumers (git panel status list, Application decoration
/// fetch): the rename orig-field consumption is the subtle part.
struct PorcelainTests {
    @Test func plainEntries() {
        let output = "M  a.txt\0 M b.txt\0?? new.txt\0A  staged.txt\0"
        #expect(Porcelain.parse(output) == [
            Porcelain.Entry(x: "M", y: " ", path: "a.txt", origPath: nil),
            Porcelain.Entry(x: " ", y: "M", path: "b.txt", origPath: nil),
            Porcelain.Entry(x: "?", y: "?", path: "new.txt", origPath: nil),
            Porcelain.Entry(x: "A", y: " ", path: "staged.txt", origPath: nil),
        ])
    }

    @Test func renameConsumesOrigField() {
        // The orig path arrives as the NEXT NUL field — it must not be
        // misparsed as an entry of its own.
        let output = "R  new.txt\0old.txt\0 M next.txt\0"
        let entries = Porcelain.parse(output)
        #expect(entries.count == 2)
        #expect(entries[0] == Porcelain.Entry(x: "R", y: " ", path: "new.txt", origPath: "old.txt"))
        #expect(entries[1].path == "next.txt")
    }

    @Test func stagedCopyKeepsOrig() {
        let output = "C  copy.txt\0src.txt\0"
        #expect(Porcelain.parse(output) == [
            Porcelain.Entry(x: "C", y: " ", path: "copy.txt", origPath: "src.txt")
        ])
    }

    @Test func rawPathsSurvive() {
        // -z keeps exotic names raw: no quoting, no escapes.
        let output = "?? кв/иллица & «имя».txt\0"
        #expect(Porcelain.parse(output).first?.path == "кв/иллица & «имя».txt")
    }

    @Test func shortFieldsSkipped() {
        let output = "XY\0?? ok.txt\0"
        #expect(Porcelain.parse(output).map(\.path) == ["ok.txt"])
    }

    @Test func emptyOutput() {
        #expect(Porcelain.parse("").isEmpty)
    }

    @Test func classifyPrecedence() {
        // Any worktree change (Y) outranks the index: MM/AM → unstaged.
        // Untracked and staged adds are additions; a fully staged change
        // of a tracked file is staged; nothing-to-color shapes are nil.
        #expect(GitChangeClass.classify(x: "?", y: "?") == .added)
        #expect(GitChangeClass.classify(x: "A", y: " ") == .added)
        #expect(GitChangeClass.classify(x: "M", y: " ") == .staged)
        #expect(GitChangeClass.classify(x: "R", y: " ") == .staged)
        #expect(GitChangeClass.classify(x: "D", y: " ") == .staged)
        #expect(GitChangeClass.classify(x: " ", y: "M") == .unstaged)
        #expect(GitChangeClass.classify(x: "M", y: "M") == .unstaged)
        #expect(GitChangeClass.classify(x: "A", y: "M") == .unstaged)
        #expect(GitChangeClass.classify(x: " ", y: "D") == .unstaged)
        #expect(GitChangeClass.classify(x: "U", y: "U") == .unstaged)  // conflict
        #expect(GitChangeClass.classify(x: " ", y: " ") == nil)
    }

    @Test func entryChangeClassMatchesClassify() {
        let entry = Porcelain.Entry(x: "A", y: "M", path: "f", origPath: nil)
        #expect(entry.changeClass == .unstaged)
    }
}
