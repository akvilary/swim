import Foundation
import Testing
import SwimCore
@testable import Swim

/// The create-phase input gate through the real branch picker:
/// characters git forbids in a ref name (the char-level half of
/// git-check-ref-format — BranchList.isForbiddenRefNameChar) are
/// silently dropped from typing, pasting and the filter seed, while
/// Enter's `check-ref-format` stays the authority for everything
/// sequence-shaped (`a..b`); the merge phase keeps its free input —
/// spaces separate `<ref> [args...]` and `~` lives inside revs like
/// `HEAD~2`. Plus the parity test: the mirror is verified against
/// live git byte-by-byte, not trusted.
struct BranchNameInputTests {

    /// A plain temp dir — `check-ref-format` needs no repository, and
    /// the name phase never re-queries the listing (the failed
    /// for-each-ref of prepare's refresh runs on its own background
    /// thread and cannot touch key handling).
    private func makePicker(delegate: StubDelegate) throws -> (GitBranchesWindow, dir: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swim-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        let w = GitBranchesWindow()
        w.width = 60
        w.height = 20
        w.delegate = delegate
        w.prepare(workingDirectory: dir.path)
        return (w, dir.path)
    }

    @Test func typedForbiddenCharsDropped() throws {
        let stub = StubDelegate()
        let (w, dir) = try makePicker(delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        press("a", on: w)                       // menu-mode a → name phase
        press("fe at~ure", on: w)               // space and ~ silently dropped
        _ = w.handleKey(.enter)                 // createSelected

        #expect(stub.gitCommands.count == 1)
        #expect(stub.gitCommands[0].label == "git switch -c feature")
        #expect(stub.gitCommands[0].args == ["switch", "-c", "feature"])
    }

    @Test func pastedForbiddenCharsDropped() throws {
        let stub = StubDelegate()
        let (w, dir) = try makePicker(delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        press("a", on: w)
        // Paste is bulk text — the gate owns it too. `#` is NOT
        // git-forbidden and survives; space and `~` drop.
        _ = w.handleKey(.paste("fe at~#x"))
        _ = w.handleKey(.enter)

        #expect(stub.gitCommands.count == 1)
        #expect(stub.gitCommands[0].label == "git switch -c feat#x")
    }

    @Test func sequenceRulesStillGitsJob() throws {
        let stub = StubDelegate()
        let (w, dir) = try makePicker(delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        press("a", on: w)
        press("a..b", on: w)                    // dots pass the char gate
        _ = w.handleKey(.enter)

        // git's own refusal, not the gate's: no command left, the
        // typing stays on screen.
        #expect(stub.gitCommands.isEmpty)
        #expect(!stub.reported.isEmpty)
        #expect(w.inputMode == true)
    }

    @Test func emptyNameStillRefused() throws {
        let stub = StubDelegate()
        let (w, dir) = try makePicker(delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        press("a", on: w)
        _ = w.handleKey(.enter)

        #expect(stub.gitCommands.isEmpty)
        #expect(stub.reported == ["Branch name is empty"])
    }

    @Test func mergePhaseTypesFreely() throws {
        let stub = StubDelegate()
        let (w, dir) = try makePicker(delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        press("m", on: w)
        // A space separates words, `~` is a legal rev char — the
        // merge input is gated by nothing.
        press("side~2 --no-ff", on: w)
        _ = w.handleKey(.enter)

        #expect(stub.gitCommands.count == 1)
        #expect(stub.gitCommands[0].label == "git merge side~2 --no-ff")
        #expect(stub.gitCommands[0].args == ["merge", "--no-ff", "--", "side~2"])
    }

    @Test func seedFromFilterSanitized() throws {
        let stub = StubDelegate()
        let (w, dir) = try makePicker(delegate: stub)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        press("i", on: w)                       // filter phase
        press("bug fix", on: w)
        _ = w.handleKey(.enter)                 // exit to menu — the filter stays
        press("a", on: w)                       // seed from the filter
        _ = w.handleKey(.enter)

        // The seed passed the gate: "bug fix" → "bugfix" (the words
        // glue as the space drops).
        #expect(stub.gitCommands.count == 1)
        #expect(stub.gitCommands[0].label == "git switch -c bugfix")
    }

    /// The mirror is verified against git itself, not a hand-copied
    /// table: every byte 1...127 (NUL cannot ride argv) wrapped as
    /// "a⟨byte⟩b" — a single character between two letters can never
    /// form the sequence rules (`..`, `@{`, a `.lock` tail), so the
    /// probe isolates exactly the char-level ban. If a future git
    /// widens the set, this fails loudly and the mirror must follow.
    @Test func charGateMirrorsGit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swim-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir.path) }

        for byte: UInt8 in 1...127 {
            let c = Character(UnicodeScalar(byte))
            let name = "a" + String(c) + "b"
            let git = Shell.git(["check-ref-format", "--branch", name], workDir: dir.path)
            #expect((git.exitCode == 0) != BranchList.isForbiddenRefNameChar(c),
                    "mirror disagrees with git at byte \(byte)")
        }
    }
}
