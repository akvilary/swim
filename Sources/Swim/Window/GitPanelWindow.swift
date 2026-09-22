import Foundation
import SwimCore

private struct GitRefreshResult {
    let branch: String
    let repoRoot: String
    let statusOutput: String
    let logOutput: String
}

struct GitFileStatus {
    let status: String
    let filePath: String
    let staged: Bool
    /// Original path for staged renames/copies (`R`/`C`); nil otherwise.
    let origPath: String?

    /// The panel row letter: staged rows speak `A` (everything in the
    /// index is added to the next commit) — except a staged DELETION,
    /// which keeps `D`: an "A" on a removed file would be a lie;
    /// unstaged rows show their real worktree letter (`M`/`D`);
    /// untracked keeps the classic `?`. One source of truth for the
    /// rendered row and the `yy` yank text.
    var sectionLetter: Character {
        if status == "?" { return "?" }
        if staged { return status == "D" ? "D" : "A" }
        return Character(status)
    }
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

/// Ordered sections of the status list; the raw value is the display
/// order.
private enum StatusSection: Int {
    case staged, unstaged, untracked, commits

    var title: String {
        switch self {
        case .staged: return "Staged"
        case .unstaged: return "Unstaged"
        case .untracked: return "Untracked"
        case .commits: return "Recent commits"
        }
    }
}

/// One selectable row of the status list.
private enum StatusItem {
    case file(GitFileStatus)
    case commit(GitCommit)

    /// Stable identity used to keep the selection on the same entry when
    /// the list is rebuilt after an action (a file moves between the
    /// staged/unstaged sections on stage/unstage/discard).
    var identity: String {
        switch self {
        case .file(let f): return "file:" + f.filePath
        case .commit(let c): return "commit:" + c.hash
        }
    }

    var visibleText: String {
        switch self {
        case .file(let f): return " \(f.sectionLetter) \(f.filePath)"
        case .commit(let c): return " \(c.hash.prefix(7)) \(c.message)"
        }
    }
}

/// A (section, row) position in the status list, ordered
/// lexicographically — visual selections can span sections.
private struct StatusPos: Comparable {
    let section: Int
    let row: Int

    static func < (lhs: StatusPos, rhs: StatusPos) -> Bool {
        lhs.section < rhs.section || (lhs.section == rhs.section && lhs.row < rhs.row)
    }
}

/// The status list view model: non-empty sections in display order.
/// Rendering derives the header rows from it, and the selection is
/// addressed as (section, row) — a header can never be selected by
/// construction.
private struct StatusList {
    struct Section {
        let kind: StatusSection
        let items: [StatusItem]
    }

    let sections: [Section]

    /// Total screen rows the list occupies: one header per section plus
    /// every item.
    var rowCount: Int {
        sections.reduce(0) { $0 + 1 + $1.items.count }
    }
}

class GitPanelWindow: Window {
    override var availableModes: [WindowMode] { [.menu, .visualLine, .command] }
    private var stagedFiles: [GitFileStatus] = []
    private var unstagedFiles: [GitFileStatus] = []
    private var untrackedFiles: [GitFileStatus] = []
    private var recentCommits: [GitCommit] = []
    private var statusList: StatusList = StatusList(sections: [])
    /// Selection as (section index, row within the section) into
    /// `statusList` — never a section header.
    private var selectedSection: Int = 0
    private var selectedRow: Int = 0
    private var scrollOffset: Int = 0
    private(set) var currentBranch: String = ""
    private var diffLines: [Substring] = []
    private var diffHunks: [DiffHunk] = []
    /// Gutter numbers parallel to `diffLines` (nil — no number: hunk
    /// headers, file headers, metadata): `+` lines carry the new-file
    /// number, `-` the old-file one, context lines the shared one. The
    /// raw `diffLines` stay untouched — yank and patch building must not
    /// see the gutter. Built by the pure `DiffGutter` parser (SwimCore,
    /// unit-tested in Tests/SwimCoreTests).
    private var diffGutter: [DiffGutter.Entry] = []
    private var diffGutterWidth: Int = 4
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

