import Foundation

struct SearchResult {
    let filePath: String
    let lineNumber: Int
    let lineContent: String
    let matchStart: Int
    let matchLength: Int
}

class SearchWindow: Window {
    private(set) var results: [SearchResult] = []
    private(set) var groupedResults: [(dir: String, files: [(name: String, results: [SearchResult])])] = []
    private(set) var selectedIndex: Int = 0
    private(set) var expandedDirs: Set<String> = []
    private(set) var expandedFiles: Set<String> = []
    private var scrollOffset: Int = 0
    private var flatItems: [SearchItem] = []
    var workingDirectory: String = ""
    var onResultSelect: ((String, Int) -> Void)?

    private enum SearchItem {
        case directory(String, Int)
        case file(String, String, Int)
        case result(String, Int, Int)
    }

    override func update() {
        clear()
        fillRegion(row: 0, col: 0, width: width, height: height, cell: Cell.colored(" ", fg: Theme.fg, bg: Theme.bgDark))

        let headerText = " SEARCH (\(results.count) matches) "
        for (i, c) in headerText.enumerated() {
            if i < width { setCell(0, i, Cell.colored(c, fg: Theme.fg, bg: Theme.bgHighlight, bold: true)) }
        }
        for i in headerText.count..<width {
            setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
        }

        buildFlatItems()
        for row in 0..<(height - 1) {
            let itemIdx = scrollOffset + row
            guard itemIdx < flatItems.count else { break }
            let isSelected = itemIdx == selectedIndex
            let bg: Color = isSelected ? Theme.bgHighlight : Theme.bgDark

            switch flatItems[itemIdx] {
            case .directory(let dir, let count):
                let expanded = expandedDirs.contains(dir)
                let icon = expanded ? "▾ " : "▸ "
                let dirName = URL(fileURLWithPath: dir).lastPathComponent
                let text = "\(icon)\(dirName) (\(count))"
                drawLine(text, row: row + 1, fg: Theme.blue, bg: bg, bold: true)
            case .file(let dir, let name, let count):
                let expanded = expandedFiles.contains(dir + "/" + name)
                let icon = expanded ? "▾ " : "▸ "
                let text = "  \(icon)\(name) (\(count))"
                drawLine(text, row: row + 1, fg: Theme.fgDark, bg: bg)
            case .result(let path, let lineNum, _):
                let result = results.first { $0.filePath == path && $0.lineNumber == lineNum }
                let indent = "      "
                let linePrefix = "\(indent)\(lineNum): "
                drawLine(linePrefix, row: row + 1, fg: Theme.comment, bg: bg)
                if let result = result {
                    let prefixCol = linePrefix.count
                    let beforeEnd = min(result.matchStart, width - prefixCol - result.matchLength)
                    let beforeMatch = String(result.lineContent.prefix(beforeEnd).trimmingCharacters(in: .whitespaces).prefix(width - prefixCol - result.matchLength))
                    drawLine(beforeMatch, row: row + 1, col: prefixCol, fg: isSelected ? Theme.fg : Theme.fgDark, bg: bg)
                    let matchStart = prefixCol + beforeMatch.count
                    let startIndex = result.lineContent.index(result.lineContent.startIndex, offsetBy: result.matchStart)
                    let endIndex = result.lineContent.index(startIndex, offsetBy: result.matchLength)
                    let matchText = String(result.lineContent[startIndex..<endIndex])
                    drawLine(matchText, row: row + 1, col: matchStart, fg: Theme.orange, bg: bg, bold: true)
                }
            }
        }
    }

    private func buildFlatItems() {
        flatItems = []
        for group in groupedResults {
            let dirExpanded = expandedDirs.contains(group.dir)
            flatItems.append(.directory(group.dir, group.files.reduce(0) { $0 + $1.results.count }))
            if dirExpanded {
                for fileGroup in group.files {
                    let fileKey = group.dir + "/" + fileGroup.name
                    let fileExpanded = expandedFiles.contains(fileKey)
                    flatItems.append(.file(group.dir, fileGroup.name, fileGroup.results.count))
                    if fileExpanded {
                        for result in fileGroup.results {
                            flatItems.append(.result(result.filePath, result.lineNumber, result.matchStart))
                        }
                    }
                }
            }
        }
    }

