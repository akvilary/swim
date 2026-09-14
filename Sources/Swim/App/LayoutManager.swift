import Foundation

struct WindowLayout {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

enum HalfScreenWindow {
    case none
    case explorer
    case git
    case command
    case searchResults
    case preview
}

struct LayoutManager {
    static func calculate(
        terminalWidth: Int,
        terminalHeight: Int,
        space: String,
        showExplorer: Bool,
        showEditor: Bool,
        showGit: Bool,
        showCommand: Bool,
        showTabBar: Bool = false,
        halfScreen: HalfScreenWindow = .none
    ) -> (explorer: WindowLayout, editor: WindowLayout, tabbar: WindowLayout, git: WindowLayout, searchResults: WindowLayout, preview: WindowLayout, command: WindowLayout, status: WindowLayout) {
        let w = max(10, terminalWidth)
        let h = max(5, terminalHeight)
        let statusH = 1
        let zero = WindowLayout(x: 0, y: 0, width: 0, height: 0)

        if space == "search" {
            var resultsW = max(30, min(w / 3, w - 30))
            if halfScreen == .searchResults { resultsW = max(20, w / 2) }
            if halfScreen == .preview { resultsW = min(w - 20, w / 2) }
            let searchResults = WindowLayout(x: 0, y: 0, width: resultsW, height: h - statusH)
            let preview = WindowLayout(x: resultsW, y: 0, width: w - resultsW, height: h - statusH)
            let status = WindowLayout(x: 0, y: h - statusH, width: w, height: statusH)
            return (zero, zero, zero, zero, searchResults, preview, zero, status)
        }

        var editorX = 0
        var editorW = w
        var explorerW = 0

        if showExplorer {
            if showEditor {
                explorerW = halfScreen == .explorer ? max(10, w / 2) : min(28, w / 4)
                editorX = explorerW
                editorW = w - explorerW
            } else {
                explorerW = w
            }
        }

        var gitH = 0
        var cmdH = 0
        if showGit { gitH = halfScreen == .git ? h / 2 : min(25, h / 2) }
        if showCommand { cmdH = halfScreen == .command ? h / 2 : min(25, h / 2) }

        let tabH = showTabBar ? 1 : 0
        let editorH = max(1, h - statusH - gitH - cmdH - tabH)
        let explorerH = max(1, h - statusH - gitH - cmdH)

        let explorer = WindowLayout(x: 0, y: 0, width: explorerW, height: explorerH)
        let tabbar = showTabBar ? WindowLayout(x: editorX, y: 0, width: editorW, height: 1) : zero
        let editor = WindowLayout(x: editorX, y: tabH, width: editorW, height: editorH)

        var bottomY = explorerH
        let git = WindowLayout(x: 0, y: bottomY, width: w, height: gitH)
        if showGit { bottomY += gitH }
        let command = WindowLayout(x: 0, y: bottomY, width: w, height: cmdH)

        let status = WindowLayout(x: 0, y: h - statusH, width: w, height: statusH)

        return (explorer, editor, tabbar, git, zero, zero, command, status)
    }
}
