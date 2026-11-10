import Foundation
import Testing
@testable import Swim

/// The per-window gb stack: entries snapshot the window's own pre-jump
/// position (named buffers only), gb unwinds LIFO to "No previous
/// position", and separate editor windows never see each other's
/// stacks — the commit window's jumps stay its own.
struct GoBackPerWindowTests {

    /// A temp file with `lineCount` lines — the named buffer the
    /// snapshot requires (scratch buffers record nothing).
    private func makeTempFile(_ lineCount: Int) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swim-tests-\(UUID().uuidString).txt")
        try (0..<lineCount).map { "line \($0)" }.joined(separator: "\n")
            .write(toFile: url.path, atomically: true, encoding: .utf8)
        return url.path
    }

    private func makeFileEditor(lineCount: Int, delegate: StubDelegate) throws -> (EditorWindow, String) {
        let path = try makeTempFile(lineCount)
        let w = EditorWindow()
        w.width = 80
        w.height = 31
        w.delegate = delegate
        _ = w.editFile(path)
        return (w, path)
    }

    @Test func emptyStackReportsNoPreviousPosition() throws {
        let stub = StubDelegate()
        let (w, path) = try makeFileEditor(lineCount: 100, delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: path) }

        press("gb", on: w)
        #expect(w.lastError == "No previous position")
        #expect(stub.goBackTargets.isEmpty)
    }

    /// :N records, gb unwinds once — the stack does not refill itself
    /// on the way back (the ping-pong hole).
    @Test func colonJumpThenGbUnwindsOnce() throws {
        let stub = StubDelegate()
        let (w, path) = try makeFileEditor(lineCount: 100, delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: path) }

        w.cursorLine = 10
        w.cursorCol = 0
        #expect(w.executeCommand("25") == true)          // snapshot (path, 10, 0), jump
        #expect(w.cursorLine == 24)

        press("gb", on: w)
        #expect(stub.goBackTargets.count == 1)
        #expect(stub.goBackTargets[0].path == path)
        #expect(stub.goBackTargets[0].line == 10)
        #expect(stub.goBackTargets[0].colUtf16 == 0)

        press("gb", on: w)                               // the stack is empty again
        #expect(w.lastError == "No previous position")
        #expect(stub.goBackTargets.count == 1)
    }

    /// LIFO across mixed jump kinds: :N then counted gg unwinds in
    /// reverse order.
    @Test func lifoAcrossJumpKinds() throws {
        let stub = StubDelegate()
        let (w, path) = try makeFileEditor(lineCount: 100, delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: path) }

        w.cursorLine = 5
        #expect(w.executeCommand("25") == true)          // snapshot (5) → line 24
        press("70gg", on: w)                             // snapshot (24) → line 69

        press("gb", on: w)
        #expect(stub.goBackTargets.last?.line == 24)
        press("gb", on: w)
        #expect(stub.goBackTargets.last?.line == 5)
        press("gb", on: w)
        #expect(w.lastError == "No previous position")
    }

    /// The requirement itself: the editor's stack and the commit
    /// window's stack never intersect. The commit editor's buffer is
    /// unnamed — its jumps record nothing, its gb reports empty, and
    /// the main editor's entries stay intact.
    @Test func commitWindowHistoryIsIsolated() throws {
        let stub = StubDelegate()
        let (editor, path) = try makeFileEditor(lineCount: 100, delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let commit = CommitWindow()
        commit.width = 80
        commit.height = 31
        commit.newFile()
        commit.buffer!.insert("alpha\nbeta\ngamma", at: 0)

        // A line jump inside the commit message moves ITS cursor and
        // records nothing (unnamed buffer).
        #expect(commit.executeCommand("2") == true)
        #expect(commit.cursorLine == 1)
        press("gb", on: commit)
        #expect(commit.lastError == "No previous position")
        #expect(stub.goBackTargets.isEmpty)

        // The main editor's own history is untouched by all of that.
        editor.cursorLine = 7
        #expect(editor.executeCommand("25") == true)
        press("gb", on: editor)
        #expect(stub.goBackTargets.count == 1)
        #expect(stub.goBackTargets[0].line == 7)
    }
}
