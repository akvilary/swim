import Foundation
import SwimCore

/// The fetch payload: the branch the listing answers to (for the
/// plate — `Log @ branch`, the panel's naming idiom), the
/// request-time (phase, query) — the landing's freshness guard — and
/// the outcome.
private struct LogFetch {
    let branch: String
    /// Request-time identity of the query this fetch answers to. The
    /// landing compares it with the CURRENT state and drops itself
    /// when they differ: BackgroundTask's newest-wins orders STARTS,
    /// but the UI can move without one — a backspace to a too-short
    /// hash (the early return in refresh starts nothing to supersede
    /// the in-flight query) or an i/f phase switch (which re-queries
    /// nothing). The last applied state stays instead of flashing a
    /// plate/list mismatch (the search window's epoch class; there
    /// the two tasks hold independent slots — here the epoch rides
    /// the one payload).
    let phase: GitLogWindow.SearchPhase
    let query: String
    let result: LogFetchResult
}

/// What a list fetch delivers. The four outcomes are kept apart so
/// the empty-list body can tell the truth: a resolved page, a
/// repository without commits (git refuses `log` on a fresh repo —
/// an honest state, not an error), an infrastructure failure (not a
/// repository / git broke), and a hash query that resolves to
/// nothing.
private enum LogFetchResult {
    /// `entries` — the page; `complete` — git exhausted the matches
    /// (fewer raw lines than the request-time `--count`, computed
    /// against RAW lines: the parser drops malformed ones and must
    /// not read as a short page); `keepsSelection` — captured at
    /// request time, the consumer's intent rides with the result
    /// (see refresh).
    case page(entries: [CommitLog.Entry], complete: Bool, keepsSelection: Bool)
    case noCommitsYet
    case loadFailed
    case hashNotFound
}

/// The commit diff payload: `git show`'s lines, or a failure flag —
/// stderr must never render as diff content (a gc between the list
/// and the show, an abbreviation that turned ambiguous after a
/// fetch: both turn `git show` non-zero without producing a diff).
private struct DiffFetch {
    let lines: [Substring]
    let failed: Bool
}

/// Git log window: the branch's commit history as a navigable list
/// (the git panel's former "Recent commits" section, grown up). The
/// shape mirrors the branch picker — the closest sibling among the
/// windows: `.menu` navigates a paginated git listing, `.insert`
/// types a query into the window's own input row, `.command` is the
/// standard `:q`. Differences that matter:
///
/// - The listing is `git log -n <limit> --format=%h|%s` of the
///   CURRENT branch (HEAD) — pagination grows `-n` page by page
///   (a page is 20) as the cursor approaches the loaded end, exactly
///   the picker's `--count` growth; git does the ordering, swim
///   never re-sorts.
/// - Two query phases over one list, each with its own buffer:
///   `i` — a case-insensitive LITERAL substring search over commit
///   messages (`-i --fixed-strings --grep`: no regex surprises — a
///   query with metacharacters stays a query; `--grep` searches the
///   full message, subject AND body, while rows show the subject);
///   `f` — a hash lookup: `rev-parse --verify <q>^{commit}` resolves
///   the prefix (git is the only authority on what a prefix names —
///   a branch or a tag resolves too, `^{commit}` peels it), then the
///   page runs from that commit. Both re-query git on every edit —
///   the first page of a longer query is NOT a subset of the page on
///   screen, so cache filtering would lie; BackgroundTask's
///   newest-wins coalesces a typing burst into the last query.
/// - `Enter` drills into the commit's diff — a READ-ONLY view (the
///   panel's file diffs carry hunk surgery; a commit is immutable
///   history, there is nothing to stage). Hash-addressed and
///   immutable: a list refresh never re-requests it, so no ordering
///   clock exists here (the panel needs one because its file diffs
///   mutate under refreshes).
/// - `y` copies the row's hash exactly as git printed it (`%h` — git
///   scales its width with repository size; a hard prefix could copy
///   an ambiguous token), `Y` the commit's full message (subject +
///   body, fetched on demand — rows carry subjects only).
///
/// Keys: `j/k/↑/↓` navigate (the prefetch fires within 5 rows of the
/// loaded page's end), `Enter` opens the diff, `y`/`Y` copy,
/// `i`/`f` enter the query phases, Esc closes. In insert, `↑/↓` and
/// Enter return to the list with the cursor on the first row; Esc
/// returns KEEPING the query — a log search is a session, not a view
/// tweak (the branch picker clears its filter on Esc; losing a typed
/// message query would be the worse accident; erasing the query to
/// empty restores the plain branch log through the same re-query
/// path). In the diff: `j/k`, `yy` copies lines, `V` visual, Esc
/// returns to the list.
class GitLogWindow: Window {
    override var availableModes: [WindowMode] { [.insert, .menu, .visualLine, .command] }

