import Foundation

struct FileEntry {
    let name: String
    let path: String
    let isDirectory: Bool
    var isExpanded: Bool = false
    var children: [FileEntry] = []
    var isLoaded: Bool = false
}

class FileExplorerWindow: Window {
    override var availableModes: [WindowMode] { [.menu, .command] }
    private var rootEntries: [FileEntry] = []
    private var flatEntries: [(entry: FileEntry, depth: Int)] = []
    private(set) var selectedIndex: Int = 0
    private var scrollOffset: Int = 0
    private var horizontalOffset: Int = 0
    private let horizontalStep: Int = 4
    var currentDirectory: String = ""

    override func update() {
        clear()

        drawHeader(" EXPLORER ", fg: Theme.fgDark)

        let visibleCount = height - 1
        for row in 0..<visibleCount {
            let idx = scrollOffset + row
            guard idx < flatEntries.count else { break }
            let (entry, depth) = flatEntries[idx]
            let isSelected = idx == selectedIndex
            let bg: Color = isSelected ? Theme.bgHighlight : Theme.bgDark
            let fg: Color = isSelected ? Theme.fg : Theme.fgDark
            let nameFg: Color = entry.isDirectory ? Theme.blue : fg

            let icon: String
            if entry.isDirectory {
                icon = entry.isExpanded ? "📂" : "📁"
            } else {
                icon = fileIcon(for: entry.name)
            }

            var content: [Cell] = []
            for _ in 0..<(depth * 2) {
                content.append(Cell.colored(" ", fg: fg, bg: bg))
            }
            content.append(Cell.colored(" ", fg: nameFg, bg: bg))
            for c in icon {
                let w = c.displayWidth
                content.append(Cell.colored(c, fg: nameFg, bg: bg, bold: entry.isDirectory))
                if w == 2 {
                    var cont = Cell.colored(" ", fg: nameFg, bg: bg)
                    cont.wideContinuation = true
                    content.append(cont)
                }
            }
            content.append(Cell.colored(" ", fg: nameFg, bg: bg))
            for c in entry.name {
                content.append(Cell.colored(c, fg: nameFg, bg: bg, bold: entry.isDirectory))
            }

            var col = 0
            if horizontalOffset < content.count {
                for i in horizontalOffset..<content.count {
                    if col < width {
                        setCell(row + 1, col, content[i])
                        col += 1
                    }
                }
            }
            while col < width {
                setCell(row + 1, col, Cell.colored(" ", fg: fg, bg: bg))
                col += 1
            }
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "🐦"
        case "js", "ts": return "⚡"
        case "py": return "🐍"
        case "rs": return "⚙"
        case "go": return "🔵"
        case "dart": return "🎯"
        case "md": return "📝"
        case "json": return "📋"
        case "yaml", "yml": return "📋"
        case "toml": return "📋"
        case "txt": return "📄"
        case "lock": return "🔒"
        case "gitignore", "dockerignore": return "🙈"
        case "sh", "bash": return "📜"
        case "css", "scss": return "🎨"
        case "html": return "🌐"
        default: return "  "
        }
    }

    func loadDirectory(_ path: String) {
        currentDirectory = path
        rootEntries = loadEntries(at: path)
        horizontalOffset = 0
        flattenEntries()
        dirty = true
    }

    /// Reveals a file opened from outside the explorer (search result,
    /// jump): expands its ancestor directories and selects the node, so the
    /// tree shows where we are. Does nothing for paths outside the root or
    /// inside hidden directories (never listed).
    func reveal(path: String) {
        guard !currentDirectory.isEmpty, path.hasPrefix(currentDirectory + "/") else { return }
        var changed = revealAncestors(&rootEntries, target: path)
        flattenEntries()
        if let idx = flatEntries.firstIndex(where: { $0.entry.path == path && !$0.entry.isDirectory }) {
            if selectedIndex != idx {
                selectedIndex = idx
                changed = true
            }
            ensureVisible()
        }
        if changed {
            dirty = true
        }
    }

    /// Expands every directory along the ancestor chain of `target`.
    @discardableResult
    private func revealAncestors(_ entries: inout [FileEntry], target: String) -> Bool {
        var changed = false
        for i in 0..<entries.count {
            guard entries[i].isDirectory, target.hasPrefix(entries[i].path + "/") else { continue }
            if !entries[i].isLoaded {
                entries[i].children = loadEntries(at: entries[i].path)
                entries[i].isLoaded = true
                changed = true
            }
            if !entries[i].isExpanded {
                entries[i].isExpanded = true
                changed = true
            }
            if revealAncestors(&entries[i].children, target: target) {
                changed = true
            }
        }
        return changed
    }

