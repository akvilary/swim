import Foundation

struct GitFileStatus {
    let status: String
    let filePath: String
    let staged: Bool
}

struct GitCommit {
    let hash: String
    let author: String
    let date: String
    let message: String
}

class GitPanelWindow: Window {
    private(set) var stagedFiles: [GitFileStatus] = []
    private(set) var unstagedFiles: [GitFileStatus] = []
    private(set) var untrackedFiles: [GitFileStatus] = []
    private(set) var recentCommits: [GitCommit] = []
    private(set) var selectedIndex: Int = 0
    private var scrollOffset: Int = 0
    private var currentBranch: String = ""
    private var diffContent: String = ""
    private var diffLines: [Substring] = []
    private var diffScrollOffset: Int = 0
    private var showDiff: Bool = false

    var onRunCommand: ((String, [String]) -> Void)?

    var workingDirectory: String = "" {
        didSet { refresh() }
    }

    override func update() {
        clear()
        fillRegion(row: 0, col: 0, width: width, height: height, cell: Cell.colored(" ", fg: Theme.fg, bg: Theme.bgDark))
        if showDiff { drawDiff() } else { drawStatus() }
    }

    private struct LayoutItem {
        let globalIdx: Int
        let row: Int
    }

    private func buildLayout() -> (items: [LayoutItem], totalContentRows: Int) {
        var items: [LayoutItem] = []
        var row = 1
        var globalIdx = 0

        if !stagedFiles.isEmpty {
            row += 1
            for _ in stagedFiles {
                items.append(LayoutItem(globalIdx: globalIdx, row: row))
                globalIdx += 1
                row += 1
            }
        }
        if !unstagedFiles.isEmpty {
            row += 1
            for _ in unstagedFiles {
                items.append(LayoutItem(globalIdx: globalIdx, row: row))
                globalIdx += 1
                row += 1
            }
        }
        if !untrackedFiles.isEmpty {
            row += 1
            for _ in untrackedFiles {
                items.append(LayoutItem(globalIdx: globalIdx, row: row))
                globalIdx += 1
                row += 1
            }
        }
        if !recentCommits.isEmpty {
            row += 1
            let commitCount = min(recentCommits.count, 5)
            for _ in 0..<commitCount {
                items.append(LayoutItem(globalIdx: globalIdx, row: row))
                globalIdx += 1
                row += 1
            }
        }

        return (items, row)
    }

    private func drawStatus() {
        let headerText = "  \(currentBranch) "
        for (i, c) in headerText.enumerated() {
            if i < width {
                setCell(0, i, Cell.colored(c, fg: Theme.orange, bg: Theme.bgHighlight, bold: true))
            }
        }
        for i in headerText.count..<width {
            setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
        }

        let (_, totalContentRows) = buildLayout()
        let visibleHeight = height - 1

        if totalContentRows - 1 <= visibleHeight {
            scrollOffset = 0
        } else {
            scrollOffset = max(0, min(scrollOffset, totalContentRows - 1 - visibleHeight))
        }

        var row = 1 - scrollOffset
        var globalIdx = 0

        if !stagedFiles.isEmpty {
            drawSectionHeader("Staged changes", screenRow: row)
            row += 1
            for file in stagedFiles {
                if row >= 1 && row < height {
                    let isSelected = globalIdx == selectedIndex
                    drawFileRow(file, row: row, selected: isSelected)
                }
                globalIdx += 1
                row += 1
            }
        }
        if !unstagedFiles.isEmpty {
            drawSectionHeader("Changes", screenRow: row)
            row += 1
            for file in unstagedFiles {
                if row >= 1 && row < height {
                    let isSelected = globalIdx == selectedIndex
                    drawFileRow(file, row: row, selected: isSelected)
                }
                globalIdx += 1
                row += 1
            }
        }
        if !untrackedFiles.isEmpty {
            drawSectionHeader("Untracked", screenRow: row)
            row += 1
            for file in untrackedFiles {
                if row >= 1 && row < height {
                    let isSelected = globalIdx == selectedIndex
                    drawFileRow(file, row: row, selected: isSelected)
                }
                globalIdx += 1
                row += 1
            }
        }
        if !recentCommits.isEmpty && row < height + scrollOffset {
            drawSectionHeader("Recent commits", screenRow: row)
            row += 1
            for commit in recentCommits.prefix(5) {
                if row >= 1 && row < height {
                    let isSelected = globalIdx == selectedIndex
                    let bg: Color = isSelected ? Theme.bgHighlight : Theme.bgDark
                    let commitText = " \(commit.hash.prefix(7)) \(commit.message.prefix(width - 14))"
                    drawLine(commitText, row: row, fg: Theme.green1, bg: bg)
                }
                globalIdx += 1
                row += 1
            }
        }

        if stagedFiles.isEmpty && unstagedFiles.isEmpty && untrackedFiles.isEmpty && recentCommits.isEmpty {
            drawLine(" No changes", row: max(1, row), fg: Theme.comment)
        }
    }

