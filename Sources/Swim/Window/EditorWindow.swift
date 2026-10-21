import SwimCore
import Foundation

class EditorWindow: Window {
    let tabs = BufferManager()

    override var availableModes: [WindowMode] { [.normal, .insert, .visual, .visualLine, .visualBlock, .command] }

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
    /// The virtual visual-block column (display cells) — see
    /// EditorBuffer.visualBlockCol.
    var visualBlockCol: Int {
        get { tabs.active.visualBlockCol }
        set { tabs.active.visualBlockCol = newValue }
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
    var lspDiagnostics: [LSPDiagnostic] { tabs.active.diagnostics }
    private var markdownCache: MarkdownTokenizer.Cache {
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
    /// The pending normal-mode command sequence — the vim grammar
    /// `[count1] operator [count2] motion`: a count before and after
    /// the operator (multiplied: 2d3d = 6 lines), the operator d/y/c
    /// (operator-pending), the g-prefix of two-letter commands.
    /// SwimCore.NormalPending, tested. The reset — a single point in
    /// handleNormal (the tail defer) + interruptPending for
    /// interceptions that bypass handleKey.
    var pending = NormalPending()

    /// The pending reset point OUTSIDE handleNormal: Application's
    /// global interceptions (Ctrl hotkeys, Tab focus, other windows)
    /// bypass the editor's handleKey — without this `d Ctrl+G … d`
    /// yields an unexpected `dd` (a leak class; the same principle as
    /// the paste interception below).
    func interruptPending() {
        pending.reset()
    }

    /// The command line is opened globally too (`:` in Application
    /// bypassing the window's handleKey) — the same leak class: `d : Esc d`.
    /// Entering also drops any armed substitution scope: the scope
    /// belongs to exactly one command session (armed by visual `s`
    /// AFTER this call — see EditorSelection), so an Esc'd prefill can
    /// never be resurrected by a manually typed `'<,'>` after edits.
    override func enterCommandMode(prefill: String = "") {
        pending.reset()
        pendingSubstituteScope = nil
        super.enterCommandMode(prefill: prefill)
    }

    /// The insert-mode Ctrl+V quote (i_CTRL-V): the next key is
    /// inserted literally. Insert-mode state — lives separately from
    /// NormalPending (normal sequences) by lifecycle: modes differ,
    /// they must not be mixed in one accumulator.
    var pendingLiteralNext = false
    private var isUndoRedoing = false

    /// The literal character for the insert Ctrl+V quote (vim i_CTRL-V):
    /// the key in its "raw" form — what insert mode would otherwise
    /// intercept with its own semantics. Nil — the key is not inserted
    /// literally (a motion): the quote is dropped, the key takes the
    /// usual route.
    private static func literalInsertChar(for key: Key) -> Character? {
        switch key {
        case .char(let c): return c
        case .tab: return "\t"
        case .enter: return "\r"
        case .escape: return "\u{1b}"
        case .ctrl(let c):
            // .ctrl(c) is parsed from the byte b+96 (1...26) — the
            // inverse conversion yields the control character.
            guard let a = c.asciiValue, a >= 97, a <= 122 else { return nil }
            return Character(UnicodeScalar(a - 96))
        default: return nil
        }
    }

    /// Converted (grapheme-indexed) LSP tokens of the ACTIVE tab, by line.
    /// Invariant: always mirrors the active tab's `semanticTokens` — rebuilt
    /// on tab activation and on token application, dropped by bufferReloaded
    /// when a disk reload swaps the active buffer in place (a reload brings
    /// empty semanticTokens; without the drop, files at/above the 50000-line
    /// cap would render stale converted tokens against the new content).
    private var tokenIndex: [Int: [SemanticToken]] = [:]

    /// One diagnostic clipped to a single line, in grapheme indices.
    /// `unnecessary` diagnostics (LSP tag 1 — unused imports) render as
    /// greyed text; the rest underline their range.
    private struct DiagnosticSpan {
        let startChar: Int
        let endChar: Int
        let severity: Int
        let unnecessary: Bool
        let message: String
    }

    /// Converted diagnostic spans of the ACTIVE tab, by line. Same
    /// invariant as tokenIndex: rebuilt together with it by
    /// rebuildLSPIndexes, never read for any other tab's content.
    private var diagnosticsIndex: [Int: [DiagnosticSpan]] = [:]

    var lastError: String?
    var tabCount: Int { tabs.count }

    /// The column for the status bar: in block mode — VIRTUAL (vim
    /// shows vcol, not the per-line clamp), otherwise real.
    var statusCursorCol: Int {
        mode == .visualBlock ? visualBlockCol : cursorCol
    }

    private func rebuildLSPIndexes() {
        tokenIndex.removeAll(keepingCapacity: true)
        diagnosticsIndex.removeAll(keepingCapacity: true)
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

        // Diagnostics: raw UTF-16 server ranges → per-line grapheme spans.
        // A range crossing lines contributes a span to every line it
        // touches (start/end clipped to that line); zero-length spans
        // stay gutter-only (startChar == endChar never underlines).
        for diag in lspDiagnostics {
            let firstLine = max(0, min(diag.startLine, diag.endLine))
            let lastLine = max(diag.startLine, diag.endLine)
            guard firstLine < buf.lineCount else { continue }
            for line in firstLine...min(lastLine, buf.lineCount - 1) {
                let chars = buf.getLineChars(line)
                var units = 0
                var prefix = [Int](repeating: 0, count: chars.count + 1)
                for (i, c) in chars.enumerated() {
                    units += c.isASCII ? 1 : c.utf16.count
                    prefix[i + 1] = units
                }
                func grapheme(ofUtf16 target: Int) -> Int {
                    var lo = 0
                    var hi = chars.count + 1
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if prefix[mid] <= target { lo = mid + 1 } else { hi = mid }
                    }
                    return max(0, lo - 1)
                }
                let start = line == diag.startLine ? grapheme(ofUtf16: diag.startChar) : 0
                let end = line == diag.endLine
                    ? min(grapheme(ofUtf16: diag.endChar), chars.count)
                    : chars.count
                diagnosticsIndex[line, default: []].append(DiagnosticSpan(
                    startChar: min(start, chars.count),
                    endChar: max(min(start, chars.count), min(end, chars.count)),
                    severity: diag.severity,
                    unnecessary: diag.unnecessary,
                    message: diag.message
                ))
            }
        }
    }

    /// Positions the cursor at an LSP (line, UTF-16 column) pair, clamped to
    /// the buffer. Used by go-to-definition jumps.
    func goToPosition(line: Int, colUtf16: Int) {
        guard let buf = buffer else { return }
        cursorLine = min(max(0, line), max(0, buf.lineCount - 1))
        cursorCol = min(buf.charIndexForUtf16(line: cursorLine, colUtf16: colUtf16),
                        buf.lineCharLength(line: cursorLine))
        syncDesiredCol()
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

    /// Register content + its vim-style type: a blockwise yank (visual
    /// block `y`, block paste over a selection) marks the register,
    /// and `p`/`P` then paste it as a block (at the cursor's display
    /// column, the register's lines onto consecutive lines). Every
    /// other yank resets the flag — the register type belongs to the
    /// last yank.
    private var yankIsBlockwise = false

    func yank(_ text: String, blockwise: Bool = false) {
        yankBuffer = text
        yankIsBlockwise = blockwise
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
        rebuildLSPIndexes()
        dirty = true
        return true
    }

    /// A disk reload swapped a tab's buffer in place — same tab, no
    /// activation event. When it is the active tab, the converted-token
    /// cache must be dropped now: it still mirrors the OLD content, and
    /// for files at/above the 50000-line cap the empty `semanticTokens`
    /// gate does NOT force the builtin path, so stale tokens would render
    /// against the new text until the LSP answers. Non-active tabs need
    /// nothing — activation rebuilds. (The fresh buffer arrives with
    /// empty diagnostics too; the server re-publishes for the new
    /// content, and version-guarded applies keep it monotone.)
    func bufferReloaded(_ buffer: EditorBuffer) {
        guard buffer === tabs.active else { return }
        rebuildLSPIndexes()
    }

    /// Routes a diagnostics batch to the owning tab — the exact shape of
    /// applySemanticTokens (a publish is all-or-nothing per file, so the
    /// array REPLACES the previous batch; an empty array clears).
    @discardableResult
    func applyDiagnostics(_ diagnostics: [LSPDiagnostic], to target: EditorBuffer) -> Bool {
        target.diagnostics = diagnostics
        guard target === tabs.active else { return false }
        rebuildLSPIndexes()
        dirty = true
        return true
    }

    /// Applies a background-computed line-level git status to the tab
    /// that owns `path` (the fetch runs for the file active at request
    /// time; a tab switch mid-fetch still lands the result on its
    /// buffer). Returns true when the active tab was updated (caller
    /// must re-render).
    @discardableResult
    func applyGitLineStatus(_ status: GitLineStatus?, for path: String) -> Bool {
        guard let target = findBuffer(forNormalizedPath: path) else { return false }
        target.gitStatus = status
        guard target === tabs.active else { return false }
        dirty = true
        return true
    }

    /// The diagnostic nearest a position (line, grapheme column):
    /// a span containing the position wins — zero-length spans are
    /// normalized to one-grapheme width so a position sitting exactly on
    /// them matches and both neighbors are one step away; then column
    /// distance to the span; then severity (lower = more severe); then
    /// span start. Ties are resolved deterministically by server order.
    /// Pure query over diagnosticsIndex — no cursor state involved.
    func diagnostic(at line: Int, col: Int) -> (message: String, severity: Int)? {
        let spans = diagnosticsIndex[line] ?? []
        guard !spans.isEmpty else { return nil }
        func distance(_ s: DiagnosticSpan) -> Int {
            let start = s.startChar
            let end = max(s.endChar, s.startChar + 1)
            if col >= start && col < end { return 0 }
            return col < start ? start - col : col - end + 1
        }
        guard let best = spans.min(by: { lhs, rhs in
            let dl = distance(lhs), dr = distance(rhs)
            if dl != dr { return dl < dr }
            if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
            return lhs.startChar < rhs.startChar
        }) else { return nil }
        return (message: best.message, severity: best.severity)
    }

    /// The diagnostic at the cursor — what the status bar shows. The
    /// gutter keeps showing the line's WORST severity; this answers the
    /// pointed question, so a hint under the cursor outranks an error
    /// elsewhere on the line.
    func cursorDiagnostic() -> (message: String, severity: Int)? {
        diagnostic(at: cursorLine, col: cursorCol)
    }

    func tabInfos() -> [(name: String, active: Bool, modified: Bool)] {
        tabs.buffers.enumerated().map { index, buf in
            (name: buf.displayName, active: index == tabs.activeIndex, modified: buf.modified)
        }
    }

    private var lastActiveFilePath: String?

    private func activateCurrentTab() {
        rebuildLSPIndexes()
        guard let buf = buffer else { return }
        if cursorLine >= buf.lineCount { cursorLine = max(0, buf.lineCount - 1) }
        cursorCol = min(cursorCol, buf.lineCharLength(line: cursorLine))
        syncDesiredCol()
        ensureCursorVisible()
        dirty = true
        if filePath != lastActiveFilePath {
            lastActiveFilePath = filePath
            delegate?.activeFileChanged()
        }
    }

    override func handleKey(_ key: Key) -> Bool {
        guard buffer != nil else { return false }
        // Bracketed paste arrives as one chunk and must go in verbatim —
        // routing it through the per-key path would re-run the newline
        // auto-indent on top of the text's own leading whitespace,
        // compounding the indent line by line. Routed per mode exactly
        // like the equivalent vim key: typing (insert), `p` (normal),
        // selection-replace (visual), cmdline typing (command).
        if case .paste(let raw) = key {
            // A paste is a complete input event: any pending count or
            // operator sequence (3, d, y, g) from earlier keystrokes is
            // dead — the same reset handleNormal's defer applies to any
            // non-count key. The interception sits before handleNormal,
            // so without this a stale count would leak into the next key.
            pending.reset()
            pendingLiteralNext = false
            // External text only: tabs follow the file's indent policy
            // (one tab = one indent step). The internal p/P round-trip
            // never passes through here — register content stays verbatim.
            let text = TabPolicy.expandTabs(raw, indent: indentSize())
            switch mode {
            case .insert: insertPasteAtCursor(text)
            case .normal: pasteTextAfterCursor(text)
            case .visual, .visualLine, .visualBlock: replaceSelectionWithPaste(text)
            case .command: return handleCommandModeKey(key)
            case .menu: return false
            }
            syncDesiredCol()
            dirty = true
            return true
        }
        switch mode {
        case .normal: return handleNormal(key)
        case .insert: return handleInsert(key)
        case .visual: return handleVisual(key)
        case .visualLine: return handleVisualLine(key)
        case .visualBlock: return handleVisualBlock(key)
        case .command: return handleCommandModeKey(key)
        case .menu: return false
        }
    }

    private func handleNormal(_ key: Key) -> Bool {
        // Numeric prefix: 1-9 starts the count of the active slot (an
        // operator armed → the count comes AFTER it, d3d; otherwise —
        // before, 3dd), 0 continues it.
        // A bare leading 0 is not a count: it falls through as the
        // "start of line" motion (normal — column 0, operator-pending —
        // d0). The early return comes BEFORE the defer: accumulating a
        // count does not kill the sequence.
        if case .char(let c) = key, c.isASCII, c.isNumber {
            if pending.appendDigit(c.wholeNumberValue!) { return true }
        }
        // The single-reset-point discipline: an arm point EITHER
        // explicitly keeps the sequence (keepPending — arming an
        // operator/g-prefix), OR it dies on this defer — a foreign key
        // and any departure from normal (insert/visual/command line)
        // leaves no "standing order". Leak classes closed by this
        // point: `d v … Esc d` → `dd`, `d i … Esc d`, `g x g` → `gg`,
        // `y d y` → `yy`; bypassing handleKey via global interceptions —
        // interruptPending/enterCommandMode.
        var keepPending = false
        defer { if !keepPending { pending.reset() } }
        // Vim dispatch order: gPrefix (a two-letter command in the
        // making) → operator-pending (the operator intercepts ANY
        // key — a motion under it cannot slip past) → plain normal
        // commands.
        let handled: Bool
        if pending.gPrefix {
            handled = handleGPrefix(key)
        } else if pending.op != nil {
            handled = handleOperatorPending(key, keepPending: &keepPending)
        } else {
            handled = handlePlainNormal(key, keepPending: &keepPending)
        }
        guard handled else { return false }
        if !isVerticalKey(key, insertMode: false) { syncDesiredCol() }
        dirty = true
        return true
    }

    /// The second key of a g-command (`gg`/`gt`/`gT`/`gb`/`gd`). Under
    /// an armed operator only `gg` is valid — a motion, the operator's
    /// argument (`dgg`); g-commands require no operator.
    private func handleGPrefix(_ key: Key) -> Bool {
        switch key {
        case .char("g"):
            _ = pending.takeGPrefix()
            let count = pending.takeCount()
            if let armed = pending.op {
                applyOperator(armed, motion: .fileStart, count: count)
            } else {
                goToCountedLine(defaultLine: 0, count: count)
            }
        case .char("t"):
            guard pending.op == nil else { return false }
            _ = pending.takeGPrefix()
            cycleTab(1)
        case .char("T"):
            guard pending.op == nil else { return false }
            _ = pending.takeGPrefix()
            cycleTab(-1)
        case .char("b"):
            guard pending.op == nil else { return false }
            _ = pending.takeGPrefix()
            goBack()
        case .char("d"):
            guard pending.op == nil else { return false }
            _ = pending.takeGPrefix()
            goToDefinition()
        default:
            return false
        }
        return true
    }

    /// Normal-mode commands without an armed operator: motions with a
    /// count, arming d/y/c, edits and vim aliases. false — the key is
    /// not ours (the sequence dies on handleNormal's tail defer).
    private func handlePlainNormal(_ key: Key, keepPending: inout Bool) -> Bool {
        switch key {
        case .char("h"), .left: moveCursorLeft(pending.takeCount() ?? 1)
        case .char("j"), .down: moveVertically(pending.takeCount() ?? 1)
        case .char("k"), .up: moveVertically(-(pending.takeCount() ?? 1))
        case .char("l"), .right: moveCursorRight(pending.takeCount() ?? 1)
        case .char("w"): moveByMotion(.wordForward, count: pending.takeCount())
        case .char("b"): moveByMotion(.wordBackward, count: pending.takeCount())
        case .char("e"): moveByMotion(.wordEnd, count: pending.takeCount())
        case .char("$"), .end: moveByMotion(.endOfLine, count: pending.takeCount())
        case .char("0"), .home: cursorCol = 0; desiredCol = 0; scrollX = 0
        case .char("g"):
            pending.armGPrefix()
            keepPending = true
            return true
        case .char("G"):
            goToCountedLine(defaultLine: max(0, buffer!.lineCount - 1), count: pending.takeCount())
        case .char("i"): mode = .insert
        // The insert variant of right: on the last character — one-past-end
        // (vim `a` appends rather than inserting before the last grapheme)
        case .char("a"): moveCursorRightInsert(); mode = .insert
        case .char("o"): insertNewLineBelow(); mode = .insert
        case .char("O"): insertNewLineAbove(); mode = .insert
        case .char("A"): moveToEndOfLineForInsert(); mode = .insert
        case .char("I"): cursorCol = 0; mode = .insert
        case .char("x"): deleteCharsAtCursor(pending.takeCount() ?? 1)
        case .char("d"):
            pending.arm(.d); keepPending = true; return true
        case .char("y"):
            pending.arm(.y); keepPending = true; return true
        case .char("c"):
            pending.arm(.c); keepPending = true; return true
        // vim aliases (with a count): D = d$, C = c$, S = cc; Y = y$ —
        // a deliberate difference from vim (there Y = yy, a historical
        // wart, see :h Y): the D/C/Y family is consistent — all act
        // from the cursor to the end of the line, the count as with a
        // motion (3Y = 3y$).
        case .char("D"): applyOperator(.d, motion: .endOfLine, count: pending.takeCount())
        case .char("C"): applyOperator(.c, motion: .endOfLine, count: pending.takeCount())
        case .char("Y"): applyOperator(.y, motion: .endOfLine, count: pending.takeCount())
        case .char("S"): applyLinewise(op: .c, count: pending.takeCount() ?? 1)
        case .char("p"): pasteRegister(pending.takeCount() ?? 1, before: false)
        case .char("P"): pasteRegister(pending.takeCount() ?? 1, before: true)
        case .char("u"): undo()
        case .ctrl("r"): redo()
        case .char("v"): switchVisualMode(to: .visual)
        case .char("V"): switchVisualMode(to: .visualLine)
        case .ctrl("v"): switchVisualMode(to: .visualBlock)
        // Both go through enterCommandMode: it resets commandCursorPos to
        // the prefill length — setting the buffer by hand leaves the caret
        // at 0 and typed text lands BEFORE the `/` prefix ("/" → "foo/",
        // the search then runs for the wrong query).
        case .char(":"): enterCommandMode()
        case .char("/"): enterCommandMode(prefill: "/")
        // n/N — next/previous search match (the vim standard).
        // The pending sequence dies on the defer — no explicit
        // resets needed.
        case .char("n"):
            searchNext()
        case .char("N"):
            searchPrev()
        case .ctrl("j"), .ctrlDown, .pageDown: pageCursorDown()
        case .ctrl("k"), .ctrlUp, .pageUp: pageCursorUp()
        case .ctrl("h"), .ctrlLeft: cycleTab(-1)
        case .ctrl("l"), .ctrlRight: cycleTab(1)
        default: return false
        }
        return true
    }

    /// `Ngg` / `NG` — jumps to line N (1-based), falling back to
    /// `defaultLine` (0-based line index) when no count was given.
    /// The count is resolved by the caller (the single takeCount point).
    private func goToCountedLine(defaultLine: Int, count: Int?) {
        guard let buf = buffer else { return }
        let target = count.map { $0 - 1 } ?? defaultLine
        cursorLine = min(max(0, target), max(0, buf.lineCount - 1))
        cursorCol = 0
        desiredCol = 0
        ensureCursorVisible()
    }

    private func handleInsert(_ key: Key) -> Bool {
        // Ctrl+V literal-next (vim i_CTRL-V): the next key is inserted
        // literally — in raw form, bypassing insert-mode interception:
        // Tab — a real "\t" (not an indent step), Enter — "\r" without
        // auto-indent, Esc — 0x1b, Ctrl+<c> — the control byte.
        // Control characters in the text are invisible (zero-width,
        // like combining marks — the column math stays consistent in
        // every pass through Character.displayStep); b"\t" is visible
        // through its expansion.
        // A key that is not quoted (a motion) takes the usual route.
        if pendingLiteralNext {
            pendingLiteralNext = false
            if let literal = Self.literalInsertChar(for: key) {
                insertText(String(literal))
                syncDesiredCol()
                dirty = true
                return true
            }
        }
        switch key {
        case .escape: mode = .normal
        case .enter: insertNewLineAtCursor()
        case .backspace: deleteBeforeCursor()
        case .tab: insertText(tabInsertText())
        case .char(let c): insertText(String(c))
        case .ctrl("v"): pendingLiteralNext = true
        case .left: moveCursorLeft()
        case .right: moveCursorRightInsert()
        case .up: moveCursorUp()
        case .down: moveCursorDown()
        case .pageDown: pageCursorDown()
        case .pageUp: pageCursorUp()
        case .home: cursorCol = 0; ensureCursorVisible()
        case .end: moveToEndOfLineForInsert()
        default: return false
        }
        if !isVerticalKey(key, insertMode: true) { syncDesiredCol() }
        dirty = true
        return true
    }

    override func executeCommand(_ cmd: String) -> Bool {
        switch cmd {
        case "w":
            saveFile()
        case "wq", "x":
            // Not quitting when the write didn't happen — the
            // changed-on-disk confirm may be pending or aborted.
            if saveOrConfirm() {
                delegate?.handleEditorCommand("wquit")
            }
        default:
            if cmd.hasPrefix("e! ") {
                editFile(String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            } else if cmd.hasPrefix("e ") {
                if modified { lastError = "No write since last change (add ! to override)" }
                else { editFile(String(cmd.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
            } else if let sub = Substitute.parse(cmd) {
                runSubstitute(sub)
            } else if cmd.hasPrefix("/") {
                searchQuery = String(cmd.dropFirst())
                lastSearchForward = true
                searchNext()
            } else if let line = Int(cmd), line >= 0 {
                // `:N` — go to line N (1-based); `:0` clamps to the first line.
                if let buf = buffer {
                    cursorLine = min(max(0, line - 1), max(0, buf.lineCount - 1))
                    cursorCol = 0
                    desiredCol = 0
                    ensureCursorVisible()
                    dirty = true
                }
            } else {
                // Window-management commands (q, q!, qa, terminal, ...)
                return super.executeCommand(cmd)
            }
        }
        return true
    }

    /// `:s` / `:%s` — substitution over the WHOLE buffer (`%` is
    /// accepted and ignored; a deliberate deviation — vim's bare `:s`
    /// covers the current line only); `'<,'>s` (armed by visual `s`)
    /// — over the selection's lines, and for a blockwise selection
    /// only inside the rectangle (byte windows per line). The pure
    /// half — command-line parsing, the vim-magic→ICU pattern
    /// translation, the edit plan in byte coordinates — is
    /// SwimCore.Substitute (tested); what lives here is the effects:
    /// applying the plan, the undo record, the cursor, the report.
    private func runSubstitute(_ cmd: Substitute.Command) {
        guard let buf = buffer else { return }
        guard !cmd.pattern.isEmpty else {
            lastError = "Empty pattern"
            return
        }
        let translated: String
        switch Substitute.translatePattern(cmd.pattern) {
        case .success(let icu): translated = icu
        case .failure:
            lastError = "Magic-mode prefixes (\\v \\m \\M \\V) are not supported"
            return
        }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: translated,
                                            options: cmd.ignoreCase ? [.caseInsensitive] : [])
        } catch {
            lastError = "Invalid pattern: \(cmd.pattern)"
            return
        }
        let segments = Substitute.translateReplacement(cmd.replacement)
        if Substitute.maxGroup(in: segments) > regex.numberOfCaptureGroups {
            lastError = "Illegal back reference"
            return
        }
        // The scope: the whole buffer, or the selection marks the
        // command line was armed with (visual `s`). The armed scope is
        // consumed by ANY substitute execution — the command that runs
        // is the one the user finished typing.
        let armed = pendingSubstituteScope
        pendingSubstituteScope = nil
        let lastLine = max(0, buf.lineCount - 1)
        let scopeLines: ClosedRange<Int>
        let blockSpan: VisualBlock.Span?
        switch cmd.scope {
        case .wholeBuffer:
            scopeLines = 0...lastLine
            blockSpan = nil
        case .selectionStart, .selectionEnd, .selectionRange:
            guard let sc = armed else {
                lastError = "Selection range expired — press s in visual mode"
                return
            }
            let single: Int?
            switch cmd.scope {
            case .selectionStart: single = sc.lines.lowerBound
            case .selectionEnd: single = sc.lines.upperBound
            default: single = nil
            }
            // A single mark ('< or '>) addresses one whole line; only
            // the pair carries the block's column band.
            blockSpan = single == nil ? sc.blockSpan : nil
            let base = single ?? sc.lines.lowerBound
            let raw = single != nil ? base...base : sc.lines
            scopeLines = raw.clamped(to: 0...lastLine)
        case .addressRange(let start, let end):
            // An explicitly typed range — whole lines, no column band.
            // `.` reads the cursor line as it is at execution time.
            guard let lines = Substitute.resolve(start, end,
                                                 currentLine: cursorLine,
                                                 lastLine: lastLine) else {
                lastError = "Backwards range"
                return
            }
            scopeLines = lines
            blockSpan = nil
        }
        // The plan is computed on the ORIGINAL text, one line at a
        // time — text without its terminator, so `$` anchors to the
        // line end, and a pattern cannot match across lines. A
        // block's per-line byte window restricts matches to the
        // rectangle (a line with no covered text contributes nothing).
        var lineInfos: [(index: Int, text: String, byteStart: Int, byteWindow: Range<Int>?)] = []
        lineInfos.reserveCapacity(scopeLines.count)
        for ln in scopeLines {
            var text = buf.getText(range: buf.lineStart(line: ln)..<buf.lineEnd(line: ln))
            // Strip the FULL terminator grapheme: "\n", "\r\n" (ONE
            // Character in Swift — hasSuffix("\n") is false for it and
            // the terminator would leak into the matchable text: ICU's
            // \s matches \r and \n, so `:%s/\s\+/ /g` would join every
            // CRLF line), or a lone "\r". Terminators stay in the
            // buffer — only the scanned text sheds them.
            if let last = text.last, last == "\n" || last == "\r" || last == "\r\n" {
                text.removeLast()
            }
            var window: Range<Int>? = nil
            if let span = blockSpan {
                guard let gr = blockSlice(line: ln, span: span).range,
                      gr.lowerBound < gr.upperBound else { continue }
                let lo = buf.charToByteOffsetInLine(line: ln, charIndex: gr.lowerBound)
                let hi = buf.charToByteOffsetInLine(line: ln, charIndex: gr.upperBound)
                window = lo..<hi
            }
            lineInfos.append((ln, text, buf.lineStart(line: ln), window))
        }
        let edits = Substitute.edits(lines: lineInfos, regex: regex,
                                     segments: segments, global: cmd.global)
        guard !edits.isEmpty else {
            lastError = "Pattern not found: \(cmd.pattern)"
            return
        }
        // vim shares the substitution pattern with `n`/`N`; the `/`
        // search here is literal, so it will look for the pattern's
        // text exactly as typed.
        searchQuery = cmd.pattern
        lastSearchForward = true

        // The undo record spans the whole substituted range — captured
        // BEFORE any edit lands (replacements with \r shift line
        // indices, byte arithmetic with `delta` stays exact).
        let rangeStart = buf.lineStart(line: scopeLines.lowerBound)
        let rangeEnd = buf.lineEnd(line: scopeLines.upperBound)
        let originalText = buf.getText(range: rangeStart..<rangeEnd)

        if cmd.confirm {
            pendingSubConfirm = SubConfirmSession(edits: edits,
                                                  rangeStart: rangeStart,
                                                  rangeEnd: rangeEnd,
                                                  originalText: originalText,
                                                  rawReplacement: cmd.replacement)
            enterCommandMode()
            promptNextSubstitution()
            return
        }
        // Plain path — apply in REVERSE: an edit never shifts the
        // offsets of the edits before it, so no delta bookkeeping
        // exists on this path at all.
        for edit in edits.reversed() {
            if edit.length > 0 { buf.delete(at: edit.offset, length: edit.length) }
            if !edit.replacement.isEmpty { buf.insert(edit.replacement, at: edit.offset) }
        }
        let delta = edits.reduce(0) { $0 + $1.replacement.utf8.count - $1.length }
        completeSubstitution(rangeStart: rangeStart, rangeEnd: rangeEnd,
                             originalText: originalText, delta: delta,
                             substitutions: edits.count,
                             lines: Set(edits.map(\.line)).count,
                             lastCursorOffset: edits[edits.count - 1].offset)
    }

    /// Closes a substitution — both the plain run and a finished
    /// `c`-session. The whole `:s` is ONE undo step (a composite
    /// action over the full range — vim's undo granularity; a single
    /// `u` restores every replaced line at once), the report counts
    /// what actually landed, and the cursor parks on the start of the
    /// last substitution. The equality guard: a substitution that
    /// changed no bytes (`:s/^//`) is not an edit — no undo entry, no
    /// modified flag; the report still shows, exactly like vim's.
    private func completeSubstitution(rangeStart: Int, rangeEnd: Int,
                                      originalText: String, delta: Int,
                                      substitutions: Int, lines: Int,
                                      lastCursorOffset: Int) {
        if let buf = buffer, substitutions > 0 {
            let finalText = buf.getText(range: rangeStart..<(rangeEnd + delta))
            if finalText != originalText {
                recordAction(offset: rangeStart, deleted: originalText, inserted: finalText)
            }
        }
        if lastCursorOffset >= 0 { moveCursorToOffset(lastCursorOffset) }
        lastError = Substitute.report(substitutions: substitutions, lines: lines)
        dirty = true
    }

    /// Asks the question for the upcoming edit and parks the cursor
    /// on the match (live coordinates: the original offset plus the
    /// bytes the already-applied edits added) — its line scrolls into
    /// view, the cursor pointing at the match the way vim highlights
    /// it.
    private func promptNextSubstitution() {
        guard let s = pendingSubConfirm else { return }
        if s.index >= s.edits.count { finishSubConfirm(); return }
        let edit = s.edits[s.index]
        moveCursorToOffset(edit.offset + s.delta)
        lastError = Substitute.confirmPrompt(replacement: s.rawReplacement)
        dirty = true
    }

    /// The `c`-flag key handler — the SINGLE point that mutates the
    /// session (one copy in, one write-back before anything re-reads
    /// it; with value semantics a forgotten write-back would silently
    /// drop the applied edits). y — apply and ask again; n — skip; a
    /// — apply this and every remaining one; l — apply this and stop
    /// (last); q/Esc — stop, keeping what already landed. Anything
    /// else re-asks, the write-confirm's behavior.
    private func handleSubConfirmKey(_ key: Key) {
        guard var s = pendingSubConfirm else { return }
        func applyCurrent() {
            let edit = s.edits[s.index]
            let live = edit.offset + s.delta
            if let buf = buffer {
                if edit.length > 0 { buf.delete(at: live, length: edit.length) }
                if !edit.replacement.isEmpty { buf.insert(edit.replacement, at: live) }
            }
            s.delta += edit.replacement.utf8.count - edit.length
            s.applied += 1
            s.appliedLines.insert(edit.line)
            s.lastPlacedCursor = live
        }
        switch key {
        case .char("y"), .char("Y"):
            applyCurrent(); s.index += 1
            pendingSubConfirm = s
            promptNextSubstitution()
        case .char("n"), .char("N"):
            s.index += 1
            pendingSubConfirm = s
            promptNextSubstitution()
        case .char("a"), .char("A"):
            applyCurrent()
            while s.index + 1 < s.edits.count {
                s.index += 1
                applyCurrent()
            }
            pendingSubConfirm = s
            finishSubConfirm()
        case .char("l"), .char("L"):
            applyCurrent()
            pendingSubConfirm = s
            finishSubConfirm()
        case .char("q"), .char("Q"), .escape:
            pendingSubConfirm = s
            finishSubConfirm()
        default:
            lastError = Substitute.confirmPrompt(replacement: s.rawReplacement)
        }
    }

    /// Ends the session: the composite undo record covers every
    /// applied edit, the command line is released, the report counts
    /// what landed. An all-`n`/first-`q` session leaves no trace at
    /// all — no record, no message (vim parity).
    private func finishSubConfirm() {
        guard let s = pendingSubConfirm else { return }
        pendingSubConfirm = nil
        exitCommandMode()
        if s.applied > 0 {
            completeSubstitution(rangeStart: s.rangeStart, rangeEnd: s.rangeEnd,
                                 originalText: s.originalText, delta: s.delta,
                                 substitutions: s.applied, lines: s.appliedLines.count,
                                 lastCursorOffset: s.lastPlacedCursor)
        } else {
            lastError = nil
            dirty = true
        }
    }

    private func saveFile() {
        _ = saveOrConfirm()
    }

    /// `:w` with vim's W12 guard: if the file was rewritten externally
    /// since it was read (mtime differs), refuse to clobber it silently —
    /// arm the confirm prompt and let the next key decide. The prompt is
    /// modal through command-mode ownership (the established "window
    /// owns the input line" mechanism): every key routes here, `:` and
    /// the global toggles included, and Escape cleans the state by
    /// simply leaving command mode. Returns false when nothing was
    /// written (confirm pending, aborted or failed) — `:wq`/`:x` must
    /// not quit then.
    @discardableResult
    private func saveOrConfirm() -> Bool {
        guard let path = filePath else {
            if buffer?.totalLength ?? 0 > 0 {
                lastError = "No file name"
                return false
            }
            return true
        }
        if !pendingWriteConfirm,
           let diskMtime = BufferManager.mtime(of: path),
           diskMtime != tabs.active.fileMtime {
            pendingWriteConfirm = true
            enterCommandMode()
            lastError = Self.writeConfirmPrompt
            return false
        }
        pendingWriteConfirm = false
        return performWrite()
    }

    private static let writeConfirmPrompt =
        "Changed on disk — w: write, r: reload (discard edits), q: quit, a: abort"

    /// The changed-on-disk confirm owns the command line: one key
    /// decides, anything else re-prompts (vim's modal dialog). Escape is
    /// the abort.
    override func handleCommandModeKey(_ key: Key) -> Bool {
        // The :s///c session owns the command line exactly like the
        // write-confirm below: one key decides, anything else re-asks.
        if pendingSubConfirm != nil {
            handleSubConfirmKey(key)
            dirty = true
            return true
        }
        guard pendingWriteConfirm else { return super.handleCommandModeKey(key) }
        switch key {
        case .char("w"), .char("W"):
            pendingWriteConfirm = false
            exitCommandMode()
            _ = performWrite()
        case .char("r"), .char("R"):
            pendingWriteConfirm = false
            exitCommandMode()
            delegate?.reloadActiveBufferDiscardingEdits()
        case .char("q"), .char("Q"):
            pendingWriteConfirm = false
            exitCommandMode()
            delegate?.handleEditorCommand("q!")
        case .char("a"), .char("A"), .escape:
            pendingWriteConfirm = false
            exitCommandMode()
            lastError = "Write aborted"
        default:
            lastError = Self.writeConfirmPrompt
        }
        dirty = true
        return true
    }

    @discardableResult
    private func performWrite() -> Bool {
        guard let path = filePath, let buf = buffer else { return false }
        let text = buf.getAllText()
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            modified = false
            tabs.noteSaved()
            lastError = nil
            delegate?.fileSaved()
            return true
        } catch {
            lastError = "Error saving: \(error.localizedDescription)"
            return false
        }
    }

    /// The changed-on-disk confirm prompt is armed (see `saveOrConfirm`)
    /// while the user answers it.
    private var pendingWriteConfirm = false

    /// Interactive `:s///c` session state. The plan is precomputed on
    /// the original text; each applied edit updates `delta`, so the
    /// next edit's live position is its original offset plus that
    /// delta (edits are walked in ascending order — only the edits
    /// BEFORE the current one shift it). Like the write-confirm, the
    /// session owns the command line: command-mode routing is the
    /// first consumer of every key (Application.handleGlobalKey), so
    /// nothing else can touch the buffer mid-session and the
    /// precomputed offsets only ever meet `delta`.
    private struct SubConfirmSession {
        let edits: [Substitute.Edit]     // ascending by offset
        let rangeStart: Int              // original bytes, incl. the last line's \n
        let rangeEnd: Int
        let originalText: String
        let rawReplacement: String
        var index = 0
        var delta = 0                    // bytes added by the applied edits
        var applied = 0
        var appliedLines = Set<Int>()
        var lastPlacedCursor = -1        // live offset of the last applied edit
    }

    private var pendingSubConfirm: SubConfirmSession?

    /// The selection scope armed by `s` in a visual mode — the lines
    /// (and, for a block, its display span) the typed `'<,'>s/…`
    /// command runs on. Lifecycle, stale-proof by construction:
    /// armed by the visual `s` AFTER enterCommandMode (entering a
    /// command line clears any previous scope), consumed by the next
    /// :s execution, and unreachable by buffer edits — the command
    /// line owns every key between arming and Enter, so no edit can
    /// shift the captured line numbers.
    struct SubstitutionScope {
        let lines: ClosedRange<Int>
        let blockSpan: VisualBlock.Span?   // nil — charwise/linewise
    }

    /// Internal, not private: EditorSelection (another file of the
    /// same target) arms it from the visual `s` handler.
    var pendingSubstituteScope: SubstitutionScope?

    func moveCursorLeft(_ n: Int = 1) {
        cursorCol = max(0, cursorCol - n)
        ensureCursorVisible()
    }
    func moveCursorRight(_ n: Int = 1) {
        guard let buf = buffer else { return }
        let maxCol = max(0, buf.lineCharLength(line: cursorLine) - 1)
        if cursorCol < maxCol { cursorCol = min(cursorCol + n, maxCol) }
        ensureCursorVisible()
    }
    private func moveCursorRightInsert() {
        guard let buf = buffer else { return }
        if cursorCol < buf.lineCharLength(line: cursorLine) { cursorCol += 1 }
        ensureCursorVisible()
    }
    func moveCursorUp() { moveVertically(-1) }
    func moveCursorDown() { moveVertically(1) }

    /// Vertical moves never recompute the column from the previous clamped
    /// value — they apply the sticky desired column (vim curswant), so the
    /// column survives short lines, one-past-end positions and mode
    /// switches. One-past-end (col == line length) is a legal cursor
    /// position in every mode: insert needs it (typing appends), all
    /// consumers are bounds-guarded (x, p/P, visual yank/delete, render).
    private func moveVertically(_ delta: Int) {
        guard let buf = buffer else { return }
        cursorLine = min(max(cursorLine + delta, 0), max(0, buf.lineCount - 1))
        // curswant in display cells: resolved into a grapheme via
        // charIndex(atDisplayCol:) — the TARGET line's tab layout does
        // not shift the wanted screen column (vim parity). A target
        // inside a tab/past the end — the first grapheme at/after it
        // (or one-past-end).
        cursorCol = charIndexAtDisplayCol(line: cursorLine, target: desiredCol)
        ensureCursorVisible()
    }

    /// The single point that records curswant after horizontal moves and
    /// edits: desiredCol lives in display cells (the screen column,
    /// like vim's curswant), not in graphemes — vertical moves read it
    /// through charIndexAtDisplayCol, so moving to a line with a
    /// different tab layout does not shift the wanted column. Vertical
    /// keys do NOT reach here (stickiness, see isVerticalKey).
    func syncDesiredCol() {
        desiredCol = displayColForChar(line: cursorLine, charCol: cursorCol)
    }

    /// Keys that only move vertically — excluded from the desired-column
    /// refresh at the handler tails so the want survives them. In insert
    /// mode j/k are literal text, not movement.
    func isVerticalKey(_ key: Key, insertMode: Bool) -> Bool {
        switch key {
        case .up, .down, .pageUp, .pageDown, .ctrlUp, .ctrlDown: return true
        case .char("j"), .char("k"), .ctrl("j"), .ctrl("k"): return !insertMode
        default: return false
        }
    }
    private func moveToEndOfLineForInsert() {
        guard let buf = buffer else { return }
        cursorCol = buf.lineCharLength(line: cursorLine)
    }

    private func moveCursorToOffset(_ offset: Int) {
        guard let buf = buffer else { return }
        let (line, byteCol) = buf.offsetToLineCol(offset)
        cursorLine = line
        cursorCol = buf.byteToCharOffsetInLine(line: line, byteOffset: byteCol)
        // The cursor-setting primitive owns curswant: a search jump from
        // command mode bypasses handleNormal's tail — without this
        // desiredCol would go stale until the next horizontal key.
        syncDesiredCol()
        ensureCursorVisible()
    }

    func recordAction(offset: Int, deleted: String, inserted: String) {
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

    /// Extends mlStringStates up to `line`. Entry N holds the state AFTER
    /// line N; consumers tokenize line N starting from mlStringStates[N - 1].
    /// The pure walk lives in SwimCore (SyntaxTokenizer.extendStringStates —
    /// shared with Highlight.Session); the inout goes at the ladder as a
    /// STORED property of the tab class via the local reference — a direct
    /// address, in-place appends. Through the window-level computed
    /// accessor it would be copy-in-copy-out, COW-copying the whole array
    /// per call — the scrolling regression this shape once fixed.
    private func ensureMLStringStates(through line: Int, buffer: PieceTable,
                                      keywords: Set<String>, literals: Set<String>,
                                      syntax: SyntaxTokenizer.LanguageSyntax) {
        let tab = tabs.active
        SyntaxTokenizer.extendStringStates(&tab.mlStringStates, through: line, buffer: buffer,
                                           keywords: keywords, literals: literals, syntax: syntax)
    }

    private func trackLSPChange(offset: Int, replaced: String, inserted: String) {
        guard let buf = buffer else { return }
        let (line, byteCol) = buf.offsetToLineCol(offset)
        // The edit rewrites line `line` itself, so its end-state entry and
        // every later one are stale; entries strictly above the edit are
        // untouched by construction and survive. The anchor is the edit
        // line derived from `offset` — NOT the cursor line: undo/redo and
        // other offset-addressed edits can rewrite lines far from where
        // the cursor sits now. removeSubrange goes to the stored property
        // directly — through the computed accessor it would COW-copy the
        // whole array per keystroke.
        let activeTab = tabs.active
        if !activeTab.mlStringStates.isEmpty {
            let keep = min(activeTab.mlStringStates.count, line)
            if keep < activeTab.mlStringStates.count {
                activeTab.mlStringStates.removeSubrange(keep...)
            }
        }
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

    /// The text the Tab key inserts: the file's indent policy — one
    /// indent step of spaces (indentSize), the same width the
    /// auto-indenter produces.
    private func tabInsertText() -> String {
        String(repeating: " ", count: indentSize())
    }

    /// Bulk insert with no indent processing — the paste path. The
    /// cursor lands after the pasted text (last line, after the last
    /// char).
    private func insertPasteAtCursor(_ text: String) {
        guard let buf = buffer, !text.isEmpty else { return }
        let byteOff = buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
        let offset = buf.lineStart(line: cursorLine) + byteOff
        buf.insert(text, at: offset)
        recordAction(offset: offset, deleted: "", inserted: text)
        let delta = MultilineInsert.cursorDelta(for: text)
        cursorLine += delta.lines
        if delta.lines > 0 { cursorCol = delta.tailCols } else { cursorCol += delta.tailCols }
        ensureCursorVisible()
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

    func indentSize() -> Int {
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

    private func pasteAfter() {
        guard !yankBuffer.isEmpty else { return }
        // A blockwise register pastes as a block: for it p and P
        // coincide — "before/after" is meaningless for a rectangle,
        // the paste goes into the cursor's column (see pasteBlock).
        if yankIsBlockwise { pasteBlock(); return }
        pasteTextAfterCursor(yankBuffer)
    }

    /// `p`/`P` with a count (vim): the register is pasted N times in one
    /// edit (a single undo step). A blockwise register ignores the
    /// count — "after" is meaningless for a rectangle, it goes into
    /// the column anyway.
    private func pasteRegister(_ count: Int, before: Bool) {
        guard !yankBuffer.isEmpty else { return }
        if yankIsBlockwise {
            if before { pasteBefore() } else { pasteAfter() }
            return
        }
        let text = count > 1 ? String(repeating: yankBuffer, count: count) : yankBuffer
        if before { pasteTextBeforeCursor(text) } else { pasteTextAfterCursor(text) }
    }

    /// Inserts text like `p` — after the cursor (charwise) or below the
    /// line (linewise, trailing "\n"). Multiline charwise text leaves the
    /// cursor ON the last pasted grapheme (vim `p`); `P` in
    /// pasteTextBeforeCursor instead ends one past it.
    private func pasteTextAfterCursor(_ text: String) {
        guard let buf = buffer, !text.isEmpty else { return }
        let offset: Int
        if MultilineInsert.endsWithLineBreak(text) {
            offset = buf.lineEnd(line: cursorLine)
            buf.insert(text, at: offset)
            cursorLine += 1; cursorCol = 0
        } else {
            let charAfterOff = buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol + 1)
            offset = buf.lineStart(line: cursorLine) + charAfterOff
            buf.insert(text, at: offset)
            let delta = MultilineInsert.cursorDelta(for: text)
            cursorLine += delta.lines
            cursorCol = delta.lines > 0 ? delta.tailCols : cursorCol + delta.tailCols
        }
        recordAction(offset: offset, deleted: "", inserted: text)
        ensureCursorVisible()
    }

    private func pasteBefore() {
        guard !yankBuffer.isEmpty else { return }
        if yankIsBlockwise { pasteBlock(); return }
        pasteTextBeforeCursor(yankBuffer)
    }

    /// Inserts text like `P` — before the cursor (charwise) or above
    /// the line (linewise, trailing "\n"). Cursor convention: one past
    /// the last pasted char (pasteTextAfterCursor instead leaves the
    /// cursor ON the last pasted grapheme — the two differ by one).
    /// Multiline
    /// charwise text (a visual yank ending mid-line has no trailing
    /// "\n") needs the same line/column delta math — a plain
    /// `cursorCol += text.count` counts newlines as columns and pushes
    /// the cursor past the line end.
    private func pasteTextBeforeCursor(_ text: String) {
        guard let buf = buffer, !text.isEmpty else { return }
        let offset: Int
        if MultilineInsert.endsWithLineBreak(text) {
            offset = buf.lineStart(line: cursorLine)
            buf.insert(text, at: offset)
            cursorCol = 0
        } else {
            offset = buf.lineStart(line: cursorLine) + buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
            buf.insert(text, at: offset)
            let delta = MultilineInsert.cursorDelta(for: text)
            cursorLine += delta.lines
            cursorCol = delta.lines > 0 ? delta.tailCols : cursorCol + delta.tailCols
        }
        recordAction(offset: offset, deleted: "", inserted: text)
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

    /// The paging jump (vim Ctrl-F/Ctrl-B): a page minus two context
    /// lines, at least one. The delta is shared by all modes:
    /// normal/insert/visual/visualLine go through moveVertically
    /// (cursor primitives), visual-block — through moveBlockVertically
    /// (moveVertically's grapheme clamping would break the virtual
    /// corner).
    var pageDelta: Int { max(1, contentHeight - 2) }

    func pageCursorDown() { moveVertically(pageDelta) }
    func pageCursorUp() { moveVertically(-pageDelta) }

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
        // In block mode the scroll follows the VIRTUAL column — the
        // rectangle's edge stays visible even past a short line's end.
        let dispCol = mode == .visualBlock
            ? visualBlockCol
            : displayColForChar(line: cursorLine, charCol: cursorCol)
        if dispCol < scrollX { scrollX = dispCol }
        else if dispCol >= scrollX + width - lineNumberWidth() - 1 {
            scrollX = dispCol - width + lineNumberWidth() + 2
        }
    }

    /// The insert-mode caret as a terminal cursor — the shared
    /// insert bar (see CursorRenderInfo.insertCaret).
    override func cursorRenderInfo() -> CursorRenderInfo? {
        guard visible, focused, mode == .insert else { return nil }
        let screenRow = cursorLine - scrollY + contentTop
        let screenCol = cursorCol - scrollX
        let lnW = lineNumberWidth()
        guard screenRow >= 0 && screenRow < height, screenCol >= 0, screenCol + lnW < width else { return nil }
        return .insertCaret(row: y + screenRow, col: x + lnW + screenCol)
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

    /// The tab width in cells for the current file (tabstop). Go — 2, everything else — 4.
    var tabWidth: Int {
        ((filePath as NSString?)?.pathExtension == "go") ? 2 : 4
    }

    /// The display-column step — a delegate of the shared authority
    /// (Character.displayStep in SwimCore): rendering, scrolling and
    /// visual-block all count tabs/wide characters identically.
    func charDisplayStep(_ ch: Character, atDisplayCol col: Int) -> Int {
        ch.displayStep(atDisplayCol: col, tabWidth: tabWidth)
    }

    /// The display column (width in terminal cells) where charCol starts on line.
    func displayColForChar(line: Int, charCol: Int) -> Int {
        guard let buf = buffer else { return 0 }
        return VisualBlock.displayCol(ofCharIndex: charCol, chars: buf.getLineChars(line), tabWidth: tabWidth)
    }

    /// The index of the line's first character whose display column is >= target (for horizontal scrolling).
    func charIndexAtDisplayCol(line: Int, target: Int) -> Int {
        guard let buf = buffer else { return 0 }
        return VisualBlock.charIndex(atDisplayCol: target, chars: buf.getLineChars(line), tabWidth: tabWidth)
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
        let isMD = MarkdownTokenizer.isMarkdown(fileExt)
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
            let mdTokens = MarkdownTokenizer.tokenizeVisible(buffer: buf, scrollY: scrollY, height: contentHeight, cache: &markdownCache)
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
                // underneath: builtin tokens fill the gaps between LSP ones
                // (merge rules — including f-string interpolation handling —
                // live in SyntaxTokenizer.mergeWithLSP, covered by tests).
                let lsp = semanticTokensFor(line: lineNum)
                let initial = lineNum > 0 && lineNum - 1 < mlStringStates.count ? mlStringStates[lineNum - 1] : .none
                tokens = SyntaxTokenizer.mergeWithLSP(
                    builtin: SyntaxTokenizer.tokenize(chars: chars, lineNum: lineNum,
                                                      keywords: builtinKeywords ?? [],
                                                      syntax: langSyntax, initialState: initial,
                                                      literals: builtinLiterals ?? []).tokens,
                    lsp: lsp)
            } else if !useBuiltinTokens {
                tokens = semanticTokensFor(line: lineNum)
            } else if let md = mdTokenIndex {
                tokens = md[lineNum] ?? []
            } else if isJSON {
                tokens = SyntaxTokenizer.tokenizeJSON(lineChars: chars, lineNum: lineNum)
            } else {
                let initial = lineNum > 0 && lineNum - 1 < mlStringStates.count ? mlStringStates[lineNum - 1] : .none
                tokens = SyntaxTokenizer.tokenize(chars: chars, lineNum: lineNum,
                                                   keywords: builtinKeywords ?? [],
                                                   syntax: langSyntax, initialState: initial,
                                                   literals: builtinLiterals ?? []).tokens
            }

            var colOffset = displayColForChar(line: lineNum, charCol: visStart) - scrollX
            var tokenIdx = 0
            let diagSpans = diagnosticsIndex[lineNum] ?? []
            func spanStyle(at col: Int) -> (underline: Bool, grey: Bool) {
                var underline = false
                var grey = false
                for span in diagSpans where col >= span.startChar && col < span.endChar {
                    if span.unnecessary { grey = true } else { underline = true }
                }
                return (underline, grey)
            }
            for i in visStart..<chars.count {
                if colOffset >= textWidth { break }
                let absCol = i
                while tokenIdx < tokens.count && tokens[tokenIdx].startChar + tokens[tokenIdx].length <= absCol {
                    tokenIdx += 1
                }
                let style = spanStyle(at: absCol)
                let tokenColor: Color
                if style.grey {
                    // LSP Unnecessary tag (unused imports): the standard
                    // greyed-out rendering, not an underline.
                    tokenColor = Theme.comment
                } else if tokenIdx < tokens.count && absCol >= tokens[tokenIdx].startChar {
                    tokenColor = Theme.color(forToken: tokens[tokenIdx].type)
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
                        var cell = Cell.colored(chars[i], fg: tokenColor, bg: Theme.bg)
                        cell.underline = style.underline
                        setCell(row + contentTop, cellX, cell)
                        if w == 2, cellX + 1 < width {
                            var cont = Cell.blank
                            cont.fg = tokenColor
                            cont.bg = Theme.bg
                            cont.wideContinuation = true
                            cont.underline = style.underline
                            setCell(row + contentTop, cellX + 1, cont)
                        }
                    }
                    colOffset += w
                }
            }
        }

        if isVisualMode { drawVisualSelection(lnWidth: lnWidth) }
        drawCursor(lnWidth: lnWidth)
    }

    private func drawLineNumbers(lnWidth: Int, lineCount: Int) {
        guard height > 0 else { return }
        let git = tabs.active.gitStatus
        for row in 0..<contentHeight {
            let lineNum = scrollY + row
            let number = lineNum < lineCount ? lineNum + 1 : nil
            // Git gutter: unstaged (Theme.unstagedColor) > new file
            // (green) > staged (Theme.stagedColor) — a line touched in
            // both trees shows the unstaged state, the one the next
            // save would write; uncolored lines keep the plain gutter
            // colors.
            var fg = lineNum == cursorLine ? Theme.fg : Theme.comment
            if let git {
                if git.unstaged.contains(lineNum) {
                    fg = Theme.unstagedColor
                } else if git.isNewFile {
                    fg = Theme.green
                } else if git.staged.contains(lineNum) {
                    fg = Theme.stagedColor
                }
            }
            // Diagnostics no longer paint the number — a marker sits in
            // the trailing gutter cell instead: • red for errors, orange
            // for warnings, yellow for info/hints. An error AND a
            // warning on one line collapse into one small square (▪,
            // half the cell) in the worst severity's color — two
            // differently-colored marks in one cell are impossible below
            // the full-cell fg/bg split (an fg/bg half-fill floods the
            // whole cell), so the shape difference carries the "more
            // than one problem" signal.
            var mark: (char: Character, fg: Color, bg: Color)?
            let diags = diagnosticsIndex[lineNum] ?? []
            if !diags.isEmpty {
                let hasError = diags.contains { $0.severity <= 1 }
                let hasWarning = diags.contains { $0.severity == 2 }
                if hasError && hasWarning {
                    mark = ("▪", Theme.red, Theme.bg)
                } else if hasError {
                    mark = ("•", Theme.red, Theme.bg)
                } else if hasWarning {
                    mark = ("•", Theme.orange, Theme.bg)
                } else {
                    mark = ("•", Theme.yellow, Theme.bg)
                }
            }
            drawLineNumberRow(row + contentTop, number: number, lnWidth: lnWidth, fg: fg, bg: Theme.bg, mark: mark)
        }
    }

    private func drawCursor(lnWidth: Int) {
        guard cursorLine >= scrollY && cursorLine < scrollY + contentHeight else { return }
        let screenRow = cursorLine - scrollY + contentTop
        // In block mode the caret sits on the VIRTUAL cell (including
        // past the line's end); if it lands on a wide glyph's
        // continuation cell, shift to the glyph's start — the renderer
        // does not draw the continuation, the caret would become
        // invisible.
        let dispCol = mode == .visualBlock
            ? visualBlockCol
            : displayColForChar(line: cursorLine, charCol: cursorCol)
        let screenCol = dispCol - scrollX
        guard screenCol >= 0 && screenCol + lnWidth < width else { return }
        var absCol = lnWidth + screenCol
        if absCol > lnWidth, getCell(screenRow, absCol).wideContinuation {
            absCol -= 1
        }
        if mode == .insert { return }
        var cell = getCell(screenRow, absCol)
        cell.reverse = true
        setCell(screenRow, absCol, cell)
    }

    private func semanticTokensFor(line: Int) -> [SemanticToken] {
        tokenIndex[line] ?? []
    }
}
