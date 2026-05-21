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
    private var rootEntries: [FileEntry] = []
    private var flatEntries: [(entry: FileEntry, depth: Int)] = []
    private(set) var selectedIndex: Int = 0
    private var scrollOffset: Int = 0
    var currentDirectory: String = ""

    override func update() {
        fillRegion(row: 0, col: 0, width: width, height: height, cell: Cell.colored(" ", fg: Theme.fg, bg: Theme.bgDark))

        let headerText = " EXPLORER "
        for (i, c) in headerText.enumerated() {
            if i < width {
                setCell(0, i, Cell.colored(c, fg: Theme.fgDark, bg: Theme.bgHighlight, bold: true))
            }
        }
        for i in headerText.count..<width {
            setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
        }

        let visibleCount = height - 1
        for row in 0..<visibleCount {
            let idx = scrollOffset + row
            guard idx < flatEntries.count else { break }
            let (entry, depth) = flatEntries[idx]
            let isSelected = idx == selectedIndex
            let bg: Color = isSelected ? Theme.bgHighlight : Theme.bgDark
            let fg: Color = isSelected ? Theme.fg : Theme.fgDark
            let nameFg: Color = entry.isDirectory ? Theme.blue : fg

            var col = 0
            let indent = depth * 2
            for _ in 0..<indent {
                if col < width {
                    setCell(row + 1, col, Cell.colored(" ", fg: fg, bg: bg))
                    col += 1
                }
            }

            let icon: String
            if entry.isDirectory {
                icon = entry.isExpanded ? "📂" : "📁"
            } else {
                icon = fileIcon(for: entry.name)
            }

            if col < width {
                setCell(row + 1, col, Cell.colored(" ", fg: nameFg, bg: bg))
                col += 1
            }

            for c in icon {
                let w = displayWidth(c)
                if col + w <= width {
                    setCell(row + 1, col, Cell.colored(c, fg: nameFg, bg: bg, bold: entry.isDirectory))
                    if w == 2 {
                        var cont = Cell.colored(" ", fg: nameFg, bg: bg)
                        cont.wideContinuation = true
                        setCell(row + 1, col + 1, cont)
                    }
                    col += w
                }
            }
            if col < width {
                setCell(row + 1, col, Cell.colored(" ", fg: nameFg, bg: bg))
                col += 1
            }

            for c in entry.name {
                if col < width {
                    setCell(row + 1, col, Cell.colored(c, fg: nameFg, bg: bg, bold: entry.isDirectory))
                    col += 1
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
        flattenEntries()
        dirty = true
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
        case .enter, .char("l"), .right: selectCurrent()
        case .char("h"), .left: collapseCurrent()
        case .char("G"): selectedIndex = max(0, flatEntries.count - 1); ensureVisible(); dirty = true
        case .char("g"): selectedIndex = 0; scrollOffset = 0; dirty = true
        default: return false
        }
        return true
    }

    private func selectCurrent() {
        guard selectedIndex < flatEntries.count else { return }
        let (entry, _) = flatEntries[selectedIndex]
        if entry.isDirectory { toggleExpand(at: selectedIndex) }
        else { delegate?.openFile(entry.path) }
    }

    private func collapseCurrent() {
        guard selectedIndex < flatEntries.count else { return }
        let (entry, _) = flatEntries[selectedIndex]
        if entry.isDirectory && entry.isExpanded {
            toggleExpand(at: selectedIndex)
        } else {
            var parentIdx = selectedIndex - 1
            while parentIdx >= 0 {
                if flatEntries[parentIdx].entry.isDirectory {
                    selectedIndex = parentIdx
                    toggleExpand(at: parentIdx)
                    break
                }
                parentIdx -= 1
            }
        }
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
        let visibleCount = height - 1
        if selectedIndex < scrollOffset { scrollOffset = selectedIndex }
        else if selectedIndex >= scrollOffset + visibleCount { scrollOffset = selectedIndex - visibleCount + 1 }
    }

    private func displayWidth(_ c: Character) -> Int {
        Renderer.isWideChar(c) ? 2 : 1
    }
}
