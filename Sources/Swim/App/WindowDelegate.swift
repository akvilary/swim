import Foundation

protocol WindowDelegate: AnyObject {
    func openFile(_ path: String)
    func openFileAtLine(_ path: String, line: Int)
    func handleEditorCommand(_ cmd: String)
    func runGitCommand(label: String, args: [String])
    func gitCommandFinished(_ label: String)
    func terminalCommandFinished()
    func requestCommitMessage()
    func requestCommit()
    func reportError(_ message: String)
    func requestRender()
    func updatePreview(path: String?, highlightLine: Int)
    func bufferClosed(_ buffer: EditorBuffer)
    func fileSaved()
    func activeFileChanged()
    func requestClose(_ window: Window)
    func requestGoToDefinition(line: Int, charUtf16: Int)
    func requestGoBack()
}
