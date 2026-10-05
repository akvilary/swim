import Foundation
import SwimCore

private struct BranchFetch {
    let entries: [BranchList.Entry]
    /// True when the fetch returned fewer rows than its request-time
    /// `--count` — git ran out of matches, no page can add anything
    /// for this query. Computed against the request-time limit so a
    /// page grown while the fetch was in flight can't flip the flag
    /// wrongly.
    let complete: Bool
}

/// Branch picker: a two-phase list window shaped like the search
/// results — `.insert` types a live filter into the window's own input
/// line, `.menu` navigates the (already filtered) list. The listing
/// comes from `git for-each-ref --sort=-committerdate` (git does the
/// ordering by last-commit date; swim never sorts).
///
/// The listing is paged: git is asked for `--count=listLimit` entries
/// (a page is 20) and navigating within a few rows of the page's end
/// grows it — the branch table is read only as deep as the user
/// actually scrolls. The query rides to git with every keystroke
/// (`--ignore-case` + a contains-pattern, see `BranchList.matchPattern`):
/// the first page of matches for a longer query is NOT a subset of the
/// page already on screen (the newest "fix*" branches may contain no
/// "fixe*" at all), so re-querying — not cache filtering — is the only
/// truthful option; BackgroundTask's newest-wins keeps a fast typist
/// to one in-flight fetch.
///
/// Keys: ↑/↓ leave insert mode while moving the selection through the
/// matches; Enter switches the selected branch (through the command
/// window — its output and the reload sweep come free) and closes the
/// picker; Ctrl+Enter switches AND pulls (on the current branch —
/// just pulls); the first Esc clears the query and leaves insert
/// mode, an Esc in menu mode closes the window; `i` returns to
/// typing.
class GitBranchesWindow: Window {
    override var availableModes: [WindowMode] { [.insert, .menu, .command] }

    /// The query-input phase is the window's insert mode; branch
    /// navigation is menu mode (same contract as SearchResultsWindow).
    var inputMode: Bool { mode == .insert }

    /// One page of the listing: the initial `--count` and the growth
    /// step when the cursor approaches the page's end.
    private static let pageSize = 20
    /// How close to the page's end the cursor triggers the next page:
    /// five rows of headroom, so the 16th row of a 20-row page
    /// already fetches ahead.
    private static let prefetchMargin = 5

    private var branches: [BranchList.Entry] = []
    /// The fetch+display window into the listing: git is asked for
    /// exactly this many entries (of the current query's matches or of
    /// everything, when the query is blank). Grows page by page on
    /// demand.
    private var listLimit = GitBranchesWindow.pageSize
    /// The loaded `branches` exhausted git's matches for the current
    /// query — no page can add anything.
    private var isComplete = false
    private(set) var isRefreshing = false
    /// The last refresh failed (not a repository) — the list area says
    /// so instead of the misleading "no branches".
    private var loadFailed = false
    private let gitTask = BackgroundTask<BranchFetch?>()
    var spinnerFrame: Int = 0
    private static let spinnerChars: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private var filterBuffer: String = ""
    private var filterCursorPos: Int = 0
    private var selectedIndex: Int = 0
    private var scrollOffset: Int = 0

    var workingDirectory: String = "" {
        didSet { refresh() }
    }

    /// Fresh open state: empty filter, first page only, selection on
    /// the newest branch, typing surface ready (insert mode).
    /// Assigning the directory (its didSet starts the reload) restarts
    /// the fetch even when it did not change — a branch may have moved
    /// since the last visit.
    func prepare(workingDirectory: String) {
        filterBuffer = ""
        filterCursorPos = 0
        selectedIndex = 0
        scrollOffset = 0
        listLimit = Self.pageSize
        isComplete = false
        mode = .insert
        self.workingDirectory = workingDirectory
        dirty = true
    }

