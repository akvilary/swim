import SwimCore
import Foundation

/// The editor's selection subsystem — all the mechanics of the three
/// visual modes (`.visual` charwise, `.visualLine` linewise,
/// `.visualBlock` blockwise) in one place, as an EditorWindow
/// extension. Separation of responsibilities:
/// - STATE — per-tab in EditorBuffer (the anchor `visualStartLine/Col`,
///   the block's virtual column `visualBlockCol`, the mode); the
///   extension stores nothing;
/// - GEOMETRY — `VisualSelection`: the mode only defines the
///   "anchor + cursor → geometry" projection; all operators consume a
///   single value resolved once per operation;
/// - PURE MATH (display columns, slices, line reassembly) —
///   SwimCore/VisualBlock.swift, tested;
/// - APPLICATION — contiguous edits directly into the PieceTable,
///   multi-line ones — through `applyBlockEdit` (one contiguous
///   replace, the undo model is unchanged);
/// - INVARIANTS: finishing operators (`y`/`d`/`x`/paste-over) return
///   to normal themselves; `H`/`L`-shift mode deliberately persists;
///   `cursorCol` is always real (in block mode — the grapheme boundary
///   at/after the virtual column).
/// Mode movement is NOT unified — each has its own physical semantics
/// (grapheme clamping / lines only / virtual cells).
extension EditorWindow {

    // MARK: - Geometry

    /// The resolved selection geometry — the shared currency of all visual modes.
    enum VisualSelection {
        case charwise(startLine: Int, startCol: Int, endLine: Int, endCol: Int)
        case linewise(ClosedRange<Int>)
        case blockwise(rows: ClosedRange<Int>, span: VisualBlock.Span)
    }

    var isVisualMode: Bool {
        mode == .visual || mode == .visualLine || mode == .visualBlock
    }

    /// The "anchor + cursor → geometry" projection of the current mode.
    func visualSelection() -> VisualSelection? {
        switch mode {
        case .visual:
            let (startLine, startCol, endLine, endCol) = visualRange()
            return .charwise(startLine: startLine, startCol: startCol,
                             endLine: endLine, endCol: endCol)
        case .visualLine:
            let (startLine, endLine) = visualLineRange()
            return .linewise(startLine...endLine)
        case .visualBlock:
            let (rows, span) = blockRowsAndSpan()
            return .blockwise(rows: rows, span: span)
        default:
            return nil
        }
    }

    func visualRange() -> (startLine: Int, startCol: Int, endLine: Int, endCol: Int) {
        if visualStartLine < cursorLine || (visualStartLine == cursorLine && visualStartCol < cursorCol) {
            return (visualStartLine, visualStartCol, cursorLine, cursorCol)
        }
        return (cursorLine, cursorCol, visualStartLine, visualStartCol)
    }

    func visualLineRange() -> (startLine: Int, endLine: Int) {
        if visualStartLine <= cursorLine {
            return (visualStartLine, cursorLine)
        }
        return (cursorLine, visualStartLine)
    }

    /// The rows and display bounds of the current block — pure wiring
    /// of per-tab state into the tested VisualBlock.blockGeometry:
    /// the real anchor (the anchor line's graphemes, `?? []` without a
    /// buffer — parity with the former guard: the anchor in cell 0) +
    /// the virtual corner (cells) → min/max rows + a span with
    /// inclusive corners.
    /// No math remains here — the "missing cell with Ctrl+V + h"
    /// regression lived in this composition; now it is in SwimCore
    /// under tests. Columns are in terminal cells, so lines with tabs
    /// and wide characters yield an honest rectangle.
    func blockRowsAndSpan() -> (rows: ClosedRange<Int>, span: VisualBlock.Span) {
        let anchorChars = buffer?.getLineChars(visualStartLine) ?? []
        return VisualBlock.blockGeometry(anchorLine: visualStartLine,
                                         anchorCharCol: visualStartCol,
                                         cursorLine: cursorLine,
                                         cursorBlockCol: visualBlockCol,
                                         anchorChars: anchorChars,
                                         tabWidth: tabWidth)
    }

