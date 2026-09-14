import Foundation

class EditorWindow: Window {
    let tabs = BufferManager()

    // Per-buffer state forwarded to the active tab
    var buffer: PieceTable? { tabs.active.buffer }
    var filePath: String? { tabs.active.filePath }
    var mode: EditorMode {
        get { tabs.active.mode }
        set { tabs.active.mode = newValue }
    }
    var cursorLine: Int {
        get { tabs.active.cursorLine }
        set { tabs.active.cursorLine = newValue }
    }
    var cursorCol: Int {
        get { tabs.active.cursorCol }
        set { tabs.active.cursorCol = newValue }
    }
    var scrollY: Int {
        get { tabs.active.scrollY }
        set { tabs.active.scrollY = newValue }
    }
    var scrollX: Int {
        get { tabs.active.scrollX }
        set { tabs.active.scrollX = newValue }
    }
    var visualStartLine: Int {
        get { tabs.active.visualStartLine }
        set { tabs.active.visualStartLine = newValue }
    }
    var visualStartCol: Int {
        get { tabs.active.visualStartCol }
        set { tabs.active.visualStartCol = newValue }
    }
    var modified: Bool {
        get { tabs.active.modified }
        set { tabs.active.modified = newValue }
    }
    var undoStack: [(offset: Int, deleted: String, inserted: String)] {
        get { tabs.active.undoStack }
        set { tabs.active.undoStack = newValue }
    }
    var redoStack: [(offset: Int, deleted: String, inserted: String)] {
        get { tabs.active.redoStack }
        set { tabs.active.redoStack = newValue }
    }
    private var lspPendingChanges: [LSPTextChange] {
        get { tabs.active.lspPendingChanges }
        set { tabs.active.lspPendingChanges = newValue }
    }
    var semanticTokens: [SemanticToken] { tabs.active.semanticTokens }
    private var markdownCache: SyntaxTokenizer.MarkdownCache {
        get { tabs.active.markdownCache }
        set { tabs.active.markdownCache = newValue }
    }

    // Window-global state (registers, pending keys, transient UI)
    var commandBuffer: String = ""
    var yankBuffer: String = ""
    var searchQuery: String = ""
    var lastSearchForward: Bool = true
    var pendingG: Bool = false
    var pendingD: Bool = false
    var pendingY: Bool = false
    private var isUndoRedoing = false

    private var tokenIndex: [Int: [SemanticToken]] = [:]

    var lastError: String?
    var tabCount: Int { tabs.count }

