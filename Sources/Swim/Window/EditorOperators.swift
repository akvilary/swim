//
//  EditorOperators.swift
//  Swim
//
//  Operator-pending mechanics of normal mode (vim): an armed operator
//  (d/y/c) + motion → an action over a range. The handleNormal
//  dispatcher (EditorWindow.swift) routes in the order gPrefix →
//  operator-pending → plain commands — with an operator armed, the
//  plain branches are unreachable, a motion cannot slip past the
//  operator (a past bug: dw moved the cursor). Ranges and destinations
//  are pure SwimCore.NormalMotion (tested); here only the application:
//  yank/delete/change as a single undo step, cursor and registers.
//

import SwimCore

extension EditorWindow {

    // MARK: - Operator-pending dispatcher

    /// A key while an operator is armed. Doubling (dd/yy/cc) — linewise
    /// over N lines; `g` arms the motion's g-prefix (`dgg`); motions are
    /// the operator's arguments; any other key — death of the sequence
    /// (false → the defer reset in handleNormal's tail, like a vim
    /// error). The operator slot is not cleared explicitly: the reset
    /// is done by the trailing defer.
    func handleOperatorPending(_ key: Key, keepPending: inout Bool) -> Bool {
        switch key {
        case .escape:
            // Silent abort (vim: ESC in operator-pending) — consumed
            return true
        case .char("g"):
            // dgg/ygg/cgg: g-prefix; under an operator only `gg` is valid
            pending.armGPrefix()
            keepPending = true
            return true
        case .char("d"):
            guard pending.op == .d else { return false }
            applyLinewise(op: .d, count: pending.takeCount() ?? 1)
        case .char("y"):
            guard pending.op == .y else { return false }
            applyLinewise(op: .y, count: pending.takeCount() ?? 1)
        case .char("c"):
            guard pending.op == .c else { return false }
            applyLinewise(op: .c, count: pending.takeCount() ?? 1)
        default:
            guard let armed = pending.op, let motion = Self.normalMotion(for: key) else {
                return false
            }
            applyOperator(armed, motion: motion, count: pending.takeCount())
        }
        return true
    }

    /// Key → normal-mode motion, consumed as the operator's argument in
    /// operator-pending (plain-normal movement maps keys itself in
    /// handlePlainNormal and does not consult this table). `gg`
    /// arrives through the g-prefix (handleGPrefix); here only single
    /// keys. Enter — linewise down (vim: d<CR> == dj); in plain mode
    /// .enter never reaches here (not our key) — plain Enter behavior
    /// is unchanged.
    static func normalMotion(for key: Key) -> NormalMotion? {
        switch key {
        case .char("h"), .left: return .left
        case .char("j"), .down: return .down
        case .char("k"), .up: return .up
        case .char("l"), .right: return .right
        case .char("w"): return .wordForward
        case .char("b"): return .wordBackward
        case .char("e"): return .wordEnd
        case .char("$"), .end: return .endOfLine
        case .char("0"), .home: return .bol
        case .char("G"): return .fileEnd
        case .enter: return .down
        default: return nil
        }
    }

    // MARK: - Applying operators

    /// Operator + motion with a count (nil — no count was given; motion
    /// defaults live in NormalMotion.destination): the range comes from
    /// NormalMotion, the action by category. An empty range is a no-op
    /// (`c` simply enters insert).
    func applyOperator(_ op: NormalPending.Op, motion: NormalMotion, count: Int?) {
        guard let buf = buffer else { return }
        var m = motion
        if op == .c, case .wordForward = motion, cursorOnNonBlank(buf) {
            m = .wordEnd // vim i_cw: cw on a non-blank behaves like ce
        }
        let dest = NormalMotion.destination(of: m, in: buf, line: cursorLine, col: cursorCol, count: count)
        guard let range = NormalMotion.operatorRange(cursorLine: cursorLine, cursorCol: cursorCol,
                                                     destination: dest, in: buf) else {
            if op == .c { mode = .insert }
            return
        }
        switch range {
        case .linewise(let lower, let upper):
            applyLinewiseRange(op, lower: lower, upper: upper)
        case .charwise(let startLine, let startCol, let endLine, let endCol):
            applyCharwiseRange(op, startLine: startLine, startCol: startCol, endLine: endLine, endCol: endCol)
        }
    }

    /// A doubled operator (dd/yy/cc) — linewise over N lines from the cursor.
    func applyLinewise(op: NormalPending.Op, count: Int) {
        guard let buf = buffer else { return }
        let last = max(0, buf.lineCount - 1)
        applyLinewiseRange(op, lower: cursorLine, upper: min(cursorLine + count - 1, last))
    }