    /// The block's slice on a line (a grapheme range, nil — the line is
    /// outside the block) — pure resolution of VisualBlock over the
    /// line's content.
    /// Without a buffer it degrades to an empty slice ([], nil) rather
    /// than crashing: an internal method with a force-unwrap would be a
    /// landmine for a future caller.
    func blockSlice(line: Int, span: VisualBlock.Span) -> (chars: [Character], range: Range<Int>?) {
        guard let buf = buffer else { return ([], nil) }
        let chars = buf.getLineChars(line)
        return (chars, VisualBlock.charRange(chars, span: span, tabWidth: tabWidth))
    }

    /// `s` in any visual mode — the substitute prefill. The selection's
    /// geometry is resolved ONCE (its lines; a block also lends its
    /// display span), the command line opens with `'<,'>s/` ready for
    /// the pattern, and the scope is armed for exactly this command
    /// session: `enterCommandMode` (called first, below) has already
    /// cleared any stale scope, the command line then owns every key
    /// (no edit can shift the captured lines), and the next :s
    /// execution consumes it. A deviation from vim, deliberate: in vim
    /// visual `s` deletes the selection and enters insert; here it is
    /// the substitute prefill (the project's choice — the range comes
    /// to the command line instead of a register).
    func prefillSubstituteFromSelection() {
        guard let sel = visualSelection() else { return }
        let lines: ClosedRange<Int>
        var span: VisualBlock.Span? = nil
        switch sel {
        case .charwise(let startLine, _, let endLine, _):
            lines = startLine...endLine          // whole lines — the '<,'> semantic
        case .linewise(let range):
            lines = range
        case .blockwise(let rows, let blockSpan):
            lines = rows
            span = blockSpan
        }
        enterCommandMode(prefill: "'<,'>s/")
        pendingSubstituteScope = SubstitutionScope(lines: lines, blockSpan: span)
    }

    /// `a` in any visual mode — select ALL of the buffer's content (the
    /// project's mapping; vim has no bare visual `a` — there it is only
    /// a text-object prefix, which swim does not have). The MODE is
    /// preserved, only the geometry grows: charwise spans (0,0)…(last
    /// line, its last char — endCol is inclusive in the selection
    /// model, so a phantom last line still selects through the final
    /// line break), linewise covers 0…lastLine, blockwise takes every
    /// row with the rectangle widened to the widest line's display
    /// width (the block's virtual column does not shrink on shorter
    /// lines, so one width honestly covers everything). The cursor
    /// lands on the far corner and scrolls into view.
    func selectAllContent() {
        guard let buf = buffer else { return }
        // Guard the mode FIRST: no state is touched on a foreign call
        // (unreachable from the three handlers, but a method that
        // mutates shared state does not lean on its callers' purity)
        switch mode {
        case .visual, .visualLine, .visualBlock: break
        default: return
        }
        let lastLine = max(0, buf.lineCount - 1)
        visualStartLine = 0
        switch mode {
        case .visual:
            visualStartCol = 0
            cursorLine = lastLine
            // endCol is INCLUSIVE (the consumers read endCol + 1) —
            // park ON the last char, not past it; an empty/phantom
            // line takes 0 (its start already sits past the final
            // line break)
            cursorCol = max(0, buf.lineCharLength(line: lastLine) - 1)
        case .visualLine:
            cursorLine = lastLine
            cursorCol = min(cursorCol, buf.lineCharLength(line: lastLine))
        case .visualBlock:
            visualStartCol = 0
            var width = 0
            for ln in 0...lastLine {
                width = max(width, displayColForChar(line: ln,
                                                     charCol: buf.lineCharLength(line: ln)))
            }
            visualBlockCol = max(width, 1)
            cursorLine = lastLine
        default:
            return
        }
        ensureCursorVisible()
    }

    // MARK: - Mode transitions

