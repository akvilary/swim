import Foundation
import SwimCore

class SearchResultsWindow: Window {
    override var availableModes: [WindowMode] { [.insert, .menu, .command] }

    /// A file's freshness fingerprint — size + modification time
    /// captured when the scan read it. A same-looking stat later means
    /// the file's search data is still current (best-effort, like
    /// every mtime scheme: a same-second, same-size edit is
    /// invisible without a watcher, which this app deliberately
    /// does not run).
    private struct Fingerprint {
        let size: Int
        let mtime: Date
    }

    /// What a background pass delivers: the search root (correctness
    /// never depends on when the mailbox is consumed — polling is
    /// space-local), the full flat result set, and the leaf files'
    /// fingerprints at read time.
    private typealias ScanPayload = (root: String, results: [SearchResult], stats: [String: Fingerprint])

    private(set) var results: [SearchResult] = []
    /// The results as a tree rooted at the working directory (the pure
    /// SwimCore `SearchTree.build`): every path component from the
    /// root down to a matched file is a navigable expand/collapse
    /// level — the full chain, not the old single-level
    /// "parent dir → file" grouping.
    private(set) var resultRoot: SearchTree.DirNode?
    private(set) var selectedIndex: Int = 0
    /// Expansion keys are the nodes' absolute paths (NOT state on the
    /// nodes): the tree is rebuilt on every search, path keys survive
    /// the rebuild — a directory re-expanded after a re-query stays
    /// expanded for the results that return.
    private(set) var expandedDirs: Set<String> = []
    private(set) var expandedFiles: Set<String> = []
    private var scrollOffset: Int = 0
    private var horizontalOffset: Int = 0
    private let horizontalStep: Int = 4
    private var flatItems: [SearchItem] = []
    private var flatItemsDirty: Bool = false
    /// The full-scan task. The refresh task below shares the payload
    /// type; both are single-slot newest-wins, so a live per-file
    /// refresh and a reopen stat-walk over the same file collapse
    /// into one read.
    private let searchTask = BackgroundTask<ScanPayload>()
    /// Per-file freshness passes: re-read and re-search ONLY the
    /// changed leaf files (never the repository), landing as an
    /// in-place tree rebuild.
    private let refreshTask = BackgroundTask<ScanPayload>()
    /// The leaf files' fingerprints as of their last read — the
    /// side-table the freshness checks walk (the tree nodes stay
    /// read-only core data; this is window-owned scan state).
    private var fileStats: [String: Fingerprint] = [:]
    /// Session state exists — a search completed this app session.
    /// Armed by pollSearch, disarmed by search() (a new query
    /// invalidates the old state; re-armed when its result lands).
    /// Reopening the space with state restores the tree in menu mode;
    /// only the session's first open lands in the query input.
    private(set) var hasSessionState: Bool = false
    /// The last EXECUTED query — what the displayed tree answers to.
    /// Set by search(); newest-wins guarantees it matches whatever the
    /// mailbox holds, the same argument that puts the root in the
    /// payload.
    private(set) var lastQuery: String = ""
    var workingDirectory: String = ""
    private(set) var isSearching: Bool = false
    /// A restore-time refresh is running: the STALE tree is deliberately
    /// not shown (showing it, then rebuilding, would visibly jump the
    /// cursor) — the body stays blank for the moment the refresh takes,
    /// the landing reveals the fresh tree in one frame. The plate is
    /// deliberately untouched (a `refreshing...` state would flicker on
    /// a refresh that takes milliseconds; the count simply updates in
    /// the landing frame). Live refreshes (while the user watches the
    /// tree) do NOT set this — in-place updates are the point there.
    private(set) var isRefreshing: Bool = false
    /// The query-input phase is the window's insert mode; results
    /// navigation is menu mode.
    var inputMode: Bool { mode == .insert }
    private(set) var inputBuffer: String = ""
    private(set) var inputCursorPos: Int = 0

    func prepareInput(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        mode = .insert
        inputBuffer = ""
        inputCursorPos = 0
        dirty = true
    }

