import Foundation

private struct GitRefreshResult {
    let branch: String
    let statusOutput: String
    let logOutput: String
}

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
    private var diffLines: [Substring] = []
    private var diffScrollOffset: Int = 0
    private var showDiff: Bool = false

    private(set) var isRefreshing: Bool = false
    private let gitTask = BackgroundTask<GitRefreshResult>()

    var workingDirectory: String = "" {
        didSet { refresh() }
    }

    private var fileSections: [(String, [GitFileStatus])] {
        [("Staged changes", stagedFiles), ("Changes", unstagedFiles), ("Untracked", untrackedFiles)]
    }

    override func update() {
        clear()
        if showDiff { drawDiff() } else { drawStatus() }
    }

    private func totalContentRowCount() -> Int {
        var count = 1
        for (_, files) in fileSections {
            if !files.isEmpty { count += 1 + files.count }
        }
        if !recentCommits.isEmpty { count += 1 + min(recentCommits.count, 5) }
        return count
    }

    private func rowForSelectedItem() -> Int? {
        var row = 1
        var globalIdx = 0
        for (_, files) in fileSections {
            guard !files.isEmpty else { continue }
            row += 1
            for _ in files {
                if globalIdx == selectedIndex { return row }
                globalIdx += 1; row += 1
            }
        }
        if !recentCommits.isEmpty {
            row += 1
            for _ in 0..<min(recentCommits.count, 5) {
                if globalIdx == selectedIndex { return row }
                globalIdx += 1; row += 1
            }
        }
        return nil
    }

    private func drawStatus() {
        let branchLabel = isRefreshing ? "loading..." : currentBranch
        drawHeader("  \(branchLabel) ", fg: Theme.orange)

        let totalContentRows = totalContentRowCount()
        let visibleHeight = height - 1

        if totalContentRows - 1 <= visibleHeight {
            scrollOffset = 0
        } else {
            scrollOffset = max(0, min(scrollOffset, totalContentRows - 1 - visibleHeight))
        }

        var row = 1 - scrollOffset
        var globalIdx = 0

        for (title, files) in fileSections {
            drawFileSection(title, files: files, row: &row, globalIdx: &globalIdx)
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

    private func drawFileSection(_ title: String, files: [GitFileStatus], row: inout Int, globalIdx: inout Int) {
        guard !files.isEmpty else { return }
        drawSectionHeader(title, screenRow: row)
        row += 1
        for file in files {
            if row >= 1 && row < height {
                drawFileRow(file, row: row, selected: globalIdx == selectedIndex)
            }
            globalIdx += 1
            row += 1
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
        drawHeader(" DIFF (Esc to close) ", fg: Theme.fg)
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
        case .char("-"): delegate?.runGitCommand(label: "git pull", args: ["pull"])
        case .char("+"): delegate?.runGitCommand(label: "git push", args: ["push"])
        case .escape: return false
        default: return false
        }
        return true
    }

    private func totalItemCount() -> Int {
        stagedFiles.count + unstagedFiles.count + untrackedFiles.count + min(recentCommits.count, 5)
    }

    private func ensureVisible() {
        let visibleCount = height - 1
        let totalContentRows = totalContentRowCount()
        if totalContentRows - 1 <= visibleCount {
            scrollOffset = 0
            return
        }
        if let selectedRow = rowForSelectedItem() {
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
            Shell.git(["reset", "HEAD", "--", file.filePath], workDir: workingDirectory)
        case .unstaged:
            let file = unstagedFiles[sel.index]
            Shell.git(["add", "--", file.filePath], workDir: workingDirectory)
        case .untracked:
            let file = untrackedFiles[sel.index]
            Shell.git(["add", "--", file.filePath], workDir: workingDirectory)
        case .commit: break
        }
        refresh()
        if selectedIndex >= totalItemCount() {
            selectedIndex = max(0, totalItemCount() - 1)
        }
    }

    private func runDiff(for path: String, staged: Bool) {
        let args = staged ? ["diff", "--cached", "--", path] : ["diff", "--", path]
        diffLines = Shell.git(args, workDir: workingDirectory).combined.split(separator: "\n", omittingEmptySubsequences: false)
        diffScrollOffset = 0
        showDiff = true
        dirty = true
    }

    func refresh() {
        guard !workingDirectory.isEmpty else { return }
        isRefreshing = true
        dirty = true

        let workDir = workingDirectory
        gitTask.start { [workDir] in
            GitRefreshResult(
                branch: Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], workDir: workDir).stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                statusOutput: Shell.git(["status", "--porcelain"], workDir: workDir).stdout,
                logOutput: Shell.git(["log", "--oneline", "-10", "--format=%h|%an|%cr|%s"], workDir: workDir).stdout
            )
        }
    }

    override func poll() {
        guard let result = gitTask.consume() else { return }
        isRefreshing = false
        currentBranch = result.branch.hasPrefix("fatal") ? "not a git repo" : result.branch
        parseStatus(result.statusOutput)
        parseLog(result.logOutput)
        dirty = true
        delegate?.requestRender()
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

}
