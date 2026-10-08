import Foundation

protocol WindowDelegate: AnyObject {
    func openFile(_ path: String)
    func openFileAtLine(_ path: String, line: Int)
    func handleEditorCommand(_ cmd: String)
    /// Runs a git command in the command window. The optional
    /// follow-up starts automatically once the command SUCCEEDS (see
    /// CommandWindow.runCommand(then:)) — the branch picker's
    /// menu-mode Ctrl+Enter: switch, then pull.
    func runGitCommand(label: String, args: [String], then followUp: (label: String, args: [String])?)
    func gitCommandFinished(_ label: String)
    func terminalCommandFinished()
    func requestCommitMessage(prefill: String)
    func requestCommit()
    /// The git panel's `a` — open the branch picker straight into its
    /// new-branch phase (name input ready).
    func requestCreateBranch()
    func reportError(_ message: String)
    func requestRender()
    func updatePreview(path: String?, highlightLine: Int)
    func bufferClosed(_ buffer: EditorBuffer)
    func fileSaved()
    /// A git-panel action (stage/unstage/discard) or an explorer FS edit
    /// (create/delete/rename) changed the worktree — the git-driven
    /// decorations (status bar stats, editor gutter lines, explorer
    /// name marks) should refetch.
    func gitWorktreeChanged()
    /// A git-panel operation rewrote a working-tree file (a discard of
    /// the whole file or a hunk): any clean editor tab for it should be
    /// reloaded from disk.
    func fileChangedOnDisk(_ path: String)
    /// The [R]eload answer of the changed-on-disk confirm prompt —
    /// discard the active tab's edits and reload it from disk.
    func reloadActiveBufferDiscardingEdits()
    func activeFileChanged()
    func requestClose(_ window: Window)
    func requestGoToDefinition(line: Int, charUtf16: Int)
    func requestGoBack()
}

extension WindowDelegate {
    /// Two-argument convenience for the no-follow-up callers (git
    /// panel's pull/push, the commit flow) — protocols can't declare
    /// default parameter values, so the default lives here.
    func runGitCommand(label: String, args: [String]) {
        runGitCommand(label: label, args: args, then: nil)
    }
}