    /// Opening the search space. Three honest branches:
    /// - session state (a completed search this app session) → the
    ///   saved tree returns in MENU mode — query in the plate, cursor
    ///   and expansions where they were — after a freshness walk;
    /// - a scan still in flight → menu mode with the scanning plate;
    ///   the result lands into it when consumed (polling is
    ///   space-local);
    /// - the session's first open → the query input (the editor's last
    ///   `/` query pre-runs, as it always has).
    func reopen(workingDirectory: String, prefillQuery: String?) {
        self.workingDirectory = workingDirectory
        if hasSessionState || isSearching {
            mode = .menu
            if !isSearching {
                // The walk is synchronous (microseconds per leaf): the
                // common no-change case shows the tree instantly; with
                // changes, the stale tree stays hidden until the
                // refresh lands — showing it and rebuilding a beat
                // later would visibly jump the cursor.
                isRefreshing = refreshStaleFiles()
            }
            // The preview follows the restored cursor row (both
            // windows persisted; this re-binds them explicitly).
            ensureFlatItems()
            notifyPreviewUpdate()
        } else {
            prepareInput(workingDirectory: workingDirectory)
            if let q = prefillQuery, !q.isEmpty {
                search(query: q, in: workingDirectory)
            }
        }
        dirty = true
    }

    // MARK: - Per-file freshness

    /// The live trigger: a file changed (an editor save, a rewrite the
    /// tab-mtime machinery detected — the Application forwards each
    /// existing event here; no loops, no watchers). An O(1) guard
    /// turns away everything that would be wasted work: the space
    /// must be open (a rebuild nobody watches is idle work — while
    /// closed, freshness is reconstructed at reopen by the stat-walk)
    /// and the file must be a leaf of the current tree; only then ONE
    /// background re-read and re-search of that file — never the
    /// repository.
    func refreshFileIfInSession(_ path: String) {
        guard visible, hasSessionState, !isSearching, fileStats[path] != nil else { return }
        startRefresh(changedPaths: [path])
    }

    /// The reopen walk: stat every leaf of the tree against its scan
    /// fingerprint. Unchanged — nothing runs, the data is current
    /// (the common case, paid in microseconds per file); changed —
    /// one background pass re-reads and re-searches exactly those
    /// files. An unstattable file (deleted) counts as changed: its
    /// re-read fails and its results drop out. Returns whether a
    /// refresh was started (the caller hides the stale tree until it
    /// lands — no visible cursor jump).
    @discardableResult
    private func refreshStaleFiles() -> Bool {
        guard let root = resultRoot else { return false }
        var changed: [String] = []
        walkLeaves(root) { file in
            if let fp = fileStats[file.path], Self.fileChanged(file.path, since: fp) {
                changed.append(file.path)
            }
        }
        guard !changed.isEmpty else { return false }
        startRefresh(changedPaths: changed)
        return true
    }

    /// Re-reads and re-searches ONLY the changed leaf files with the
    /// session's query, delivering the updated full payload. Their
    /// old results leave the set, the new ones (possibly none — the
    /// file's branch then collapses away in the rebuild, because
    /// SearchTree only materializes directories on paths to matched
    /// files) take their place; fingerprints re-arm at read time.
    /// Bumped by every search() — the freshness epoch. A refresh
    /// captures it at start; its landing drops the payload when a
    /// search has run since: the two tasks hold independent single
    /// slots, and newest-wins works WITHIN a slot, not across — an
    /// in-flight refresh computed from pre-search state must never
    /// clobber the new search's results.
    private var searchGeneration = 0
    private var refreshGenAtStart = 0

