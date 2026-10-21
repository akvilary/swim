import Foundation
import SwimCore

class SearchResultsWindow: Window {
    override var availableModes: [WindowMode] { [.insert, .menu, .command] }
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
    /// The scan result carries its own root: the mailbox may be
    /// consumed long after the search started (polling runs over the
    /// current space — leaving the search space defers the pickup), so
    /// building the tree from a separately stored directory would tie
    /// correctness to the consume timing. The root rides with the
    /// data; correctness holds by construction.
    private let searchTask = BackgroundTask<(root: String, results: [SearchResult])>()
    var workingDirectory: String = ""
    private(set) var isSearching: Bool = false
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

        if !inputMode {
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
            let headerText: String
            if isSearching {
                headerText = " Search & scanning... "
            } else {
                // The plate hint follows the git panel's `key: action`
                // idiom — `i` (a new query from an empty line) is the
                // one non-obvious key. A narrow panel truncates the
                // tail first; the matches count stays visible.
                headerText = " Search & \(results.count) matches (i: new search) "
            }
            drawHeader(headerText, fg: Theme.fg)
        }
    }

    private func drawResults() {
        ensureFlatItems()
        let visibleH = max(0, height - 1)
        for row in 0..<visibleH {
            let itemIdx = scrollOffset + row
            guard itemIdx < flatItems.count else { break }
            let isSelected = itemIdx == selectedIndex
            let bg: Color = isSelected ? Theme.bgHighlight : Theme.bgDark
            let y = row + 1

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
                let indent = String(repeating: " ", count: depth * 2)
                let linePrefix = "\(indent)\(result.lineNumber): "
                // availW is the room left for the before-match text so
                // the match itself starts on screen; CLAMPED at 0 — a
                // match longer than the window (a deep indent plus a
                // long query in the narrow half-screen panel) must
                // draw from its start truncated by the cell bounds, not
                // feed prefix() a negative length (a fatal error —
                // String.prefix traps on negative input).
                let availW = max(0, width - linePrefix.count - result.matchLength)
                let beforeEnd = min(result.matchStart, availW)
                let beforeMatch = String(result.lineContent.prefix(beforeEnd).trimmingCharacters(in: .whitespaces).prefix(availW))
                let startIndex = result.lineContent.index(result.lineContent.startIndex, offsetBy: result.matchStart)
                let endIndex = result.lineContent.index(startIndex, offsetBy: result.matchLength)
                let matchText = String(result.lineContent[startIndex..<endIndex])
                var cells = Self.textCells(linePrefix, fg: Theme.comment, bg: bg)
                cells += Self.textCells(beforeMatch, fg: isSelected ? Theme.fg : Theme.fgDark, bg: bg)
                cells += Self.textCells(matchText, fg: Theme.orange, bg: bg, bold: true)
                drawCells(cells, row: y, offset: horizontalOffset, fillFg: Theme.fg, fillBg: bg)
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
        results = []
        resultRoot = nil
        selectedIndex = 0
        scrollOffset = 0
        horizontalOffset = 0
        isSearching = true
        dirty = true
        flatItemsDirty = true

        let dir = directory
        searchTask.start { [dir] in
            var found = [SearchResult]()
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
                    SearchResultsWindow.searchIn(content: content, filePath: fullPath, query: query, results: &found)
                }
            }
            return (root: dir, results: found)
        }
    }

    override func poll() {
        pollSearch()
    }

    func pollSearch() {
        guard let found = searchTask.consume() else { return }
        // A fresh result set is a fresh navigation session: cursor at
        // the root row, view at the top — self-contained, not relying
        // on the start-of-search reset having survived the scanning
        // window. Nothing auto-expands — the tree lands collapsed on
        // its root row; the user opens the nodes they need (Enter/`l`
        // descend to the first child, the explorer's mechanic).
        results = found.results
        isSearching = false
        resultRoot = SearchTree.build(results: found.results, root: found.root)
        selectedIndex = 0
        scrollOffset = 0
        // The tree changed, so the flat list is stale by definition —
        // arm the flag (a frame drawn during the scan has already
        // consumed the start-of-search one over an empty tree), then
        // rebuild NOW so notifyPreviewUpdate reads the new rows
        // instead of the old list.
        flatItemsDirty = true
        ensureFlatItems()
        notifyPreviewUpdate()
        dirty = true
        delegate?.requestRender()
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
            if expandedDirs.contains(node.path) { expandedDirs.remove(node.path) } else { expandedDirs.insert(node.path) }
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
        let visibleH = max(0, height - 1)
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

    private func ensureVisible() {
        scrollOffset = Window.clampedScroll(selectedIndex: selectedIndex, scrollOffset: scrollOffset, visibleCount: max(0, height - 1))
    }
}