    /// A typing phase (message or hash query) is the window's insert
    /// mode; list navigation is menu mode.
    var inputMode: Bool { mode == .insert }

    /// One page of the listing: the initial `-n` and the growth step
    /// when the cursor approaches the page's end.
    private static let pageSize = 20
    /// How close to the page's end the cursor triggers the next page:
    /// five rows of headroom, so the 16th row of a 20-row page
    /// already fetches ahead.
    private static let prefetchMargin = 5
    /// A hash shorter than this resolves nothing in any repository
    /// (git's minimum abbreviation); shorter queries don't even ask.
    private static let minHashChars = 4

    // MARK: - List state

    private var commits: [CommitLog.Entry] = []
    /// The fetch+display window into the history: git is asked for
    /// exactly this many commits of the current query. Grows page by
    /// page on demand.
    private var listLimit = GitLogWindow.pageSize
    /// The loaded `commits` exhausted git's matches — no page can add
    /// anything.
    private var isComplete = false
    private(set) var isRefreshing = false
    /// The last fetch failed (not a repository) — the body says so
    /// instead of the misleading "no commits".
    private var loadFailed = false
    /// The repository has no commits yet (a fresh repo; git refuses
    /// `log`) — an honest state, distinct from a failure.
    private var noCommitsYet = false
    /// The branch the listing answers to — the plate's `@ branch` part
    /// (the panel's naming idiom). Empty until the first fetch lands
    /// and on an unborn branch (git refuses the probe there); detached
    /// HEAD reports "HEAD" and the plate says so, honestly.
    private var currentBranch: String = ""
    private let gitTask = BackgroundTask<LogFetch>()
    var spinnerFrame: Int = 0
    private static let spinnerChars: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    // MARK: - Query phases

    /// Which question the input row asks. The buffers are separate:
    /// a message query is never a hash prefix and vice versa, so a
    /// phase switch keeps each phase's typing for the session — and
    /// RE-QUERIES for the new phase (their empty queries mean
    /// different lists, so the old phase's result must not stand as
    /// if it answered the new one). Fileprivate: the fetch payload
    /// (LogFetch) carries the phase as its freshness epoch.
    fileprivate enum SearchPhase { case message, hash }
    private var searchPhase: SearchPhase = .message
    private var messageQuery: String = ""
    private var messageCursorPos: Int = 0
    private var hashQuery: String = ""
    private var hashCursorPos: Int = 0

    // MARK: - List view

    private var selectedIndex: Int = 0
    private var scrollOffset: Int = 0

    // MARK: - Commit diff view (read-only)

    private var showDiff = false
    private var diffHash: String = ""
    private var diffLines: [Substring] = []
    private var diffGutter: [DiffGutter.Entry] = []
    private var diffGutterWidth: Int = 4
    private var diffScrollOffset: Int = 0
    private var diffCursorRow: Int = 0
    /// Visual selection anchor for the diff's line-wise yank.
    private var diffVisualStart: Int = 0
    private var pendingY = false
    /// The diff fetch failed — the body says so; stderr is never
    /// rendered as diff content.
    private var diffFailed = false
    private(set) var isDiffLoading = false
    var diffSpinnerFrame: Int = 0
    private let diffTask = BackgroundTask<DiffFetch>()