    /// Absolute path of the repository root (git paths are always
    /// repo-root-relative, even when `workingDirectory` is a subdirectory).
    /// Resolved on refresh; resolved synchronously as a fallback until then.
    private var repoRoot: String = ""

    private var pendingY: Bool = false
    /// Visual selection anchor; compared with the current position
    /// lexicographically.
    private var statusVisualStart: StatusPos = StatusPos(section: 0, row: 0)
    private var diffVisualStart: Int = 0
    private var selectionPosition: StatusPos { StatusPos(section: selectedSection, row: selectedRow) }

    var workingDirectory: String = "" {
        didSet { refresh() }
    }

    /// Runs a git command, surfacing failures as a red status-bar message
    /// (same channel as editor errors, cleared by the next key press).
    @discardableResult
    private func runGit(_ args: [String], stdin: String? = nil) -> Shell.Result {
        let result = Shell.git(args, workDir: workingDirectory, stdin: stdin)
        if result.exitCode != 0 {
            var detail = result.stderr.split(separator: "\n").first.map(String.init) ?? ""
            detail = detail.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "fatal: ", with: "")
                .replacingOccurrences(of: "error: ", with: "")
            if detail.isEmpty { detail = "exit code \(result.exitCode)" }
            let command = args.first ?? "?"
            delegate?.reportError("git \(command): \(detail)")
        }
        return result
    }

    /// `--porcelain` paths are repo-root-relative; pathspec magic makes the
    /// same string valid no matter which subdirectory git runs from.
    /// `literal` disables globbing for names containing `*?[]`.
    private func topPathspec(_ path: String) -> String {
        ":(top,literal)\(path)"
    }

    private func absolutePath(_ repoRelativePath: String) -> String {
        var root = repoRoot
        if root.isEmpty {
            root = Shell.git(["rev-parse", "--show-toplevel"], workDir: workingDirectory)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !root.isEmpty, !root.hasPrefix("fatal") else {
            return workingDirectory + "/" + repoRelativePath
        }
        return root + "/" + repoRelativePath
    }

    private func deleteFileOnDisk(_ repoRelativePath: String) {
        let path = absolutePath(repoRelativePath)
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            delegate?.reportError("discard: \(error.localizedDescription)")
        }
    }

    override func update() {
        clear()
        if showDiff { drawDiff() } else { drawStatus() }
    }

    /// Screen row of the selected item, mirroring the drawStatus walk
    /// (one header row per section, then its items).
    private func rowForSelectedItem() -> Int? {
        guard statusList.sections.indices.contains(selectedSection) else { return nil }
        var row = contentTop
        for (sectionIdx, section) in statusList.sections.enumerated() {
            row += 1  // section header
            if sectionIdx == selectedSection { return row + selectedRow }
            row += section.items.count
        }
        return nil
    }

    private func drawStatus() {
        let branchLabel = isRefreshing ? "Git @ loading..." : "Git @ \(currentBranch)"
        if mode == .visualLine {
            headerPlate = HeaderPlate(text: " [ VISUAL ] \(branchLabel) ", fg: Theme.purple)
        } else {
            headerPlate = HeaderPlate(text: " \(branchLabel) (s: stage/unstage, d: discard, c/C: commit / + last msg) ", fg: Theme.orange)
        }
        drawPlate()

        let totalRows = statusList.rowCount
        let visibleHeight = contentHeight
        if totalRows <= visibleHeight {
            scrollOffset = 0
        } else {
            scrollOffset = max(0, min(scrollOffset, totalRows - visibleHeight))
        }

        var row = contentTop - scrollOffset
        for (sectionIdx, section) in statusList.sections.enumerated() {
            drawSectionHeader(section.kind.title, screenRow: row)
            row += 1
            for (itemIdx, item) in section.items.enumerated() {
                if row >= contentTop && row < height {
                    drawItemRow(item, row: row, selected: isSelectedItem(sectionIdx, itemIdx), section: section.kind)
                }
                row += 1
            }
        }

        if statusList.sections.isEmpty {
            drawLine(" No changes", row: max(contentTop, row), fg: Theme.comment)
        }
    }

