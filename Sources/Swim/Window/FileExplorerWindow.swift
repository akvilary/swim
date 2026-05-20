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
    var onFileSelect: ((String) -> Void)?

    override func update() {
        clear()
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
        var entries = [FileEntry]()
        for name in contents.sorted() {
            if name.hasPrefix(".") { continue }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            entries.append(FileEntry(name: name, path: fullPath, isDirectory: isDir.boolValue))
        }
        let dirs = entries.filter { $0.isDirectory }
        let files = entries.filter { !$0.isDirectory }
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
        else { onFileSelect?(entry.path) }
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
        let s = String(c)
        let scalars = s.unicodeScalars
        guard let scalar = scalars.first else { return 1 }
        let v = scalar.value
        if v <= 0x7F { return 1 }
        if v >= 0x1100 {
            if v <= 0x115F { return 2 }
            if v >= 0x231A && v <= 0x231B { return 2 }
            if v >= 0x2329 && v <= 0x232A { return 2 }
            if v >= 0x23E9 && v <= 0x23EC { return 2 }
            if v == 0x23F0 { return 2 }
            if v == 0x23F3 { return 2 }
            if v >= 0x25FD && v <= 0x25FE { return 2 }
            if v >= 0x2614 && v <= 0x2615 { return 2 }
            if v >= 0x2648 && v <= 0x2653 { return 2 }
            if v == 0x267F { return 2 }
            if v >= 0x2693 && v <= 0x269A { return 2 }
            if v >= 0x26A1 { return 2 }
            if v >= 0x26AA && v <= 0x26AB { return 2 }
            if v >= 0x26BD && v <= 0x26BC + 3 { return 2 }
            if v >= 0x26C4 && v <= 0x26CD { return 2 }
            if v >= 0x26CF && v <= 0x26E1 { return 2 }
            if v >= 0x26E8 && v <= 0x26FF { return 2 }
            if v >= 0x2702 && v <= 0x27B0 { return 2 }
            if v >= 0x2B1B && v <= 0x2B55 { return 2 }
            if v >= 0x2E80 && v <= 0x303E { return 2 }
            if v >= 0x3040 && v <= 0x3247 { return 2 }
            if v >= 0x3250 && v <= 0x4DBF { return 2 }
            if v >= 0x4E00 && v <= 0x9FFF { return 2 }
            if v >= 0xA960 && v <= 0xA97C { return 2 }
            if v >= 0xAC00 && v <= 0xD7A3 { return 2 }
            if v >= 0xF900 && v <= 0xFAFF { return 2 }
            if v >= 0xFE10 && v <= 0xFE19 { return 2 }
            if v >= 0xFE30 && v <= 0xFE6B { return 2 }
            if v >= 0xFF01 && v <= 0xFF60 { return 2 }
            if v >= 0xFFE0 && v <= 0xFFE6 { return 2 }
            if v >= 0x1F000 && v <= 0x1F02F { return 2 }
            if v >= 0x1F0A0 && v <= 0x1F0FF { return 2 }
            if v >= 0x1F100 && v <= 0x1F1AD { return 2 }
            if v >= 0x1F1E6 && v <= 0x1F6FF { return 2 }
            if v >= 0x1F700 && v <= 0x1F77F { return 2 }
            if v >= 0x1F780 && v <= 0x1F7FF { return 2 }
            if v >= 0x1F800 && v <= 0x1F8FF { return 2 }
            if v >= 0x1F900 && v <= 0x1F9FF { return 2 }
            if v >= 0x1FA00 && v <= 0x1FA6F { return 2 }
            if v >= 0x1FA70 && v <= 0x1FAFF { return 2 }
            if v >= 0x20000 { return 2 }
        }
        return 1
    }
}