    var workingDirectory: String = "" {
        // Assigned only by prepare (a fresh open): the reload must not
        // keep the previous visit's cursor — the fresh page parks on
        // HEAD.
        didSet { refresh(keepingSelection: false) }
    }

    /// The input line's prompt — a constant per phase, so drawing and
    /// caret math can never drift apart.
    private var activePrompt: String {
        searchPhase == .message ? " Message: " : " Hash: "
    }
    private var activeQuery: String {
        searchPhase == .message ? messageQuery : hashQuery
    }
    private var activeCursorPos: Int {
        searchPhase == .message ? messageCursorPos : hashCursorPos
    }

    /// The hash query as git sees it: trimmed (a pasted prefix often
    /// rides a space) and lowercased (object hex is lowercase; an
    /// uppercase paste would resolve nothing).
    private var normalizedHashQuery: String {
        hashQuery.trimmingCharacters(in: .whitespaces).lowercased()
    }
    /// The current query in the request pipeline's own normalization —
    /// the landing's freshness guard compares against this. Message
    /// queries ride raw (that is what --grep received); hash queries
    /// normalized.
    private var requestQuery: String {
        searchPhase == .message ? messageQuery : normalizedHashQuery
    }
    /// The hash phase has too little to resolve anything — no fetch
    /// runs; the page on screen stays and the tail (or, with no page,
    /// the body) says why. Showing the previous list here mirrors the
    /// picker: the old page stays while the new query has nothing to
    /// say yet.
    private var hashQueryTooShort: Bool {
        searchPhase == .hash && normalizedHashQuery.count < Self.minHashChars
    }

    /// True while the listing may have commits past the loaded page.
    private var mayHaveMore: Bool { !isComplete }

    private var selectedEntry: CommitLog.Entry? {
        guard commits.indices.contains(selectedIndex) else { return nil }
        return commits[selectedIndex]
    }

    // MARK: - Open / refresh

    /// Fresh open state: empty queries, first page only, the cursor
    /// parked on HEAD, list reloaded — a commit may have landed since
    /// the last visit. The previous visit's rows, verdicts AND branch
    /// are wiped too (the panel's prepareOpen idiom): stale rows —
    /// possibly a FILTERED subset — must not flash under a plate that
    /// no longer names their query, and a branch switched while the
    /// window was closed must not pretend; branch and rows ride one
    /// fetch and land in the same frame. The previous visit's DIFF is
    /// wiped the same way: the window can be closed straight out of
    /// it (Ctrl+X, the toggle, `:q` skip the Esc exit), and a stale
    /// diff of a dead session must not return.
    func prepare(workingDirectory: String) {
        searchPhase = .message
        messageQuery = ""
        messageCursorPos = 0
        hashQuery = ""
        hashCursorPos = 0
        commits = []
        currentBranch = ""
        loadFailed = false
        noCommitsYet = false
        selectedIndex = 0
        scrollOffset = 0
        listLimit = Self.pageSize
        isComplete = false
        showDiff = false
        diffHash = ""
        diffLines = []
        diffGutter = []
        diffGutterWidth = 4
        diffScrollOffset = 0
        diffCursorRow = 0
        diffVisualStart = 0
        pendingY = false
        diffFailed = false
        isDiffLoading = false
        headerPlate = nil
        mode = .menu
        self.workingDirectory = workingDirectory
        dirty = true
    }

