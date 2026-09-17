import SwimCore
import Foundation

class EditorWindow: Window {
    let tabs = BufferManager()

    override var availableModes: [WindowMode] { [.normal, .insert, .visual, .visualLine, .command] }

    // Per-buffer state forwarded to the active tab
    var buffer: PieceTable? { tabs.active.buffer }
    var filePath: String? { tabs.active.filePath }
    override var mode: WindowMode {
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
    var desiredCol: Int {
        get { tabs.active.desiredCol }
        set { tabs.active.desiredCol = newValue }
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
    private var mlStringStates: [SyntaxTokenizer.MultilineStringState] {
        get { tabs.active.mlStringStates }
        set { tabs.active.mlStringStates = newValue }
    }

    // Window-global state (registers, pending keys, transient UI)
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

        // LSP servers classify boolean/null literals as keywords; they are
        // values — recolor to the number (value) color, per language.
        let lspLiterals = SyntaxTokenizer.valueLiterals(for: (filePath as NSString?)?.pathExtension ?? "")

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
                if type == "keyword", start + length <= chars.count,
                   lspLiterals.contains(String(chars[start..<start + length])) {
                    type = "number"
                }
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
        cursorCol = min(buf.charIndexForUtf16(line: cursorLine, colUtf16: colUtf16),
                        buf.lineCharLength(line: cursorLine))
        desiredCol = cursorCol
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

    private var lastActiveFilePath: String?

    private func activateCurrentTab() {
        rebuildTokenIndex()
        guard let buf = buffer else { return }
        if cursorLine >= buf.lineCount { cursorLine = max(0, buf.lineCount - 1) }
        cursorCol = min(cursorCol, buf.lineCharLength(line: cursorLine))
        desiredCol = cursorCol
        ensureCursorVisible()
        dirty = true
        if filePath != lastActiveFilePath {
            lastActiveFilePath = filePath
            delegate?.activeFileChanged()
        }
    }

    override func handleKey(_ key: Key) -> Bool {
        guard buffer != nil else { return false }
        switch mode {
        case .normal: return handleNormal(key)
        case .insert: return handleInsert(key)
        case .visual: return handleVisual(key)
        case .visualLine: return handleVisualLine(key)
        case .command: return handleCommandModeKey(key)
        case .menu: return false
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
        // Both go through enterCommandMode: it resets commandCursorPos to
        // the prefill length — setting the buffer by hand leaves the caret
        // at 0 and typed text lands BEFORE the `/` prefix ("/" → "foo/",
        // the search then runs for the wrong query).
        case .char(":"): enterCommandMode()
        case .char("/"): enterCommandMode(prefill: "/")
        case .char("n"): searchNext()
        case .char("N"): searchPrev()
        case .ctrl("j"), .ctrlDown: pageDown()
        case .ctrl("k"), .ctrlUp: pageUp()
        case .ctrl("h"), .ctrlLeft: cycleTab(-1)
        case .ctrl("l"), .ctrlRight: cycleTab(1)
        default: pendingG = false; pendingD = false; pendingY = false; return false
        }
        if !isVerticalKey(key, insertMode: false) { desiredCol = cursorCol }
        dirty = true
        return true
    }

    private func handleInsert(_ key: Key) -> Bool {
        switch key {
        case .escape: mode = .normal
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
        if !isVerticalKey(key, insertMode: true) { desiredCol = cursorCol }
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
        if !isVerticalKey(key, insertMode: false) { desiredCol = cursorCol }
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
        case .char("H"), .shiftLeft: shiftVisualLines(by: -indentSize())
        case .char("L"), .shiftRight: shiftVisualLines(by: indentSize())
        default: return false
        }
        if !isVerticalKey(key, insertMode: false) { desiredCol = cursorCol }
        dirty = true
        return true
    }

    override func executeCommand(_ cmd: String) -> Bool {
        switch cmd {
        case "w":
            saveFile()
        case "wq", "x":
            saveFile()
            delegate?.handleEditorCommand("wquit")
        default:
            if cmd.hasPrefix("e! ") {
                editFile(String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            } else if cmd.hasPrefix("e ") {
                if modified { lastError = "No write since last change (add ! to override)" }
                else { editFile(String(cmd.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
            } else if cmd.hasPrefix("%s/") {
                handleSubstitute(cmd)
            } else if cmd.hasPrefix("/") {
                searchQuery = String(cmd.dropFirst())
                lastSearchForward = true
                searchNext()
            } else {
                // Window-management commands (q, q!, qa, terminal, ...)
                return super.executeCommand(cmd)
            }
        }
        return true
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
            delegate?.fileSaved()
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
    private func moveCursorUp() { moveVertically(-1) }
    private func moveCursorDown() { moveVertically(1) }

    /// Vertical moves never recompute the column from the previous clamped
    /// value — they apply the sticky desired column (vim curswant), so the
    /// column survives short lines, one-past-end positions and mode
    /// switches. One-past-end (col == line length) is a legal cursor
    /// position in every mode: insert needs it (typing appends), all
    /// consumers are bounds-guarded (x, p/P, visual yank/delete, render).
    private func moveVertically(_ delta: Int) {
        guard let buf = buffer else { return }
        cursorLine = min(max(cursorLine + delta, 0), max(0, buf.lineCount - 1))
        cursorCol = min(desiredCol, buf.lineCharLength(line: cursorLine))
        ensureCursorVisible()
    }

    /// Keys that only move vertically — excluded from the desired-column
    /// refresh at the handler tails so the want survives them. In insert
    /// mode j/k are literal text, not movement.
    private func isVerticalKey(_ key: Key, insertMode: Bool) -> Bool {
        switch key {
        case .up, .down, .pageUp, .pageDown, .ctrlUp, .ctrlDown: return true
        case .char("j"), .char("k"), .ctrl("j"), .ctrl("k"): return !insertMode
        default: return false
        }
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

    /// Extends mlStringStates (state before each line) up to `line`.
    /// Appends go directly into the tab's stored property — through-accessor
    /// or local-copy patterns COW-copy the whole array per call, which made
    /// scrolling a large file copy the array every frame.
    private func ensureMLStringStates(through line: Int, buffer: PieceTable,
                                      keywords: Set<String>, literals: Set<String>,
                                      syntax: SyntaxTokenizer.LanguageSyntax) {
        let tab = tabs.active
        while tab.mlStringStates.count <= line {
            let idx = tab.mlStringStates.count
            let initial: SyntaxTokenizer.MultilineStringState = idx == 0 ? .none : tab.mlStringStates[idx - 1]
            let chars = buffer.getLineChars(idx)
            let endState = SyntaxTokenizer.tokenize(chars: chars, lineNum: idx, keywords: keywords,
                                                    syntax: syntax, initialState: initial,
                                                    literals: literals).endState
            tab.mlStringStates.append(endState)
        }
    }

    private func trackLSPChange(offset: Int, replaced: String, inserted: String) {
        guard let buf = buffer else { return }
        // The edit invalidates multi-line string state from its line on;
        // states before the cursor line stay valid. removeSubrange goes to
        // the stored property directly — through the computed accessor it
        // would COW-copy the whole array per keystroke.
        let activeTab = tabs.active
        if !activeTab.mlStringStates.isEmpty {
            let keep = min(activeTab.mlStringStates.count, cursorLine + 1)
            if keep < activeTab.mlStringStates.count {
                activeTab.mlStringStates.removeSubrange(keep...)
            }
        }
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
        let fullLine = buf.getLine(cursorLine)
        let splitIndex = fullLine.index(fullLine.startIndex, offsetBy: cursorCol)
        let before = String(fullLine[..<splitIndex])
        let after = String(fullLine[splitIndex...])
        cursorCol = 0; cursorLine += 1
        let plan = IndentEngine.plan(
            before: before,
            after: after,
            fullLine: fullLine,
            baseIndent: leadingSpaces(fullLine),
            shiftWidth: indentSize(),
            tabWidth: tabWidth,
            lineAbove: { n in
                let idx = self.cursorLine - 1 - n
                return idx >= 0 ? buf.getLine(idx) : nil
            })
        switch plan {
        case .plain(let cursorIndent):
            if cursorIndent > 0 {
                let indentText = String(repeating: " ", count: cursorIndent)
                buf.insert(indentText, at: buf.lineStart(line: cursorLine))
                inserted += indentText
            }
            cursorCol = cursorIndent
        case .closerOnly(let bracketPad):
            if bracketPad > 0 {
                let padText = String(repeating: " ", count: bracketPad)
                buf.insert(padText, at: buf.lineStart(line: cursorLine))
                inserted += padText
            }
            cursorCol = leadingSpaces(buf.getLine(cursorLine))
        case .closerWithBody(let cursorIndent, let bracketPad):
            let padText = bracketPad > 0 ? String(repeating: " ", count: bracketPad) : ""
            let bodyText = String(repeating: " ", count: cursorIndent) + "\n" + padText
            buf.insert(bodyText, at: buf.lineStart(line: cursorLine))
            inserted += bodyText
            cursorCol = cursorIndent
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
            // join point: between the last char of the upper line and the
            // first char of the lower one — insert cursor sits past the end
            cursorCol = buf.lineCharLength(line: cursorLine)
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

    /// Shifts the visual-line selection by the per-language indent width:
    /// positive indents, negative outdents (removes at most |delta| leading
    /// spaces per line). Applied as a single undo action; the selection and
    /// mode are kept so the shift can be repeated.
    private func shiftVisualLines(by delta: Int) {
        guard let buf = buffer else { return }
        let (startLine, rawEndLine) = visualLineRange()
        // The phantom empty line after a trailing newline (its start sits
        // at totalLength) is a buffer artifact, not content — vim's visual
        // line selection never includes it; shifting it would rewrite the
        // file's trailing-newline structure. A selection consisting of the
        // phantom alone (cursor on the last empty line) shifts nothing.
        var endLine = rawEndLine
        if buf.lineStart(line: endLine) == buf.totalLength {
            if endLine == startLine { return }
            endLine -= 1
        }
        var newLines = [String]()
        var changed = false
        var cursorDelta = 0
        for line in startLine...endLine {
            let content = buf.getLine(line)
            if delta > 0 {
                newLines.append(String(repeating: " ", count: delta) + content)
                changed = true
                if line == cursorLine { cursorDelta = delta }
            } else {
                var spaces = 0
                for c in content { if c == " " { spaces += 1 } else { break } }
                let remove = min(spaces, -delta)
                newLines.append(String(content.dropFirst(remove)))
                if remove > 0 {
                    changed = true
                    if line == cursorLine { cursorDelta = -remove }
                }
            }
        }
        guard changed else { return }
        let start = buf.lineStart(line: startLine)
        let end = buf.lineEnd(line: endLine)
        let deletedText = buf.getText(range: start..<min(end, buf.totalLength))
        // Each line is rebuilt with its own terminator — "\n" or "\r\n",
        // detected from the byte gap between content end and the next line
        // start (checked against the ORIGINAL line length; suffix sniffing
        // on deletedText would double-add the newline when the last
        // selected line is the phantom empty line after a trailing one).
        var terminators = [String]()
        for line in startLine...endLine {
            let content = buf.getLine(line)
            let contentEnd = buf.lineStart(line: line) + content.utf8.count
            let nextStart = line < endLine ? buf.lineStart(line: line + 1) : end
            if contentEnd < nextStart {
                terminators.append(nextStart - contentEnd == 2 ? "\r\n" : "\n")
            } else {
                terminators.append("")
            }
        }
        var insertedText = ""
        for (i, content) in newLines.enumerated() {
            insertedText += content + terminators[i]
        }
        buf.delete(at: start, length: end - start)
        buf.insert(insertedText, at: start)
        recordAction(offset: start, deleted: deletedText, inserted: insertedText)
        cursorCol = min(max(0, cursorCol + cursorDelta), buf.lineCharLength(line: cursorLine))
        desiredCol = cursorCol
        ensureCursorVisible()
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

    private func pageDown() { moveVertically(contentHeight - 2) }
    private func pageUp() { moveVertically(-(contentHeight - 2)) }

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
        // Before the first layout the window is 0x0; the scroll math below
        // would degenerate (scrollY = 1, scrollX = lnWidth + 2) and corrupt
        // the initial view of every file opened at startup.
        guard width > 1, height > 0 else {
            scrollX = 0
            scrollY = 0
            return
        }
        if cursorLine < scrollY { scrollY = cursorLine }
        else if cursorLine >= scrollY + contentHeight { scrollY = cursorLine - contentHeight + 1 }
        let dispCol = displayColForChar(line: cursorLine, charCol: cursorCol)
        if dispCol < scrollX { scrollX = dispCol }
        else if dispCol >= scrollX + width - lineNumberWidth() - 1 {
            scrollX = dispCol - width + lineNumberWidth() + 2
        }
    }

    /// The insert-mode caret as a terminal cursor (bar, shape 5).
    override func cursorRenderInfo() -> CursorRenderInfo? {
        guard visible, focused, mode == .insert else { return nil }
        let screenRow = cursorLine - scrollY + contentTop
        let screenCol = cursorCol - scrollX
        let lnW = lineNumberWidth()
        guard screenRow >= 0 && screenRow < height, screenCol >= 0, screenCol + lnW < width else { return nil }
        return CursorRenderInfo(row: y + screenRow, col: x + lnW + screenCol, shape: 5, visible: true)
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

        drawPlate()

        let lnWidth = lineNumberWidth()
        let textWidth = max(0, width - lnWidth)

        drawLineNumbers(lnWidth: lnWidth, lineCount: buf.lineCount)

        let useBuiltinTokens = semanticTokens.isEmpty && buf.lineCount < 50000
        let fileExt = (filePath as NSString?)?.pathExtension ?? ""
        let isJSON = fileExt == "json"
        let isMD = SyntaxTokenizer.isMarkdown(fileExt)
        let builtinKeywords = !isMD && !isJSON && buf.lineCount < 50000
            ? SyntaxTokenizer.keywords(for: fileExt)
            : nil
        let builtinLiterals = !isMD && !isJSON && buf.lineCount < 50000
            ? SyntaxTokenizer.valueLiterals(for: fileExt)
            : nil

        // Language syntax profile (multi-line strings, line comments),
        // resolved once; string states built lazily up to the viewport.
        let langSyntax = SyntaxTokenizer.syntax(for: fileExt)
        if langSyntax.mlRules.isEmpty {
            if !mlStringStates.isEmpty { mlStringStates = [] }
        } else {
            ensureMLStringStates(through: min(scrollY + contentHeight, buf.lineCount),
                                 buffer: buf, keywords: builtinKeywords ?? [],
                                 literals: builtinLiterals ?? [],
                                 syntax: langSyntax)
        }

        var mdTokenIndex: [Int: [SemanticToken]]?
        if useBuiltinTokens && isMD {
            let mdTokens = SyntaxTokenizer.tokenizeMarkdownVisible(buffer: buf, scrollY: scrollY, height: contentHeight, cache: &markdownCache)
            var idx = [Int: [SemanticToken]]()
            idx.reserveCapacity(height)
            for t in mdTokens {
                idx[t.line, default: []].append(t)
            }
            mdTokenIndex = idx
        }

        for row in 0..<contentHeight {
            let lineNum = scrollY + row
            guard lineNum < buf.lineCount else { continue }
            let chars = buf.getLineChars(lineNum)
            let visStart = charIndexAtDisplayCol(line: lineNum, target: scrollX)

            let tokens: [SemanticToken]
            if !useBuiltinTokens && !isMD && !isJSON {
                // LSP semantic tokens cover only semantic entities — keywords,
                // strings and numbers are left untokenized (basedpyright) or
                // untyped (sourcekit-lsp). Layer the syntactic tokenizer
                // underneath: builtin tokens fill the gaps between LSP ones.
                let lsp = semanticTokensFor(line: lineNum)
                let initial = lineNum < mlStringStates.count ? mlStringStates[lineNum] : .none
                let builtin = SyntaxTokenizer.tokenize(chars: chars, lineNum: lineNum,
                                                        keywords: builtinKeywords ?? [],
                                                        syntax: langSyntax, initialState: initial,
                                                        literals: builtinLiterals ?? []).tokens
                let merged = builtin.filter { b in
                    !lsp.contains { l in
                        b.startChar < l.startChar + l.length && l.startChar < b.startChar + b.length
                    }
                } + lsp
                tokens = merged.sorted { $0.startChar < $1.startChar }
            } else if !useBuiltinTokens {
                tokens = semanticTokensFor(line: lineNum)
            } else if let md = mdTokenIndex {
                tokens = md[lineNum] ?? []
            } else if isJSON {
                tokens = SyntaxTokenizer.tokenizeJSON(lineChars: chars, lineNum: lineNum)
            } else {
                let initial = lineNum < mlStringStates.count ? mlStringStates[lineNum] : .none
                tokens = SyntaxTokenizer.tokenize(chars: chars, lineNum: lineNum,
                                                   keywords: builtinKeywords ?? [],
                                                   syntax: langSyntax, initialState: initial,
                                                   literals: builtinLiterals ?? []).tokens
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
                            setCell(row + contentTop, cellX, Cell.colored(" ", fg: tokenColor, bg: Theme.bg))
                        }
                        colOffset += 1
                    }
                } else {
                    let w = chars[i].displayWidth
                    guard w > 0 else { continue }
                    let cellX = lnWidth + colOffset
                    if cellX < width {
                        setCell(row + contentTop, cellX, Cell.colored(chars[i], fg: tokenColor, bg: Theme.bg))
                        if w == 2, cellX + 1 < width {
                            var cont = Cell.blank
                            cont.fg = tokenColor
                            cont.bg = Theme.bg
                            cont.wideContinuation = true
                            setCell(row + contentTop, cellX + 1, cont)
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
        for row in 0..<contentHeight {
            let lineNum = scrollY + row
            let number = lineNum < lineCount ? lineNum + 1 : nil
            let fg: Color = lineNum == cursorLine ? Theme.fg : Theme.comment
            drawLineNumberRow(row + contentTop, number: number, lnWidth: lnWidth, fg: fg, bg: Theme.bg)
        }
    }

    private func drawCursor(lnWidth: Int) {
        guard cursorLine >= scrollY && cursorLine < scrollY + contentHeight else { return }
        let screenRow = cursorLine - scrollY + contentTop
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
            let screenRow = lineNum - scrollY + contentTop
            guard screenRow >= contentTop && screenRow < height else { continue }
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
            let screenRow = lineNum - scrollY + contentTop
            guard screenRow >= contentTop && screenRow < height else { continue }
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
        case "parameter", "selfParameter", "clsParameter": return Theme.yellow
        case "operator": return Theme.blue5
        case "punctuation": return Theme.fg
        case "namespace", "module": return Theme.module
        case "decorator", "attribute": return Theme.yellow
        case "regexp": return Theme.red
        case "macro": return Theme.red1
        default: return Theme.fg
        }
    }
}
