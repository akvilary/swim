import SwimCore
@testable import Swim

/// Captures the gb unwind; every other WindowDelegate obligation is a
/// no-op — the headless tests never trigger them. Held strongly by the
/// test (the window's delegate is weak).
final class StubDelegate: WindowDelegate {
    var goBackTargets: [(path: String, line: Int, colUtf16: Int)] = []
    var reported: [String] = []
    var worktreeChanges = 0

    func openFile(_ path: String) {}
    func openFileAtLine(_ path: String, line: Int) {}
    func handleEditorCommand(_ cmd: String) {}
    func runGitCommand(label: String, args: [String], then followUp: (label: String, args: [String])?) {}
    func gitCommandFinished(_ label: String) {}
    func terminalCommandFinished() {}
    func requestCommitMessage(prefill: String, amend: Bool, amendTarget: String) {}
    func requestCommit() {}
    func reportError(_ message: String) { reported.append(message) }
    func requestRender() {}
    func updatePreview(path: String?, highlightLine: Int) {}
    func bufferClosed(_ buffer: EditorBuffer) {}
    func fileSaved() {}
    func gitWorktreeChanged() { worktreeChanges += 1 }
    func fileChangedOnDisk(_ path: String) {}
    func reloadActiveBufferDiscardingEdits() {}
    func activeFileChanged() {}
    func requestClose(_ window: Window) {}
    func requestGoToDefinition(line: Int, charUtf16: Int) {}
    func requestGoBack(path: String, line: Int, colUtf16: Int) {
        goBackTargets.append((path, line, colUtf16))
    }
}

/// A headless editor window over synthetic content: geometry set by
/// hand (no layout manager), no delegate, no terminal. The fresh
/// window starts with one empty unnamed [No Name] tab in normal mode —
/// exactly the state the app's commit editor builds on.
/// contentHeight = height (no header plate): height 31 → 1/3 floor 10.
@discardableResult
func makeTestEditor(lineCount: Int, width: Int = 80, height: Int = 31) -> EditorWindow {
    let w = EditorWindow()
    w.width = width
    w.height = height
    if lineCount > 0, let buf = w.buffer {
        buf.insert((0..<lineCount).map { "line \($0)" }.joined(separator: "\n"), at: 0)
    }
    return w
}

/// Feeds a key sequence through the REAL dispatch (pending counts, the
/// g-prefix machine) — the same path a keystroke takes in the app.
func press(_ keys: String, on window: Window) {
    for c in keys {
        _ = window.handleKey(.char(c))
    }
}
