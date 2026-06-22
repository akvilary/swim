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

private struct DiffHunk {
    let headerLine: Int  // index of the @@ line in diffLines
    let contentEnd: Int  // exclusive: index of next @@ or diffLines.count
}

private enum GitPanelMode {
    case normal
    case visual
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
    private var diffHunks: [DiffHunk] = []
    private var diffScrollOffset: Int = 0
    private var diffCursorRow: Int = 0
    private var showDiff: Bool = false
    private var diffPath: String = ""
    private var diffStaged: Bool = false
    private var diffUntracked: Bool = false
    private var diffCommitHash: String = ""
    private(set) var isDiffLoading: Bool = false
    var diffSpinnerFrame: Int = 0
    private let diffTask = BackgroundTask<[Substring]>()
    private static let spinnerChars: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private(set) var isRefreshing: Bool = false
    private let gitTask = BackgroundTask<GitRefreshResult>()

    private var mode: GitPanelMode = .normal
    private var pendingY: Bool = false
    private var statusVisualStart: Int = 0
    private var diffVisualStart: Int = 0

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
        if mode == .visual {
            drawHeader(" [ VISUAL ] \(branchLabel) ", fg: Theme.purple)
        } else {
            drawHeader("  \(branchLabel) ", fg: Theme.orange)
        }

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
                    let bg = bgForStatusRow(globalIdx)
                    let commitText = " \(commit.hash.prefix(7)) \(commit.message.prefix(width - 14))"
                    drawLine(commitText, row: row, fg: Theme.cyan, bg: bg)
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
                drawFileRow(file, row: row, globalIdx: globalIdx)
            }
            globalIdx += 1
            row += 1
        }
    }

    private func drawFileRow(_ file: GitFileStatus, row: Int, globalIdx: Int) {
        let bg = bgForStatusRow(globalIdx)
        let isSelected = isStatusRowSelected(globalIdx)
        let statusColor = statusColorFor(file.status)
        let statusText = " \(file.status) "
        drawLine(statusText, row: row, col: 0, fg: statusColor, bg: bg, bold: true)
        let nameStart = statusText.count
        let name = file.filePath.prefix(width - nameStart)
        drawLine(String(name), row: row, col: nameStart, fg: isSelected ? Theme.fg : Theme.fgDark, bg: bg)
    }

    private func drawDiff() {
        let isCommit = !diffCommitHash.isEmpty
        let title = isCommit ? "COMMIT \(diffCommitHash)" : "DIFF \(diffPath)"

        if isDiffLoading {
            let spinner = Self.spinnerChars[diffSpinnerFrame % Self.spinnerChars.count]
            drawHeader(" \(spinner) \(title) ", fg: Theme.blue)
            let msg = "\(spinner) Loading..."
            let midRow = height / 2
            let startCol = max(0, (width - msg.count - 2) / 2)
            for (i, c) in msg.enumerated() {
                if startCol + i < width {
                    setCell(midRow, startCol + i, Cell.colored(c, fg: Theme.blue, bg: Theme.bgDark, bold: true))
                }
            }
            return
        }

        if diffLines.isEmpty {
            drawHeader(" \(title) (empty) ", fg: Theme.comment)
            let msg = "No changes"
            let midRow = height / 2
            let startCol = max(0, (width - msg.count - 2) / 2)
            drawLine(msg, row: midRow, col: startCol, fg: Theme.comment)
            return
        }

        if isCommit {
            drawHeader(" \(title) (yy: copy, V: visual, Esc: close) ", fg: Theme.fg)
        } else {
            let hunkHint = diffUntracked ? "s: add file" : (diffStaged ? "s: unstage hunk" : "s: stage hunk")
            drawHeader(" \(title) (\(hunkHint), yy: copy, V: visual, Esc: close) ", fg: Theme.fg)
        }
        if mode == .visual {
            drawHeader(" [ VISUAL ] \(title) (y: copy, Esc: cancel) ", fg: Theme.purple)
        }
        let visibleLines = height - 1
        let visualRange = mode == .visual ? diffVisualRange() : nil
        for i in 0..<visibleLines {
            let lineIdx = diffScrollOffset + i
            guard lineIdx < diffLines.count else { break }
            let line = diffLines[lineIdx]
            let row = i + 1
            let isCursor = lineIdx == diffCursorRow

            let style = diffLineStyle(for: line)

            let bg: Color
            if let vr = visualRange, vr.contains(lineIdx) {
                bg = Theme.visualBg
            } else {
                bg = isCursor ? Theme.bgHighlight : Theme.bgDark
            }
            drawLine(String(line.prefix(width)), row: row, fg: style.fg, bg: bg, bold: style.bold)
        }
    }

    private func diffLineStyle(for line: Substring) -> (fg: Color, bold: Bool) {
        if line.hasPrefix("commit ") { return (Theme.blue, true) }
        if line.hasPrefix("Author:") || line.hasPrefix("Date:") { return (Theme.cyan, false) }
        if line.hasPrefix("diff --git") { return (Theme.magenta, true) }
        if line.hasPrefix("index ")
            || line.hasPrefix("new file mode")
            || line.hasPrefix("deleted file mode")
            || line.hasPrefix("old mode")
            || line.hasPrefix("new mode") { return (Theme.comment, false) }
        if line.hasPrefix("+")  { return (Theme.green, false) }
        if line.hasPrefix("-")  { return (Theme.red, false) }
        if line.hasPrefix("@@") { return (Theme.cyan, false) }
        return (Theme.fgDark, false)
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
        fileSection(for: selectedIndex)
    }

    private func fileSection(for globalIdx: Int) -> (section: FileSection, index: Int)? {
        var idx = globalIdx
        if idx < stagedFiles.count { return (.staged, idx) }
        idx -= stagedFiles.count
        if idx < unstagedFiles.count { return (.unstaged, idx) }
        idx -= untrackedFiles.count
        if idx < untrackedFiles.count { return (.untracked, idx) }
        idx -= untrackedFiles.count
        if idx < min(recentCommits.count, 5) { return (.commit, idx) }
        return nil
    }

    private func visibleTextForItem(at globalIdx: Int) -> String? {
        guard let sel = fileSection(for: globalIdx) else { return nil }
        switch sel.section {
        case .staged:    return " \(stagedFiles[sel.index].status) \(stagedFiles[sel.index].filePath)"
        case .unstaged:  return " \(unstagedFiles[sel.index].status) \(unstagedFiles[sel.index].filePath)"
        case .untracked: return " \(untrackedFiles[sel.index].status) \(untrackedFiles[sel.index].filePath)"
        case .commit:    return " \(recentCommits[sel.index].hash.prefix(7)) \(recentCommits[sel.index].message)"
        }
    }

    override func handleKey(_ key: Key) -> Bool {
        if showDiff {
            switch key {
            case .char("j"), .down:
                if diffCursorRow < diffLines.count - 1 {
                    diffCursorRow += 1; ensureDiffCursorVisible(); dirty = true
                }
                pendingY = false
            case .char("k"), .up:
                if diffCursorRow > 0 {
                    diffCursorRow -= 1; ensureDiffCursorVisible(); dirty = true
                }
                pendingY = false
            case .char("s"):
                stageOrUnstageFromDiff()
                pendingY = false
            case .char("y"):
                if pendingY {
                    yankDiffLines(diffCursorRow...diffCursorRow)
                    pendingY = false
                } else if mode == .visual {
                    yankDiffLines(diffVisualRange())
                    mode = .normal; dirty = true
                } else {
                    pendingY = true
                }
            case .char("V"):
                mode = (mode == .visual) ? .normal : .visual
                diffVisualStart = diffCursorRow
                pendingY = false; dirty = true
            case .escape:
                if mode == .visual { mode = .normal; dirty = true }
                else { showDiff = false; dirty = true }
                pendingY = false
            default:
                pendingY = false
                return false
            }
            return true
        }

        switch key {
        case .char("j"), .down:
            let total = totalItemCount()
            if selectedIndex < total - 1 { selectedIndex += 1; ensureVisible(); dirty = true }
            pendingY = false
        case .char("k"), .up:
            if selectedIndex > 0 { selectedIndex -= 1; ensureVisible(); dirty = true }
            pendingY = false
        case .enter:
            mode = .normal; pendingY = false
            showDiffForSelected()
        case .char("s"):
            mode = .normal; pendingY = false
            stageOrUnstageSelected()
        case .char("-"):
            mode = .normal; pendingY = false
            delegate?.runGitCommand(label: "git pull", args: ["pull"])
        case .char("+"):
            mode = .normal; pendingY = false
            delegate?.runGitCommand(label: "git push", args: ["push"])
        case .char("y"):
            if pendingY {
                if let text = visibleTextForItem(at: selectedIndex) { Terminal.shared.osc52Copy(text) }
                pendingY = false
            } else if mode == .visual {
                let lo = min(statusVisualStart, selectedIndex)
                let hi = max(statusVisualStart, selectedIndex)
                yankStatusItems(lo...hi)
                mode = .normal; dirty = true
            } else {
                pendingY = true
            }
        case .char("V"):
            mode = (mode == .visual) ? .normal : .visual
            statusVisualStart = selectedIndex
            pendingY = false; dirty = true
        case .escape:
            if mode == .visual { mode = .normal; dirty = true; pendingY = false; return true }
            pendingY = false
            return false
        default:
            pendingY = false
            return false
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
        case .staged:    runDiff(for: stagedFiles[sel.index].filePath,    staged: true,  untracked: false)
        case .unstaged:  runDiff(for: unstagedFiles[sel.index].filePath,  staged: false, untracked: false)
        case .untracked: runDiff(for: untrackedFiles[sel.index].filePath, staged: false, untracked: true)
        case .commit:    runDiffForCommit(recentCommits[sel.index].hash)
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

    private func runDiff(for path: String, staged: Bool, untracked: Bool) {
        let args: [String]
        if untracked {
            args = ["diff", "--no-index", "/dev/null", path]
        } else if staged {
            args = ["diff", "--cached", "--", path]
        } else {
            args = ["diff", "--", path]
        }

        diffPath = path
        diffStaged = staged
        diffUntracked = untracked
        diffCommitHash = ""
        diffLines = []
        diffHunks = []
        diffScrollOffset = 0
        diffCursorRow = 0
        isDiffLoading = true
        showDiff = true
        mode = .normal
        pendingY = false
        dirty = true

        let workDir = workingDirectory
        diffTask.start {
            let result = Shell.git(args, workDir: workDir)
            return result.combined.split(separator: "\n", omittingEmptySubsequences: false)
        }
    }

    private func runDiffForCommit(_ hash: String) {
        diffPath = ""
        diffStaged = false
        diffUntracked = false
        diffCommitHash = hash
        diffLines = []
        diffHunks = []
        diffScrollOffset = 0
        diffCursorRow = 0
        isDiffLoading = true
        showDiff = true
        mode = .normal
        pendingY = false
        dirty = true

        let workDir = workingDirectory
        diffTask.start {
            let result = Shell.git(["show", hash], workDir: workDir)
            return result.combined.split(separator: "\n", omittingEmptySubsequences: false)
        }
    }

    private func parseHunks() -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var currentHeader: Int? = nil
        for (i, line) in diffLines.enumerated() {
            if line.hasPrefix("@@") {
                if let h = currentHeader {
                    hunks.append(DiffHunk(headerLine: h, contentEnd: i))
                }
                currentHeader = i
            }
        }
        if let h = currentHeader {
            hunks.append(DiffHunk(headerLine: h, contentEnd: diffLines.count))
        }
        return hunks
    }

    private func activeHunkIndex() -> Int? {
        for (i, hunk) in diffHunks.enumerated() {
            if diffCursorRow >= hunk.headerLine && diffCursorRow < hunk.contentEnd {
                return i
            }
        }
        return nil
    }

    private func buildPatchForHunk(_ hunk: DiffHunk) -> String {
        guard let firstHunk = diffHunks.first else { return "" }
        var patch = ""
        for i in 0..<firstHunk.headerLine {
            patch += diffLines[i] + "\n"
        }
        for i in hunk.headerLine..<hunk.contentEnd {
            patch += diffLines[i] + "\n"
        }
        return patch
    }

    private func stageOrUnstageFromDiff() {
        guard !diffPath.isEmpty else { return }

        if diffUntracked {
            Shell.git(["add", "--", diffPath], workDir: workingDirectory)
        } else if let hunkIdx = activeHunkIndex() {
            let patch = buildPatchForHunk(diffHunks[hunkIdx])
            guard !patch.isEmpty else { return }
            if diffStaged {
                Shell.git(["apply", "--reverse", "--cached"], workDir: workingDirectory, stdin: patch)
            } else {
                Shell.git(["apply", "--cached"], workDir: workingDirectory, stdin: patch)
            }
        }

        refresh()
        runDiff(for: diffPath, staged: diffStaged, untracked: diffUntracked)
    }

    private func ensureDiffCursorVisible() {
        let visibleLines = height - 1
        if diffCursorRow < diffScrollOffset {
            diffScrollOffset = diffCursorRow
        } else if diffCursorRow >= diffScrollOffset + visibleLines {
            diffScrollOffset = diffCursorRow - visibleLines + 1
        }
    }

    private func isStatusRowSelected(_ globalIdx: Int) -> Bool {
        if mode == .visual {
            let lo = min(statusVisualStart, selectedIndex)
            let hi = max(statusVisualStart, selectedIndex)
            return globalIdx >= lo && globalIdx <= hi
        }
        return globalIdx == selectedIndex
    }

    private func bgForStatusRow(_ globalIdx: Int) -> Color {
        guard isStatusRowSelected(globalIdx) else { return Theme.bgDark }
        return mode == .visual ? Theme.visualBg : Theme.bgHighlight
    }

    private func diffVisualRange() -> ClosedRange<Int> {
        let lo = min(diffVisualStart, diffCursorRow)
        let hi = max(diffVisualStart, diffCursorRow)
        return lo...hi
    }

    private func yankDiffLines(_ range: ClosedRange<Int>) {
        guard range.lowerBound >= 0, range.upperBound < diffLines.count else { return }
        var text = ""
        for i in range {
            text += diffLines[i] + "\n"
        }
        Terminal.shared.osc52Copy(text)
    }

    private func yankStatusItems(_ range: ClosedRange<Int>) {
        var text = ""
        for i in range {
            if let t = visibleTextForItem(at: i) { text += t + "\n" }
        }
        if !text.isEmpty { Terminal.shared.osc52Copy(text) }
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
        var anyUpdate = false

        if let result = gitTask.consume() {
            isRefreshing = false
            currentBranch = result.branch.hasPrefix("fatal") ? "not a git repo" : result.branch
            parseStatus(result.statusOutput)
            parseLog(result.logOutput)
            anyUpdate = true
        }

        if isDiffLoading, let lines = diffTask.consume() {
            diffLines = lines
            diffHunks = parseHunks()
            isDiffLoading = false
            if diffLines.isEmpty { showDiff = false; mode = .normal }
            anyUpdate = true
        }

        if anyUpdate {
            dirty = true
            delegate?.requestRender()
        }
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