    private func drawItemRow(_ item: StatusItem, row: Int, selected: Bool, section: StatusSection) {
        let bg: Color = selected
            ? (mode == .visualLine ? Theme.visualBg : Theme.bgHighlight)
            : Theme.bgDark
        switch item {
        case .file(let file):
            let statusText = " \(file.sectionLetter) "
            drawLine(statusText, row: row, col: 0, fg: statusColorFor(file, in: section), bg: bg, bold: true)
            let name = file.filePath.prefix(max(0, width - statusText.count))
            drawLine(String(name), row: row, col: statusText.count, fg: selected ? Theme.fg : Theme.fgDark, bg: bg)
        case .commit(let commit):
            let commitText = " \(commit.hash.prefix(7)) \(commit.message.prefix(max(0, width - 14)))"
            drawLine(commitText, row: row, fg: Theme.cyan, bg: bg)
        }
    }

    private func drawDiff() {
        let isCommit = !diffCommitHash.isEmpty
        let title = isCommit ? "COMMIT \(diffCommitHash)" : "DIFF \(diffPath)"

        if isDiffLoading {
            let spinner = Self.spinnerChars[diffSpinnerFrame % Self.spinnerChars.count]
            headerPlate = HeaderPlate(text: " \(spinner) \(title) ", fg: Theme.blue)
            drawPlate()
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
            headerPlate = HeaderPlate(text: " \(title) (empty) ", fg: Theme.comment)
            drawPlate()
            let msg = "No changes"
            let midRow = height / 2
            let startCol = max(0, (width - msg.count - 2) / 2)
            drawLine(msg, row: midRow, col: startCol, fg: Theme.comment)
            return
        }

        if mode == .visualLine {
            headerPlate = HeaderPlate(text: " [ VISUAL ] \(title) (y: copy, Esc: cancel) ", fg: Theme.purple)
        } else if isCommit {
            headerPlate = HeaderPlate(text: " \(title) (yy: copy, V: visual, Esc: close) ", fg: Theme.fg)
        } else {
            let hunkHint = diffUntracked ? "s: add file" : (diffStaged ? "s: unstage hunk" : "s: stage hunk")
            headerPlate = HeaderPlate(text: " \(title) (\(hunkHint), d: discard, yy: copy, V: visual, Esc: close) ", fg: Theme.fg)
        }
        drawPlate()
        let visibleLines = contentHeight
        let visualRange = mode == .visualLine ? diffVisualRange() : nil
        let lnWidth = diffGutterWidth
        for i in 0..<visibleLines {
            let lineIdx = diffScrollOffset + i
            guard lineIdx < diffLines.count else { break }
            let line = diffLines[lineIdx]
            let row = i + contentTop
            let isCursor = lineIdx == diffCursorRow

            let style = diffLineStyle(for: line)

            let bg: Color
            if let vr = visualRange, vr.contains(lineIdx) {
                bg = Theme.visualBg
            } else {
                bg = isCursor ? Theme.bgHighlight : Theme.bgDark
            }
            // Editor-style gutter (the shared drawLineNumberRow primitive):
            // green numbers on added lines, red on removed, dim elsewhere.
            // The number color never changes with the cursor — the row
            // highlight already marks the current line.
            let gutter = lineIdx < diffGutter.count ? diffGutter[lineIdx] : nil
            let numFg: Color
            if gutter?.add == true {
                numFg = Theme.green
            } else if gutter?.del == true {
                numFg = Theme.red
            } else {
                numFg = Theme.comment
            }
            drawLineNumberRow(row, number: gutter?.num, lnWidth: lnWidth, fg: numFg, bg: bg)
            drawLine(String(line.prefix(max(0, width - lnWidth))), row: row, col: lnWidth, fg: style.fg, bg: bg, bold: style.bold)
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
        guard screenRow >= contentTop && screenRow < height else { return }
        drawLine(" \(text)", row: screenRow, fg: Theme.blue, bold: true)
    }

    /// Letter color follows the shared decoration palette — the
    /// `Theme.*Color` constants, the same ones as the editor gutter and
    /// the explorer names: staged additions stagedColor (teal),
    /// worktree changes unstagedColor (orange), untracked the classic
    /// muted `?`, with `D` in deleteColor on both sides — a deletion
    /// reads on its own.
    private func statusColorFor(_ file: GitFileStatus, in section: StatusSection) -> Color {
        switch section {
        case .staged: return file.status == "D" ? Theme.deleteColor : Theme.stagedColor
        case .unstaged: return file.status == "D" ? Theme.deleteColor : Theme.unstagedColor
        case .untracked, .commits: return Theme.comment
        }
    }

    /// The item under the selection; nil when the list is empty (the
    /// selection is always valid otherwise — headers are not addressable).
    private var selectedItem: StatusItem? {
        item(at: selectionPosition)
    }

    /// True when the item at (section, row) is the selection — or inside
    /// the visual range in visual-line mode.
    private func isSelectedItem(_ sectionIdx: Int, _ itemIdx: Int) -> Bool {
        let position = StatusPos(section: sectionIdx, row: itemIdx)
        if mode == .visualLine {
            let lo = min(statusVisualStart, selectionPosition)
            let hi = max(statusVisualStart, selectionPosition)
            return position >= lo && position <= hi
        }
        return sectionIdx == selectedSection && itemIdx == selectedRow
    }

    /// Moves the selection one item down/up, crossing section borders;
    /// section headers are skipped because only items are addressable.
    private func moveSelection(_ down: Bool) {
        guard statusList.sections.indices.contains(selectedSection) else { return }
        if down {
            if selectedRow + 1 < statusList.sections[selectedSection].items.count {
                selectedRow += 1
            } else if selectedSection + 1 < statusList.sections.count {
                selectedSection += 1
                selectedRow = 0
            }
        } else {
            if selectedRow > 0 {
                selectedRow -= 1
            } else if selectedSection > 0 {
                selectedSection -= 1
                selectedRow = statusList.sections[selectedSection].items.count - 1
            }
        }
        ensureVisible()
        dirty = true
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
            case .char("d"):
                pendingY = false
                discardFromDiff()
            case .char("y"):
                if pendingY {
                    yankDiffLines(diffCursorRow...diffCursorRow)
                    pendingY = false
                } else if mode == .visualLine {
                    yankDiffLines(diffVisualRange())
                    mode = .menu; dirty = true
                } else {
                    pendingY = true
                }
            case .char("Y"):
                copyCurrentBranch()
                pendingY = false
            case .char("V"):
                mode = (mode == .visualLine) ? .menu : .visualLine
                diffVisualStart = diffCursorRow
                pendingY = false; dirty = true
            case .escape:
                if mode == .visualLine { mode = .menu; dirty = true }
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
            moveSelection(true)
            pendingY = false
        case .char("k"), .up:
            moveSelection(false)
            pendingY = false
        case .enter:
            mode = .menu; pendingY = false
            showDiffForSelected()
        case .char("s"):
            mode = .menu; pendingY = false
            stageOrUnstageSelected()
        case .char("d"):
            mode = .menu; pendingY = false
            discardSelected()
        case .char("c"):
            mode = .menu; pendingY = false
            delegate?.requestCommitMessage(prefill: "")
        case .char("C"):
            mode = .menu; pendingY = false
            delegate?.requestCommitMessage(prefill: lastCommitMessage())
        case .char("p"):
            mode = .menu; pendingY = false
            delegate?.runGitCommand(label: "git pull", args: ["pull"])
        case .char("P"):
            mode = .menu; pendingY = false
            delegate?.runGitCommand(label: "git push", args: ["push"])
        case .char("y"):
            if pendingY {
                if let item = selectedItem { Terminal.shared.osc52Copy(item.visibleText) }
                pendingY = false
            } else if mode == .visualLine {
                yankSelectedItems()
                mode = .menu; dirty = true
            } else {
                pendingY = true
            }
        case .char("Y"):
            copyCurrentBranch()
            pendingY = false
        case .char("V"):
            mode = (mode == .visualLine) ? .menu : .visualLine
            statusVisualStart = selectionPosition
            pendingY = false; dirty = true
        case .escape:
            if mode == .visualLine { mode = .menu; dirty = true; pendingY = false; return true }
            pendingY = false
            return false
        default:
            pendingY = false
            return false
        }
        return true
    }

