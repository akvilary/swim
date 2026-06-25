import Foundation

enum EditorMode {
    case normal
    case insert
    case visual
    case visualLine
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
    private var isUndoRedoing = false

    var semanticTokens: [SemanticToken] = [] {
        didSet { rebuildTokenIndex() }
    }
    private var tokenIndex: [Int: [SemanticToken]] = [:]
    private var markdownCache = SyntaxTokenizer.MarkdownCache()

    var lastError: String?

    private func rebuildTokenIndex() {
        tokenIndex.removeAll(keepingCapacity: true)
        for token in semanticTokens {
            tokenIndex[token.line, default: []].append(token)
        }
    }

    private func yank(_ text: String) {
        yankBuffer = text
        Terminal.shared.osc52Copy(text)
    }

    override init(x: Int = 0, y: Int = 0, width: Int = 0, height: Int = 0) {
        super.init(x: x, y: y, width: width, height: height)
    }

    func openFile(_ path: String) {
        filePath = path
        buffer = PieceTable.fromFile(path) ?? PieceTable(text: "")
        resetEditorState()
    }

    func newFile() {
        filePath = nil
        buffer = PieceTable(text: "")
        resetEditorState()
    }

    private func resetEditorState() {
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
        case .visualLine: return handleVisualLine(key)
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
        case .char("A"): moveToEndOfLineForInsert(); mode = .insert
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
        case .char("V"): mode = .visualLine; visualStartLine = cursorLine
        case .char(":"): mode = .command; commandBuffer = ""
        case .char("/"): mode = .command; commandBuffer = "/"
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
        case .escape: mode = .normal; clampCol()
        case .enter: insertNewLineAtCursor()
        case .backspace: deleteBeforeCursor()
        case .tab: insertText("    ")
        case .char(let c): insertText(String(c))
        case .left: moveCursorLeft()
        case .right: moveCursorRightInsert()
        case .up: moveCursorUp()
        case .down: moveCursorDown()
        case .home: cursorCol = 0; ensureCursorVisible()
        case .end: moveToEndOfLineForInsert()
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

    private func handleVisualLine(_ key: Key) -> Bool {
        switch key {
        case .escape: mode = .normal
        case .char("j"), .down: moveCursorDown()
        case .char("k"), .up: moveCursorUp()
        case .char("y"): yankVisualLineSelection(); mode = .normal
        case .char("d"): deleteVisualLineSelection(); mode = .normal
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
        else if cmd == "q" { delegate?.handleEditorCommand("quit") }
        else if cmd == "wq" || cmd == "x" { saveFile(); delegate?.handleEditorCommand("quit") }
        else if cmd == "q!" { delegate?.handleEditorCommand("forcequit") }
        else if cmd.hasPrefix("e ") { openFile(String(cmd.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
        else if cmd.hasPrefix("%s/") { handleSubstitute(cmd) }
        else if cmd.hasPrefix("/") {
            searchQuery = String(cmd.dropFirst())
            lastSearchForward = true
            searchNext()
        }
    }

    private func handleSubstitute(_ cmd: String) {
        let parts = String(cmd.dropFirst(3)).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return }
        let search = String(parts[0])
        let replace = String(parts[1])
        let flags = parts.count > 2 ? String(parts[2]) : ""
        guard let buf = buffer else { return }
        let lineStart = buf.lineStart(line: cursorLine)
        let lineEnd = buf.lineEnd(line: cursorLine)
        let lineText = buf.getText(range: lineStart..<lineEnd)
        let result: String
        if flags.contains("g") { result = lineText.replacingOccurrences(of: search, with: replace) }
        else {
            if let range = lineText.range(of: search) { result = lineText.replacingCharacters(in: range, with: replace) }
            else { result = lineText }
        }
        let deletedLen = lineText.utf8.count
        buf.delete(at: lineStart, length: deletedLen)
        buf.insert(result, at: lineStart)
        recordAction(offset: lineStart, deleted: lineText, inserted: result)
    }

    private func saveFile() {
        guard let path = filePath, let buf = buffer else { return }
        let text = buf.getAllText()
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            modified = false
            lastError = nil
        } catch {
            lastError = "Error saving: \(error.localizedDescription)"
        }
    }

    private func moveCursorLeft() { if cursorCol > 0 { cursorCol -= 1 }; ensureCursorVisible() }
    private func moveCursorRight() {
        guard let buf = buffer else { return }
        let maxCol = max(0, buf.lineCharLength(line: cursorLine) - 1)
        if cursorCol < maxCol { cursorCol += 1 }
        ensureCursorVisible()
    }
    private func moveCursorRightInsert() {
        guard let buf = buffer else { return }
        if cursorCol < buf.lineCharLength(line: cursorLine) { cursorCol += 1 }
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
        let maxCol = max(0, buf.lineCharLength(line: cursorLine) - 1)
        if cursorCol > maxCol { cursorCol = maxCol }
    }
    private func moveToEndOfLine() {
        guard let buf = buffer else { return }
        cursorCol = max(0, buf.lineCharLength(line: cursorLine) - 1)
    }
    private func moveToEndOfLineForInsert() {
        guard let buf = buffer else { return }
        cursorCol = buf.lineCharLength(line: cursorLine)
    }
    private func moveWordForward() {
        guard let buf = buffer else { return }
        let offset = buf.lineStart(line: cursorLine) + buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
        moveCursorToOffset(buf.wordForward(from: offset))
    }
    private func moveWordBackward() {
        guard let buf = buffer else { return }
        let offset = buf.lineStart(line: cursorLine) + buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
        moveCursorToOffset(buf.wordBackward(from: offset))
    }

    private func moveCursorToOffset(_ offset: Int) {
        guard let buf = buffer else { return }
        let (line, byteCol) = buf.offsetToLineCol(offset)
        cursorLine = line
        cursorCol = buf.byteToCharOffsetInLine(line: line, byteOffset: byteCol)
        ensureCursorVisible()
    }

    private func recordAction(offset: Int, deleted: String, inserted: String) {
        guard !isUndoRedoing else { return }
        undoStack.append((offset: offset, deleted: deleted, inserted: inserted))
        redoStack.removeAll()
        modified = true
    }

    private func insertText(_ text: String) {
        guard let buf = buffer else { return }
        let byteOff = buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
        let offset = buf.lineStart(line: cursorLine) + byteOff
        buf.insert(text, at: offset)
        recordAction(offset: offset, deleted: "", inserted: text)
        cursorCol += text.count
        ensureCursorVisible()
    }

    private func indentSize() -> Int {
        let ext = (filePath as NSString?)?.pathExtension ?? ""
        switch ext {
        case "swift", "cpp", "hpp", "cc", "cxx", "h", "dart": return 2
        default: return 4
        }
    }

    private func insertNewLineAtCursor() {
        guard let buf = buffer else { return }
        let byteOff = buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
        let offset = buf.lineStart(line: cursorLine) + byteOff
        buf.insert("\n", at: offset)
        var inserted = "\n"
        let lineContent = buf.getLine(cursorLine)
        cursorCol = 0; cursorLine += 1
        let baseIndent = leadingSpaces(lineContent)
        let trimmed = lineContent.trimmingCharacters(in: .whitespaces)
        var extra = 0
        if trimmed.hasSuffix("{") || trimmed.hasSuffix("(") || trimmed.hasSuffix(":") {
            extra = indentSize()
        }
        let newLineContent = buf.getLine(cursorLine)
        let newTrimmed = newLineContent.trimmingCharacters(in: .whitespaces)
        let closesBlock = newTrimmed.hasPrefix("}") || newTrimmed.hasPrefix(")")
        if closesBlock {
            let fullIndent = baseIndent + extra
            let extraText = String(repeating: " ", count: fullIndent) + "\n" + String(repeating: " ", count: baseIndent)
            buf.insert(extraText, at: buf.lineStart(line: cursorLine))
            inserted += extraText
            cursorCol = fullIndent
        } else {
            let indent = baseIndent + extra
            if indent > 0 {
                let indentText = String(repeating: " ", count: indent)
                buf.insert(indentText, at: buf.lineStart(line: cursorLine))
                inserted += indentText
                cursorCol = indent
            }
        }
        recordAction(offset: offset, deleted: "", inserted: inserted)
        ensureCursorVisible()
    }

    private func insertNewLineBelow() {
        guard let buf = buffer else { return }
        let offset = buf.lineEnd(line: cursorLine)
        buf.insert("\n", at: offset)
        recordAction(offset: offset, deleted: "", inserted: "\n")
        cursorLine += 1; cursorCol = 0; ensureCursorVisible()
    }

    private func insertNewLineAbove() {
        guard let buf = buffer else { return }
        let offset = buf.lineStart(line: cursorLine)
        buf.insert("\n", at: offset)
        recordAction(offset: offset, deleted: "", inserted: "\n")
        cursorCol = 0; ensureCursorVisible()
    }

    private func deleteCharAtCursor() {
        guard let buf = buffer else { return }
        let chars = buf.getLineChars(cursorLine)
        guard cursorCol < chars.count else { return }
        let byteOff = buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
        let offset = buf.lineStart(line: cursorLine) + byteOff
        let deleteLen = chars[cursorCol].utf8.count
        let deletedText = String(chars[cursorCol])
        buf.delete(at: offset, length: deleteLen)
        recordAction(offset: offset, deleted: deletedText, inserted: "")
        clampCol()
    }

    private func deleteBeforeCursor() {
        guard let buf = buffer else { return }
        if cursorCol > 0 {
            let prevIdx = cursorCol - 1
            let deleteByteStart = buf.charToByteOffsetInLine(line: cursorLine, charIndex: prevIdx)
            let deleteByteEnd = buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
            let offset = buf.lineStart(line: cursorLine) + deleteByteStart
            let deleteLen = deleteByteEnd - deleteByteStart
            let deletedText = buf.getText(range: offset..<(offset + deleteLen))
            buf.delete(at: offset, length: deleteLen)
            recordAction(offset: offset, deleted: deletedText, inserted: "")
            cursorCol -= 1
        } else if cursorLine > 0 {
            let currentLineStart = buf.lineStart(line: cursorLine)
            let offset = currentLineStart - 1
            let deletedText = "\n"
            buf.delete(at: offset, length: 1)
            recordAction(offset: offset, deleted: deletedText, inserted: "")
            cursorLine -= 1
            cursorCol = max(0, buf.lineCharLength(line: cursorLine) - 1)
        }
    }

    private func deleteCurrentLine() {
        guard let buf = buffer, buf.lineCount > 0 else { return }
        let start = buf.lineStart(line: cursorLine)
        let len = buf.lineEnd(line: cursorLine) - start
        let deletedText = buf.getText(range: start..<(start + len))
        yank(deletedText)
        buf.delete(at: start, length: len)
        recordAction(offset: start, deleted: deletedText, inserted: "")
        if cursorLine >= buf.lineCount { cursorLine = max(0, buf.lineCount - 1) }
        cursorCol = 0
    }

    private func yankCurrentLine() { guard let buf = buffer else { return }; yank(buf.getLine(cursorLine) + "\n") }

    private func pasteAfter() {
        guard let buf = buffer, !yankBuffer.isEmpty else { return }
        let offset: Int
        if yankBuffer.hasSuffix("\n") {
            offset = buf.lineEnd(line: cursorLine)
            buf.insert(yankBuffer, at: offset)
            cursorLine += 1; cursorCol = 0
        } else {
            let charAfterOff = buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol + 1)
            offset = buf.lineStart(line: cursorLine) + charAfterOff
            buf.insert(yankBuffer, at: offset)
            cursorCol += yankBuffer.count
        }
        recordAction(offset: offset, deleted: "", inserted: yankBuffer)
    }

    private func pasteBefore() {
        guard let buf = buffer, !yankBuffer.isEmpty else { return }
        let offset: Int
        if yankBuffer.hasSuffix("\n") {
            offset = buf.lineStart(line: cursorLine)
            buf.insert(yankBuffer, at: offset)
            cursorCol = 0
        } else {
            offset = buf.lineStart(line: cursorLine) + buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
            buf.insert(yankBuffer, at: offset)
            cursorCol += yankBuffer.count
        }
        recordAction(offset: offset, deleted: "", inserted: yankBuffer)
    }

    private func yankVisualSelection() {
        guard let buf = buffer else { return }
        let (startLine, startCol, endLine, endCol) = visualRange()
        let startOffset = buf.lineStart(line: startLine) + buf.charToByteOffsetInLine(line: startLine, charIndex: startCol)
        let endOffset = buf.lineStart(line: endLine) + buf.charToByteOffsetInLine(line: endLine, charIndex: endCol + 1)
        yank(buf.getText(range: startOffset..<min(endOffset, buf.totalLength)))
    }

    private func deleteVisualSelection() {
        guard let buf = buffer else { return }
        let (startLine, startCol, endLine, endCol) = visualRange()
        let startOffset = buf.lineStart(line: startLine) + buf.charToByteOffsetInLine(line: startLine, charIndex: startCol)
        let endOffset = buf.lineStart(line: endLine) + buf.charToByteOffsetInLine(line: endLine, charIndex: endCol + 1)
        let len = min(endOffset, buf.totalLength) - startOffset
        let deletedText = buf.getText(range: startOffset..<(startOffset + len))
        yank(deletedText)
        buf.delete(at: startOffset, length: len)
        recordAction(offset: startOffset, deleted: deletedText, inserted: "")
        cursorLine = startLine; cursorCol = startCol
    }

    private func visualRange() -> (startLine: Int, startCol: Int, endLine: Int, endCol: Int) {
        if visualStartLine < cursorLine || (visualStartLine == cursorLine && visualStartCol < cursorCol) {
            return (visualStartLine, visualStartCol, cursorLine, cursorCol)
        }
        return (cursorLine, cursorCol, visualStartLine, visualStartCol)
    }

    private func visualLineRange() -> (startLine: Int, endLine: Int) {
        if visualStartLine <= cursorLine {
            return (visualStartLine, cursorLine)
        }
        return (cursorLine, visualStartLine)
    }

    private func yankVisualLineSelection() {
        guard let buf = buffer else { return }
        let (startLine, endLine) = visualLineRange()
        var text = ""
        for line in startLine...endLine {
            text += buf.getLine(line) + "\n"
        }
        yank(text)
    }

    private func deleteVisualLineSelection() {
        guard let buf = buffer else { return }
        let (startLine, endLine) = visualLineRange()
        let start = buf.lineStart(line: startLine)
        let end = buf.lineEnd(line: endLine)
        let len = end - start
        let deletedText = buf.getText(range: start..<min(end, buf.totalLength))
        yank(deletedText)
        buf.delete(at: start, length: len)
        recordAction(offset: start, deleted: deletedText, inserted: "")
        cursorLine = min(startLine, max(0, buf.lineCount - 1))
        cursorCol = 0
    }

    private func searchNext() {
        guard let buf = buffer, !searchQuery.isEmpty else { return }
        let byteOff = buf.lineStart(line: cursorLine) + buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol) + 1
        if let found = buf.search(searchQuery, from: byteOff) {
            moveCursorToOffset(found)
        } else if let found = buf.search(searchQuery, from: 0) {
            moveCursorToOffset(found)
        }
    }

    private func searchPrev() {
        guard let buf = buffer, !searchQuery.isEmpty else { return }
        let byteOff = buf.lineStart(line: cursorLine) + buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
        if let found = buf.searchBackward(searchQuery, from: byteOff) {
            moveCursorToOffset(found)
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

    private func applyInverse(_ action: (offset: Int, deleted: String, inserted: String)) {
        guard let buf = buffer else { return }
        if !action.inserted.isEmpty {
            buf.delete(at: action.offset, length: action.inserted.utf8.count)
        }
        if !action.deleted.isEmpty {
            buf.insert(action.deleted, at: action.offset)
        }
    }

    private func undo() {
        guard let buf = buffer, !undoStack.isEmpty else { return }
        let action = undoStack.removeLast()
        isUndoRedoing = true
        applyInverse(action)
        redoStack.append(action)
        isUndoRedoing = false
        modified = !undoStack.isEmpty

        let (line, byteCol) = buf.offsetToLineCol(action.offset)
        cursorLine = line
        cursorCol = buf.byteToCharOffsetInLine(line: line, byteOffset: byteCol)
        ensureCursorVisible()
    }

    private func redo() {
        guard let buf = buffer, !redoStack.isEmpty else { return }
        let action = redoStack.removeLast()
        isUndoRedoing = true
        applyInverse(action)
        undoStack.append(action)
        isUndoRedoing = false
        modified = true

        let endOffset = action.offset + action.deleted.utf8.count
        let (line, byteCol) = buf.offsetToLineCol(min(endOffset, buf.totalLength))
        cursorLine = line
        cursorCol = buf.byteToCharOffsetInLine(line: line, byteOffset: byteCol)
        ensureCursorVisible()
    }

    func ensureCursorVisible() {
        if cursorLine < scrollY { scrollY = cursorLine }
        else if cursorLine >= scrollY + height { scrollY = cursorLine - height + 1 }
        let dispCol = displayColForChar(line: cursorLine, charCol: cursorCol)
        if dispCol < scrollX { scrollX = dispCol }
        else if dispCol >= scrollX + width - lineNumberWidth() - 1 {
            scrollX = dispCol - width + lineNumberWidth() + 2
        }
    }

    func lineNumberWidth() -> Int {
        guard let buf = buffer else { return 4 }
        return max(4, String(buf.lineCount).count + 2)
    }

    private func leadingSpaces(_ str: String) -> Int {
        var count = 0
        let t = tabWidth
        for c in str { if c == " " { count += 1 } else if c == "\t" { count += t } else { break } }
        return count
    }

    /// Ширина табуляции в клетках для текущего файла (tabstop). Go — 2, прочее — 4.
    private var tabWidth: Int {
        ((filePath as NSString?)?.pathExtension == "go") ? 2 : 4
    }

    private func charDisplayStep(_ ch: Character, atDisplayCol col: Int) -> Int {
        if ch == "\t" { let t = tabWidth; return t - (col % t) }
        let w = ch.displayWidth
        return w > 0 ? w : 0
    }

    /// display-колонка (ширина в клетках терминала), с которой начинается символ charCol на строке line.
    func displayColForChar(line: Int, charCol: Int) -> Int {
        guard let buf = buffer else { return 0 }
        let chars = buf.getLineChars(line)
        var col = 0
        for i in 0..<min(charCol, chars.count) {
            col += charDisplayStep(chars[i], atDisplayCol: col)
        }
        return col
    }

    /// Индекс первого символа строки, чья display-колонка >= target (для горизонтального скролла).
    func charIndexAtDisplayCol(line: Int, target: Int) -> Int {
        guard let buf = buffer else { return 0 }
        let chars = buf.getLineChars(line)
        var col = 0
        for (i, ch) in chars.enumerated() {
            if col >= target { return i }
            col += charDisplayStep(ch, atDisplayCol: col)
        }
        return chars.count
    }

    override func update() {
        guard let buf = buffer, height > 0, width > 4 else { return }

        clear(bg: Theme.bg)

        let lnWidth = lineNumberWidth()
        let textWidth = max(0, width - lnWidth)

        drawLineNumbers(lnWidth: lnWidth, lineCount: buf.lineCount)

        let useBuiltinTokens = semanticTokens.isEmpty && buf.lineCount < 50000
        let fileExt = (filePath as NSString?)?.pathExtension ?? ""
        let isJSON = fileExt == "json"
        let isMD = SyntaxTokenizer.isMarkdown(fileExt)
        let builtinKeywords = useBuiltinTokens && !isMD && !isJSON ? SyntaxTokenizer.keywords(for: fileExt) : nil

        var mdTokenIndex: [Int: [SemanticToken]]?
        if useBuiltinTokens && isMD {
            let mdTokens = SyntaxTokenizer.tokenizeMarkdownVisible(buffer: buf, scrollY: scrollY, height: height, cache: &markdownCache)
            var idx = [Int: [SemanticToken]]()
            idx.reserveCapacity(height)
            for t in mdTokens {
                idx[t.line, default: []].append(t)
            }
            mdTokenIndex = idx
        }

        for row in 0..<height {
            let lineNum = scrollY + row
            guard lineNum < buf.lineCount else { continue }
            let chars = buf.getLineChars(lineNum)
            let visStart = charIndexAtDisplayCol(line: lineNum, target: scrollX)

            let tokens: [SemanticToken]
            if !useBuiltinTokens {
                tokens = semanticTokensFor(line: lineNum)
            } else if let md = mdTokenIndex {
                tokens = md[lineNum] ?? []
            } else if isJSON {
                tokens = SyntaxTokenizer.tokenizeJSON(lineChars: chars, lineNum: lineNum)
            } else {
                tokens = SyntaxTokenizer.tokenize(lineChars: chars, lineNum: lineNum, keywords: builtinKeywords ?? [])
            }

            var colOffset = displayColForChar(line: lineNum, charCol: visStart) - scrollX
            var tokenIdx = 0
            for i in visStart..<chars.count {
                if colOffset >= textWidth { break }
                let absCol = i
                while tokenIdx < tokens.count && tokens[tokenIdx].startChar + tokens[tokenIdx].length <= absCol {
                    tokenIdx += 1
                }
                let tokenColor: Color
                if tokenIdx < tokens.count && absCol >= tokens[tokenIdx].startChar {
                    tokenColor = colorForTokenType(tokens[tokenIdx].type)
                } else {
                    tokenColor = Theme.fg
                }
                if chars[i] == "\t" {
                    let t = tabWidth
                    let spaces = t - (colOffset % t)
                    for _ in 0..<spaces {
                        let cellX = lnWidth + colOffset
                        if cellX < width {
                            setCell(row, cellX, Cell.colored(" ", fg: tokenColor, bg: Theme.bg))
                        }
                        colOffset += 1
                    }
                } else {
                    let w = chars[i].displayWidth
                    guard w > 0 else { continue }
                    let cellX = lnWidth + colOffset
                    if cellX < width {
                        setCell(row, cellX, Cell.colored(chars[i], fg: tokenColor, bg: Theme.bg))
                        if w == 2, cellX + 1 < width {
                            var cont = Cell.blank
                            cont.fg = tokenColor
                            cont.bg = Theme.bg
                            cont.wideContinuation = true
                            setCell(row, cellX + 1, cont)
                        }
                    }
                    colOffset += w
                }
            }
        }

        if mode == .visual { drawVisualHighlight(lnWidth: lnWidth) }
        if mode == .visualLine { drawVisualLineHighlight(lnWidth: lnWidth) }
        drawCursor(lnWidth: lnWidth)
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
        let screenCol = displayColForChar(line: cursorLine, charCol: cursorCol) - scrollX
        guard screenCol >= 0 && screenCol + lnWidth < width else { return }
        let absCol = lnWidth + screenCol
        if mode == .insert { return }
        var cell = getCell(screenRow, absCol)
        cell.reverse = true
        setCell(screenRow, absCol, cell)
    }

    private func drawVisualHighlight(lnWidth: Int) {
        let (startLine, startCol, endLine, endCol) = visualRange()
        for lineNum in startLine...endLine {
            let screenRow = lineNum - scrollY
            guard screenRow >= 0 && screenRow < height else { continue }
            guard let buf = buffer else { continue }
            let lineEnd = max(0, buf.lineCharLength(line: lineNum) - 1)
            let colStart = (lineNum == startLine) ? startCol : 0
            let colEnd = (lineNum == endLine) ? min(endCol, lineEnd) : lineEnd
            let startDisp = displayColForChar(line: lineNum, charCol: colStart)
            let endDisp = displayColForChar(line: lineNum, charCol: min(colEnd + 1, buf.lineCharLength(line: lineNum)))
            let scLo = startDisp - scrollX
            let scHi = endDisp - scrollX
            if scLo < scHi {
                for sc in scLo..<scHi {
                    guard sc >= 0 && sc + lnWidth < width else { continue }
                    let absCol = lnWidth + sc
                    var cell = getCell(screenRow, absCol)
                    cell.bg = Theme.visualBg
                    setCell(screenRow, absCol, cell)
                }
            }
        }
    }

    private func drawVisualLineHighlight(lnWidth: Int) {
        let (startLine, endLine) = visualLineRange()
        for lineNum in startLine...endLine {
            let screenRow = lineNum - scrollY
            guard screenRow >= 0 && screenRow < height else { continue }
            for col in 0..<width {
                var cell = getCell(screenRow, col)
                cell.bg = Theme.visualBg
                setCell(screenRow, col, cell)
            }
        }
    }

    private func semanticTokensFor(line: Int) -> [SemanticToken] {
        tokenIndex[line] ?? []
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
        case "punctuation": return Theme.fg
        case "namespace", "module": return Theme.magenta
        case "decorator", "attribute": return Theme.yellow
        case "regexp": return Theme.red
        case "macro": return Theme.red1
        default: return Theme.fg
        }
    }
}