    /// The single transition matrix between visual modes (v/V/Ctrl+V
    /// from normal and from any visual). Anchor rules:
    /// - from normal the anchor = the cursor position (visual/block —
    ///   line+col, visualLine — line only);
    /// - visual ↔ block: the anchor is preserved (a shared entry point);
    /// - visualLine → visual/block: the col anchor = the cursor column
    ///   (linewise selection has no column of its own), the line anchor
    ///   is preserved;
    /// - block → visual/visualLine: nothing — the cursor is already
    ///   real (syncCursorToBlockCol holds the grapheme boundary).
    /// Entering block mode initializes the virtual column: from normal —
    /// from the real cursor; from visual/visualLine — from the sticky
    /// curswant (desiredCol), see the corner comment below.
    ///
    /// A deliberate difference from vim: pressing the same mode's key
    /// again in vim finishes the mode (:h v_v — the transition table);
    /// swim ignores it — the selection lives until Esc/an operator (a
    /// project decision, see ARCHITECTURE.md).
    func switchVisualMode(to target: WindowMode) {
        switch target {
        case .visual:
            switch mode {
            case .normal: visualStartLine = cursorLine; visualStartCol = cursorCol
            case .visualLine: visualStartCol = cursorCol
            default: break // from visual/block — the anchor already exists
            }
            mode = .visual
        case .visualLine:
            if mode == .normal { visualStartLine = cursorLine }
            mode = .visualLine
        case .visualBlock:
            switch mode {
            case .normal: visualStartLine = cursorLine; visualStartCol = cursorCol
            case .visualLine: visualStartCol = cursorCol
            default: break // from visual — the anchor is preserved
            }
            // The block corner: from normal — the cursor's actual
            // position (a fresh session, anchor = corner, like Ctrl+V in
            // vim); from visual/visualLine — the STICKY curswant
            // (desiredCol, display cells): the column survived the
            // v/V interval and vertical moves, the middle of a tab/wide
            // glyph does not slide to the next grapheme boundary (vim
            // parity, verified: ^V h v ^V d == ^V h d).
            let fromVisual = mode == .visual || mode == .visualLine
            mode = .visualBlock
            visualBlockCol = fromVisual
                ? desiredCol
                : displayColForChar(line: cursorLine, charCol: cursorCol)
        default: break
        }
    }

    // MARK: - Block movement

    /// Block vertical movement: the line is clamped to the buffer
    /// (the phantom line is legal — an empty contribution, the
    /// rectangle does not shrink), the virtual column is untouched.
    /// Paging included — via the shared pageDelta, bypassing
    /// moveVertically (grapheme clamping).
    func moveBlockVertically(_ delta: Int) {
        guard let buf = buffer else { return }
        cursorLine = min(max(cursorLine + delta, 0), max(0, buf.lineCount - 1))
    }

    /// The real position for the virtual column: the boundary of the
    /// first grapheme at/after visualBlockCol (≤ the line length).
    /// Holds the "cursorCol is always real" invariant for the caret
    /// renderer, the status bar and every other consumer. curswant
    /// (desiredCol, display cells) is synced to the same VIRTUAL
    /// column — not the real cursorCol: the Ctrl+V → v → Ctrl+V
    /// round-trip must return the corner to the middle of the tab/wide
    /// glyph where it stood (vim keeps curswant; entering block mode
    /// from visual takes desiredCol).
    func syncCursorToBlockCol() {
        guard let buf = buffer else { return }
        cursorCol = VisualBlock.charIndex(atDisplayCol: visualBlockCol,
                                          chars: buf.getLineChars(cursorLine),
                                          tabWidth: tabWidth)
        desiredCol = visualBlockCol
    }

    // MARK: - Key handlers

    func handleVisual(_ key: Key) -> Bool {
        switch key {
        case .escape: mode = .normal
        case .char("h"), .left: moveCursorLeft()
        case .char("j"), .down: moveCursorDown()
        case .char("k"), .up: moveCursorUp()
        case .char("l"), .right: moveCursorRight()
        case .ctrl("j"), .ctrlDown, .pageDown: pageCursorDown()
        case .ctrl("k"), .ctrlUp, .pageUp: pageCursorUp()
        case .char("y"): yankSelection()
        case .char("d"), .char("x"): deleteSelection()
        case .char("s"): prefillSubstituteFromSelection()
        case .char("a"): selectAllContent()
        case .char("V"): switchVisualMode(to: .visualLine)
        case .ctrl("v"): switchVisualMode(to: .visualBlock)
        default: return false
        }
        if !isVerticalKey(key, insertMode: false) { syncDesiredCol() }
        dirty = true
        return true
    }

    func handleVisualLine(_ key: Key) -> Bool {
        switch key {
        case .escape: mode = .normal
        case .char("j"), .down: moveCursorDown()
        case .char("k"), .up: moveCursorUp()
        case .ctrl("j"), .ctrlDown, .pageDown: pageCursorDown()
        case .ctrl("k"), .ctrlUp, .pageUp: pageCursorUp()
        case .char("y"): yankSelection()
        case .char("d"), .char("x"): deleteSelection()
        case .char("s"): prefillSubstituteFromSelection()
        case .char("a"): selectAllContent()
        case .char("H"), .shiftLeft: shiftVisualLines(by: -indentSize())
        case .char("L"), .shiftRight: shiftVisualLines(by: indentSize())
        case .char("v"): switchVisualMode(to: .visual)
        case .ctrl("v"): switchVisualMode(to: .visualBlock)
        default: return false
        }
        if !isVerticalKey(key, insertMode: false) { syncDesiredCol() }
        dirty = true
        return true
    }

