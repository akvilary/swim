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
    /// Whether the consumer must keep the selected branch where it
    /// still matches (menu-mode page growth, external refreshes) or
    /// land on the first row (insert-phase query edits, the Esc
    /// reset, a fresh open — the typing phase owns no visible
    /// selection to preserve). Captured at request time like the
    /// query and the limit: the intent rides with the result, immune
    /// to later refreshes while the fetch is in flight.
    let keepsSelection: Bool
}

/// Branch picker: a list window shaped like the search results with
/// two typing surfaces over one list — `.insert` types either a live
/// filter or (the `a` create phase) a new-branch name into the
/// window's own input line, `.menu` navigates the (already filtered)
/// list. The listing comes from `git for-each-ref
/// --sort=-committerdate` (git does the ordering by last-commit date;
/// swim never sorts).
///
/// The listing is paged: git is asked for `--count=listLimit` entries
/// (a page is 20) and navigating within a few rows of the page's end
/// grows it — the branch table is read only as deep as the user
/// actually scrolls. The query rides to git with every keystroke
/// (`--ignore-case` + contains-patterns, see `BranchList.matchPatterns`;
/// the blank query lists LOCAL branches only, a query reaches into
/// refs/remotes too — a fetched branch without a local counterpart is
/// exactly what a search is for, and a local twin suppresses its
/// remote rows — the local row covers the same switch):
/// the first page of matches for a longer query is NOT a subset of the
/// page already on screen (the newest "fix*" branches may contain no
/// "fixe*" at all), so re-querying — not cache filtering — is the only
/// truthful option; BackgroundTask's newest-wins keeps a fast typist
/// to one in-flight fetch.
///
/// Keys: `Ctrl+B` lands on the LIST (menu mode) — the cursor on the
/// newest branch, ready to navigate; `i` returns to the typing phase
/// (live filter), whose ↑/↓ and Enter leave it for menu mode with the
/// cursor revealed on the first row, and whose first Esc does the
/// same while also clearing the query. In menu mode Enter switches
/// the selected branch (through the command window — its output and
/// the reload sweep come free) and closes the picker, Ctrl+Enter
/// switches AND pulls (on the current branch — just pulls); `a`
/// starts branch creation: the input line becomes a name prompt
/// seeded with the current filter, Enter runs `git switch -c <name>`
/// (create + switch, the common intent) through the command window
/// and closes the picker, Esc returns to the plain list; `d` deletes
/// the selected branch locally (`git branch -d` — git itself refuses
/// unmerged branches), `D` also deletes its remote counterpart (the
/// remote leg runs only after the local one succeeded) — the picker
/// stays open, the finishing command refreshes the list; an Esc in
/// menu mode closes the window.
class GitBranchesWindow: Window {
    override var availableModes: [WindowMode] { [.insert, .menu, .command] }

    /// A typing phase (the filter or the new-branch name) is the
    /// window's insert mode; branch navigation is menu mode (same
    /// contract as SearchResultsWindow).
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
    /// The create phase's own typing surface: a separate buffer, so
    /// canceling creation (Esc) restores the filter exactly as it
    /// was. Edits here never re-query git — the listing is idle
    /// while the name is being typed.
    private var createMode = false
    private var nameBuffer: String = ""
    private var nameCursorPos: Int = 0
    private var selectedIndex: Int = 0
    private var scrollOffset: Int = 0
    /// The input line's prompt — a constant per phase (filter vs
    /// create) so the drawing and the caret math can never drift
    /// apart.
    private var activePrompt: String { createMode ? " New branch: " : " Branch: " }

    var workingDirectory: String = "" {
        // Assigned only by prepare (a fresh open): the reload must
        // not follow the previous visit's rows — the typing phase
        // starts parked on the top of the plain page.
        didSet { refresh(keepingSelection: false) }
    }