    /// Linewise action over a range of lines. The phantom line
    /// (start == totalLength) is a buffer artifact, not content (the
    /// same policy as shiftVisualLines): Ndd/Nyy/dj/dG that run onto
    /// it do not pull it into the range and the register (vim: 3dd on
    /// the second-to-last line yields a two-line register). Yank — with
    /// the original file's terminators (CRLF round-trip, the linewise
    /// guarantee of a last line without a trailing newline). Delete/
    /// change — one buf.delete + one undo step; `cc` re-inserts the
    /// first line's indent within the same step (vim auto-indent). An
    /// empty range (cursor on the phantom) is an honest no-op for all
    /// three operators, with no undo record and — for `y` — without
    /// wiping the register either: the phantom's contribution is just
    /// the forced "\n" (the no-wipe principle, as in yankSelection).
    func applyLinewiseRange(_ op: NormalPending.Op, lower: Int, upper: Int) {
        guard let buf = buffer else { return }
        let last = max(0, buf.lineCount - 1)
        let lo = min(max(0, lower), last)
        var hi = min(max(lo, upper), last)
        if hi > lo, buf.lineStart(line: hi) == buf.totalLength {
            hi -= 1
        }
        var registerText = ""
        for line in lo...hi {
            registerText += buf.getLine(line) + registerTerminator(after: line)
        }
        if op == .y {
            // Cursor on the phantom line (lo == hi, start == totalLength):
            // the contribution is just the forced "\n" — no-op without
            // wiping the register (the no-wipe principle, as in yankSelection).
            if buf.lineStart(line: lo) == buf.totalLength { return }
            yankLinewiseRegister(registerText)
            return // yy does not move the cursor (vim)
        }
        let start = buf.lineStart(line: lo)
        let end = min(buf.lineEnd(line: hi), buf.totalLength)
        guard end > start else {
            if op == .c { mode = .insert }
            return
        }
        yankLinewiseRegister(registerText)
        let deletedText = buf.getText(range: start..<end)
        let indent = op == .c ? Self.lineIndent(buf, line: lo) : ""
        buf.delete(at: start, length: end - start)
        if !indent.isEmpty { buf.insert(indent, at: start) }
        recordAction(offset: start, deleted: deletedText, inserted: indent)
        cursorLine = min(lo, max(0, buf.lineCount - 1))
        cursorCol = indent.count
        syncDesiredCol()
        if op != .c {
            cursorCol = 0
            desiredCol = 0
        } else {
            mode = .insert
        }
        ensureCursorVisible()
    }

    /// Charwise action over a range (exclusive end, in char columns;
    /// ranges spanning newlines — d2$/de — in bytes).
    func applyCharwiseRange(_ op: NormalPending.Op, startLine: Int, startCol: Int,
                            endLine: Int, endCol: Int) {
        guard let buf = buffer else { return }
        let startOffset = buf.lineStart(line: startLine)
            + buf.charToByteOffsetInLine(line: startLine, charIndex: startCol)
        let endOffset = buf.lineStart(line: endLine)
            + buf.charToByteOffsetInLine(line: endLine, charIndex: endCol)
        let len = endOffset - startOffset
        guard len > 0 else {
            if op == .c { mode = .insert }
            return
        }
        let deletedText = buf.getText(range: startOffset..<endOffset)
        yank(deletedText)
        if op == .y {
            // yank does not move the cursor (vim): yb/y0/yh leave it in place
            return
        }
        buf.delete(at: startOffset, length: len)
        recordAction(offset: startOffset, deleted: deletedText, inserted: "")
        // d/c: the cursor lands at the start of the deleted range (db
        // returns the cursor to the start of the word — vim)
        cursorLine = startLine
        cursorCol = startCol
        syncDesiredCol()
        if op == .c { mode = .insert }
        ensureCursorVisible()
    }

    // MARK: - Edits with a count

    /// `x` with a count (vim parity: the deleted text goes to the yank
    /// register and OSC 52) — N graphemes from the cursor, without
    /// going past the end of the line.
    func deleteCharsAtCursor(_ count: Int) {
        guard let buf = buffer else { return }
        let chars = buf.getLineChars(cursorLine)
        guard cursorCol < chars.count else { return }
        let endCol = min(cursorCol + max(1, count), chars.count)
        let startOff = buf.lineStart(line: cursorLine)
            + buf.charToByteOffsetInLine(line: cursorLine, charIndex: cursorCol)
        let endOff = buf.lineStart(line: cursorLine)
            + buf.charToByteOffsetInLine(line: cursorLine, charIndex: endCol)
        let len = endOff - startOff
        guard len > 0 else { return }
        let deletedText = buf.getText(range: startOff..<endOff)
        yank(deletedText)
        buf.delete(at: startOff, length: len)
        recordAction(offset: startOff, deleted: deletedText, inserted: "")
    }

    /// Applying a motion as a cursor move (normal, without an
    /// operator). Vertical j/k bypass this — moveVertically with the
    /// sticky column (desiredCol) in handlePlainNormal.
    func moveByMotion(_ motion: NormalMotion, count: Int?) {
        guard let buf = buffer else { return }
        let dest = NormalMotion.destination(of: motion, in: buf,
                                            line: cursorLine, col: cursorCol, count: count)
        cursorLine = dest.line
        cursorCol = dest.col
        ensureCursorVisible()
    }

    // MARK: - Helpers

    private func cursorOnNonBlank(_ buf: PieceTable) -> Bool {
        let chars = buf.getLineChars(cursorLine)
        guard cursorCol < chars.count else { return false }
        let c = chars[cursorCol]
        return c != " " && c != "\t"
    }

    private static func lineIndent(_ buf: PieceTable, line: Int) -> String {
        var indent = ""
        for c in buf.getLineChars(line) {
            if c == " " || c == "\t" { indent.append(c) } else { break }
        }
        return indent
    }
}
