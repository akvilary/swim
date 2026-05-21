import Foundation

struct WindowLayout {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct LayoutManager {
    static func calculate(
        terminalWidth: Int,
        terminalHeight: Int,
        space: String,
        showExplorer: Bool,
        showGit: Bool,
        showCommand: Bool
    ) -> (explorer: WindowLayout, editor: WindowLayout, git: WindowLayout, searchResults: WindowLayout, preview: WindowLayout, command: WindowLayout, status: WindowLayout) {
        let w = max(10, terminalWidth)
        let h = max(5, terminalHeight)
        let statusH = 1
        let zero = WindowLayout(x: 0, y: 0, width: 0, height: 0)

        if space == "search" {
            let resultsW = max(30, min(w / 3, w - 30))
            let searchResults = WindowLayout(x: 0, y: 0, width: resultsW, height: h - statusH)
            let preview = WindowLayout(x: resultsW, y: 0, width: w - resultsW, height: h - statusH)
            let status = WindowLayout(x: 0, y: h - statusH, width: w, height: statusH)
            return (zero, zero, zero, searchResults, preview, zero, status)
        }

        var editorX = 0
        var editorW = w
        var explorerW = 0

        if showExplorer {
            explorerW = min(28, w / 4)
            editorX = explorerW
            editorW = w - explorerW
        }

        var gitH = 0
        var cmdH = 0
        if showGit { gitH = min(25, h / 2) }
        if showCommand { cmdH = min(25, h / 2) }

        let editorH = max(1, h - statusH - gitH - cmdH)

        let explorer = WindowLayout(x: 0, y: 0, width: explorerW, height: editorH)
        let editor = WindowLayout(x: editorX, y: 0, width: editorW, height: editorH)

        var bottomY = editorH
        let git = WindowLayout(x: 0, y: bottomY, width: w, height: gitH)
        if showGit { bottomY += gitH }
        let command = WindowLayout(x: 0, y: bottomY, width: w, height: cmdH)

        let status = WindowLayout(x: 0, y: h - statusH, width: w, height: statusH)

        return (explorer, editor, git, zero, zero, command, status)
    }
}