    func refresh() {
        guard !workingDirectory.isEmpty else { return }
        isRefreshing = true
        // A new fetch invalidates the previous failure — the window
        // shows the loading state, not a stale "not a repository".
        loadFailed = false
        dirty = true
        let workDir = workingDirectory
        let limit = listLimit
        // Captured at request time: a queued closure must carry the
        // query it was started for, immune to later keystrokes.
        let pattern = BranchList.matchPattern(for: filterBuffer)
        gitTask.start {
            var args = [
                "for-each-ref",
                "--ignore-case",
                "--count=\(limit)",
                "--sort=-committerdate",
                "--format=%(refname:short)%00%(committerdate:relative)%00%(HEAD)"
            ]
            args.append(pattern ?? "refs/heads/")
            let result = Shell.git(args, workDir: workDir)
            // A non-zero exit (not a repository) is a result too — nil
            // keeps it apart from the legitimate empty listing.
            guard result.exitCode == 0 else { return nil }
            let entries = BranchList.parse(result.stdout)
            return BranchFetch(entries: entries, complete: entries.count < limit)
        }
    }

    /// True while the listing may have entries past the loaded page —
    /// the "N+" count and the "… more" tail draw from this. Refers to
    /// the current query once its fetch lands; until then the page on
    /// screen is the previous query's (the "… loading" tail says so).
    private var mayHaveMore: Bool {
        !isComplete
    }

    private var selectedEntry: BranchList.Entry? {
        guard branches.indices.contains(selectedIndex) else { return nil }
        return branches[selectedIndex]
    }

    override func update() {
        clear()
        // The top row (input line or plate) is always drawn — even
        // mid-fetch: hiding the typing surface while the user keeps
        // typing would erase their own input from under them.
        if inputMode {
            drawFilterLine()
        } else {
            drawPlateHeader()
        }
        drawBranchList()
    }

    /// The typing surface — the search window's input row, verbatim:
    /// prompt + query in the plate colors, the caret inverted in place.
    private func drawFilterLine() {
        let prompt = " Branch: "
        drawLine(prompt, row: 0, col: 0, fg: Theme.fg, bg: Theme.bgHighlight, bold: true)
        let maxInput = width - prompt.count - 2
        let displayText = String(filterBuffer.suffix(max(0, maxInput)))
        drawLine(displayText, row: 0, col: prompt.count, fg: Theme.fg, bg: Theme.bgHighlight)
        // Fill the whole tail — starting one past the text would leave a
        // stray dark cell right after the last character once the
        // cursor moves away from it.
        for i in min(width, max(0, prompt.count + displayText.count))..<width {
            setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
        }
        let cursorCol = prompt.count + min(filterCursorPos, maxInput)
        if cursorCol < width {
            // Invert the existing cell — the character keeps its text
            // color and stays visible.
            var cell = getCell(0, cursorCol)
            cell.reverse = true
            setCell(0, cursorCol, cell)
        }
    }

    private func drawPlateHeader() {
        if isRefreshing, branches.isEmpty {
            // Nothing on screen yet — say so in the plate, spinner in
            // the list area below.
            let spinner = Self.spinnerChars[spinnerFrame % Self.spinnerChars.count]
            headerPlate = HeaderPlate(text: " \(spinner) Branches ", fg: Theme.blue)
            drawPlate()
            return
        }
        let query = filterBuffer.trimmingCharacters(in: .whitespaces)
        let filterNote = query.isEmpty ? "" : " [\(query)] "
        // The "+" marks a paged listing: more matches exist past the
        // loaded page, waiting for navigation to fetch them.
        let countNote = mayHaveMore ? "\(branches.count)+" : "\(branches.count)"
        headerPlate = HeaderPlate(
            text: " Branches (\(countNote))\(filterNote)(Enter: switch, Ctrl+Enter: +pull, i: filter, Esc: close) ",
            fg: Theme.orange)
        drawPlate()
    }