    private func drawFileRow(_ file: GitFileStatus, row: Int, selected: Bool) {
        let bg: Color = selected ? Theme.bgHighlight : Theme.bgDark
        let statusColor = statusColorFor(file.status)
        let statusText = " \(file.status) "
        drawLine(statusText, row: row, col: 0, fg: statusColor, bg: bg, bold: true)
        let nameStart = statusText.count
        let name = file.filePath.prefix(width - nameStart)
        drawLine(String(name), row: row, col: nameStart, fg: selected ? Theme.fg : Theme.fgDark, bg: bg)
    }

    private func drawDiff() {
        let headerText = " DIFF (Esc to close) "
        for (i, c) in headerText.enumerated() {
            if i < width { setCell(0, i, Cell.colored(c, fg: Theme.fg, bg: Theme.bgHighlight, bold: true)) }
        }
        let visibleLines = height - 1
        for i in 0..<visibleLines {
            let lineIdx = diffScrollOffset + i
            guard lineIdx < diffLines.count else { break }
            let line = diffLines[lineIdx]
            let row = i + 1
            let fg: Color
            if line.hasPrefix("+") { fg = Theme.green }
            else if line.hasPrefix("-") { fg = Theme.red }
            else if line.hasPrefix("@@") { fg = Theme.cyan }
            else { fg = Theme.fgDark }
            drawLine(String(line.prefix(width)), row: row, fg: fg)
        }
    }

    private func drawSectionHeader(_ text: String, screenRow: Int) {
        guard screenRow >= 1 && screenRow < height else { return }
        drawLine(" \(text)", row: screenRow, fg: Theme.blue, bold: true)
    }

    private func drawLine(_ text: String, row: Int, col: Int = 0, fg: Color = Theme.fgDark, bg: Color = Theme.bgDark, bold: Bool = false) {
        guard row >= 0 && row < height else { return }
        for (i, c) in text.enumerated() {
            if col + i < width { setCell(row, col + i, Cell.colored(c, fg: fg, bg: bg, bold: bold)) }
        }
    }

    private func statusColorFor(_ status: String) -> Color {
        switch status {
        case "M": return Theme.yellow
        case "A": return Theme.green
        case "D": return Theme.red
        case "R": return Theme.magenta
        case "?": return Theme.comment
        default: return Theme.fgDark
        }
    }

    private enum FileSection {
        case staged, unstaged, untracked, commit
    }

    private func selectedFileSection() -> (section: FileSection, index: Int)? {
        var idx = selectedIndex
        if idx < stagedFiles.count { return (.staged, idx) }
        idx -= stagedFiles.count
        if idx < unstagedFiles.count { return (.unstaged, idx) }
        idx -= unstagedFiles.count
        if idx < untrackedFiles.count { return (.untracked, idx) }
        idx -= untrackedFiles.count
        if idx < min(recentCommits.count, 5) { return (.commit, idx) }
        return nil
    }

    override func handleKey(_ key: Key) -> Bool {
        if showDiff {
            switch key {
            case .char("j"), .down:
                let visibleLines = height - 1
                if diffScrollOffset + visibleLines < diffLines.count {
                    diffScrollOffset += 1; dirty = true
                }
            case .char("k"), .up:
                if diffScrollOffset > 0 { diffScrollOffset -= 1; dirty = true }
            case .escape:
                showDiff = false; dirty = true
            default: return false
            }
            return true
        }

        switch key {
        case .char("j"), .down:
            let total = totalItemCount()
            if selectedIndex < total - 1 { selectedIndex += 1; ensureVisible(); dirty = true }
        case .char("k"), .up:
            if selectedIndex > 0 { selectedIndex -= 1; ensureVisible(); dirty = true }
        case .enter: showDiffForSelected()
        case .char("s"): stageOrUnstageSelected()
        case .char("-"): onRunCommand?("git pull", ["pull"])
        case .char("+"): onRunCommand?("git push", ["push"])
        case .escape: break
        default: return false
        }
        return true
    }