    private func ensureVisible() {
        let visibleCount = contentHeight
        let totalRows = statusList.rowCount
        if totalRows <= visibleCount {
            scrollOffset = 0
            return
        }
        if let selectedScreenRow = rowForSelectedItem() {
            if selectedScreenRow < scrollOffset + contentTop {
                scrollOffset = selectedScreenRow - contentTop
            } else if selectedScreenRow >= scrollOffset + height {
                scrollOffset = selectedScreenRow - height + 1
            }
        }
    }

    private func showDiffForSelected() {
        switch selectedItem {
        case .file(let file):
            let section = statusList.sections[selectedSection].kind
            runDiff(for: file.filePath,
                    staged: section == .staged,
                    untracked: section == .untracked)
        case .commit(let commit):
            runDiffForCommit(commit.hash)
        case nil:
            break
        }
    }

    private func stageOrUnstageSelected() {
        switch selectedItem {
        case .file(let file):
            let section = statusList.sections[selectedSection].kind
            if section == .staged {
                // A staged rename is two index changes (delete old + add
                // new); resetting only the new path would leave the
                // deletion staged.
                var paths = [topPathspec(file.filePath)]
                if file.status == "R", let old = file.origPath {
                    paths.insert(topPathspec(old), at: 0)
                }
                runGit(["reset", "HEAD", "--"] + paths)
            } else {
                runGit(["add", "--", topPathspec(file.filePath)])
            }
        case .commit, nil:
            break
        }
        refresh()
        delegate?.gitWorktreeChanged()
    }

