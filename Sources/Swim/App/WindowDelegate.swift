import Foundation

protocol WindowDelegate: AnyObject {
    func openFile(_ path: String)
    func openFileAtLine(_ path: String, line: Int)
    func handleEditorCommand(_ cmd: String)
    func runGitCommand(label: String, args: [String])
    func requestRender()
    func updatePreview(path: String?, highlightLine: Int)
}
