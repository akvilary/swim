import Foundation

enum EditorMode {
    case normal
    case insert
    case visual
    case command
}

class EditorWindow: Window {
    var buffer: PieceTable?
    var filePath: String?
    var mode: EditorMode = .normal
    var cursorLine: Int = 0
    var cursorCol: Int = 0
    var scrollY: Int = 0
    var scrollX: Int = 0
    var commandBuffer: String = ""
    var yankBuffer: String = ""
    var searchQuery: String = ""
    var lastSearchForward: Bool = true
    var pendingG: Bool = false
    var pendingD: Bool = false
    var pendingY: Bool = false
    var visualStartLine: Int = 0
    var visualStartCol: Int = 0
    var modified: Bool = false
    var undoStack: [(offset: Int, deleted: String, inserted: String)] = []
    var redoStack: [(offset: Int, deleted: String, inserted: String)] = []

    var semanticTokens: [SemanticToken] = []

    var onFileOpen: ((String) -> Void)?
    var onCommand: ((String) -> Void)?

    override init(x: Int = 0, y: Int = 0, width: Int = 0, height: Int = 0) {
        super.init(x: x, y: y, width: width, height: height)
    }

    func openFile(_ path: String) {
        filePath = path
        buffer = PieceTable.fromFile(path) ?? PieceTable(text: "")
        cursorLine = 0
        cursorCol = 0
        scrollY = 0
        scrollX = 0
        modified = false
        undoStack = []
        redoStack = []
        dirty = true
    }

    func newFile() {
        filePath = nil
        buffer = PieceTable(text: "")
        cursorLine = 0
        cursorCol = 0
        scrollY = 0
        scrollX = 0
        modified = false
        undoStack = []
        redoStack = []
        dirty = true
    }

    override func handleKey(_ key: Key) -> Bool {
        guard buffer != nil else { return false }
        switch mode {
        case .normal: return handleNormal(key)
        case .insert: return handleInsert(key)
        case .visual: return handleVisual(key)
        case .command: return handleCommand(key)
        }
    }

    private func handleNormal(_ key: Key) -> Bool {
        switch key {
        case .char("h"), .left: moveCursorLeft()
        case .char("j"), .down: moveCursorDown()
        case .char("k"), .up: moveCursorUp()
        case .char("l"), .right: moveCursorRight()
        case .char("w"): moveWordForward()
        case .char("b"): moveWordBackward()
        case .char("0"), .home: cursorCol = 0; scrollX = 0
        case .char("$"), .end: moveToEndOfLine()
        case .char("g"):
            if pendingG { cursorLine = 0; cursorCol = 0; ensureCursorVisible(); pendingG = false }
            else { pendingG = true; return true }
        case .char("G"): cursorLine = max(0, buffer!.lineCount - 1); cursorCol = 0; ensureCursorVisible()
        case .char("i"): mode = .insert
        case .char("a"): moveCursorRight(); mode = .insert
        case .char("o"): insertNewLineBelow(); mode = .insert
        case .char("O"): insertNewLineAbove(); mode = .insert
        case .char("A"): moveToEndOfLine(); mode = .insert
        case .char("I"): cursorCol = 0; mode = .insert
        case .char("x"): deleteCharAtCursor()
        case .char("d"):
            if pendingD { deleteCurrentLine(); pendingD = false }
            else { pendingD = true; return true }
        case .char("y"):
            if pendingY { yankCurrentLine(); pendingY = false }
            else { pendingY = true; return true }
        case .char("p"): pasteAfter()
        case .char("P"): pasteBefore()
        case .char("u"): undo()
        case .ctrl("r"): redo()
        case .char("v"): mode = .visual; visualStartLine = cursorLine; visualStartCol = cursorCol
        case .char(":"): mode = .command; commandBuffer = ""
        case .char("/"): mode = .command; commandBuffer = ""
        case .char("n"): searchNext()
        case .char("N"): searchPrev()
        case .ctrl("f"): pageDown()
        case .ctrl("b"): pageUp()
        default: pendingG = false; pendingD = false; pendingY = false; return false
        }
        dirty = true
        return true
    }