    private func runDiff(for path: String, staged: Bool, untracked: Bool) {
        let args: [String]
        var workDir = workingDirectory
        if untracked {
            // `--no-index` takes file operands (not pathspecs) — resolve
            // them from the repo root so repo-root-relative paths work and
            // the diff header stays root-relative.
            var root = repoRoot
            if root.isEmpty {
                root = Shell.git(["rev-parse", "--show-toplevel"], workDir: workDir)
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !root.isEmpty, !root.hasPrefix("fatal") { workDir = root }
            args = ["diff", "--no-index", "/dev/null", path]
        } else if staged {
            args = ["diff", "--cached", "--", topPathspec(path)]
        } else {
            args = ["diff", "--", topPathspec(path)]
        }

        diffPath = path
        diffStaged = staged
        diffUntracked = untracked
        diffCommitHash = ""
        diffLines = []
        diffHunks = []
        diffGutter = []
        diffGutterWidth = 4
        diffScrollOffset = 0
        diffCursorRow = 0
        isDiffLoading = true
        showDiff = true
        mode = .menu
        pendingY = false
        dirty = true

        let dir = workDir
        diffTask.start {
            let result = Shell.git(args, workDir: dir)
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
        diffGutter = []
        diffGutterWidth = 4
        diffScrollOffset = 0
        diffCursorRow = 0
        isDiffLoading = true
        showDiff = true
        mode = .menu
        pendingY = false
        dirty = true

        let workDir = workingDirectory
        diffTask.start {
            let result = Shell.git(["show", hash], workDir: workDir)
            return result.combined.split(separator: "\n", omittingEmptySubsequences: false)
        }
    }

    /// Annotates the loaded diff with gutter numbers via the pure
    /// `DiffGutter` parser (SwimCore) — see its doc comment and
    /// DiffGutterTests for the format rules and edge cases.
    private func parseDiffGutter() {
        let parsed = DiffGutter.parse(diffLines)
        diffGutter = parsed.entries
        diffGutterWidth = parsed.width
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
            runGit(["add", "--", topPathspec(diffPath)])
        } else if let hunkIdx = activeHunkIndex() {
            let patch = buildPatchForHunk(diffHunks[hunkIdx])
            guard !patch.isEmpty else { return }
            if diffStaged {
                runGit(["apply", "--reverse", "--cached"], stdin: patch)
            } else {
                runGit(["apply", "--cached"], stdin: patch)
            }
        }

        refresh()
        delegate?.gitWorktreeChanged()
        runDiff(for: diffPath, staged: diffStaged, untracked: diffUntracked)
    }

    /// Full message (subject + body) of HEAD — the `C` prefill for a
    /// follow-up commit with the same description. Empty when there is
    /// no history yet (fresh repo): `C` then behaves like `c`.
    private func lastCommitMessage() -> String {
        let result = Shell.git(["log", "-1", "--format=%B"], workDir: workingDirectory)
        guard result.exitCode == 0 else { return "" }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Notifies the app that a discard rewrote a working-tree file — a
    /// clean editor tab for it reloads from disk (see
    /// `Application.fileChangedOnDisk`).
    private func notifyBufferReload(_ repoRelativePath: String) {
        delegate?.fileChangedOnDisk(absolutePath(repoRelativePath))
    }

    private func discardSelected() {
        let section = statusList.sections.indices.contains(selectedSection)
            ? statusList.sections[selectedSection].kind : nil
        switch selectedItem {
        case .file(let file):
            switch section {
            case .staged:
                switch file.status {
                case "A":
                    // Not in HEAD: drop from index and disk.
                    if runGit(["rm", "-f", "--", topPathspec(file.filePath)]).exitCode == 0 {
                        notifyBufferReload(file.filePath)
                    }
                case "R":
                    // Staged rename: restore the old path, remove the new one.
                    if let old = file.origPath {
                        if runGit(["checkout", "HEAD", "--", topPathspec(old)]).exitCode == 0 {
                            notifyBufferReload(old)
                        }
                        if runGit(["rm", "-f", "--", topPathspec(file.filePath)]).exitCode == 0 {
                            notifyBufferReload(file.filePath)
                        }
                    } else {
                        if runGit(["checkout", "HEAD", "--", topPathspec(file.filePath)]).exitCode == 0 {
                            notifyBufferReload(file.filePath)
                        }
                    }
                case "C":
                    // Staged copy: the source is untouched, drop only the copy.
                    if runGit(["rm", "-f", "--", topPathspec(file.filePath)]).exitCode == 0 {
                        notifyBufferReload(file.filePath)
                    }
                default:
                    if runGit(["checkout", "HEAD", "--", topPathspec(file.filePath)]).exitCode == 0 {
                        notifyBufferReload(file.filePath)
                    }
                }
            case .unstaged:
                if runGit(["checkout", "--", topPathspec(file.filePath)]).exitCode == 0 {
                    notifyBufferReload(file.filePath)
                }
            case .untracked:
                deleteFileOnDisk(file.filePath)
            case .commits, nil:
                break
            }
        case .commit, nil:
            break
        }
        refresh()
        delegate?.gitWorktreeChanged()
        dirty = true
    }

    private func discardFromDiff() {
        guard !diffPath.isEmpty, diffCommitHash.isEmpty else { return }

        if diffUntracked {
            deleteFileOnDisk(diffPath)
            showDiff = false
            refresh()
            return
        }

        guard let hunkIdx = activeHunkIndex() else { return }
        let patch = buildPatchForHunk(diffHunks[hunkIdx])
        guard !patch.isEmpty else { return }
        if diffStaged {
            let indexResult = runGit(["apply", "--reverse", "--cached"], stdin: patch)
            if indexResult.exitCode == 0 {
                // Worktree may have diverged from the index (partially
                // staged region): a failure here leaves the hunk moved to
                // unstaged instead of discarded — the user must know.
                let worktreeResult = runGit(["apply", "--reverse"], stdin: patch)
                if worktreeResult.exitCode == 0 {
                    notifyBufferReload(diffPath)
                }
            }
        } else {
            if runGit(["apply", "--reverse"], stdin: patch).exitCode == 0 {
                notifyBufferReload(diffPath)
            }
        }

        refresh()
        delegate?.gitWorktreeChanged()
        runDiff(for: diffPath, staged: diffStaged, untracked: diffUntracked)
    }

    private func ensureDiffCursorVisible() {
        let visibleLines = contentHeight
        if diffCursorRow < diffScrollOffset {
            diffScrollOffset = diffCursorRow
        } else if diffCursorRow >= diffScrollOffset + visibleLines {
            diffScrollOffset = diffCursorRow - visibleLines + 1
        }
    }

    private func diffVisualRange() -> ClosedRange<Int> {
        let lo = min(diffVisualStart, diffCursorRow)
        let hi = max(diffVisualStart, diffCursorRow)
        return lo...hi
    }

    private func copyCurrentBranch() {
        let branch = currentBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, branch != "not a git repo" else { return }
        Terminal.shared.osc52Copy(branch)
    }

    private func yankDiffLines(_ range: ClosedRange<Int>) {
        guard range.lowerBound >= 0, range.upperBound < diffLines.count else { return }
        var text = ""
        for i in range {
            text += diffLines[i] + "\n"
        }
        Terminal.shared.osc52Copy(text)
    }

    /// Yanks every item between the visual anchor and the selection.
    private func yankSelectedItems() {
        let lo = min(statusVisualStart, selectionPosition)
        let hi = max(statusVisualStart, selectionPosition)
        var text = ""
        for (sectionIdx, section) in statusList.sections.enumerated() {
            for (itemIdx, item) in section.items.enumerated() {
                let position = StatusPos(section: sectionIdx, row: itemIdx)
                if position >= lo && position <= hi {
                    text += item.visibleText + "\n"
                }
            }
        }
        if !text.isEmpty { Terminal.shared.osc52Copy(text) }
    }

    /// Rebuilds the status list from the data arrays — the single
    /// composition point, called after parseStatus/parseLog. Keeps the
    /// selection on the same entry when it still exists (a file moves
    /// between sections on stage/unstage/discard); otherwise clamps the
    /// (section, row) into the new list.
    private func rebuildStatusList() {
        let sections: [StatusList.Section] = [
            .init(kind: .staged, items: stagedFiles.map(StatusItem.file)),
            .init(kind: .unstaged, items: unstagedFiles.map(StatusItem.file)),
            .init(kind: .untracked, items: untrackedFiles.map(StatusItem.file)),
            .init(kind: .commits, items: recentCommits.prefix(5).map(StatusItem.commit)),
        ].filter { !$0.items.isEmpty }

        // Capture identities before replacing the list so the selection
        // (and the visual anchor) survive entries moving between sections.
        let previousIdentity = selectedItem?.identity
        let anchorIdentity = item(at: statusVisualStart)?.identity
        statusList = StatusList(sections: sections)

        if let identity = previousIdentity,
           let found = findItem(identity) {
            selectedSection = found.section
            selectedRow = found.row
        } else if !sections.isEmpty {
            selectedSection = min(selectedSection, sections.count - 1)
            selectedRow = min(selectedRow, sections[selectedSection].items.count - 1)
        }
        // Keep the visual range anchored to the same entry; when it is
        // gone the range collapses onto the selection.
        if mode == .visualLine {
            statusVisualStart = anchorIdentity.flatMap(findItem) ?? selectionPosition
        }
        dirty = true
    }

    private func item(at pos: StatusPos) -> StatusItem? {
        guard statusList.sections.indices.contains(pos.section) else { return nil }
        let section = statusList.sections[pos.section]
        guard section.items.indices.contains(pos.row) else { return nil }
        return section.items[pos.row]
    }

    private func findItem(_ identity: String) -> StatusPos? {
        for (sectionIdx, section) in statusList.sections.enumerated() {
            for (itemIdx, item) in section.items.enumerated() where item.identity == identity {
                return StatusPos(section: sectionIdx, row: itemIdx)
            }
        }
        return nil
    }

    /// Returns from the diff view to the status list; called when the
    /// panel is reopened so a diff left open at close time (`:q`, Ctrl+X)
    /// does not show stale content.
    func closeDiffView() {
        guard showDiff else { return }
        showDiff = false
        diffCursorRow = 0
        diffScrollOffset = 0
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
                repoRoot: Shell.git(["rev-parse", "--show-toplevel"], workDir: workDir).stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                // -z: NUL-separated entries with raw (unquoted, unescaped)
                // paths — Cyrillic and other non-ASCII paths stay intact.
                statusOutput: Shell.git(["status", "--porcelain", "-z"], workDir: workDir).stdout,
                logOutput: Shell.git(["log", "--oneline", "-10", "--format=%h|%an|%cr|%s"], workDir: workDir).stdout
            )
        }
    }

