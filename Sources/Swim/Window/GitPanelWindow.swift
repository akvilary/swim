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
    private var showDiff: Bool = false

    var workingDirectory: String = "" {
        didSet { refresh() }
    }

    override func update() {
        clear()
        fillRegion(row: 0, col: 0, width: width, height: height, cell: Cell.colored(" ", fg: Theme.fg, bg: Theme.bgDark))
        if showDiff { drawDiff() } else { drawStatus() }
    }

    private func drawStatus() {
        for (i, c) in "  \(currentBranch) ".enumerated() {
            if i < width {
                setCell(0, i, Cell.colored(c, fg: Theme.orange, bg: Theme.bgHighlight, bold: true))
            }
        }
        for i in currentBranch.count + 3..<width {
            setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
        }

        var row = 1
        var globalIdx = 0
        if !stagedFiles.isEmpty { row = drawSection("Staged changes", files: stagedFiles, startRow: row, startIdx: &globalIdx) }
        if !unstagedFiles.isEmpty { row = drawSection("Changes", files: unstagedFiles, startRow: row, startIdx: &globalIdx) }
        if !untrackedFiles.isEmpty { row = drawSection("Untracked", files: untrackedFiles, startRow: row, startIdx: &globalIdx) }
        if !recentCommits.isEmpty && row < height - 1 {
            row += 1
            drawSectionHeader("Recent commits", row: row)
            row += 1
            for commit in recentCommits.prefix(5) {
                guard row < height else { break }
                let globalSelect = globalIdx == selectedIndex
                let bg: Color = globalSelect ? Theme.bgHighlight : Theme.bgDark
                let commitText = " \(commit.hash.prefix(7)) \(commit.message.prefix(width - 14))"
                drawLine(commitText, row: row, fg: Theme.green1, bg: bg)
                globalIdx += 1
                row += 1
            }
        }
    }

    private func drawSection(_ title: String, files: [GitFileStatus], startRow: Int, startIdx: inout Int) -> Int {
        var row = startRow
        guard row < height else { return row }
        drawSectionHeader(title, row: row)
        row += 1
        for file in files {
            guard row < height else { break }
            let isSelected = startIdx == selectedIndex
            let bg: Color = isSelected ? Theme.bgHighlight : Theme.bgDark
            let statusColor = statusColorFor(file.status)
            let statusText = " \(file.status) "
            drawLine(statusText, row: row, col: 0, fg: statusColor, bg: bg, bold: true)
            let nameStart = statusText.count
            let name = file.filePath.prefix(width - nameStart)
            drawLine(String(name), row: row, col: nameStart, fg: isSelected ? Theme.fg : Theme.fgDark, bg: bg)
            startIdx += 1
            row += 1
        }
        return row
    }

    private func drawDiff() {
        let headerText = " DIFF (Esc to close) "
        for (i, c) in headerText.enumerated() {
            if i < width { setCell(0, i, Cell.colored(c, fg: Theme.fg, bg: Theme.bgHighlight, bold: true)) }
        }
        let lines = diffContent.split(separator: "\n", omittingEmptySubsequences: false)
        for (row, line) in lines.enumerated() {
            guard row + 1 < height else { break }
            let fg: Color
            if line.hasPrefix("+") { fg = Theme.green }
            else if line.hasPrefix("-") { fg = Theme.red }
            else if line.hasPrefix("@@") { fg = Theme.cyan }
            else { fg = Theme.fgDark }
            drawLine(String(line.prefix(width)), row: row + 1, fg: fg)
        }
    }

    private func drawSectionHeader(_ text: String, row: Int) {
        drawLine(" \(text)", row: row, fg: Theme.blue, bold: true)
    }

    private func drawLine(_ text: String, row: Int, col: Int = 0, fg: Color = Theme.fgDark, bg: Color = Theme.bgDark, bold: Bool = false) {
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

    override func handleKey(_ key: Key) -> Bool {
        switch key {
        case .char("j"), .down:
            let total = totalItemCount()
            if selectedIndex < total - 1 { selectedIndex += 1; ensureVisible(); dirty = true }
        case .char("k"), .up:
            if selectedIndex > 0 { selectedIndex -= 1; ensureVisible(); dirty = true }
        case .enter: showDiffForSelected()
        case .escape:
            if showDiff { showDiff = false; dirty = true }
        default: return false
        }
        return true
    }

    private func totalItemCount() -> Int {
        stagedFiles.count + unstagedFiles.count + untrackedFiles.count + min(recentCommits.count, 5)
    }

    private func ensureVisible() {
        let visibleCount = height - 1
        if selectedIndex < scrollOffset { scrollOffset = selectedIndex }
        else if selectedIndex >= scrollOffset + visibleCount { scrollOffset = selectedIndex - visibleCount + 1 }
    }

    private func showDiffForSelected() {
        var idx = selectedIndex
        if idx < stagedFiles.count { runDiff(for: stagedFiles[idx].filePath, staged: true); return }
        idx -= stagedFiles.count
        if idx < unstagedFiles.count { runDiff(for: unstagedFiles[idx].filePath, staged: false) }
    }

    private func runDiff(for path: String, staged: Bool) {
        let args = staged ? ["diff", "--cached", "--", path] : ["diff", "--", path]
        diffContent = runGit(args)
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