    func search(query: String, in directory: String) {
        guard !query.isEmpty else { return }
        workingDirectory = directory
        results = []
        let fm = FileManager.default
        let enumerator = fm.enumerator(atPath: directory)
        let excludedDirs: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData"]
        while let relPath = enumerator?.nextObject() as? String {
            let fullPath = (directory as NSString).appendingPathComponent(relPath)
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
                searchIn(content: content, filePath: fullPath, query: query)
            }
        }
        groupResults()
        if !groupedResults.isEmpty {
            expandedDirs.insert(groupedResults[0].dir)
            if !groupedResults[0].files.isEmpty {
                let firstFile = groupedResults[0].files[0].name
                expandedFiles.insert(groupedResults[0].dir + "/" + firstFile)
            }
        }
        dirty = true
    }

    private func searchIn(content: String, filePath: String, query: String) {
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

    private func groupResults() {
        var dirMap: [String: [String: [SearchResult]]] = [:]
        for result in results {
            let dir = (result.filePath as NSString).deletingLastPathComponent
            let file = (result.filePath as NSString).lastPathComponent
            if dirMap[dir] == nil { dirMap[dir] = [:] }
            if dirMap[dir]?[file] == nil { dirMap[dir]?[file] = [] }
            dirMap[dir]?[file]?.append(result)
        }
        groupedResults = dirMap.map { dir, files in
            (dir: dir, files: files.map { name, results in
                (name: name, results: results.sorted { $0.lineNumber < $1.lineNumber })
            }.sorted { $0.name < $1.name })
        }.sorted { $0.dir < $1.dir }
    }

    override func handleKey(_ key: Key) -> Bool {
        switch key {
        case .char("j"), .down:
            if selectedIndex < flatItems.count - 1 { selectedIndex += 1; ensureVisible(); dirty = true }
        case .char("k"), .up:
            if selectedIndex > 0 { selectedIndex -= 1; ensureVisible(); dirty = true }
        case .enter, .char("l"), .right: handleEnter()
        case .char("h"), .left: handleCollapse()
        default: return false
        }
        return true
    }

    private func handleEnter() {
        guard selectedIndex < flatItems.count else { return }
        switch flatItems[selectedIndex] {
        case .directory(let dir, _):
            if expandedDirs.contains(dir) { expandedDirs.remove(dir) } else { expandedDirs.insert(dir) }
        case .file(let dir, let name, _):
            let key = dir + "/" + name
            if expandedFiles.contains(key) { expandedFiles.remove(key) } else { expandedFiles.insert(key) }
        case .result(let path, let lineNum, _): onResultSelect?(path, lineNum)
        }
        dirty = true
    }

    private func handleCollapse() {
        guard selectedIndex < flatItems.count else { return }
        switch flatItems[selectedIndex] {
        case .directory(let dir, _): expandedDirs.remove(dir)
        case .file(let dir, let name, _): expandedFiles.remove(dir + "/" + name)
        case .result: break
        }
        dirty = true
    }

    private func ensureVisible() {
        let visibleCount = height - 1
        if selectedIndex < scrollOffset { scrollOffset = selectedIndex }
        else if selectedIndex >= scrollOffset + visibleCount { scrollOffset = selectedIndex - visibleCount + 1 }
    }

    private func drawLine(_ text: String, row: Int, col: Int = 0, fg: Color = Theme.fgDark, bg: Color = Theme.bgDark, bold: Bool = false) {
        for (i, c) in text.enumerated() {
            if col + i < width { setCell(row, col + i, Cell.colored(c, fg: fg, bg: bg, bold: bold)) }
        }
    }
}