    private func totalItemCount() -> Int {
        stagedFiles.count + unstagedFiles.count + untrackedFiles.count + min(recentCommits.count, 5)
    }

    private func ensureVisible() {
        let visibleCount = height - 1
        let (_, totalContentRows) = buildLayout()
        if totalContentRows - 1 <= visibleCount {
            scrollOffset = 0
            return
        }
        if let item = buildLayout().items.first(where: { $0.globalIdx == selectedIndex }) {
            let selectedRow = item.row
            if selectedRow < scrollOffset + 1 { scrollOffset = selectedRow - 1 }
            else if selectedRow >= scrollOffset + height { scrollOffset = selectedRow - height + 1 }
        }
    }

    private func showDiffForSelected() {
        guard let sel = selectedFileSection() else { return }
        switch sel.section {
        case .staged: runDiff(for: stagedFiles[sel.index].filePath, staged: true)
        case .unstaged: runDiff(for: unstagedFiles[sel.index].filePath, staged: false)
        case .untracked: runDiff(for: untrackedFiles[sel.index].filePath, staged: false)
        case .commit: break
        }
    }

    private func stageOrUnstageSelected() {
        guard let sel = selectedFileSection() else { return }
        switch sel.section {
        case .staged:
            let file = stagedFiles[sel.index]
            runGit(["reset", "HEAD", "--", file.filePath])
        case .unstaged:
            let file = unstagedFiles[sel.index]
            runGit(["add", "--", file.filePath])
        case .untracked:
            let file = untrackedFiles[sel.index]
            runGit(["add", "--", file.filePath])
        case .commit: break
        }
        refresh()
        if selectedIndex >= totalItemCount() {
            selectedIndex = max(0, totalItemCount() - 1)
        }
    }

    private func runDiff(for path: String, staged: Bool) {
        let args = staged ? ["diff", "--cached", "--", path] : ["diff", "--", path]
        diffContent = runGit(args)
        diffLines = diffContent.split(separator: "\n", omittingEmptySubsequences: false)
        diffScrollOffset = 0
        showDiff = true
        dirty = true
    }

    func refresh() {
        guard !workingDirectory.isEmpty else { return }
        currentBranch = runGit(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if currentBranch.hasPrefix("fatal") { currentBranch = "not a git repo" }
        let statusOutput = runGit(["status", "--porcelain"])
        parseStatus(statusOutput)
        let logOutput = runGit(["log", "--oneline", "-10", "--format=%h|%an|%cr|%s"])
        parseLog(logOutput)
        dirty = true
    }

    private func parseStatus(_ output: String) {
        stagedFiles = []; unstagedFiles = []; untrackedFiles = []
        for line in output.components(separatedBy: "\n") {
            guard line.count >= 3 else { continue }
            let indexStatus = line[line.index(line.startIndex, offsetBy: 0)]
            let workStatus = line[line.index(line.startIndex, offsetBy: 1)]
            let filePath = String(line[line.index(line.startIndex, offsetBy: 3)...])
            if indexStatus != " " && indexStatus != "?" { stagedFiles.append(GitFileStatus(status: String(indexStatus), filePath: filePath, staged: true)) }
            if workStatus != " " && workStatus != "?" { unstagedFiles.append(GitFileStatus(status: String(workStatus), filePath: filePath, staged: false)) }
            if indexStatus == "?" && workStatus == "?" { untrackedFiles.append(GitFileStatus(status: "?", filePath: filePath, staged: false)) }
        }
    }

    private func parseLog(_ output: String) {
        recentCommits = []
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: "|", maxSplits: 3)
            guard parts.count >= 4 else { continue }
            recentCommits.append(GitCommit(hash: String(parts[0]), author: String(parts[1]), date: String(parts[2]), message: String(parts[3])))
        }
    }

    @discardableResult
    private func runGit(_ args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        if !workingDirectory.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch { return "" }
    }
}