    func refresh(keepingSelection: Bool = true) {
        guard !workingDirectory.isEmpty else { return }
        // The hash phase with a too-short prefix resolves nothing —
        // no fetch; the page on screen stays honest (the tail says
        // why), the previous result with it.
        guard !hashQueryTooShort else {
            isRefreshing = false
            dirty = true
            return
        }
        isRefreshing = true
        // A new fetch invalidates the previous failure verdicts — the
        // body shows the loading state, not a stale message.
        loadFailed = false
        noCommitsYet = false
        dirty = true
        // Captured at request time: a queued closure must carry the
        // query it was started for, immune to later keystrokes.
        let workDir = workingDirectory
        let limit = listLimit
        let phase = searchPhase
        let message = messageQuery
        let hash = normalizedHashQuery
        let keep = keepingSelection
        // The freshness epoch: exactly what the request pipeline sends
        // (requestQuery mirrors the normalization below).
        let epochPhase = phase
        let epochQuery = phase == .message ? message : hash
        gitTask.start {
            // The branch rides the same fetch: the plate names it
            // (`Log @ branch`). One probe per refresh, next to the
            // query itself — the panel fetches the same way.
            let branchResult = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], workDir: workDir)
            let branch = branchResult.exitCode == 0
                ? branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            var args = ["log", "-n", "\(limit)", "--format=%h|%s"]
            switch phase {
            case .message:
                // Literal substring match: --fixed-strings keeps a
                // query with regex metacharacters a query (an
                // unbalanced "[" would otherwise fail git's regex and
                // poison the failure verdicts). Empty query — no
                // --grep at all: the plain branch log, not
                // --grep=""'s coincidental "match everything".
                if !message.isEmpty {
                    args += ["-i", "--fixed-strings", "--grep=\(message)"]
                }
            case .hash:
                // Resolve the prefix first; then the page from that
                // commit (its row 0 is the commit itself, pagination
                // walks its ancestors). A joint argument starting
                // with "-" (a query like "-v") reads as an option to
                // git and fails cleanly — no injection surface, args
                // are an array. The failure is classified, not
                // flattened: outside a repository rev-parse dies with
                // its own fatal — reporting "no matching commit"
                // there would be a lie the message phase never tells.
                let resolve = Shell.git(
                    ["rev-parse", "--verify", "--quiet", "\(hash)^{commit}"],
                    workDir: workDir)
                guard resolve.exitCode == 0 else {
                    if resolve.stderr.contains("not a git repository") {
                        return LogFetch(branch: branch, phase: epochPhase, query: epochQuery, result: .loadFailed)
                    }
                    return LogFetch(branch: branch, phase: epochPhase, query: epochQuery, result: .hashNotFound)
                }
                let resolved = resolve.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !resolved.isEmpty else { return LogFetch(branch: branch, phase: epochPhase, query: epochQuery, result: .hashNotFound) }
                args.append(resolved)
            }
            let result = Shell.git(args, workDir: workDir)
            guard result.exitCode == 0 else {
                // Two honest failures, told apart by stderr — safe:
                // Shell pins children to English (AppLocale). A fresh
                // repository is a state, not an error.
                if result.stderr.contains("does not have any commits yet") {
                    return LogFetch(branch: branch, phase: epochPhase, query: epochQuery, result: .noCommitsYet)
                }
                return LogFetch(branch: branch, phase: epochPhase, query: epochQuery, result: .loadFailed)
            }
            // Completeness is git's own page fullness — the RAW line
            // count, not the parsed entries (the parser drops
            // malformed lines and must not read as a short page).
            let rawLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).count
            return LogFetch(branch: branch, phase: epochPhase, query: epochQuery,
                            result: .page(entries: CommitLog.parse(result.stdout),
                                         complete: rawLines < limit,
                                         keepsSelection: keep))
        }
    }

    // MARK: - Keys

    override func handleKey(_ key: Key) -> Bool {
        if showDiff {
            return handleDiffKey(key)
        }
        if inputMode {
            return handleInputKey(key)
        }
        switch key {
        case .char("j"), .down:
            moveSelection(1)
        case .char("k"), .up:
            moveSelection(-1)
        case .enter:
            if let entry = selectedEntry { runCommitDiff(entry.hash) }
        case .char("y"):
            if let entry = selectedEntry { Terminal.shared.osc52Copy(entry.hash) }
        case .char("Y"):
            copyFullMessage()
        case .char("i"):
            searchPhase = .message
            messageCursorPos = messageQuery.count
            mode = .insert
            // The switch re-queries: the phases' empty queries mean
            // different lists (message-empty — the plain branch log;
            // hash-empty — nothing yet), so the old phase's result
            // must not stand as if it answered the new one. Newest-
            // wins supersedes any fetch still in flight.
            refresh(keepingSelection: false)
            dirty = true
        case .char("f"):
            searchPhase = .hash
            hashCursorPos = hashQuery.count
            mode = .insert
            refresh(keepingSelection: false)
            dirty = true
        case .escape:
            // The list never enters visual mode (V is the diff's);
            // the guard is defensive parity with the panel.
            if mode == .visualLine { mode = .menu; dirty = true; return true }
            return false
        default:
            return false
        }
        return true
    }

    /// The insert phase owns neither the selection nor the action
    /// keys: ↑/↓ and Enter return to the list revealing the cursor on
    /// the first row; Esc does the same KEEPING the query (see the
    /// class comment). Every text edit re-queries git and parks the
    /// index on the first row (the typing phase shows no selection).
    private func handleInputKey(_ key: Key) -> Bool {
        switch key {
        case .escape, .up, .down, .enter:
            revealSelectionAtFirstRow()
        default:
            var text = activeQuery
            var cursor = activeCursorPos
            switch Self.applyLineEdit(key, text: &text, cursor: &cursor) {
            case .textChanged:
                setSearchQuery(text, cursor: cursor)
                selectedIndex = 0
                ensureVisible()
                refresh(keepingSelection: false)
                dirty = true
            case .caretOnly:
                setSearchQuery(text, cursor: cursor)
                dirty = true
            case .notEditing:
                break
            }
        }
        return true
    }

    private func setSearchQuery(_ text: String, cursor: Int) {
        switch searchPhase {
        case .message: messageQuery = text; messageCursorPos = cursor
        case .hash: hashQuery = text; hashCursorPos = cursor
        }
    }

    /// The insert→menu transition: the typing phase shows no
    /// selection, so leaving it always reveals the cursor on the
    /// first row — the next press moves from there.
    private func revealSelectionAtFirstRow() {
        mode = .menu
        selectedIndex = 0
        scrollOffset = 0
        dirty = true
    }

    /// The read-only diff's keys: navigation, line copy (`yy`), line
    /// visual yank, Esc back to the list (from visual — exit visual
    /// first). No hunk actions exist here by design: a commit is
    /// immutable history.
    private func handleDiffKey(_ key: Key) -> Bool {
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

    // MARK: - List mechanics

    private func moveSelection(_ delta: Int) {
        guard !commits.isEmpty else { return }
        selectedIndex = max(0, min(selectedIndex + delta, commits.count - 1))
        prefetchAhead()
        ensureVisible()
        dirty = true
    }

    /// The pager's trigger: reaching within `prefetchMargin` rows of
    /// the loaded page's end (the 16th row of a 20-row page) grows
    /// the page and refetches — one wider `-n` slice of the current
    /// query's matches, which git still orders newest first. Nothing
    /// to fetch while a fetch is already in flight (its result may
    /// already satisfy the cursor; the next keypress re-checks) or
    /// when the page is exhausted.
    private func prefetchAhead() {
        guard mayHaveMore, !isRefreshing,
              selectedIndex >= commits.count - Self.prefetchMargin else { return }
        listLimit += Self.pageSize
        refresh()
    }

    private func ensureVisible() {
        scrollOffset = Window.clampedScroll(
            selectedIndex: selectedIndex,
            scrollOffset: scrollOffset,
            visibleCount: max(0, height - 1))
    }

    private func resolveSelection(keeping hash: String?) {
        if let hash, let idx = commits.firstIndex(where: { $0.hash == hash }) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }
        ensureVisible()
    }

    // MARK: - Copy actions

    /// `Y` — the commit's full message (subject + body) to the
    /// clipboard. Fetched on demand: rows carry subjects only, and
    /// preloading bodies would waste bytes on every page. Sync on the
    /// main thread — the panel's `C` prefill makes the same call. A
    /// failure (the commit gc'ed between the list and the press) is
    /// reported, not swallowed into a silent empty copy.
    private func copyFullMessage() {
        guard let entry = selectedEntry else { return }
        let result = Shell.git(["show", "-s", "--format=%B", entry.hash], workDir: workingDirectory)
        guard result.exitCode == 0 else {
            var detail = result.stderr.split(separator: "\n").first.map(String.init) ?? ""
            detail = detail.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "fatal: ", with: "")
                .replacingOccurrences(of: "error: ", with: "")
            delegate?.reportError(detail.isEmpty ? "git show failed" : detail)
            return
        }
        // Trim only the ends — inner line breaks are the message.
        let message = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        Terminal.shared.osc52Copy(message)
    }

    // MARK: - Commit diff

    /// Enter — the commit's diff (`git show`). Read-only and
    /// hash-addressed: immutable, never re-requested by a refresh
    /// (unlike the panel's file diffs, no ordering clock exists
    /// here), so Esc returns to whatever fresh list the refreshes
    /// delivered meanwhile.
    private func runCommitDiff(_ hash: String) {
        diffHash = hash
        diffLines = []
        diffGutter = []
        diffGutterWidth = 4
        diffScrollOffset = 0
        diffCursorRow = 0
        diffVisualStart = 0
        diffFailed = false
        isDiffLoading = true
        showDiff = true
        mode = .menu
        pendingY = false
        dirty = true
        let workDir = workingDirectory
        diffTask.start {
            let result = Shell.git(["show", hash], workDir: workDir)
            guard result.exitCode == 0 else {
                return DiffFetch(lines: [], failed: true)
            }
            return DiffFetch(
                lines: result.combined.split(separator: "\n", omittingEmptySubsequences: false),
                failed: false)
        }
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

    private func yankDiffLines(_ range: ClosedRange<Int>) {
        guard range.lowerBound >= 0, range.upperBound < diffLines.count else { return }
        var text = ""
        for i in range {
            text += diffLines[i] + "\n"
        }
        Terminal.shared.osc52Copy(text)
    }

    // MARK: - Poll

    override func poll() {
        var anyUpdate = false

        if isDiffLoading, let fetch = diffTask.consume() {
            isDiffLoading = false
            if fetch.failed {
                diffFailed = true
                diffLines = []
                diffGutter = []
                diffGutterWidth = 4
            } else {
                diffLines = fetch.lines
                let parsed = DiffGutter.parse(diffLines)
                diffGutter = parsed.entries
                diffGutterWidth = parsed.width
            }
            anyUpdate = true
        }

        if let fetch = gitTask.consume() {
            isRefreshing = false
            // The freshness guard: a landing for a query the user has
            // since left is dropped whole (branch included) — the last
            // applied state stays. isRefreshing's flip still repaints
            // (the "… loading" tail goes away).
            if fetch.phase == searchPhase && fetch.query == requestQuery {
                currentBranch = fetch.branch
                switch fetch.result {
                case .page(let entries, let complete, let keepsSelection):
                    isComplete = complete
                    loadFailed = false
                    noCommitsYet = false
                    // Keeping is ownership-bound: a selection exists only
                    // in menu mode, so even a keep-intent fetch (an
                    // external refresh from a finished git command) resets
                    // to the first row when it lands mid-typing — the
                    // parked index must not drift while the user types.
                    let keptHash = keepsSelection && !inputMode ? selectedEntry?.hash : nil
                    commits = entries
                    resolveSelection(keeping: keptHash)
                case .noCommitsYet:
                    noCommitsYet = true
                    commits = []
                    isComplete = true
                    selectedIndex = 0
                    ensureVisible()
                case .loadFailed:
                    loadFailed = true
                    commits = []
                    isComplete = false
                    selectedIndex = 0
                    ensureVisible()
                case .hashNotFound:
                    commits = []
                    isComplete = true
                    selectedIndex = 0
                    ensureVisible()
                }
            }
            anyUpdate = true
        }

        if anyUpdate {
            dirty = true
            delegate?.requestRender()
        }
    }

    // MARK: - Drawing

    override func update() {
        clear()
        if showDiff {
            drawDiff()
        } else {
            // The input row owns row 0 in insert mode — the plate must
            // not linger (a set headerPlate would shift contentTop and
            // with it the diff geometry on the next switch).
            if inputMode {
                headerPlate = nil
                drawInputLine()
            } else {
                drawPlateHeader()
            }
            drawCommitList()
        }
    }

    /// The typing surface — the branch picker's input row: prompt +
    /// query in the plate colors; the caret itself is the terminal's
    /// insert bar (see cursorRenderInfo). The visible window into the
    /// text follows the shared pure policy (`InputLine`, SwimCore —
    /// tested, cell-aware: wide graphemes occupy two cells).
    private func drawInputLine() {
        let prompt = activePrompt
        let text = activeQuery
        let caret = activeCursorPos
        drawLine(prompt, row: 0, col: 0, fg: Theme.fg, bg: Theme.bgHighlight, bold: true)
        let maxInput = max(0, width - prompt.count - 2)
        let win = InputLine.window(text: text, caret: caret, capacity: maxInput)
        let displayText = String(text.dropFirst(win.start).prefix(win.visibleCount))
        drawLine(displayText, row: 0, col: prompt.count, fg: Theme.fg, bg: Theme.bgHighlight)
        // Fill the whole tail so no stray dark cell trails the text
        // once the cursor moves away from its end (measured in cells).
        for i in min(width, max(0, prompt.count + win.visibleCells))..<width {
            setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
        }
    }

    /// The typing caret is a terminal cursor — the shared insert-mode
    /// bar every typing surface shows. Menu mode owns no typing
    /// surface: no cursor, the renderer falls back to its navigation
    /// default.
    override func cursorRenderInfo() -> CursorRenderInfo? {
        guard visible, focused, mode == .insert, !showDiff else { return nil }
        let prompt = activePrompt
        let text = activeQuery
        let caret = activeCursorPos
        let maxInput = max(0, width - prompt.count - 2)
        let win = InputLine.window(text: text, caret: caret, capacity: maxInput)
        let col = prompt.count + win.caretOffset
        guard col >= 0, col < width else { return nil }
        return .insertCaret(row: y, col: x + col)
    }

    /// The plate's title: `Log @ branch` (the panel's naming idiom —
    /// no "@ branch" until the first fetch lands, none on an unborn
    /// branch), `Found by … @ branch` while a query is active (the
    /// input row is not visible in menu mode — the title is the only
    /// reminder that the list is filtered).
    private var plateTitle: String {
        let branch = currentBranch.isEmpty ? "" : " @ \(currentBranch)"
        switch searchPhase {
        case .message:
            let q = messageQuery.trimmingCharacters(in: .whitespaces)
            return q.isEmpty ? "Log\(branch)" : "Found by \"\(q)\"\(branch)"
        case .hash:
            let q = normalizedHashQuery
            return q.isEmpty ? "Log\(branch)" : "Found by hash \(q)\(branch)"
        }
    }

    private func drawPlateHeader() {
        if isRefreshing, commits.isEmpty {
            // Nothing on screen yet — say so in the plate, spinner in
            // the body below.
            let spinner = Self.spinnerChars[spinnerFrame % Self.spinnerChars.count]
            headerPlate = HeaderPlate(text: " \(spinner) \(plateTitle) ", fg: Theme.blue)
            drawPlate()
            return
        }
        headerPlate = HeaderPlate(
            text: " \(plateTitle) (Enter: diff, y/Y: copy hash/message, i: search, f: by hash, Esc: close) ",
            fg: Theme.orange)
        drawPlate()
    }

    private func drawCommitList() {
        let list = commits
        let visibleH = max(0, height - 1)
        scrollOffset = Window.clampedScroll(selectedIndex: selectedIndex, scrollOffset: scrollOffset, visibleCount: visibleH)

        if list.isEmpty {
            if isRefreshing {
                let spinner = Self.spinnerChars[spinnerFrame % Self.spinnerChars.count]
                let msg = "\(spinner) Loading commits..."
                let midRow = max(1, height / 2)
                let startCol = max(0, (width - msg.count - 2) / 2)
                for (i, c) in msg.enumerated() where startCol + i < width {
                    setCell(midRow, startCol + i, Cell.colored(c, fg: Theme.blue, bg: Theme.bgDark, bold: true))
                }
                return
            }
            let msg: String
            if hashQueryTooShort {
                msg = " Type at least \(Self.minHashChars) characters of the hash"
            } else if loadFailed {
                msg = " Not a git repository"
            } else if noCommitsYet {
                msg = " No commits yet"
            } else {
                msg = " No matching commits"
            }
            drawLine(msg, row: 1, fg: Theme.comment)
            return
        }

        for row in 0..<visibleH {
            let idx = scrollOffset + row
            guard idx < list.count else { break }
            let entry = list[idx]
            // The typing phase shows no selection: the cursor row
            // appears only in menu mode.
            let selected = !inputMode && idx == selectedIndex
            let hl = Cell.highlight(selected, tint: Theme.bgHighlight, base: Theme.bgDark)
            let bg: Color = hl.bg
            fillRegion(row: row + 1, col: 0, width: width, height: 1, cell: Cell.colored(" ", fg: Theme.fg, bg: bg, reverse: hl.reverse))
            // The row format the git panel's commits section used:
            // short hash + subject, the hash verbatim (%h — git
            // scales its width; rows and `y` copy the same token).
            drawLine(" \(entry.hash) \(entry.subject)", row: row + 1, fg: Theme.cyan, bg: bg, reverse: hl.reverse)
        }

        // The pager's tail — only when it may mean something: more
        // matches past the page, a fetch in flight, or the hash phase
        // waiting for enough characters to resolve anything.
        if hashQueryTooShort || mayHaveMore || isRefreshing {
            let footerRow = 1 + list.count - scrollOffset
            if footerRow >= 1, footerRow < height {
                let msg: String
                if hashQueryTooShort {
                    msg = " type at least \(Self.minHashChars) hash characters"
                } else if isRefreshing {
                    msg = " … loading"
                } else {
                    msg = " …more"
                }
                drawLine(msg, row: footerRow, fg: Theme.comment)
            }
        }
    }

    private func drawDiff() {
        let title = "COMMIT \(diffHash)"
        if isDiffLoading {
            let spinner = Self.spinnerChars[diffSpinnerFrame % Self.spinnerChars.count]
            headerPlate = HeaderPlate(text: " \(spinner) \(title) ", fg: Theme.blue)
            drawPlate()
            let msg = "\(spinner) Loading..."
            let midRow = height / 2
            let startCol = max(0, (width - msg.count - 2) / 2)
            for (i, c) in msg.enumerated() where startCol + i < width {
                setCell(midRow, startCol + i, Cell.colored(c, fg: Theme.blue, bg: Theme.bgDark, bold: true))
            }
            return
        }
        if diffFailed {
            headerPlate = HeaderPlate(text: " \(title) ", fg: Theme.comment)
            drawPlate()
            drawLine(" Failed to load commit", row: max(contentTop, height / 2), fg: Theme.comment)
            return
        }
        if diffLines.isEmpty {
            headerPlate = HeaderPlate(text: " \(title) (empty) ", fg: Theme.comment)
            drawPlate()
            drawLine("No changes", row: height / 2, col: max(0, (width - 10 - 2) / 2), fg: Theme.comment)
            return
        }
        if mode == .visualLine {
            headerPlate = HeaderPlate(text: " [ VISUAL ] \(title) (y: copy, Esc: cancel) ", fg: Theme.purple)
        } else {
            headerPlate = HeaderPlate(text: " \(title) (yy: copy, V: visual, Esc: back) ", fg: Theme.fg)
        }
        drawPlate()
        drawDiffRows(
            diffLines: diffLines,
            gutter: diffGutter,
            gutterWidth: diffGutterWidth,
            scrollOffset: diffScrollOffset,
            cursorRow: diffCursorRow,
            visualRange: mode == .visualLine ? diffVisualRange() : nil)
    }
}

extension GitLogWindow: SpinnerWindow {
    var spinnerActive: Bool { visible && (isRefreshing || isDiffLoading) }
    func tickSpinner() {
        // The list spinner animates (picker-style); the diff spinner
        // has its own frame.
        if isDiffLoading { diffSpinnerFrame &+= 1 } else { spinnerFrame &+= 1 }
        dirty = true
    }
}
