import Foundation
import Testing
@testable import Swim

/// The explorer's y/p through the real window over a temp tree:
/// yank captures the selection, paste copies it into the selected
/// directory (next to a selected file) with Finder-style name dedup —
/// a repeated paste is the duplicate workflow; a directory refuses to
/// be pasted into itself; the register survives navigation.
struct ExplorerYankPasteTests {

    /// A temp tree: sub/b.txt (directories partition first — the rows
    /// are [sub, a.txt], the initial selection is `sub`).
    private func makeExplorer(delegate: StubDelegate) throws -> (FileExplorerWindow, dir: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swim-yank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: dir.appendingPathComponent("sub").path, withIntermediateDirectories: true)
        try "one".write(toFile: dir.appendingPathComponent("a.txt").path,
                        atomically: true, encoding: .utf8)
        try "two".write(toFile: dir.appendingPathComponent("sub/b.txt").path,
                        atomically: true, encoding: .utf8)
        let w = FileExplorerWindow()
        w.width = 60
        w.height = 20
        w.delegate = delegate
        w.loadDirectory(dir.path)
        return (w, dir.path)
    }

    @Test func yankThenPasteNextToFileDedups() throws {
        let stub = StubDelegate()
        let (w, dir) = try makeExplorer(delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        press("j", on: w)                       // sub → a.txt
        press("y", on: w)                       // yank a.txt
        #expect(stub.reported.last?.hasPrefix("Yanked ./") == true)

        press("p", on: w)                       // next to a.txt
        let copy1 = dir + "/a copy.txt"
        #expect(FileManager.default.fileExists(atPath: copy1))
        #expect(stub.worktreeChanges == 1)

        press("p", on: w)                       // the duplicate workflow
        #expect(FileManager.default.fileExists(atPath: dir + "/a copy 2.txt"))
        #expect(stub.worktreeChanges == 2)
    }

    @Test func pasteIntoSelectedDirectory() throws {
        let stub = StubDelegate()
        let (w, dir) = try makeExplorer(delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        press("j", on: w)
        press("y", on: w)                       // yank a.txt
        press("k", on: w)                       // back to sub — the register survives navigation
        press("p", on: w)                       // INTO sub
        #expect(FileManager.default.fileExists(atPath: dir + "/sub/a.txt"))
    }

    @Test func directoryIntoItselfIsRefused() throws {
        let stub = StubDelegate()
        let (w, dir) = try makeExplorer(delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        press("y", on: w)                       // the selection is sub itself
        press("p", on: w)                       // pasting sub into sub
        #expect(stub.reported.last == "paste: destination inside the yanked directory")
        #expect(!FileManager.default.fileExists(atPath: dir + "/sub/sub"))
    }

    @Test func yankNothingOrPasteNothing() throws {
        let stub = StubDelegate()
        let (w, dir) = try makeExplorer(delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        press("p", on: w)                       // no yank yet
        #expect(stub.reported.last == "paste: nothing yanked — press y")

        press("j", on: w)
        press("y", on: w)
        try FileManager.default.removeItem(atPath: dir + "/a.txt")  // the source vanished
        press("p", on: w)
        #expect(stub.reported.last == "paste: not found")
    }
}