    /// Visual-block (Ctrl+V): rectangular selection in display columns.
    /// The cursor corner is a VIRTUAL column (not clamped to the line
    /// length): the block does not shrink on short, empty and the
    /// phantom line. Operations use intersection semantics (see
    /// yankSelection/deleteSelection/replaceSelectionWithPaste). Known
    /// limitations vs vim (deliberate, see ARCHITECTURE.md): no
    /// `A`/`I`/`c`, no `$`-extension and no `o` corner swap.
    func handleVisualBlock(_ key: Key) -> Bool {
        switch key {
        case .escape: mode = .normal
        case .char("h"), .left: visualBlockCol = max(0, visualBlockCol - 1)
        case .char("l"), .right: visualBlockCol += 1
        case .char("j"), .down: moveBlockVertically(1)
        case .char("k"), .up: moveBlockVertically(-1)
        case .ctrl("j"), .ctrlDown, .pageDown: moveBlockVertically(pageDelta)
        case .ctrl("k"), .ctrlUp, .pageUp: moveBlockVertically(-pageDelta)
        case .char("y"): yankSelection()
        case .char("d"), .char("x"): deleteSelection()
        case .char("s"): prefillSubstituteFromSelection()
        case .char("a"): selectAllContent()
        case .char("v"): switchVisualMode(to: .visual)
        case .char("V"): switchVisualMode(to: .visualLine)
        default: return false
        }
        if mode == .visualBlock {
            syncCursorToBlockCol()
            // Block movement deliberately bypasses moveVertically
            // (grapheme clamping would break the virtual corner) — but
            // its scrolling must not be skipped: pull visibility on
            // BOTH axes after every move (ensureCursorVisible in block
            // mode reads the corner's virtual column and the cursor line).
            ensureCursorVisible()
        }
        dirty = true
        return true
    }

    // MARK: - Operators (finishing: return to normal themselves)

    /// Yank of the current selection — a single point for all visual
    /// modes: the geometry is resolved once, the register type follows
    /// the kind (charwise/linewise — plain, blockwise — rectangular).
    /// A degenerate selection (empty contribution — anchor and cursor
    /// past EOL) does NOT wipe the register: an empty yank must not
    /// destroy the previous contents (class: v on one-past-end + y).
    func yankSelection() {
        guard let sel = visualSelection() else { return }
        switch sel {
        case .charwise(let startLine, let startCol, let endLine, let endCol):
            guard let buf = buffer else { return }
            let startOffset = buf.lineStart(line: startLine)
                + buf.charToByteOffsetInLine(line: startLine, charIndex: startCol)
            let endOffset = buf.lineStart(line: endLine)
                + buf.charToByteOffsetInLine(line: endLine, charIndex: endCol + 1)
            let text = buf.getText(range: startOffset..<min(endOffset, buf.totalLength))
            if !text.isEmpty { yank(text) }
        case .linewise(let lines):
            guard let buf = buffer else { return }
            var text = ""
            for line in lines {
                text += buf.getLine(line) + registerTerminator(after: line)
            }
            if !text.isEmpty { yank(text) }
        case .blockwise(let rows, let span):
            guard buffer != nil else { return }
            let text = VisualBlock.blockText(rows: rows.map { blockSlice(line: $0, span: span) },
                                          span: span, tabWidth: tabWidth)
            if !text.isEmpty { yank(text, blockwise: true) }
        }
        mode = .normal
    }

    /// The line terminator for assembling a linewise register: the
    /// source file supplies the original terminators (a CRLF file — a
    /// CRLF register, the `p` round-trip does not repaint the file's
    /// lines as LF), but the last line without a trailing newline
    /// forcibly gets "\n" — the register type is sniffed from the
    /// tail, a linewise yank must stay linewise (vim parity on `p`),
    /// otherwise the paste degrades to charwise.
    func registerTerminator(after line: Int) -> String {
        let t = lineTerminator(after: line)
        return t.isEmpty ? "\n" : t
    }

