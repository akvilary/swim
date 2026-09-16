import Foundation

/// Thin layer over the editor for the commit message: a real editor
/// window in the command slot below the git panel, opened in insert
/// mode. Writing means committing (`:w`, `:wq`, `:x`); quitting discards
/// (`:q`, `:q!`, double Esc — insert Esc drops to normal, the second
/// Esc closes the window). The header plate ("Commit @ branch") is set
/// by the application when the window opens.
class CommitWindow: EditorWindow {
    override func executeCommand(_ cmd: String) -> Bool {
        switch cmd {
        case "w", "wq", "x", "wquit":
            delegate?.requestCommit()
            return true
        default:
            return super.executeCommand(cmd)
        }
    }
}