    private func drawBranchList() {
        let list = branches
        let visibleH = max(0, height - 1)
        scrollOffset = Window.clampedScroll(selectedIndex: selectedIndex, scrollOffset: scrollOffset, visibleCount: visibleH)

        if list.isEmpty {
            if isRefreshing {
                // First load (or a query whose previous page was empty):
                // spinner in the list area, the top row stays honest.
                let spinner = Self.spinnerChars[spinnerFrame % Self.spinnerChars.count]
                let msg = "\(spinner) Loading branches..."
                let midRow = max(1, height / 2)
                let startCol = max(0, (width - msg.count - 2) / 2)
                for (i, c) in msg.enumerated() {
                    if startCol + i < width {
                        setCell(midRow, startCol + i, Cell.colored(c, fg: Theme.blue, bg: Theme.bgDark, bold: true))
                    }
                }
                return
            }
            let query = filterBuffer.trimmingCharacters(in: .whitespaces)
            let msg = loadFailed ? " Not a git repository"
                : (query.isEmpty ? " No branches" : " No matching branches")
            drawLine(msg, row: 1, fg: Theme.comment)
            return
        }

        for row in 0..<visibleH {
            let idx = scrollOffset + row
            guard idx < list.count else { break }
            let entry = list[idx]
            let selected = idx == selectedIndex
            let bg: Color = selected ? Theme.bgHighlight : Theme.bgDark
            fillRegion(row: row + 1, col: 0, width: width, height: 1, cell: Cell.colored(" ", fg: Theme.fg, bg: bg))
            let marker = entry.isCurrent ? "* " : "  "
            let nameFg: Color = entry.isCurrent ? Theme.green : (selected ? Theme.fg : Theme.fgDark)
            drawLine(marker + entry.name, row: row + 1, col: 0, fg: nameFg, bg: bg, bold: entry.isCurrent)
            // Relative last-commit date, right-aligned, dim — never
            // drawn over a long name: the name owns the width it needs.
            let date = " \(entry.lastCommit) "
            let dateCol = width - date.count
            if dateCol > marker.count + entry.name.count {
                drawLine(date, row: row + 1, col: dateCol, fg: Theme.comment, bg: bg)
            }
        }

        // The pager's tail note — only when it may mean something:
        // more matches exist past the page, or a fetch is in flight
        // (a page growth / the query being re-queried).
        if mayHaveMore || isRefreshing {
            let footerRow = 1 + list.count - scrollOffset
            if footerRow >= 1, footerRow < height {
                let msg = isRefreshing ? " … loading" : " … more"
                drawLine(msg, row: footerRow, fg: Theme.comment)
            }
        }
    }

    override func handleKey(_ key: Key) -> Bool {
        if inputMode {
            return handleInputKey(key)
        }
        switch key {
        case .char("j"), .down:
            moveSelection(1)
        case .char("k"), .up:
            moveSelection(-1)
        case .enter:
            switchSelected(pullAfter: false)
        case .ctrl("j"):
            // Ctrl+Enter — every mainstream terminal sends it as LF
            // (byte 10), the byte twin of Ctrl+J: no keyboard protocol
            // needed, and this window has no other claim on it.
            switchSelected(pullAfter: true)
        case .char("i"):
            mode = .insert
            filterCursorPos = filterBuffer.count
            dirty = true
        case .escape:
            return false
        default:
            return false
        }
        return true
    }

    private func handleInputKey(_ key: Key) -> Bool {
        switch key {
        case .escape:
            // The first Esc leaves the typing phase AND clears the
            // query — the list returns to the plain recent-branches
            // page through the same re-query path as any other edit
            // (selection keeps its branch while it stays on the
            // page); the next one (menu mode) closes the window.
            mode = .menu
            if !filterBuffer.isEmpty {
                editFilter {
                    filterBuffer = ""
                    filterCursorPos = 0
                }
            } else {
                dirty = true
            }
        case .enter:
            switchSelected(pullAfter: false)
        case .ctrl("j"):
            // Ctrl+Enter — see the menu-mode twin above.
            switchSelected(pullAfter: true)
        case .up:
            mode = .menu
            moveSelection(-1)
        case .down:
            mode = .menu
            moveSelection(1)
        case .backspace:
            editFilter {
                if filterCursorPos > 0 {
                    let idx = filterBuffer.index(filterBuffer.startIndex, offsetBy: filterCursorPos - 1)
                    filterBuffer.remove(at: idx)
                    filterCursorPos -= 1
                }
            }
        case .delete:
            editFilter {
                if filterCursorPos < filterBuffer.count {
                    let idx = filterBuffer.index(filterBuffer.startIndex, offsetBy: filterCursorPos)
                    filterBuffer.remove(at: idx)
                }
            }
        case .left:
            if filterCursorPos > 0 { filterCursorPos -= 1; dirty = true }
        case .right:
            if filterCursorPos < filterBuffer.count { filterCursorPos += 1; dirty = true }
        case .home:
            filterCursorPos = 0; dirty = true
        case .end:
            filterCursorPos = filterBuffer.count; dirty = true
        case .char(let c) where c.unicodeScalars.count == 1:
            editFilter {
                let idx = filterBuffer.index(filterBuffer.startIndex, offsetBy: filterCursorPos)
                filterBuffer.insert(c, at: idx)
                filterCursorPos += 1
            }
        default:
            break
        }
        return true
    }