    private func startRefresh(changedPaths: [String]) {
        guard let rootPath = resultRoot?.path, !lastQuery.isEmpty else { return }
        refreshGenAtStart = searchGeneration
        let query = lastQuery
        let oldResults = results
        let oldStats = fileStats
        let changed = Set(changedPaths)
        refreshTask.start {
            var results = oldResults.filter { !changed.contains($0.filePath) }
            var stats = oldStats
            let fm = FileManager.default
            for path in changedPaths {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                   let content = String(data: data, encoding: .utf8) {
                    var found = [SearchResult]()
                    SearchResultsWindow.searchIn(content: content, filePath: path, query: query, results: &found)
                    results.append(contentsOf: found)
                    let attrs = try? fm.attributesOfItem(atPath: path)
                    stats[path] = Fingerprint(
                        size: (attrs?[.size] as? NSNumber)?.intValue ?? data.count,
                        mtime: (attrs?[.modificationDate] as? Date) ?? Date())
                } else {
                    // Unreadable or deleted — the file's results are
                    // gone; its fingerprint must not linger either.
                    stats.removeValue(forKey: path)
                }
            }
            return (root: rootPath, results: results, stats: stats)
        }
    }

    /// The refresh landing: an in-place rebuild. The selection is
    /// preserved by its file anchor (see applyPayload) — matches may
    /// have shifted, the cursor stays with its file or clamps. A
    /// payload from before the latest search (the interleaving guard
    /// above) is dropped here — consumed, never applied; either way
    /// the hidden-restore state ends (a superseding search owns the
    /// view with its scanning plate).
    private func pollRefresh() {
        guard let payload = refreshTask.consume() else { return }
        let wasHiddenRestore = isRefreshing
        isRefreshing = false
        guard refreshGenAtStart == searchGeneration else {
            if wasHiddenRestore { dirty = true; delegate?.requestRender() }
            return
        }
        applyPayload(payload, preservingCursor: true)
    }