    private func rebuildTokenIndex() {
        tokenIndex.removeAll(keepingCapacity: true)
        guard let buf = buffer else { return }

        var byLine = [Int: [SemanticToken]]()
        for token in semanticTokens {
            byLine[token.line, default: []].append(token)
        }

        for (line, tokens) in byLine {
            guard line >= 0, line < buf.lineCount else { continue }

            // LSP positions are UTF-16 code units; convert to grapheme indices
            // via per-line prefix sums (binary search per token boundary).
            let chars = buf.getLineChars(line)
            var prefix = [Int](repeating: 0, count: chars.count + 1)
            var units = 0
            for (i, c) in chars.enumerated() {
                units += c.isASCII ? 1 : c.utf16.count
                prefix[i + 1] = units
            }

            func graphemeIndex(ofUtf16 target: Int) -> Int {
                // prefix has chars.count + 1 entries; the full-length entry
                // (index chars.count) must be reachable or tokens ending at
                // end-of-line get truncated by one grapheme.
                var lo = 0
                var hi = chars.count + 1
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if prefix[mid] <= target { lo = mid + 1 } else { hi = mid }
                }
                return max(0, lo - 1)
            }

            var converted = [SemanticToken]()
            converted.reserveCapacity(tokens.count)
            // sourcekit-lsp marks declaration names as bare `identifier`;
            // recolor them from the declaration keyword that precedes them.
            let declTypeKeywords: Set<String> = [
                "class", "struct", "enum", "protocol", "interface", "actor",
                "extension", "typealias", "associatedtype",
            ]
            var prevKeyword: (text: String, endCol: Int)?
            for t in tokens {
                let start = graphemeIndex(ofUtf16: t.startChar)
                let end = graphemeIndex(ofUtf16: t.startChar + t.length)
                let length = max(1, end - start)
                var type = t.type
                if type == "identifier", let prev = prevKeyword,
                   start >= prev.endCol, start - prev.endCol <= 1 {
                    if declTypeKeywords.contains(prev.text) { type = "class" }
                    else if prev.text == "func" { type = "function" }
                }
                // sourcekit-lsp types signature parameters and call-site
                // argument labels as function/method; they are exactly the
                // ones immediately followed by ':' — recolor as parameter.
                if (type == "function" || type == "method"),
                   start + length < chars.count,
                   chars[start + length] == ":" {
                    type = "parameter"
                }
                if t.type == "keyword", start + length <= chars.count {
                    prevKeyword = (String(chars[start..<start + length]), start + length)
                } else {
                    prevKeyword = nil
                }
                converted.append(SemanticToken(
                    line: t.line,
                    startChar: start,
                    length: length,
                    type: type,
                    modifiers: t.modifiers
                ))
            }
            tokenIndex[line] = converted
        }
    }

    /// Positions the cursor at an LSP (line, UTF-16 column) pair, clamped to
    /// the buffer. Used by go-to-definition jumps.
    func goToPosition(line: Int, colUtf16: Int) {
        guard let buf = buffer else { return }
        cursorLine = min(max(0, line), max(0, buf.lineCount - 1))
        cursorCol = buf.charIndexForUtf16(line: cursorLine, colUtf16: colUtf16)
        clampCol()
        ensureCursorVisible()
        dirty = true
    }

    private func goToDefinition() {
        guard let buf = buffer else { return }
        let charUtf16 = buf.utf16ColForCharIndex(line: cursorLine, charIndex: cursorCol)
        delegate?.requestGoToDefinition(line: cursorLine, charUtf16: charUtf16)
    }

    /// `gb` — jump back to the position before the last `gd`.
    private func goBack() {
        delegate?.requestGoBack()
    }

    private func yank(_ text: String) {
        yankBuffer = text
        Terminal.shared.osc52Copy(text)
    }

    override init(x: Int = 0, y: Int = 0, width: Int = 0, height: Int = 0) {
        super.init(x: x, y: y, width: width, height: height)
    }

    /// Opens a file in a new tab (or switches to its existing tab).
    /// Returns true when a new tab was created (LSP didOpen needed).
    @discardableResult
    func openFile(_ path: String) -> Bool {
        let (_, isNew) = tabs.open(path: path)
        activateCurrentTab()
        return isNew
    }

    func newFile() {
        let current = tabs.active
        guard current.filePath != nil || current.modified || current.buffer.totalLength > 0 else { return }
        let old = tabs.replaceCurrent(path: "") // "" normalizes to empty -> fresh [No Name]
        if let old { delegate?.bufferClosed(old) }
        activateCurrentTab()
    }

    /// `:e [file]` — replaces the current tab (vim semantics). When the target
    /// is already open in another tab, switches there instead.
    /// Returns the discarded buffer (caller sends LSP didClose), nil on switch.
    @discardableResult
    func editFile(_ path: String) -> EditorBuffer? {
        guard !path.isEmpty else { return nil }
        let discarded = tabs.replaceCurrent(path: path)
        if let discarded { delegate?.bufferClosed(discarded) }
        activateCurrentTab()
        return discarded
    }

    /// Closes the active tab. Returns the closed buffer, or nil when refused
    /// because of unsaved changes.
    @discardableResult
    func closeCurrentTab(force: Bool) -> EditorBuffer? {
        switch tabs.closeActive(force: force) {
        case .refusedModified:
            return nil
        case .closed(let closed):
            activateCurrentTab()
            return closed
        }
    }

    /// `Ctrl+Z` — closes all other tabs except those with unsaved changes.
    /// Returns closed buffers (for LSP didClose) and the kept-modified count.
    func closeOtherTabs() -> (closed: [EditorBuffer], keptModified: Int) {
        tabs.closeOthers()
    }

    /// `gt` / `gT`
    func cycleTab(_ delta: Int) {
        tabs.cycle(delta)
        activateCurrentTab()
    }

    func findBuffer(forNormalizedPath path: String) -> EditorBuffer? {
        tabs.buffer(forNormalizedPath: path)
    }

    /// Routes LSP tokens to the owning tab. Returns true when the active tab
    /// was updated (caller must re-render).
    @discardableResult
    func applySemanticTokens(_ tokens: [SemanticToken], to target: EditorBuffer) -> Bool {
        target.semanticTokens = tokens
        guard target === tabs.active else { return false }
        rebuildTokenIndex()
        dirty = true
        return true
    }

    func tabInfos() -> [(name: String, active: Bool, modified: Bool)] {
        tabs.buffers.enumerated().map { index, buf in
            (name: buf.displayName, active: index == tabs.activeIndex, modified: buf.modified)
        }
    }

    private func activateCurrentTab() {
        rebuildTokenIndex()
        guard let buf = buffer else { return }
        if cursorLine >= buf.lineCount { cursorLine = max(0, buf.lineCount - 1) }
        clampCol()
        ensureCursorVisible()
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
        case .char("b"):
            if pendingG { pendingG = false; goBack() }
            else { moveWordBackward() }
        case .char("0"), .home: cursorCol = 0; scrollX = 0
        case .char("$"), .end: moveToEndOfLine()
        case .char("g"):
            if pendingG { cursorLine = 0; cursorCol = 0; ensureCursorVisible(); pendingG = false }
            else { pendingD = false; pendingY = false; pendingG = true; return true }
        case .char("t"):
            guard pendingG else { pendingG = false; pendingD = false; pendingY = false; return false }
            pendingG = false
            cycleTab(1)
        case .char("T"):
            guard pendingG else { pendingG = false; pendingD = false; pendingY = false; return false }
            pendingG = false
            cycleTab(-1)
        case .char("G"): cursorLine = max(0, buffer!.lineCount - 1); cursorCol = 0; ensureCursorVisible()
        case .char("i"): mode = .insert
        case .char("a"): moveCursorRight(); mode = .insert
        case .char("o"): insertNewLineBelow(); mode = .insert
        case .char("O"): insertNewLineAbove(); mode = .insert
        case .char("A"): moveToEndOfLineForInsert(); mode = .insert
        case .char("I"): cursorCol = 0; mode = .insert
        case .char("x"): deleteCharAtCursor()
        case .char("d"):
            if pendingG { pendingG = false; goToDefinition() }
            else if pendingD { deleteCurrentLine(); pendingD = false }
            else { pendingD = true; return true }
        case .char("y"):
            pendingG = false
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
        case .ctrl("j"), .ctrlDown: pageDown()
        case .ctrl("k"), .ctrlUp: pageUp()
        case .ctrl("h"), .ctrlLeft: cycleTab(-1)
        case .ctrl("l"), .ctrlRight: cycleTab(1)
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
        else if cmd == "q" || cmd == "bd" { delegate?.handleEditorCommand(cmd) }
        else if cmd == "wq" || cmd == "x" { saveFile(); delegate?.handleEditorCommand("quit") }
        else if cmd == "q!" || cmd == "forcequit" { delegate?.handleEditorCommand("forcequit") }
        else if cmd == "bd!" { delegate?.handleEditorCommand("bd!") }
        else if cmd.hasPrefix("e! ") {
            editFile(String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces))
        }
        else if cmd.hasPrefix("e ") {
            if modified { lastError = "No write since last change (add ! to override)" }
            else { editFile(String(cmd.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
        }
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
        trackLSPChange(offset: offset, replaced: deleted, inserted: inserted)
    }

    func takeLSPPendingChanges() -> [LSPTextChange] {
        let changes = lspPendingChanges
        lspPendingChanges = []
        return changes
    }

    private func trackLSPChange(offset: Int, replaced: String, inserted: String) {
        guard let buf = buffer else { return }
        let (line, byteCol) = buf.offsetToLineCol(offset)
        let startChar = buf.utf16Col(line: line, byteCol: byteCol)
        var endLine = line
        var endChar: Int
        if let lastNL = replaced.lastIndex(of: "\n") {
            endLine = line + replaced.filter { $0 == "\n" }.count
            endChar = replaced[replaced.index(after: lastNL)...].utf16.count
        } else {
            endChar = startChar + replaced.utf16.count
        }
        lspPendingChanges.append(LSPTextChange(
            startLine: line,
            startChar: startChar,
            endLine: endLine,
            endChar: endChar,
            text: inserted
        ))
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
        trackLSPChange(offset: action.offset, replaced: action.inserted, inserted: action.deleted)
        if !action.inserted.isEmpty {
            buf.delete(at: action.offset, length: action.inserted.utf8.count)
        }
        if !action.deleted.isEmpty {
            buf.insert(action.deleted, at: action.offset)
        }
    }

    private func applyForward(_ action: (offset: Int, deleted: String, inserted: String)) {
        guard let buf = buffer else { return }
        trackLSPChange(offset: action.offset, replaced: action.deleted, inserted: action.inserted)
        if !action.deleted.isEmpty {
            buf.delete(at: action.offset, length: action.deleted.utf8.count)
        }
        if !action.inserted.isEmpty {
            buf.insert(action.inserted, at: action.offset)
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
        applyForward(action)
        undoStack.append(action)
        isUndoRedoing = false
        modified = true

        let endOffset = action.offset + action.inserted.utf8.count
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
        case "parameter": return Theme.yellow
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