    override func poll() {
        var anyUpdate = false

        if let result = gitTask.consume() {
            isRefreshing = false
            currentBranch = result.branch.hasPrefix("fatal") ? "not a git repo" : result.branch
            if !result.repoRoot.isEmpty, !result.repoRoot.hasPrefix("fatal") {
                repoRoot = result.repoRoot
            }
            parseStatus(result.statusOutput)
            parseLog(result.logOutput)
            rebuildStatusList()
            anyUpdate = true
        }

        if isDiffLoading, let lines = diffTask.consume() {
            diffLines = lines
            diffHunks = parseHunks()
            parseDiffGutter()
            isDiffLoading = false
            if diffLines.isEmpty { showDiff = false; mode = .menu }
            anyUpdate = true
        }

        if anyUpdate {
            dirty = true
            delegate?.requestRender()
        }
    }

    /// Parses `git status --porcelain -z` through the shared SwimCore
    /// `Porcelain` parser (NUL fields, raw paths, rename/copy orig-path
    /// consumption) into the panel's staged/unstaged/untracked lists.
    private func parseStatus(_ output: String) {
        stagedFiles = []; unstagedFiles = []; untrackedFiles = []
        for entry in Porcelain.parse(output) {
            if entry.x != " " && entry.x != "?" {
                stagedFiles.append(GitFileStatus(
                    status: String(entry.x), filePath: entry.path, staged: true,
                    origPath: entry.x == "R" || entry.x == "C" ? entry.origPath : nil))
            }
            if entry.y != " " && entry.y != "?" {
                unstagedFiles.append(GitFileStatus(
                    status: String(entry.y), filePath: entry.path, staged: false, origPath: nil))
            }
            if entry.x == "?" && entry.y == "?" {
                untrackedFiles.append(GitFileStatus(
                    status: "?", filePath: entry.path, staged: false, origPath: nil))
            }
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