    /// Size+mtime vs the recorded fingerprint; an unstattable file is
    /// changed (deleted files must fall out of the tree).
    private static func fileChanged(_ path: String, since fp: Fingerprint) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = (attrs?[.size] as? NSNumber)?.intValue,
              let mtime = attrs?[.modificationDate] as? Date else { return true }
        return size != fp.size || mtime != fp.mtime
    }

    /// Every file leaf of the tree, in tree order.
    private func walkLeaves(_ dir: SearchTree.DirNode, _ visit: (SearchTree.FileNode) -> Void) {
        for child in dir.dirs { walkLeaves(child, visit) }
        for file in dir.files { visit(file) }
    }

    /// Installs a scan or refresh payload: the tree is rebuilt from
    /// the flat results (expansions survive by path keys; emptied
    /// branches and files cannot exist in a built tree), the preview
    /// is re-notified, and — for refresh landings — the selection
    /// follows its FILE anchor: the file owning the selected row
    /// (a match line belongs to its file, a branch to itself); the
    /// first row of that file after the rebuild, clamped when the
    /// anchor is gone entirely.
    private func applyPayload(_ payload: ScanPayload, preservingCursor: Bool) {
        let anchor = preservingCursor ? selectedFileAnchor() : nil
        results = payload.results
        fileStats = payload.stats
        resultRoot = SearchTree.build(results: payload.results, root: payload.root)
        flatItemsDirty = true
        ensureFlatItems()
        if let anchor, let idx = flatItems.firstIndex(where: { rowOwnerPath($0) == anchor }) {
            selectedIndex = idx
        } else if preservingCursor {
            selectedIndex = min(selectedIndex, max(0, flatItems.count - 1))
        } else {
            selectedIndex = 0
            scrollOffset = 0
        }
        ensureVisible()
        notifyPreviewUpdate()
        dirty = true
        delegate?.requestRender()
    }

    /// The file/branch path that owns the selected row — the anchor a
    /// rebuild tries to keep the cursor with.
    private func selectedFileAnchor() -> String? {
        guard selectedIndex >= 0, selectedIndex < flatItems.count else { return nil }
        return rowOwnerPath(flatItems[selectedIndex])
    }

    private func rowOwnerPath(_ item: SearchItem) -> String? {
        switch item {
        case .directory(let node, _): return node.path
        case .file(let node, _): return node.path
        case .result(let r, _): return r.filePath
        }
    }

    /// A visible row. Directory and file rows carry their tree node
    /// (its `path` is the expansion key, its `matchCount` the row's
    /// count); result rows carry the match and the depth they indent
    /// to — one past their file.
    private enum SearchItem {
        case directory(SearchTree.DirNode, Int)
        case file(SearchTree.FileNode, Int)
        case result(SearchResult, Int)
    }

    override func update() {
        clear()

        drawHeader()

        // A restore-time refresh hides the body: the stale tree must
        // not appear for the instant before the fresh one replaces it
        // (the cursor jump). The plate stays as it was — a transient
        // `refreshing` label would flicker on a milliseconds refresh.
        if !inputMode && !isRefreshing {
            drawResults()
        }
    }

    private func drawHeader() {
        if inputMode {
            let prompt = " Search: "
            drawLine(prompt, row: 0, col: 0, fg: Theme.fg, bg: Theme.bgHighlight, bold: true)
            let maxInput = width - prompt.count - 2
            let win = InputLine.window(text: inputBuffer, caret: inputCursorPos, capacity: max(0, maxInput))
            let displayText = String(inputBuffer.dropFirst(win.start).prefix(win.visibleCount))
            drawLine(displayText, row: 0, col: prompt.count, fg: Theme.fg, bg: Theme.bgHighlight)
            // Fill the whole tail — starting one past the text would leave a
            // stray dark cell right after the last character once the
            // cursor moves away from it. Measured in cells (visibleCells),
            // not characters.
            for i in min(width, max(0, prompt.count + win.visibleCells))..<width {
                setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
            }
        } else {
            // The two-row plate: the query on row 0, the count and
            // the one non-obvious key on row 1 (the git panel's
            // `key: action` idiom). A narrow panel truncates the
            // tail; the count leads row 1, the query leads row 0.
            let queryLine = lastQuery.isEmpty ? " Search " : " Search \"\(lastQuery)\""
            drawPlateLine(queryLine, row: 0)
            if isSearching {
                drawPlateLine(" scanning... ", row: 1)
            } else {
                drawPlateLine(" \(results.count) matches (i: new search) ", row: 1)
            }
        }
    }

    /// One plate row in the base drawHeader's style (that one is
    /// hardwired to row 0; the plate here spans two).
    private func drawPlateLine(_ text: String, row: Int) {
        let visible = text.prefix(width)
        for (i, c) in visible.enumerated() {
            setCell(row, i, Cell.colored(c, fg: Theme.fg, bg: Theme.bgHighlight, bold: true))
        }
        for i in visible.count..<width {
            setCell(row, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
        }
    }

    private func drawResults() {
        ensureFlatItems()
        // Two plate rows above the tree — the single constant every
        // height computation shares.
        let visibleH = max(0, height - plateRowCount)
        for row in 0..<visibleH {
            let itemIdx = scrollOffset + row
            guard itemIdx < flatItems.count else { break }
            let isSelected = itemIdx == selectedIndex
            let bg: Color = isSelected ? Theme.bgHighlight : Theme.bgDark
            let y = row + plateRowCount

            switch flatItems[itemIdx] {
            case .directory(let node, let depth):
                let expanded = expandedDirs.contains(node.path)
                let icon = expanded ? "▾ " : "▸ "
                let text = String(repeating: " ", count: depth * 2) + icon + node.name + " (\(node.matchCount))"
                let cells = Self.textCells(text, fg: Theme.blue, bg: bg, bold: true)
                drawCells(cells, row: y, offset: horizontalOffset, fillFg: Theme.fg, fillBg: bg)
            case .file(let node, let depth):
                let expanded = expandedFiles.contains(node.path)
                let icon = expanded ? "▾ " : "▸ "
                let text = String(repeating: " ", count: depth * 2) + icon + node.name + " (\(node.matchCount))"
                let cells = Self.textCells(text, fg: Theme.fgDark, bg: bg)
                drawCells(cells, row: y, offset: horizontalOffset, fillFg: Theme.fg, fillBg: bg)
            case .result(let result, let depth):
                // The whole WORD containing the match (MatchWord —
                // SwimCore, tested): the match colored inside its word,
                // bounded by spaces/brackets/quotes/punctuation, clipped
                // by the window edge. This replaced the old pre-match
                // character window — a left-trimmed fragment cut
                // mid-word, unreadable — and with it the windowing
                // arithmetic (the clamped prefix math of the old row).
                let indent = String(repeating: " ", count: depth * 2)
                let linePrefix = "\(indent)\(result.lineNumber): "
                let chars = Array(result.lineContent)
                let wordSpan = MatchWord.span(
                    chars: chars, matchStart: result.matchStart, matchLength: result.matchLength,
                    maxCells: max(1, width))
                let matchStart = min(result.matchStart, chars.count)
                let matchEnd = min(matchStart + result.matchLength, chars.count)
                let dim: Color = isSelected ? Theme.fg : Theme.fgDark
                var cells = Self.textCells(linePrefix, fg: Theme.comment, bg: bg)
                if wordSpan.start < matchStart {
                    cells += Self.textCells(String(chars[wordSpan.start..<matchStart]), fg: dim, bg: bg)
                }
                cells += Self.textCells(String(chars[matchStart..<matchEnd]), fg: Theme.orange, bg: bg, bold: true)
                if matchEnd < wordSpan.end {
                    cells += Self.textCells(String(chars[matchEnd..<wordSpan.end]), fg: dim, bg: bg)
                }
                drawCells(cells, row: y, offset: horizontalOffset, fillFg: dim, fillBg: bg)
            }
        }
    }

    /// Flattens the visible part of the tree: a node's children appear
    /// only while it is expanded. Depth drives the row indent: a file
    /// sits at its parent directory's depth + 1, a match line one past
    /// its file. The branch row an action acts on always persists
    /// through the rebuild (only its children vanish below), so an
    /// index pointing at a branch stays valid across it.
    private func buildFlatItems() {
        flatItems = []
        appendDir(resultRoot, depth: 0)
    }

    private func appendDir(_ dir: SearchTree.DirNode?, depth: Int) {
        guard let dir else { return }
        flatItems.append(.directory(dir, depth))
        guard expandedDirs.contains(dir.path) else { return }
        let childDepth = depth + 1
        for child in dir.dirs {
            appendDir(child, depth: childDepth)
        }
        for file in dir.files {
            flatItems.append(.file(file, childDepth))
            if expandedFiles.contains(file.path) {
                for result in file.results {
                    flatItems.append(.result(result, childDepth + 1))
                }
            }
        }
    }

    /// Every list-reading path (the renderer, the key handlers) goes
    /// through here: a rebuild happens exactly once per dirty flag, so
    /// each consumer sees the CURRENT list. Without this in the key
    /// handlers, a j after an Enter-collapse would bound-check against
    /// the stale (longer) list and could step the selection past the
    /// real end — an invisible, silently drifting cursor.
    private func ensureFlatItems() {
        guard flatItemsDirty else { return }
        buildFlatItems()
        flatItemsDirty = false
    }

    /// Row depth — the TreeListNavigation policy's view of the list.
    private func depth(of item: SearchItem) -> Int {
        switch item {
        case .directory(_, let depth), .file(_, let depth), .result(_, let depth):
            return depth
        }
    }

    func search(query: String, in directory: String) {
        guard !query.isEmpty else { return }
        workingDirectory = directory
        lastQuery = query
        // A new query invalidates the session state; pollSearch re-arms
        // the flag when this search's result lands. The epoch bump also
        // invalidates any refresh still in flight (see pollRefresh).
        hasSessionState = false
        searchGeneration += 1
        isRefreshing = false
        results = []
        resultRoot = nil
        fileStats = [:]
        selectedIndex = 0
        scrollOffset = 0
        horizontalOffset = 0
        isSearching = true
        dirty = true
        flatItemsDirty = true

        let dir = directory
        searchTask.start { [dir] in
            var found = [SearchResult]()
            var stats = [String: Fingerprint]()
            let fm = FileManager.default
            let enumerator = fm.enumerator(atPath: dir)
            let excludedDirs: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData"]
            while let relPath = enumerator?.nextObject() as? String {
                let fullPath = (dir as NSString).appendingPathComponent(relPath)
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                if isDir.boolValue {
                    let dirName = (relPath as NSString).lastPathComponent
                    if excludedDirs.contains(dirName) { enumerator?.skipDescendants() }
                    continue
                }
                let ext = (relPath as NSString).pathExtension
                let binaryExts: Set<String> = ["png", "jpg", "jpeg", "gif", "pdf", "zip", "gz", "o", "so", "dylib", "a"]
                if binaryExts.contains(ext) { continue }
                if let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath), options: .mappedIfSafe),
                   let content = String(data: data, encoding: .utf8) {
                    let before = found.count
                    SearchResultsWindow.searchIn(content: content, filePath: fullPath, query: query, results: &found)
                    if found.count > before {
                        // Fingerprint the files the session actually
                        // tracks — the matched leaves.
                        let attrs = try? fm.attributesOfItem(atPath: fullPath)
                        stats[fullPath] = Fingerprint(
                            size: (attrs?[.size] as? NSNumber)?.intValue ?? data.count,
                            mtime: (attrs?[.modificationDate] as? Date) ?? Date())
                    }
                }
            }
            return (root: dir, results: found, stats: stats)
        }
    }

    override func poll() {
        pollSearch()
        pollRefresh()
    }

    func pollSearch() {
        guard let found = searchTask.consume() else { return }
        isSearching = false
        applyPayload(found, preservingCursor: false)
        // A fresh result set is a fresh navigation session: cursor at
        // the root row, view at the top — self-contained, not relying
        // on the start-of-search reset having survived the scanning
        // window. Nothing auto-expands — the tree lands collapsed on
        // its root row; the user opens the nodes they need (Enter/`l`
        // descend to the first child, the explorer's mechanic).
        hasSessionState = true
    }

    private static func searchIn(content: String, filePath: String, query: String, results: inout [SearchResult]) {
        let lines = content.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            if let range = line.range(of: query, options: .caseInsensitive) {
                results.append(SearchResult(
                    filePath: filePath, lineNumber: idx + 1, lineContent: line,
                    matchStart: line.distance(from: line.startIndex, to: range.lowerBound),
                    matchLength: line.distance(from: range.lowerBound, to: range.upperBound)
                ))
            }
        }
    }

    /// The query-input caret is a terminal cursor — the shared
    /// insert-mode bar every typing surface shows (see
    /// CursorRenderInfo.insertCaret), not a faked inverted cell.
    override func cursorRenderInfo() -> CursorRenderInfo? {
        guard visible, focused, inputMode else { return nil }
        let prompt = " Search: ".count
        let maxInput = max(0, width - prompt - 2)
        let win = InputLine.window(text: inputBuffer, caret: inputCursorPos, capacity: maxInput)
        let col = prompt + win.caretOffset
        guard col >= 0, col < width else { return nil }
        return .insertCaret(row: y, col: x + col)
    }

    override func handleKey(_ key: Key) -> Bool {
        if inputMode {
            return handleInputKey(key)
        }
        ensureFlatItems()
        switch key {
        case .char("j"), .down:
            if selectedIndex < flatItems.count - 1 { selectedIndex += 1; ensureVisible(); notifyPreviewUpdate(); dirty = true }
        case .char("k"), .up:
            if selectedIndex > 0 { selectedIndex -= 1; ensureVisible(); notifyPreviewUpdate(); dirty = true }
        case .right: shiftHorizontally(horizontalStep)
        case .left: shiftHorizontally(-horizontalStep)
        case .enter: handleActivate()
        case .char("l"), .ctrlRight, .ctrl("l"): handleSelect()
        case .char("h"), .ctrlLeft, .ctrl("h"): handleCollapse()
        case .char("i"):
            // `i` — back to the query input, a NEW query from an empty
            // line (the vim insert idiom). The branch picker's `i`
            // keeps its filter; a search query is a fresh search, not
            // a view tweak — the deliberate difference.
            mode = .insert
            inputBuffer = ""
            inputCursorPos = 0
            dirty = true
        default: return false
        }
        return true
    }

    private func handleInputKey(_ key: Key) -> Bool {
        switch key {
        case .escape:
            return false
        case .enter:
            guard !inputBuffer.isEmpty else { return true }
            mode = .menu
            let cwd = workingDirectory.isEmpty
                ? FileManager.default.currentDirectoryPath
                : workingDirectory
            search(query: inputBuffer, in: cwd)
            dirty = true
        default:
            // The shared single-line editor (see Window.applyLineEdit):
            // every typing key lands here. Nothing re-runs while typing
            // — the search starts on Enter alone; edits only repaint.
            if Self.applyLineEdit(key, text: &inputBuffer, cursor: &inputCursorPos) != .notEditing {
                dirty = true
            }
        }
        return true
    }

    /// Enter — the explorer's activateCurrent: on a match line opens
    /// the file; on a directory/file row toggles it — expanding
    /// descends to the first child, collapsing keeps the row.
    private func handleActivate() {
        guard selectedIndex < flatItems.count else { return }
        switch flatItems[selectedIndex] {
        case .directory(let node, _):
            if expandedDirs.contains(node.path) {
                expandedDirs.remove(node.path)
                purgeExpansionBelow(node.path)
            } else {
                expandedDirs.insert(node.path)
            }
            flatItemsDirty = true
            ensureFlatItems()
            descendToFirstChild()
        case .file(let node, _):
            if expandedFiles.contains(node.path) { expandedFiles.remove(node.path) } else { expandedFiles.insert(node.path) }
            flatItemsDirty = true
            ensureFlatItems()
            descendToFirstChild()
        case .result(let r, _):
            delegate?.openFileAtLine(r.filePath, line: r.lineNumber)
        }
        dirty = true
    }

    /// `l` / Ctrl+Right — the explorer's selectCurrent: never
    /// collapses. A collapsed row expands and descends, an expanded
    /// one just descends; a match line opens the file.
    private func handleSelect() {
        guard selectedIndex < flatItems.count else { return }
        switch flatItems[selectedIndex] {
        case .directory(let node, _):
            if !expandedDirs.contains(node.path) {
                expandedDirs.insert(node.path)
                flatItemsDirty = true
                ensureFlatItems()
            }
            descendToFirstChild()
        case .file(let node, _):
            if !expandedFiles.contains(node.path) {
                expandedFiles.insert(node.path)
                flatItemsDirty = true
                ensureFlatItems()
            }
            descendToFirstChild()
        case .result(let r, _):
            delegate?.openFileAtLine(r.filePath, line: r.lineNumber)
        }
        dirty = true
    }

    /// Collapsing discards the subtree's expansion MEMORY: every key
    /// below the collapsed node leaves the sets, so re-expanding opens
    /// the node fresh — its children collapsed — instead of restoring
    /// the previous depth. Keys of untouched nodes survive rebuilds
    /// and re-queries as before; only collapse wipes.
    private func purgeExpansionBelow(_ path: String) {
        let prefix = path + "/"
        // Set has no removeAll(where:) — filter reassignment is the
        // idiomatic wipe.
        expandedDirs = expandedDirs.filter { !$0.hasPrefix(prefix) }
        expandedFiles = expandedFiles.filter { !$0.hasPrefix(prefix) }
    }

    /// The descend after an expand — the explorer's mechanic, on the
    /// shared pure policy (`TreeListNavigation.firstChild`): the
    /// selection moves onto the branch's first child, the row right
    /// below one depth deeper; a collapsed-again branch has no such
    /// row — the selection stays. The selection moving rows means the
    /// preview follows.
    private func descendToFirstChild() {
        let child = TreeListNavigation.firstChild(
            rowCount: flatItems.count,
            selectedIndex: selectedIndex,
            depthAt: { depth(of: flatItems[$0]) }
        )
        if let child {
            selectedIndex = child
            ensureVisible()
            notifyPreviewUpdate()
        }
    }

    /// The explorer-style `h` (the shared TreeListNavigation policy):
    /// the key acts on the selected row's PARENT branch — the nearest
    /// row above one depth shallower — selecting it and collapsing it
    /// (a nested row's parent is always expanded, or the row would not
    /// be visible; remove, never insert — expanding is `l`/Enter's
    /// job). At the top level the row acts on itself: the root
    /// collapses the whole tree, a collapsed root makes the press a
    /// no-op.
    private func handleCollapse() {
        guard selectedIndex < flatItems.count else { return }
        let target = TreeListNavigation.collapseTarget(
            rowCount: flatItems.count,
            selectedIndex: selectedIndex
        ) { depth(of: flatItems[$0]) }
        selectedIndex = target
        switch flatItems[target] {
        case .directory(let node, _):
            expandedDirs.remove(node.path)
            purgeExpansionBelow(node.path)
            flatItemsDirty = true
        case .file(let node, _):
            expandedFiles.remove(node.path)
            flatItemsDirty = true
        case .result:
            // Unreachable: the target is a parent branch by the
            // flatten invariant; kept total for the switch.
            break
        }
        ensureVisible()
        // The selection moved rows — the preview follows, like j/k.
        notifyPreviewUpdate()
        dirty = true
    }

    private func shiftHorizontally(_ delta: Int) {
        ensureFlatItems()
        let maxOffset = max(0, maxVisibleContentLength() - width + 1)
        horizontalOffset = max(0, min(horizontalOffset + delta, maxOffset))
        dirty = true
    }

    /// The scroll bound in terminal CELLS, not Characters — a wide
    /// grapheme occupies two columns (the shared `Window.cellCount`,
    /// the accounting of the rows `textCells` builds), and a bound
    /// counted in characters would stop short of a wide row's tail.
    private func maxVisibleContentLength() -> Int {
        var maxLen = 0
        let visibleH = max(0, height - plateRowCount)
        for row in 0..<visibleH {
            let itemIdx = scrollOffset + row
            guard itemIdx < flatItems.count else { break }
            switch flatItems[itemIdx] {
            case .directory(let node, let depth):
                // indent + icon + name + " (" + count + ")"
                maxLen = max(maxLen, depth * 2 + 2 + Self.cellCount(node.name) + 3 + String(node.matchCount).count)
            case .file(let node, let depth):
                maxLen = max(maxLen, depth * 2 + 2 + Self.cellCount(node.name) + 3 + String(node.matchCount).count)
            case .result(let r, let depth):
                maxLen = max(maxLen, depth * 2 + String(r.lineNumber).count + 2 + Self.cellCount(r.lineContent))
            }
        }
        return maxLen
    }

    private func notifyPreviewUpdate() {
        guard selectedIndex < flatItems.count else {
            delegate?.updatePreview(path: nil, highlightLine: -1)
            return
        }
        switch flatItems[selectedIndex] {
        case .result(let r, _):
            delegate?.updatePreview(path: r.filePath, highlightLine: r.lineNumber)
        case .file(let node, _):
            delegate?.updatePreview(path: node.path, highlightLine: -1)
        case .directory:
            delegate?.updatePreview(path: nil, highlightLine: -1)
        }
    }

    /// Rows the plate occupies above the tree — the one constant every
    /// height computation in the window shares.
    private var plateRowCount: Int { 2 }

    private func ensureVisible() {
        scrollOffset = Window.clampedScroll(selectedIndex: selectedIndex, scrollOffset: scrollOffset, visibleCount: max(0, height - plateRowCount))
    }
}

extension SearchResultsWindow: SpinnerWindow {
    // No spinner to animate — the search plate says "scanning..."
    // plainly. The tick is the idle-loop keep-alive: it keeps the
    // anyDirty block consuming landed scan results while the user
    // types nothing.
    var spinnerActive: Bool { visible && isSearching }
    func tickSpinner() {
        dirty = true
    }
}