    private func loadEntries(at path: String) -> [FileEntry] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        var dirs = [FileEntry]()
        var files = [FileEntry]()
        for name in contents.sorted() {
            if name.hasPrefix(".") { continue }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            let entry = FileEntry(name: name, path: fullPath, isDirectory: isDir.boolValue)
            if isDir.boolValue { dirs.append(entry) } else { files.append(entry) }
        }
        return dirs + files
    }

    private func loadChildren(of entry: FileEntry, at index: Int) -> FileEntry {
        var mutable = entry
        if !entry.isLoaded {
            mutable.children = loadEntries(at: entry.path)
            mutable.isLoaded = true
        }
        mutable.isExpanded = !entry.isExpanded
        return mutable
    }

    private func flattenEntries() {
        flatEntries = []
        flattenRecursive(rootEntries, depth: 0)
    }

    private func flattenRecursive(_ entries: [FileEntry], depth: Int) {
        for entry in entries {
            flatEntries.append((entry, depth))
            if entry.isDirectory && entry.isExpanded {
                flattenRecursive(entry.children, depth: depth + 1)
            }
        }
    }

    override func handleKey(_ key: Key) -> Bool {
        switch key {
        case .char("j"), .down:
            if selectedIndex < flatEntries.count - 1 { selectedIndex += 1; ensureVisible(); dirty = true }
        case .char("k"), .up:
            if selectedIndex > 0 { selectedIndex -= 1; ensureVisible(); dirty = true }
        case .right: shiftHorizontally(horizontalStep)
        case .left: shiftHorizontally(-horizontalStep)
        case .enter: activateCurrent()
        case .char("l"), .ctrlRight, .ctrl("l"): selectCurrent()
        case .char("h"), .ctrlLeft, .ctrl("h"): collapseCurrent()
        case .char("G"): selectedIndex = max(0, flatEntries.count - 1); ensureVisible(); dirty = true
        case .char("g"): selectedIndex = 0; scrollOffset = 0; dirty = true
        default: return false
        }
        return true
    }

    private func shiftHorizontally(_ delta: Int) {
        let maxOffset = max(0, maxVisibleContentLength() - width + 1)
        horizontalOffset = max(0, min(horizontalOffset + delta, maxOffset))
        dirty = true
    }

    private func maxVisibleContentLength() -> Int {
        var maxLen = 0
        let visibleCount = height - 1
        for row in 0..<visibleCount {
            let idx = scrollOffset + row
            guard idx < flatEntries.count else { break }
            let (entry, depth) = flatEntries[idx]
            let icon = entry.isDirectory ? "📂" : fileIcon(for: entry.name)
            let iconWidth = icon.reduce(0) { $0 + $1.displayWidth }
            let len = depth * 2 + 1 + iconWidth + 1 + entry.name.count
            maxLen = max(maxLen, len)
        }
        return maxLen
    }

    /// Enter: opens a file; toggles a directory — collapsed expands and
    /// selection descends, expanded collapses and selection stays.
    private func activateCurrent() {
        guard selectedIndex < flatEntries.count else { return }
        let (entry, depth) = flatEntries[selectedIndex]
        guard entry.isDirectory else {
            delegate?.openFile(entry.path)
            return
        }
        toggleExpand(at: selectedIndex)
        descendToFirstChild(depth: depth)
    }

    /// `l` / Ctrl+Right: opens a file; expands a collapsed directory or
    /// descends into an already expanded one — never collapses.
    private func selectCurrent() {
        guard selectedIndex < flatEntries.count else { return }
        let (entry, depth) = flatEntries[selectedIndex]
        guard entry.isDirectory else {
            delegate?.openFile(entry.path)
            return
        }
        if !entry.isExpanded {
            toggleExpand(at: selectedIndex)
        }
        descendToFirstChild(depth: depth)
    }

    private func descendToFirstChild(depth: Int) {
        let nextIdx = selectedIndex + 1
        if nextIdx < flatEntries.count && flatEntries[nextIdx].depth == depth + 1 {
            selectedIndex = nextIdx
            ensureVisible()
            dirty = true
        }
    }

    private func collapseCurrent() {
        guard selectedIndex < flatEntries.count else { return }
        let (_, depth) = flatEntries[selectedIndex]

        var targetIdx = selectedIndex
        if depth > 0 {
            var idx = selectedIndex - 1
            while idx >= 0 {
                let (e, d) = flatEntries[idx]
                if d == depth - 1 && e.isDirectory {
                    targetIdx = idx
                    break
                }
                idx -= 1
            }
        }

        selectedIndex = targetIdx
        let (entry, _) = flatEntries[targetIdx]
        if entry.isDirectory && entry.isExpanded {
            toggleExpand(at: targetIdx)
        }
        ensureVisible()
        dirty = true
    }

    private func toggleExpand(at index: Int) {
        let (entry, _) = flatEntries[index]
        let updated = loadChildren(of: entry, at: index)
        let parentPath = entry.path
        updateEntryInTree(&rootEntries, path: parentPath, updated: updated)
        flattenEntries()
        dirty = true
    }

    private func updateEntryInTree(_ entries: inout [FileEntry], path: String, updated: FileEntry) {
        for i in 0..<entries.count {
            if entries[i].path == path { entries[i] = updated; return }
            if entries[i].isDirectory { updateEntryInTree(&entries[i].children, path: path, updated: updated) }
        }
    }

    private func ensureVisible() {
        scrollOffset = Window.clampedScroll(selectedIndex: selectedIndex, scrollOffset: scrollOffset, visibleCount: height - 1)
    }
}