    /// Fresh open state: empty filter, first page only, the index
    /// parked on the first row, list reloaded — a branch may have
    /// moved since the last visit. `Ctrl+B` lands in MENU mode (the
    /// list itself, cursor on the newest branch); `createBranch` (the
    /// git panel's `a`) opens straight into the name prompt instead.
    func prepare(workingDirectory: String, createBranch: Bool = false) {
        filterBuffer = ""
        filterCursorPos = 0
        createMode = createBranch
        nameBuffer = ""
        nameCursorPos = 0
        selectedIndex = 0
        scrollOffset = 0
        listLimit = Self.pageSize
        isComplete = false
        mode = createBranch ? .insert : .menu
        self.workingDirectory = workingDirectory
        dirty = true
    }

    func refresh(keepingSelection: Bool = true) {
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
        let patterns = BranchList.matchPatterns(for: filterBuffer)
        let keep = keepingSelection
        gitTask.start {
            var args = [
                "for-each-ref",
                "--ignore-case",
                "--count=\(limit)",
                "--sort=-committerdate",
                "--format=%(refname:short)%00%(committerdate:relative)%00%(HEAD)%00%(refname)"
            ]
            // Blank query — locals only; a query reaches into the
            // remotes too (a fetched branch without a local
            // counterpart is exactly what a search is for).
            args += patterns
            let result = Shell.git(args, workDir: workDir)
            // A non-zero exit (not a repository) is a result too — nil
            // keeps it apart from the legitimate empty listing.
            guard result.exitCode == 0 else { return nil }
            let entries = BranchList.parse(result.stdout)
            // Completeness is git's own page fullness — the RAW line
            // count, not the parsed entries: the parser drops the
            // remote HEAD pointers, and a page whose boundary they
            // share must not read as "git ran out of matches" one page
            // early.
            let rawLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).count
            return BranchFetch(entries: entries, complete: rawLines < limit, keepsSelection: keep)
        }
    }

    /// True while the listing may have entries past the loaded page —
    /// the "… more" tail draws from this. Refers to the current query
    /// once its fetch lands; until then the page on screen is the
    /// previous query's (the "… loading" tail says so).
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

    /// The typing surface — the search window's input row: prompt +
    /// query in the plate colors; the caret itself is the terminal's
    /// insert bar (see cursorRenderInfo), not a faked inverted cell.
    /// The visible window into the text follows the shared pure
    /// policy (`InputLine`, SwimCore — tested, cell-aware: wide
    /// graphemes occupy two cells), shared with the caret math below.
    private func drawFilterLine() {
        let prompt = activePrompt
        let text = createMode ? nameBuffer : filterBuffer
        let caret = createMode ? nameCursorPos : filterCursorPos
        drawLine(prompt, row: 0, col: 0, fg: Theme.fg, bg: Theme.bgHighlight, bold: true)
        let maxInput = max(0, width - prompt.count - 2)
        let win = InputLine.window(text: text, caret: caret, capacity: maxInput)
        let displayText = String(text.dropFirst(win.start).prefix(win.visibleCount))
        drawLine(displayText, row: 0, col: prompt.count, fg: Theme.fg, bg: Theme.bgHighlight)
        // Fill the whole tail — starting one past the text would leave a
        // stray dark cell right after the last character once the
        // cursor moves away from it. Measured in cells (visibleCells),
        // not characters.
        for i in min(width, max(0, prompt.count + win.visibleCells))..<width {
            setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
        }
    }

    /// The typing caret is a terminal cursor — the shared insert-mode
    /// bar every typing surface shows. Menu mode owns no typing
    /// surface: no cursor, the renderer falls back to its navigation
    /// default.
    override func cursorRenderInfo() -> CursorRenderInfo? {
        guard visible, focused, mode == .insert else { return nil }
        let prompt = activePrompt
        let text = createMode ? nameBuffer : filterBuffer
        let caret = createMode ? nameCursorPos : filterCursorPos
        let maxInput = max(0, width - prompt.count - 2)
        let win = InputLine.window(text: text, caret: caret, capacity: maxInput)
        let col = prompt.count + win.caretOffset
        guard col >= 0, col < width else { return nil }
        return .insertCaret(row: y, col: x + col)
    }

    /// The plate's title: "Found by <query>" while a filter is active
    /// (the input line itself is not visible in menu mode — the title
    /// is the only reminder that the list is filtered), plain
    /// "Branches" otherwise. Shared by the loading and hint plates so
    /// the title never flickers between them mid-query.
    private var plateTitle: String {
        let query = filterBuffer.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? "Branches" : "Found by \(query)"
    }

    private func drawPlateHeader() {
        if isRefreshing, branches.isEmpty {
            // Nothing on screen yet — say so in the plate, spinner in
            // the list area below.
            let spinner = Self.spinnerChars[spinnerFrame % Self.spinnerChars.count]
            headerPlate = HeaderPlate(text: " \(spinner) \(plateTitle) ", fg: Theme.blue)
            drawPlate()
            return
        }
        headerPlate = HeaderPlate(
            text: " \(plateTitle) (Enter: switch, Ctrl+Enter: +pull, a: new, d/D: delete /+remote, i: filter, Esc: close) ",
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
            // The typing phase shows no selection: the cursor row
            // appears only in menu mode, revealed by the phase exits
            // (Esc, ↑/↓, Enter) on the first row.
            let selected = !inputMode && idx == selectedIndex
            let bg: Color = selected ? Theme.bgHighlight : Theme.bgDark
            fillRegion(row: row + 1, col: 0, width: width, height: 1, cell: Cell.colored(" ", fg: Theme.fg, bg: bg))
            let marker = entry.isCurrent ? "* " : "  "
            // Remote-tracking entries are dimmer than locals — the
            // "origin/" prefix says what they are, the color says
            // they are not the working set (no local counterpart).
            let nameFg: Color
            if entry.isCurrent {
                nameFg = Theme.green
            } else if entry.isRemote {
                nameFg = Theme.comment
            } else {
                nameFg = selected ? Theme.fg : Theme.fgDark
            }
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
            // needed, and this window has no other claim on it. A
            // menu-mode binding only — the typing phase swallows the
            // byte silently (see handleInputKey).
            switchSelected(pullAfter: true)
        case .char("i"):
            mode = .insert
            filterCursorPos = filterBuffer.count
            dirty = true
        case .char("a"):
            beginCreateBranch()
        case .char("d"):
            deleteSelected(alsoRemote: false)
        case .char("D"):
            deleteSelected(alsoRemote: true)
        case .escape:
            return false
        default:
            return false
        }
        return true
    }

    private func handleInputKey(_ key: Key) -> Bool {
        if createMode {
            return handleCreateKey(key)
        }
        switch key {
        case .escape:
            // The first Esc leaves the typing phase AND clears the
            // query — the list returns to the plain recent-branches
            // page through the same re-query path as any other edit,
            // the cursor revealed on the first row; the next one
            // (menu mode) closes the window.
            revealSelectionAtFirstRow()
            if !filterBuffer.isEmpty {
                filterBuffer = ""
                filterCursorPos = 0
                refresh(keepingSelection: false)
            }
        case .up, .down, .enter:
            // Phase exits: the typing phase owns neither a selection
            // nor action keys — ↑/↓ navigating out and Enter finishing
            // the query merely reveal the cursor on the first match;
            // the switch/pull actions live in menu mode (Ctrl+Enter's
            // LF byte falls through to default — ignored here). The
            // filter stays — Esc is the exit that clears it.
            revealSelectionAtFirstRow()
        default:
            switch Self.applyLineEdit(key, text: &filterBuffer, cursor: &filterCursorPos) {
            case .textChanged:
                // Every text edit re-queries git and parks the index
                // on the first row of the page on screen (the typing
                // phase shows no selection): the first page of
                // matches for the new query is not a subset of the
                // page on screen — newest-wins coalesces a typing
                // burst into the last query. Caret-only moves (←/→,
                // Home/End) re-query nothing.
                reresolveSelection(keeping: nil)
                refresh(keepingSelection: false)
                dirty = true
            case .caretOnly:
                dirty = true
            case .notEditing:
                break
            }
        }
        return true
    }

    /// Menu-mode `a` (or a fresh open with the create intent — the
    /// git panel's `a`): the input line becomes a name prompt. The
    /// name is seeded with the current filter — typing a name that
    /// matches nothing and pressing `a` keeps the typing instead of
    /// discarding it.
    private func beginCreateBranch() {
        nameBuffer = filterBuffer
        nameCursorPos = nameBuffer.count
        createMode = true
        mode = .insert
        dirty = true
    }

    /// The create phase's typing surface: Enter creates the branch,
    /// Esc returns to the plain list (the filter survives — the name
    /// lives in its own buffer); every other key goes through the
    /// shared line editor. Name edits never re-query git — the
    /// listing is idle while the name is being typed. ↑/↓
    /// deliberately do NOT leave the phase (unlike the filter's
    /// phase exits): re-entering `a` reseeds the name from the
    /// filter, so an accidental exit would discard the typing.
    private func handleCreateKey(_ key: Key) -> Bool {
        switch key {
        case .enter:
            createSelected()
        case .escape:
            createMode = false
            mode = .menu
            dirty = true
        default:
            if Self.applyLineEdit(key, text: &nameBuffer, cursor: &nameCursorPos) != .notEditing {
                dirty = true
            }
        }
        return true
    }

    /// Enter in the create phase: `git switch -c <name>` — create and
    /// switch in one move, through the shared command window (its
    /// visible output, error reporting and the finished-hook reload
    /// sweep are the same free contract as a branch switch). The
    /// picker closes first, so the command window takes the stage
    /// cleanly.
    ///
    /// The name is vetted by git itself (`check-ref-format --branch`)
    /// BEFORE the picker closes: git stays the single authority on
    /// what a branch name may be — and `--branch` also rejects a
    /// leading dash, which `switch -c -foo` would only answer with an
    /// obscure "unknown switch". A refused name keeps the window (and
    /// the typing) on screen; an empty name is the same story.
    private func createSelected() {
        let name = nameBuffer.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            delegate?.reportError("Branch name is empty")
            return
        }
        let check = Shell.git(["check-ref-format", "--branch", name], workDir: workingDirectory)
        guard check.exitCode == 0 else {
            var detail = check.stderr.split(separator: "\n").first.map(String.init)
                ?? "'\(name)' is not a valid branch name"
            detail = detail.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "fatal: ", with: "")
                .replacingOccurrences(of: "error: ", with: "")
            delegate?.reportError(detail.isEmpty ? "'\(name)' is not a valid branch name" : detail)
            return
        }
        createMode = false
        delegate?.requestClose(self)
        delegate?.runGitCommand(label: "git switch -c \(name)", args: ["switch", "-c", name])
    }

    /// The insert→menu transition (Esc, ↑/↓, Enter). The typing
    /// phase shows no selection, so leaving it always reveals the
    /// cursor on the first row — the next press moves from there.
    private func revealSelectionAtFirstRow() {
        mode = .menu
        selectedIndex = 0
        scrollOffset = 0
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
    /// the stage cleanly. Ctrl+Enter (menu mode) chains a `git pull`
    /// after a successful switch; on the current branch the switch is
    /// a no-op, so the pull alone runs.
    private func switchSelected(pullAfter: Bool) {
        guard let entry = selectedEntry else { return }
        // A remote-tracking entry switches by the branch name WITHOUT
        // the remote prefix — git's DWIM: the local branch exists →
        // switch to it; it doesn't but exactly this remote has it →
        // create the local tracking branch (the manual `git switch
        // <name>` flow). Switching at the remote ref itself would
        // detach HEAD — never what a branch picker means.
        let name = entry.isRemote && entry.name.contains("/")
            ? String(entry.name.split(separator: "/", maxSplits: 1)[1])
            : entry.name
        // The remote row of the CURRENT branch behaves exactly like
        // its local row: an instant "Already on" without closing the
        // picker (or a plain pull on Ctrl+Enter) — git would only
        // echo the same refusal after the picker is gone.
        let isTargetCurrent = entry.isCurrent
            || (entry.isRemote && branches.first(where: { $0.isCurrent })?.name == name)
        if isTargetCurrent {
            guard pullAfter else {
                delegate?.reportError("Already on \(name)")
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

    /// Menu-mode `d`/`D`: delete the selected branch through the
    /// shared command window. `d` is local only (`git branch -d` —
    /// git itself refuses the current branch and unmerged work, both
    /// visible in the output); `D` also deletes the remote
    /// counterpart — the remote leg is a follow-up, so it runs ONLY
    /// after the local deletion succeeded (an unmerged branch stops
    /// the chain). The remote is the branch's configured upstream
    /// (`name@{upstream}`), falling back to the repo's sole remote —
    /// several remotes with no upstream is refused with a message
    /// instead of guessing. The picker STAYS open: the finishing
    /// command refreshes the list (`gitCommandFinished`), the deleted
    /// entry drops out, the selection falls back to its row policy.
    /// The current branch is refused up front — git would only echo
    /// its own refusal — and so are remote-tracking rows: `branch -d`
    /// cannot touch them, a remote-side deletion is a different
    /// operation than this picker's `d`.
    private func deleteSelected(alsoRemote: Bool) {
        guard let entry = selectedEntry else { return }
        if entry.isCurrent {
            delegate?.reportError("Cannot delete the current branch")
            return
        }
        // A remote-tracking row is not a local branch — `branch -d`
        // cannot touch it; removing a remote branch is a remote-side
        // operation (a `git push --delete`), not this picker's `d`.
        if entry.isRemote {
            delegate?.reportError("Cannot delete a remote branch here — only local branches (D also removes the remote side)")
            return
        }
        let name = entry.name
        if alsoRemote {
            // A refused remote resolution (reported inside) aborts the
            // whole `D` — deleting only the local half of what the user
            // asked for would be a silent surprise.
            guard let remote = remoteForDeletion(of: name) else { return }
            delegate?.runGitCommand(
                label: "git branch -d \(name)", args: ["branch", "-d", name],
                then: (label: "git push \(remote) --delete \(name)", args: ["push", remote, "--delete", name]))
        } else {
            delegate?.runGitCommand(label: "git branch -d \(name)", args: ["branch", "-d", name])
        }
    }

    /// The remote a `D`-deletion would target: the branch's upstream
    /// (`origin/name` → `origin`), else the repo's single remote;
    /// nil — several remotes and no upstream, nothing to guess with.
    /// Reports the refusal itself. A LOCAL upstream (`remote = .`,
    /// the name comes back with no slash) is not a remote — it falls
    /// through to the sole-remote fallback instead of feeding a
    /// branch name to `git push`.
    private func remoteForDeletion(of name: String) -> String? {
        let workDir = workingDirectory
        let upstream = Shell.git(["rev-parse", "--abbrev-ref", "\(name)@{upstream}"], workDir: workDir)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !upstream.hasPrefix("fatal"), let slash = upstream.firstIndex(of: "/") {
            let remote = String(upstream[upstream.startIndex..<slash])
            if !remote.isEmpty { return remote }
        }
        let remotes = Shell.git(["remote"], workDir: workDir).stdout
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if remotes.count == 1 { return remotes[0] }
        delegate?.reportError("Branch '\(name)' has no upstream and the repo has \(remotes.count) remotes")
        return nil
    }

    override func poll() {
        guard let result = gitTask.consume() else { return }
        isRefreshing = false
        if let fetched = result {
            loadFailed = false
            isComplete = fetched.complete
            // Keeping is ownership-bound: a selection exists only in
            // menu mode, so even a keep-intent fetch (an external
            // refresh from a finishing git command) resets to the
            // first row when it lands mid-typing — the parked index
            // must not drift while the user types.
            let keptName = fetched.keepsSelection && !inputMode ? selectedEntry?.name : nil
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