    /// Yank of a byte range with a linewise guarantee (deletions): the
    /// content ends with a line break even when the deleted span ended
    /// on the file's last line without a terminator — a delete
    /// register must paste linewise, as in vim.
    func yankLinewiseRegister(_ text: String) {
        yank(MultilineInsert.endsWithLineBreak(text) ? text : text + "\n")
    }

    /// Deletion of the current selection — a single point for all
    /// visual modes.
    /// Charwise/linewise — a contiguous delete (one undo step);
    /// blockwise — applyBlockEdit (line-by-line reassembly, with the
    /// same undo model). The deleted text goes to the yank register
    /// (the type follows the kind: charwise/linewise — plain,
    /// blockwise — rectangular; an empty contribution does not wipe
    /// the register). The cursor lands at the selection start and is
    /// scrolled into view (the anchor may have traveled off the top of
    /// the screen while the selection was dragged down).
    func deleteSelection() {
        guard let sel = visualSelection(), let buf = buffer else { return }
        switch sel {
        case .charwise(let startLine, let startCol, let endLine, let endCol):
            let startOffset = buf.lineStart(line: startLine)
                + buf.charToByteOffsetInLine(line: startLine, charIndex: startCol)
            let endOffset = buf.lineStart(line: endLine)
                + buf.charToByteOffsetInLine(line: endLine, charIndex: endCol + 1)
            let len = min(endOffset, buf.totalLength) - startOffset
            guard len > 0 else { mode = .normal; return }
            let deletedText = buf.getText(range: startOffset..<(startOffset + len))
            yank(deletedText)
            buf.delete(at: startOffset, length: len)
            recordAction(offset: startOffset, deleted: deletedText, inserted: "")
            cursorLine = startLine; cursorCol = startCol
        case .linewise(let lines):
            let start = buf.lineStart(line: lines.lowerBound)
            let end = buf.lineEnd(line: lines.upperBound)
            let len = end - start
            guard len > 0 else { mode = .normal; return }
            let deletedText = buf.getText(range: start..<min(end, buf.totalLength))
            yankLinewiseRegister(deletedText)
            buf.delete(at: start, length: len)
            recordAction(offset: start, deleted: deletedText, inserted: "")
            cursorLine = min(lines.lowerBound, max(0, buf.lineCount - 1))
            cursorCol = 0
        case .blockwise(let rows, let span):
            // The deleted block goes to the register (blockwise, vim
            // parity `vd`+`p`):
            // BEFORE the edit — applyBlockEdit reassembles the lines,
            // no slices will exist afterwards. An empty contribution (a
            // block entirely past EOL) does not wipe the register.
            let text = VisualBlock.blockText(rows: rows.map { blockSlice(line: $0, span: span) },
                                          span: span, tabWidth: tabWidth)
            if !text.isEmpty { yank(text, blockwise: true) }
            _ = applyBlockEdit(rows: rows, span: span, replacement: { _, _ in "" })
        }
        mode = .normal
        ensureCursorVisible()
    }

    /// Paste over the selection (bracketed paste in any visual mode —
    /// vim visual `p`): the replaced text goes to the yank register
    /// (+OSC 52), the pasted text takes its place, the whole
    /// replacement is one undo step. Charwise and linewise — one
    /// contiguous replaceContiguousRange; blockwise — the slices of
    /// the first min(block rows, pasted rows) lines via applyBlockEdit
    /// (the rest of the
    /// block is untouched — more conservative than vim, which clears
    /// the whole block; see ARCHITECTURE.md). A finishing operator.
    func replaceSelectionWithPaste(_ text: String) {
        guard let buf = buffer, !text.isEmpty, let sel = visualSelection() else { return }
        switch sel {
        case .charwise(let startLine, let startCol, let endLine, let endCol):
            let startOffset = buf.lineStart(line: startLine)
                + buf.charToByteOffsetInLine(line: startLine, charIndex: startCol)
            let endOffset = min(buf.lineStart(line: endLine)
                + buf.charToByteOffsetInLine(line: endLine, charIndex: endCol + 1),
                buf.totalLength)
            replaceContiguousRange(startOffset..<endOffset, with: text,
                                   anchorLine: startLine, anchorCol: startCol)
        case .linewise(let lines):
            let startOffset = buf.lineStart(line: lines.lowerBound)
            let endOffset = min(buf.lineEnd(line: lines.upperBound), buf.totalLength)
            replaceContiguousRange(startOffset..<endOffset, with: text,
                                   anchorLine: lines.lowerBound, anchorCol: 0)
        case .blockwise(let rows, let span):
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let n = min(rows.count, lines.count)
            let target = rows.lowerBound..<(rows.lowerBound + n)
            // The replaced block goes to the register BEFORE the edit
            // (no slices afterwards); an empty contribution does not
            // wipe the register (pasting "\n" over a block entirely
            // past EOL — the edit is a no-op).
            let replaced = VisualBlock.blockText(rows: target.map { blockSlice(line: $0, span: span) },
                                               span: span, tabWidth: tabWidth)
            if !replaced.isEmpty { yank(replaced, blockwise: true) }
            // Before the mode switch: applyBlockEdit internally syncs
            // the virtual column and calls ensureCursorVisible while
            // the mode is still block.
            _ = applyBlockEdit(rows: rows.lowerBound...(rows.lowerBound + n - 1), span: span,
                               replacement: { offset, _ in lines[offset] })
        }
        mode = .normal
        ensureCursorVisible()
    }