    /// Applies an edit to the filter and re-resolves the selection: the
    /// selected branch stays selected while it still matches; otherwise
    /// the cursor lands on the first match. The same identity-follows
    /// idea as the git panel's SectionedListSelection, scoped to a flat
    /// list. Every edit re-queries git: the first page of matches for
    /// the new query is not a subset of the page on screen (newest-wins
    /// coalesces a typing burst into the last query).
    private func editFilter(_ edit: () -> Void) {
        let keptName = selectedEntry?.name
        edit()
        reresolveSelection(keeping: keptName)
        refresh()
        dirty = true
    }

    private func reresolveSelection(keeping name: String?) {
        if let name, let idx = branches.firstIndex(where: { $0.name == name }) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }
        ensureVisible()
    }

    private func moveSelection(_ delta: Int) {
        guard !branches.isEmpty else { return }
        selectedIndex = max(0, min(selectedIndex + delta, branches.count - 1))
        prefetchAhead()
        ensureVisible()
        dirty = true
    }

    /// The pager's trigger: reaching within `prefetchMargin` rows of
    /// the loaded page's end (the 16th row of a 20-row page) grows the
    /// page and refetches — one wider `--count` slice of the current
    /// query's matches, which git still orders by committerdate.
    /// Nothing to fetch while a fetch is already in flight (its result
    /// may already satisfy the cursor; the next keypress re-checks) or
    /// when the page is exhausted.
    private func prefetchAhead() {
        guard mayHaveMore, !isRefreshing,
              selectedIndex >= branches.count - Self.prefetchMargin else { return }
        listLimit += Self.pageSize
        refresh()
    }

    private func ensureVisible() {
        scrollOffset = Window.clampedScroll(
            selectedIndex: selectedIndex,
            scrollOffset: scrollOffset,
            visibleCount: max(0, height - 1))
    }

    /// Enter: switch to the selected branch through the shared command
    /// window — its visible output, error reporting and the finished
    /// hook (stats refetch, panel refresh, changed-tab reload sweep)
    /// come free. The picker closes first, so the command window takes
    /// the stage cleanly. Ctrl+Enter (pullAfter) chains a `git pull`
    /// after a successful switch; on the current branch the switch is
    /// a no-op, so the pull alone runs.
    private func switchSelected(pullAfter: Bool) {
        guard let entry = selectedEntry else { return }
        let name = entry.name
        if entry.isCurrent {
            guard pullAfter else {
                delegate?.reportError("Already on \(entry.name)")
                return
            }
            delegate?.requestClose(self)
            delegate?.runGitCommand(label: "git pull", args: ["pull"])
            return
        }
        delegate?.requestClose(self)
        if pullAfter {
            delegate?.runGitCommand(
                label: "git switch \(name)", args: ["switch", name],
                then: (label: "git pull", args: ["pull"]))
        } else {
            delegate?.runGitCommand(label: "git switch \(name)", args: ["switch", name])
        }
    }

    override func poll() {
        guard let result = gitTask.consume() else { return }
        isRefreshing = false
        if let fetched = result {
            loadFailed = false
            isComplete = fetched.complete
            let keptName = selectedEntry?.name
            branches = fetched.entries
            reresolveSelection(keeping: keptName)
        } else {
            loadFailed = true
            branches = []
            isComplete = false
            selectedIndex = 0
            ensureVisible()
        }
        dirty = true
        delegate?.requestRender()
    }
}