    private func handleInsert(_ key: Key) -> Bool {
        switch key {
        case .escape: mode = .normal; moveCursorLeft()
        case .enter: insertNewLineAtCursor()
        case .backspace: deleteBeforeCursor()
        case .tab: insertText("    ")
        case .char(let c): insertText(String(c))
        default: return false
        }
        dirty = true
        return true
    }

    private func handleVisual(_ key: Key) -> Bool {
        switch key {
        case .escape: mode = .normal
        case .char("h"), .left: moveCursorLeft()
        case .char("j"), .down: moveCursorDown()
        case .char("k"), .up: moveCursorUp()
        case .char("l"), .right: moveCursorRight()
        case .char("y"): yankVisualSelection(); mode = .normal
        case .char("d"): deleteVisualSelection(); mode = .normal
        default: return false
        }
        dirty = true
        return true
    }

    private func handleCommand(_ key: Key) -> Bool {
        switch key {
        case .escape: mode = .normal
        case .enter: executeCommand(); mode = .normal
        case .backspace:
            if commandBuffer.isEmpty { mode = .normal }
            else { commandBuffer.removeLast() }
        case .char(let c): commandBuffer.append(c)
        default: return false
        }
        dirty = true
        return true
    }

    private func executeCommand() {
        let cmd = commandBuffer
        if cmd == "w" { saveFile() }
        else if cmd == "q" { onCommand?("quit") }
        else if cmd == "wq" || cmd == "x" { saveFile(); onCommand?("quit") }
        else if cmd == "q!" { onCommand?("forcequit") }
        else if cmd.hasPrefix("e ") { openFile(String(cmd.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
        else if cmd.hasPrefix("%s/") { handleSubstitute(cmd) }
        else if commandBuffer.hasPrefix("/") {
            searchQuery = String(commandBuffer.dropFirst())
            lastSearchForward = true
            searchNext()
        }
    }

    private func handleSubstitute(_ cmd: String) {
        let parts = String(cmd.dropFirst(3)).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return }
        let search = String(parts[0])
        let replace = parts.count > 1 ? String(parts[1]) : ""
        let flags = parts.count > 2 ? String(parts[2]) : ""
        let lineStart = buffer!.lineStart(line: cursorLine)
        let lineEnd = buffer!.lineEnd(line: cursorLine)
        let lineText = buffer!.getText(range: lineStart..<lineEnd)
        let result: String
        if flags.contains("g") { result = lineText.replacingOccurrences(of: search, with: replace) }
        else {
            if let range = lineText.range(of: search) { result = lineText.replacingCharacters(in: range, with: replace) }
            else { result = lineText }
        }
        buffer!.delete(at: lineStart, length: lineText.utf8.count)
        buffer!.insert(result, at: lineStart)
        modified = true
    }

    private func saveFile() {
        guard let path = filePath, let buf = buffer else { return }
        let text = buf.getAllText()
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            modified = false
        } catch {}
    }

    private func moveCursorLeft() { if cursorCol > 0 { cursorCol -= 1 }; ensureCursorVisible() }
    private func moveCursorRight() {
        guard let buf = buffer else { return }
        let maxCol = max(0, buf.lineLength(line: cursorLine) - 1)
        if cursorCol < maxCol { cursorCol += 1 }
        ensureCursorVisible()
    }
    private func moveCursorUp() { if cursorLine > 0 { cursorLine -= 1; clampCol() }; ensureCursorVisible() }
    private func moveCursorDown() {
        guard let buf = buffer else { return }
        if cursorLine < buf.lineCount - 1 { cursorLine += 1; clampCol() }
        ensureCursorVisible()
    }
    private func clampCol() {
        guard let buf = buffer else { return }
        let maxCol = max(0, buf.lineLength(line: cursorLine) - 1)
        if cursorCol > maxCol { cursorCol = maxCol }
    }
    private func moveToEndOfLine() {
        guard let buf = buffer else { return }
        cursorCol = max(0, buf.lineLength(line: cursorLine) - 1)
    }
    private func moveWordForward() {
        guard let buf = buffer else { return }
        let offset = buf.lineStart(line: cursorLine) + cursorCol
        let newOffset = buf.wordForward(from: offset)
        let (newLine, newCol) = buf.offsetToLineCol(newOffset)
        cursorLine = newLine; cursorCol = newCol; ensureCursorVisible()
    }
    private func moveWordBackward() {
        guard let buf = buffer else { return }
        let offset = buf.lineStart(line: cursorLine) + cursorCol
        let newOffset = buf.wordBackward(from: offset)
        let (newLine, newCol) = buf.offsetToLineCol(newOffset)
        cursorLine = newLine; cursorCol = newCol; ensureCursorVisible()
    }

    private func insertText(_ text: String) {
        guard let buf = buffer else { return }
        let offset = buf.lineStart(line: cursorLine) + cursorCol
        buf.insert(text, at: offset)
        cursorCol += text.count
        modified = true; ensureCursorVisible()
    }

    private func insertNewLineAtCursor() {
        guard let buf = buffer else { return }
        let offset = buf.lineStart(line: cursorLine) + cursorCol
        buf.insert("\n", at: offset)
        let lineContent = buf.getLine(cursorLine)
        cursorCol = 0; cursorLine += 1
        let indent = leadingSpaces(lineContent)
        if indent > 0 {
            buf.insert(String(repeating: " ", count: indent), at: buf.lineStart(line: cursorLine))
            cursorCol = indent
        }
        modified = true; ensureCursorVisible()
    }

    private func insertNewLineBelow() {
        guard let buf = buffer else { return }
        buf.insert("\n", at: buf.lineEnd(line: cursorLine))
        cursorLine += 1; cursorCol = 0; modified = true; ensureCursorVisible()
    }

    private func insertNewLineAbove() {
        guard let buf = buffer else { return }
        buf.insert("\n", at: buf.lineStart(line: cursorLine))
        cursorCol = 0; modified = true; ensureCursorVisible()
    }

    private func deleteCharAtCursor() {
        guard let buf = buffer else { return }
        let offset = buf.lineStart(line: cursorLine) + cursorCol
        guard offset < buf.totalLength else { return }
        buf.delete(at: offset, length: 1); clampCol(); modified = true
    }

    private func deleteBeforeCursor() {
        guard let buf = buffer else { return }
        if cursorCol > 0 {
            let offset = buf.lineStart(line: cursorLine) + cursorCol - 1
            buf.delete(at: offset, length: 1); cursorCol -= 1
        } else if cursorLine > 0 {
            let currentLineStart = buf.lineStart(line: cursorLine)
            buf.delete(at: currentLineStart - 1, length: 1)
            cursorLine -= 1
            cursorCol = max(0, buf.lineLength(line: cursorLine) - 1)
        }
        modified = true
    }

    private func deleteCurrentLine() {
        guard let buf = buffer, buf.lineCount > 0 else { return }
        let start = buf.lineStart(line: cursorLine)
        let len = buf.lineEnd(line: cursorLine) - start
        yankBuffer = buf.getLine(cursorLine) + "\n"
        buf.delete(at: start, length: len)
        if cursorLine >= buf.lineCount { cursorLine = max(0, buf.lineCount - 1) }
        cursorCol = 0; modified = true
    }

    private func yankCurrentLine() { guard let buf = buffer else { return }; yankBuffer = buf.getLine(cursorLine) + "\n" }

    private func pasteAfter() {
        guard let buf = buffer, !yankBuffer.isEmpty else { return }
        if yankBuffer.hasSuffix("\n") {
            buf.insert(yankBuffer, at: buf.lineEnd(line: cursorLine))
            cursorLine += 1; cursorCol = 0
        } else {
            buf.insert(yankBuffer, at: buf.lineStart(line: cursorLine) + cursorCol + 1)
            cursorCol += yankBuffer.count
        }
        modified = true
    }

    private func pasteBefore() {
        guard let buf = buffer, !yankBuffer.isEmpty else { return }
        if yankBuffer.hasSuffix("\n") {
            buf.insert(yankBuffer, at: buf.lineStart(line: cursorLine))
            cursorCol = 0
        } else {
            buf.insert(yankBuffer, at: buf.lineStart(line: cursorLine) + cursorCol)
            cursorCol += yankBuffer.count
        }
        modified = true
    }

    private func yankVisualSelection() {
        guard let buf = buffer else { return }
        let (startLine, startCol, endLine, endCol) = visualRange()
        let startOffset = buf.lineStart(line: startLine) + startCol
        let endOffset = buf.lineStart(line: endLine) + endCol + 1
        yankBuffer = buf.getText(range: startOffset..<min(endOffset, buf.totalLength))
    }

    private func deleteVisualSelection() {
        guard let buf = buffer else { return }
        let (startLine, startCol, endLine, endCol) = visualRange()
        let startOffset = buf.lineStart(line: startLine) + startCol
        let endOffset = buf.lineStart(line: endLine) + endCol + 1
        let len = min(endOffset, buf.totalLength) - startOffset
        yankBuffer = buf.getText(range: startOffset..<(startOffset + len))
        buf.delete(at: startOffset, length: len)
        cursorLine = startLine; cursorCol = startCol; modified = true
    }

    private func visualRange() -> (startLine: Int, startCol: Int, endLine: Int, endCol: Int) {
        if visualStartLine < cursorLine || (visualStartLine == cursorLine && visualStartCol < cursorCol) {
            return (visualStartLine, visualStartCol, cursorLine, cursorCol)
        }
        return (cursorLine, cursorCol, visualStartLine, visualStartCol)
    }

    private func searchNext() {
        guard let buf = buffer, !searchQuery.isEmpty else { return }
        let offset = buf.lineStart(line: cursorLine) + cursorCol + 1
        if let found = buf.search(searchQuery, from: offset) {
            let (line, col) = buf.offsetToLineCol(found); cursorLine = line; cursorCol = col; ensureCursorVisible()
        } else if let found = buf.search(searchQuery, from: 0) {
            let (line, col) = buf.offsetToLineCol(found); cursorLine = line; cursorCol = col; ensureCursorVisible()
        }
    }

    private func searchPrev() {
        guard let buf = buffer, !searchQuery.isEmpty else { return }
        let offset = buf.lineStart(line: cursorLine) + cursorCol
        if let found = buf.searchBackward(searchQuery, from: offset) {
            let (line, col) = buf.offsetToLineCol(found); cursorLine = line; cursorCol = col; ensureCursorVisible()
        }
    }

    private func pageDown() {
        guard let buf = buffer else { return }
        cursorLine += height - 2
        if cursorLine >= buf.lineCount { cursorLine = max(0, buf.lineCount - 1) }
        clampCol(); ensureCursorVisible()
    }

    private func pageUp() {
        cursorLine -= (height - 2)
        if cursorLine < 0 { cursorLine = 0 }
        clampCol(); ensureCursorVisible()
    }

    private func undo() {}
    private func redo() {}

    func ensureCursorVisible() {
        if cursorLine < scrollY { scrollY = cursorLine }
        else if cursorLine >= scrollY + height { scrollY = cursorLine - height + 1 }
        if cursorCol < scrollX { scrollX = cursorCol }
        else if cursorCol >= scrollX + width - lineNumberWidth() - 1 {
            scrollX = cursorCol - width + lineNumberWidth() + 2
        }
    }

    private func lineNumberWidth() -> Int {
        guard let buf = buffer else { return 4 }
        return max(4, String(buf.lineCount).count + 2)
    }

    private func leadingSpaces(_ str: String) -> Int {
        var count = 0
        for c in str { if c == " " { count += 1 } else if c == "\t" { count += 4 } else { break } }
        return count
    }

    override func update() {
        guard let buf = buffer, height > 0, width > 4 else { return }

        fillRegion(row: 0, col: 0, width: width, height: height, cell: Cell.colored(" ", fg: Theme.fg, bg: Theme.bg))

        let lnWidth = lineNumberWidth()
        let textWidth = max(0, width - lnWidth)

        drawLineNumbers(lnWidth: lnWidth, lineCount: buf.lineCount)

        for row in 0..<height {
            let lineNum = scrollY + row
            guard lineNum < buf.lineCount else { continue }
            let lineData = buf.getLineData(lineNum)
            let visibleData = Array(lineData.dropFirst(scrollX).prefix(textWidth))
            let tokens = semanticTokensFor(line: lineNum)
            var colOffset = 0
            for (i, byte) in visibleData.enumerated() {
                guard let char = String(bytes: [byte], encoding: .utf8)?.first else { continue }
                let absCol = scrollX + i
                let tokenColor = tokenColorAt(line: lineNum, col: absCol, tokens: tokens)
                setCell(row, lnWidth + colOffset, Cell.colored(char, fg: tokenColor, bg: Theme.bg))
                colOffset += 1
            }
        }

        if mode == .visual { drawVisualHighlight(lnWidth: lnWidth) }
        drawCursor(lnWidth: lnWidth)

        if mode == .command { drawCommandLine() }
    }

    private func drawLineNumbers(lnWidth: Int, lineCount: Int) {
        guard height > 0 else { return }
        for row in 0..<height {
            let lineNum = scrollY + row
            let isCurrentLine = lineNum == cursorLine
            if lineNum < lineCount {
                let numStr = String(lineNum + 1)
                let spaceCount = max(0, lnWidth - numStr.count - 1)
                let padded = String(repeating: " ", count: spaceCount) + numStr + " "
                let fg: Color = isCurrentLine ? Theme.fg : Theme.comment
                for (i, c) in padded.enumerated() {
                    if i < width && i < lnWidth {
                        setCell(row, i, Cell.colored(c, fg: fg, bg: Theme.bg))
                    }
                }
            } else {
                for i in 0..<min(lnWidth, width) {
                    setCell(row, i, Cell.colored(" ", fg: Theme.comment, bg: Theme.bg))
                }
            }
        }
    }

    private func drawCursor(lnWidth: Int) {
        guard cursorLine >= scrollY && cursorLine < scrollY + height else { return }
        let screenRow = cursorLine - scrollY
        let screenCol = cursorCol - scrollX
        guard screenCol >= 0 && screenCol + lnWidth < width else { return }
        let absCol = lnWidth + screenCol
        var cell = getCell(screenRow, absCol)
        cell.reverse = true
        if mode == .insert { cell.reverse = false; cell.underline = true }
        setCell(screenRow, absCol, cell)
    }

    private func drawVisualHighlight(lnWidth: Int) {
        let (startLine, _, endLine, _) = visualRange()
        for lineNum in startLine...endLine {
            let screenRow = lineNum - scrollY
            guard screenRow >= 0 && screenRow < height else { continue }
            guard let buf = buffer else { continue }
            let lineEnd = max(0, buf.lineLength(line: lineNum) - 1)
            for c in 0...lineEnd {
                let screenCol = c - scrollX
                guard screenCol >= 0 && screenCol + lnWidth < width else { continue }
                let absCol = lnWidth + screenCol
                var cell = getCell(screenRow, absCol)
                cell.bg = Theme.bgHighlight
                setCell(screenRow, absCol, cell)
            }
        }
    }

    private func drawCommandLine() {
        let prompt = commandBuffer.hasPrefix("/") ? "/" : ":"
        let cmdLine = prompt + commandBuffer
        if height > 0 {
            writeString(cmdLine, row: height - 1, col: 0, fg: Theme.fg, bg: Theme.bg)
        }
    }

    private func semanticTokensFor(line: Int) -> [SemanticToken] {
        semanticTokens.filter { $0.line == line }
    }

    private func tokenColorAt(line: Int, col: Int, tokens: [SemanticToken]) -> Color {
        for token in tokens {
            if col >= token.startChar && col < token.startChar + token.length {
                return colorForTokenType(token.type)
            }
        }
        return Theme.fg
    }

    private func colorForTokenType(_ type: String) -> Color {
        switch type {
        case "keyword", "controlKeyword": return Theme.magenta
        case "string": return Theme.green
        case "number": return Theme.orange
        case "comment": return Theme.comment
        case "type", "class", "struct", "enum", "interface": return Theme.blue1
        case "function", "method": return Theme.blue
        case "variable", "property": return Theme.fg
        case "parameter": return Theme.orange
        case "operator": return Theme.blue5
        case "namespace", "module": return Theme.magenta
        case "decorator", "attribute": return Theme.yellow
        case "regexp": return Theme.red
        case "macro": return Theme.red1
        default: return Theme.fg
        }
    }
}