    /// A contiguous replacement of a range with pasted text — the shared
    /// body of the charwise and linewise branches of "paste over": the
    /// replaced text goes to the yank register (like visual `d`), the
    /// whole replacement is one undo step, the cursor follows the `p`
    /// rules (a linewise paste with a trailing "\n" — on the first
    /// pasted line, otherwise — after the last pasted character).
    private func replaceContiguousRange(_ range: Range<Int>, with text: String,
                                        anchorLine: Int, anchorCol: Int) {
        guard let buf = buffer else { return }
        let deleted = buf.getText(range: range)
        if !deleted.isEmpty { yank(deleted) }
        buf.delete(at: range.lowerBound, length: range.upperBound - range.lowerBound)
        buf.insert(text, at: range.lowerBound)
        recordAction(offset: range.lowerBound, deleted: deleted, inserted: text)
        if MultilineInsert.endsWithLineBreak(text) {
            cursorLine = min(anchorLine, max(0, buf.lineCount - 1))
            cursorCol = 0
        } else {
            let delta = MultilineInsert.cursorDelta(for: text)
            cursorLine = min(anchorLine + delta.lines, max(0, buf.lineCount - 1))
            cursorCol = delta.lines > 0 ? delta.tailCols : anchorCol + delta.tailCols
        }
    }

    // MARK: - Block application

