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
    case terminal
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
        showTerminal: Bool,
        showTabBar: Bool = false,
        halfScreen: HalfScreenWindow = .none
    ) -> (explorer: WindowLayout, editor: WindowLayout, tabbar: WindowLayout, git: WindowLayout, searchResults: WindowLayout, preview: WindowLayout, command: WindowLayout, terminal: WindowLayout, status: WindowLayout) {
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
            return (zero, zero, zero, zero, searchResults, preview, zero, zero, status)
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

        // Single invariant: everything lives strictly above the status
        // bar (its row is untouchable, whatever the window count). The
        // bottom stack keeps its desired heights while they fit and
        // shrinks waterfall-style only on a true overflow — h/2 + h/2
        // alone overflows every terminal <= 50 rows, and stacking
        // top-down used to run the last window past the status row,
        // covering it. The editor/explorer area gets the remainder and
        // may legitimately be zero rows: the panels then start from the
        // very top of the screen instead of leaving a dead sliver.
        let availH = h - statusH
        var gitH = 0
        var cmdH = 0
        var termH = 0
        if showGit { gitH = halfScreen == .git ? h / 2 : min(25, h / 2) }
        if showCommand { cmdH = halfScreen == .command ? h / 2 : min(25, h / 2) }
        if showTerminal { termH = halfScreen == .terminal ? h / 2 : min(25, h / 2) }
        var heights = [gitH, cmdH, termH]
        if heights.reduce(0, +) > availH {
            let shownIdx = heights.indices.filter { heights[$0] > 0 }
            var remaining = availH
            for (pos, idx) in shownIdx.enumerated() {
                // Fair share of what is left among the windows still to
                // size; never below one row, never more than remaining.
                let fair = max(1, remaining / (shownIdx.count - pos))
                heights[idx] = min(heights[idx], fair)
                remaining -= heights[idx]
            }
        }
        gitH = heights[0]
        cmdH = heights[1]
        termH = heights[2]

        let topH = max(0, availH - gitH - cmdH - termH)
        let tabH = showTabBar ? min(1, topH) : 0
        let editorH = max(0, topH - tabH)
        let explorerH = topH

        let explorer = WindowLayout(x: 0, y: 0, width: explorerW, height: explorerH)
        let tabbar = WindowLayout(x: editorX, y: 0, width: editorW, height: tabH)
        let editor = WindowLayout(x: editorX, y: tabH, width: editorW, height: editorH)

        var bottomY = topH
        let git = WindowLayout(x: 0, y: bottomY, width: w, height: gitH)
        bottomY += gitH
        let command = WindowLayout(x: 0, y: bottomY, width: w, height: cmdH)
        bottomY += cmdH
        let terminal = WindowLayout(x: 0, y: bottomY, width: w, height: termH)

        let status = WindowLayout(x: 0, y: h - statusH, width: w, height: statusH)

        return (explorer, editor, tabbar, git, zero, zero, command, terminal, status)
    }
}
