import Foundation

struct SearchResult {
    let filePath: String
    let lineNumber: Int
    let lineContent: String
    let matchStart: Int
    let matchLength: Int
}

class SearchResultsWindow: Window {
    private(set) var results: [SearchResult] = []
    private(set) var groupedResults: [(dir: String, files: [(name: String, results: [SearchResult])])] = []
    private(set) var selectedIndex: Int = 0
    private(set) var expandedDirs: Set<String> = []
    private(set) var expandedFiles: Set<String> = []
    private var scrollOffset: Int = 0
    private var horizontalOffset: Int = 0
    private let horizontalStep: Int = 4
    private var flatItems: [SearchItem] = []
    private var flatItemsDirty: Bool = false
    private let searchTask = BackgroundTask<[SearchResult]>()
    var workingDirectory: String = ""
    private(set) var isSearching: Bool = false
    private(set) var inputMode: Bool = true
    private(set) var inputBuffer: String = ""
    private(set) var inputCursorPos: Int = 0

    func prepareInput(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        inputMode = true
        inputBuffer = ""
        inputCursorPos = 0
        dirty = true
    }

    private enum SearchItem {
        case directory(String, Int)
        case file(String, String, Int)
        case result(SearchResult)
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
            let displayText = String(inputBuffer.suffix(max(0, maxInput)))
            drawLine(displayText, row: 0, col: prompt.count, fg: Theme.fg, bg: Theme.bgHighlight)
            let cursorCol = prompt.count + min(inputCursorPos, maxInput)
            if cursorCol < width {
                setCell(0, cursorCol, Cell.colored(" ", fg: Theme.fg, bg: Theme.fgGutter))
            }
            for i in (prompt.count + displayText.count + 1)..<width {
                setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
            }
        } else {
            let headerText: String
            if isSearching {
                headerText = " SEARCH (scanning...) "
            } else {
                headerText = " SEARCH (\(results.count) matches) "
            }
            drawHeader(headerText, fg: Theme.fg)
        }
    }

    private func drawResults() {
        if flatItemsDirty {
            buildFlatItems()
            flatItemsDirty = false
        }
        let visibleH = height - 1
        for row in 0..<visibleH {
            let itemIdx = scrollOffset + row
            guard itemIdx < flatItems.count else { break }
            let isSelected = itemIdx == selectedIndex
            let bg: Color = isSelected ? Theme.bgHighlight : Theme.bgDark
            let y = row + 1

            fillRegion(row: y, col: 0, width: width, height: 1, cell: Cell.colored(" ", fg: Theme.fg, bg: bg))

            switch flatItems[itemIdx] {
            case .directory(let dir, let count):
                let expanded = expandedDirs.contains(dir)
                let icon = expanded ? "▾ " : "▸ "
                let dirName = URL(fileURLWithPath: dir).lastPathComponent
                let text = "\(icon)\(dirName) (\(count))"
                drawShifted([(text: text, fg: Theme.blue, bold: true)], row: y, bg: bg)
            case .file(let dir, let name, let count):
                let expanded = expandedFiles.contains(dir + "/" + name)
                let icon = expanded ? "▾ " : "▸ "
                let text = "  \(icon)\(name) (\(count))"
                drawShifted([(text: text, fg: Theme.fgDark, bold: false)], row: y, bg: bg)
            case .result(let result):
                let indent = "      "
                let linePrefix = "\(indent)\(result.lineNumber): "
                let availW = width - linePrefix.count - result.matchLength
                let beforeEnd = min(result.matchStart, availW)
                let beforeMatch = String(result.lineContent.prefix(beforeEnd).trimmingCharacters(in: .whitespaces).prefix(availW))
                let startIndex = result.lineContent.index(result.lineContent.startIndex, offsetBy: result.matchStart)
                let endIndex = result.lineContent.index(startIndex, offsetBy: result.matchLength)
                let matchText = String(result.lineContent[startIndex..<endIndex])
                drawShifted([
                    (text: linePrefix, fg: Theme.comment, bold: false),
                    (text: beforeMatch, fg: isSelected ? Theme.fg : Theme.fgDark, bold: false),
                    (text: matchText, fg: Theme.orange, bold: true)
                ], row: y, bg: bg)
            }
        }
    }

    private func drawShifted(_ parts: [(text: String, fg: Color, bold: Bool)], row: Int, bg: Color) {
        var col = 0
        var skip = horizontalOffset
        outer: for part in parts {
            for ch in part.text {
                if skip > 0 {
                    skip -= 1
                    continue
                }
                if col >= width { break outer }
                setCell(row, col, Cell.colored(ch, fg: part.fg, bg: bg, bold: part.bold))
                col += 1
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
                            flatItems.append(.result(result))
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
        groupedResults = []
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
            return found
        }
    }

    override func poll() {
        pollSearch()
    }

    func pollSearch() {
        guard let found = searchTask.consume() else { return }
        results = found
        isSearching = false
        groupResults()
        if !groupedResults.isEmpty {
            expandedDirs.insert(groupedResults[0].dir)
            if !groupedResults[0].files.isEmpty {
                let firstFile = groupedResults[0].files[0].name
                expandedFiles.insert(groupedResults[0].dir + "/" + firstFile)
            }
        }
        dirty = true
        flatItemsDirty = true
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

    private func groupResults() {
        var dirMap: [String: [String: [SearchResult]]] = [:]
        for result in results {
            let dir = (result.filePath as NSString).deletingLastPathComponent
            let file = (result.filePath as NSString).lastPathComponent
            dirMap[dir, default: [:]][file, default: []].append(result)
        }
        flatItemsDirty = true
        groupedResults = dirMap.map { dir, files in
            (dir: dir, files: files.map { name, results in
                (name: name, results: results.sorted { $0.lineNumber < $1.lineNumber })
            }.sorted { $0.name < $1.name })
        }.sorted { $0.dir < $1.dir }
    }

    override func handleKey(_ key: Key) -> Bool {
        if inputMode {
            return handleInputKey(key)
        }
        switch key {
        case .char("j"), .down:
            if selectedIndex < flatItems.count - 1 { selectedIndex += 1; ensureVisible(); notifyPreviewUpdate(); dirty = true }
        case .char("k"), .up:
            if selectedIndex > 0 { selectedIndex -= 1; ensureVisible(); notifyPreviewUpdate(); dirty = true }
        case .right: shiftHorizontally(horizontalStep)
        case .left: shiftHorizontally(-horizontalStep)
        case .enter, .char("l"), .ctrlRight, .ctrl("l"): handleEnter()
        case .char("h"), .ctrlLeft, .ctrl("h"): handleCollapse()
        case .escape:
            inputMode = true
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
            inputMode = false
            let cwd = workingDirectory.isEmpty
                ? FileManager.default.currentDirectoryPath
                : workingDirectory
            search(query: inputBuffer, in: cwd)
            dirty = true
        case .backspace:
            if inputCursorPos > 0 {
                let idx = inputBuffer.index(inputBuffer.startIndex, offsetBy: inputCursorPos - 1)
                inputBuffer.remove(at: idx)
                inputCursorPos -= 1
                dirty = true
            }
        case .delete:
            if inputCursorPos < inputBuffer.count {
                let idx = inputBuffer.index(inputBuffer.startIndex, offsetBy: inputCursorPos)
                inputBuffer.remove(at: idx)
                dirty = true
            }
        case .left:
            if inputCursorPos > 0 { inputCursorPos -= 1; dirty = true }
        case .right:
            if inputCursorPos < inputBuffer.count { inputCursorPos += 1; dirty = true }
        case .home:
            inputCursorPos = 0; dirty = true
        case .end:
            inputCursorPos = inputBuffer.count; dirty = true
        case .char(let c):
            if c.unicodeScalars.count == 1 {
                let idx = inputBuffer.index(inputBuffer.startIndex, offsetBy: inputCursorPos)
                inputBuffer.insert(c, at: idx)
                inputCursorPos += 1
                dirty = true
            }
        default: break
        }
        return true
    }

    private func handleEnter() {
        guard selectedIndex < flatItems.count else { return }
        switch flatItems[selectedIndex] {
        case .directory(let dir, _):
            if expandedDirs.contains(dir) { expandedDirs.remove(dir) } else { expandedDirs.insert(dir) }
            flatItemsDirty = true
        case .file(let dir, let name, _):
            let key = dir + "/" + name
            if expandedFiles.contains(key) { expandedFiles.remove(key) } else { expandedFiles.insert(key) }
            flatItemsDirty = true
        case .result(let r): delegate?.openFileAtLine(r.filePath, line: r.lineNumber)
        }
        dirty = true
    }

    private func handleCollapse() {
        guard selectedIndex < flatItems.count else { return }
        switch flatItems[selectedIndex] {
        case .directory(let dir, _): expandedDirs.remove(dir); flatItemsDirty = true
        case .file(let dir, let name, _): expandedFiles.remove(dir + "/" + name); flatItemsDirty = true
        case .result: break
        }
        dirty = true
    }

    private func shiftHorizontally(_ delta: Int) {
        if flatItemsDirty {
            buildFlatItems()
            flatItemsDirty = false
        }
        let maxOffset = max(0, maxVisibleContentLength() - width + 1)
        horizontalOffset = max(0, min(horizontalOffset + delta, maxOffset))
        dirty = true
    }

    private func maxVisibleContentLength() -> Int {
        var maxLen = 0
        let visibleH = height - 1
        for row in 0..<visibleH {
            let itemIdx = scrollOffset + row
            guard itemIdx < flatItems.count else { break }
            switch flatItems[itemIdx] {
            case .directory(let dir, let count):
                let dirName = URL(fileURLWithPath: dir).lastPathComponent
                maxLen = max(maxLen, 2 + dirName.count + 3 + String(count).count)
            case .file(_, let name, let count):
                maxLen = max(maxLen, 4 + name.count + 3 + String(count).count)
            case .result(let r):
                maxLen = max(maxLen, 6 + String(r.lineNumber).count + 2 + r.lineContent.count)
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
        case .result(let r):
            delegate?.updatePreview(path: r.filePath, highlightLine: r.lineNumber)
        case .file(let dir, let name, _):
            delegate?.updatePreview(path: dir + "/" + name, highlightLine: -1)
        case .directory:
            delegate?.updatePreview(path: nil, highlightLine: -1)
        }
    }

    private func ensureVisible() {
        scrollOffset = Window.clampedScroll(selectedIndex: selectedIndex, scrollOffset: scrollOffset, visibleCount: height - 1)
    }
}