    /// Block `p`/`P`: the blockwise register's lines are inserted at
    /// the cursor's display column on consecutive lines (short lines
    /// are padded with spaces up to the column), as a single undo
    /// step.
    /// Lines past the end of the buffer are not created — a v1
    /// limitation (see ARCHITECTURE.md).
    func pasteBlock() {
        guard let buf = buffer else { return }
        let lines = yankBuffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return }
        let lastRow = min(cursorLine + lines.count - 1, buf.lineCount - 1)
        guard lastRow >= cursorLine else { return }
        let col = displayColForChar(line: cursorLine, charCol: cursorCol)
        _ = applyBlockEdit(rows: cursorLine...lastRow, span: .point(col),
                           replacement: { offset, _ in lines[offset] })
    }

    /// The shared executor of block edits: reassembles the lines with
    /// ONE contiguous replace over the per-line span (lineStart of the
    /// first changed .. lineEnd of the last; the insertion = the
    /// reassembled lines, each with its own original terminator;
    /// unchanged lines between the bounds are reassembled identically)
    /// — the undo model is unchanged, the action remains the triple
    /// (offset, deleted, inserted).
    /// `replacement(offset, range)` receives the line's offset within
    /// the block and its slice; nil — "leave the line unchanged"; a
    /// line without a slice and with an empty replacement is also left
    /// unchanged. The cursor lands on the first changed line, after
    /// the pasted text (for deletion — at the start of the slice).
    /// Returns false when there is nothing to change.
    @discardableResult
    func applyBlockEdit(rows: ClosedRange<Int>, span: VisualBlock.Span,
                        replacement: (Int, Range<Int>?) -> String?) -> Bool {
        guard let buf = buffer, !rows.isEmpty else { return false }
        let t = tabWidth

        // The plan for each line: nil — an identical reassembly (an
        // unchanged line in the middle of the span stays byte-for-byte).
        var plans: [(line: Int, plan: VisualBlock.RowPlan?)] = []
        plans.reserveCapacity(rows.count)
        var firstChanged = -1
        var lastChanged = -1
        for (offset, line) in rows.enumerated() {
            let (chars, range) = blockSlice(line: line, span: span)
            var plan: VisualBlock.RowPlan? = nil
            if let repl = replacement(offset, range), !(range == nil && repl.isEmpty) {
                plan = VisualBlock.rowPlan(chars: chars, span: span, range: range,
                                           replacement: repl, tabWidth: t)
            }
            if plan != nil {
                if firstChanged < 0 { firstChanged = offset }
                lastChanged = offset
            }
            plans.append((line, plan))
        }
        guard firstChanged >= 0 else { return false }

        let firstLine = plans[firstChanged].line
        let lastLine = plans[lastChanged].line
        let firstPlan = plans[firstChanged].plan!
        let startOffset = buf.lineStart(line: firstLine)
        let endOffset = min(buf.lineEnd(line: lastLine), buf.totalLength)

        let deletedText = endOffset > startOffset ? buf.getText(range: startOffset..<endOffset) : ""
        // Reassemble all lines between the first and last change,
        // each with ITS OWN terminator (lineEnd includes the last
        // one's terminator). The separator is joined by index, not by
        // non-emptiness of the accumulated text: a reassembled line
        // may itself be empty.
        var insertedText = ""
        for entry in plans[firstChanged...lastChanged] {
            insertedText += (entry.plan?.text ?? buf.getLine(entry.line))
                + lineTerminator(after: entry.line)
        }
        if endOffset > startOffset {
            buf.delete(at: startOffset, length: endOffset - startOffset)
        }
        if !insertedText.isEmpty {
            buf.insert(insertedText, at: startOffset)
        }
        recordAction(offset: startOffset, deleted: deletedText, inserted: insertedText)

        cursorLine = firstLine
        cursorCol = min(firstPlan.caret, buf.lineCharLength(line: firstLine))
        // A block edit positions the REAL cursor — the virtual column
        // follows it (ensureCursorVisible below reads it in block mode);
        // curswant — to the same cell.
        visualBlockCol = displayColForChar(line: firstLine, charCol: cursorCol)
        desiredCol = visualBlockCol
        ensureCursorVisible()
        return true
    }

    /// The line terminator ("\n", "\r\n", or "" for the file's last
    /// line without a trailing newline) — from the byte gap between
    /// the content's end and the next line's start; the original
    /// buffer, call before mutation.
    func lineTerminator(after line: Int) -> String {
        guard let buf = buffer else { return "\n" }
        let contentEnd = buf.lineStart(line: line) + buf.getLine(line).utf8.count
        let nextStart = buf.lineStart(line: line + 1)
        guard contentEnd < nextStart else { return "" }
        return nextStart - contentEnd == 2 ? "\r\n" : "\n"
    }

    // MARK: - Line shift (visualLine, mode is kept)

    /// Shifts the visual-line selection by the per-language indent width:
    /// positive indents, negative outdents (removes at most |delta| leading
    /// spaces per line). Applied as a single undo action; the selection and
    /// mode are kept so the shift can be repeated.
    func shiftVisualLines(by delta: Int) {
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
        // Each line is rebuilt with its own terminator — "\n" or "\r\n"
        // (the byte-gap detection lives in lineTerminator; the phantom
        // empty line after a trailing newline is handled there too).
        var insertedText = ""
        for (i, content) in newLines.enumerated() {
            insertedText += content + lineTerminator(after: startLine + i)
        }
        buf.delete(at: start, length: end - start)
        buf.insert(insertedText, at: start)
        recordAction(offset: start, deleted: deletedText, inserted: insertedText)
        cursorCol = min(max(0, cursorCol + cursorDelta), buf.lineCharLength(line: cursorLine))
        syncDesiredCol()
        ensureCursorVisible()
    }

    // MARK: - Highlighting

    /// The highlighting dispatcher: a single entry point from update(),
    /// the geometry is resolved once, the branches paint each their own
    /// shape.
    func drawVisualSelection(lnWidth: Int) {
        guard let sel = visualSelection() else { return }
        switch sel {
        case .charwise(let startLine, let startCol, let endLine, let endCol):
            drawCharwiseHighlight(startLine: startLine, startCol: startCol,
                                  endLine: endLine, endCol: endCol, lnWidth: lnWidth)
        case .linewise(let lines):
            drawLinewiseHighlight(lines: lines)
        case .blockwise(let rows, let span):
            drawBlockwiseHighlight(rows: rows, span: span, lnWidth: lnWidth)
        }
    }

    /// The selection's screen row (nil — outside the viewport).
    private func selectionScreenRow(_ lineNum: Int) -> Int? {
        let screenRow = lineNum - scrollY + contentTop
        return (screenRow >= contentTop && screenRow < height) ? screenRow : nil
    }

    /// Painting the text-area cells in the selection color — the shared
    /// inner loop of the charwise and block highlighting.
    private func paintSelectionCells(screenRow: Int, dispFrom: Int, dispTo: Int, lnWidth: Int) {
        guard dispFrom < dispTo else { return }
        for sc in (dispFrom - scrollX)..<(dispTo - scrollX) {
            guard sc >= 0 && sc + lnWidth < width else { continue }
            var cell = getCell(screenRow, lnWidth + sc)
            let hl = Cell.highlight(true, tint: Theme.visualBg, base: cell.bg)
            cell.bg = hl.bg
            cell.reverse = hl.reverse
            setCell(screenRow, lnWidth + sc, cell)
        }
    }

    private func drawCharwiseHighlight(startLine: Int, startCol: Int,
                                       endLine: Int, endCol: Int, lnWidth: Int) {
        guard let buf = buffer else { return }
        for lineNum in startLine...endLine {
            guard let screenRow = selectionScreenRow(lineNum) else { continue }
            let lineEnd = max(0, buf.lineCharLength(line: lineNum) - 1)
            let colStart = (lineNum == startLine) ? startCol : 0
            let colEnd = (lineNum == endLine) ? min(endCol, lineEnd) : lineEnd
            let startDisp = displayColForChar(line: lineNum, charCol: colStart)
            let endDisp = displayColForChar(line: lineNum, charCol: min(colEnd + 1, buf.lineCharLength(line: lineNum)))
            paintSelectionCells(screenRow: screenRow, dispFrom: startDisp, dispTo: endDisp, lnWidth: lnWidth)
        }
    }

    /// Linewise highlighting paints the WHOLE line, gutter included —
    /// the selection geometry is not bounded by columns.
    private func drawLinewiseHighlight(lines: ClosedRange<Int>) {
        for lineNum in lines {
            guard let screenRow = selectionScreenRow(lineNum) else { continue }
            for col in 0..<width {
                var cell = getCell(screenRow, col)
                let hl = Cell.highlight(true, tint: Theme.visualBg, base: cell.bg)
                cell.bg = hl.bg
                cell.reverse = hl.reverse
                setCell(screenRow, col, cell)
            }
        }
    }

    /// The block's rectangular highlight — exactly what the edits
    /// touch: the cell intersection rule (VisualBlock); the "painted
    /// but not operated on" split no longer exists. A tab is painted
    /// by its COVERED cells (it splits — a tab's cells are
    /// independent in the cell buffer, the renderer draws them as
    /// spaces), other glyphs — whole (atomic; operations take them
    /// whole too, even when their cells stick out past the edge).
    /// Empty cells past the line's end inside the band are painted as
    /// well — the rectangle stays readable on short lines.
    private func drawBlockwiseHighlight(rows: ClosedRange<Int>, span: VisualBlock.Span,
                                        lnWidth: Int) {
        guard let buf = buffer else { return }
        for lineNum in rows {
            guard let screenRow = selectionScreenRow(lineNum) else { continue }
            let chars = buf.getLineChars(lineNum)
            let cells = VisualBlock.glyphCells(chars, tabWidth: tabWidth)
            for (i, ch) in chars.enumerated() {
                let c = cells[i]
                guard c.start < span.right && c.end > span.left else { continue }
                if ch == "\t" {
                    paintSelectionCells(screenRow: screenRow,
                                        dispFrom: max(c.start, span.left),
                                        dispTo: min(c.end, span.right), lnWidth: lnWidth)
                } else {
                    paintSelectionCells(screenRow: screenRow, dispFrom: c.start, dispTo: c.end,
                                        lnWidth: lnWidth)
                }
            }
            let lineEnd = cells.last?.end ?? 0
            if lineEnd < span.right {
                paintSelectionCells(screenRow: screenRow, dispFrom: max(span.left, lineEnd),
                                    dispTo: span.right, lnWidth: lnWidth)
            }
        }
    }
}
