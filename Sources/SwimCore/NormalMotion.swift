import Foundation

/// A normal-mode motion — the vim model: the same motion moves the
/// cursor in normal mode, and gives an armed operator (d/y/c,
/// operator-pending) its range of action. Vim categorization:
/// - exclusive — range WITHOUT the end position (`w`, `b`, `0`, `h`);
/// - inclusive — including the end position (`e`, `$`, `l`);
/// - linewise — whole lines (`j`, `k`, `gg`, `G`).
///
/// Pure logic without cursor state: the consumer (EditorWindow)
/// passes the cursor position and count, and gets a destination;
/// applying the operator receives a normalized range. Range math
/// (sorting the ends of backward motions, the vim adjustment
/// "exclusive end at start of line → end of previous line" — without
/// it `dw` on the last word of a line would glue lines together) —
/// lives here and is tested here too. Line indices MUST be clamped
/// to 0…lineCount-1 BEFORE calling PieceTable.lineStart/lineEnd:
/// out of range those silently return 0/totalLength — correct
/// bookkeeping over an invalid range (a class of bugs caught by
/// the delete stress test).
public enum NormalMotion: Equatable {
    case left, right, up, down
    case wordForward, wordBackward, wordEnd
    case endOfLine, bol
    case fileStart, fileEnd

    public enum Kind: Equatable {
        /// h/l — exclusive in the operator context (vim): `dl` = one
        /// character = `x`, `[cursor, cursor+1)`.
        case exclusive, inclusive, linewise
    }

    /// The motion's destination: line/column (0-based, char indices) and
    /// the vim category. For `up`/`down` the column matters only for
    /// ranges — ordinary movement applies the sticky column
    /// (desiredCol) in the window itself.
    public struct Destination: Equatable {
        public let line: Int
        public let col: Int
        public let kind: Kind

        public init(line: Int, col: Int, kind: Kind) {
            self.line = line
            self.col = col
            self.kind = kind
        }
    }

    /// The operator's normalized range. The charwise end is EXCLUSIVE —
    /// the column of the first character OUTSIDE the range (the same
    /// convention as visual selections). Empty range — nil: the consumer
    /// no-ops (and `c` simply enters insert).
    public enum OperatorRange: Equatable {
        case linewise(lower: Int, upper: Int)
        case charwise(startLine: Int, startCol: Int, endLine: Int, endCol: Int)
    }

    /// The motion's destination from the cursor position with a count.
    /// count == nil — no count was given at all: for motions this is 1,
    /// for `gg`/`G` — their defaults (first/last line; vim distinguishes
    /// `G` from `1G`). Word primitives are applied count times;
    /// `endOfLine` (`$`) moves down count-1 lines — all as in vim.
    public static func destination(of motion: NormalMotion, in buffer: PieceTable,
                                   line: Int, col: Int, count: Int?) -> Destination {
        let last = max(0, buffer.lineCount - 1)
        let l = min(max(0, line), last)
        let n = count ?? 1
        switch motion {
        case .left:
            return Destination(line: l, col: max(0, col - n), kind: .exclusive)
        case .right:
            // one-past-end (col == len, vertical moves) — no
            // motion: `dl` at this position is a no-op, parity with `x`
            let len = buffer.lineCharLength(line: l)
            if col >= len { return Destination(line: l, col: col, kind: .exclusive) }
            return Destination(line: l, col: min(col + n, max(0, len - 1)), kind: .exclusive)
        case .up:
            return Destination(line: max(0, l - n), col: col, kind: .linewise)
        case .down:
            return Destination(line: min(last, l + n), col: col, kind: .linewise)
        case .wordForward, .wordBackward, .wordEnd:
            let len = buffer.lineCharLength(line: l)
            var off = buffer.lineStart(line: l)
                + buffer.charToByteOffsetInLine(line: l, charIndex: min(col, len))
            for _ in 0..<n {
                off = motion == .wordForward ? buffer.wordForwardUnclamped(from: off)
                    : motion == .wordBackward ? buffer.wordBackward(from: off)
                    : buffer.wordEnd(from: off)
            }
            let (nl, byteCol) = buffer.offsetToLineCol(off)
            let destCol = buffer.byteToCharOffsetInLine(line: nl, byteOffset: byteCol)
            return Destination(line: nl, col: destCol,
                               kind: motion == .wordEnd ? .inclusive : .exclusive)
        case .endOfLine:
            let target = min(last, l + n - 1)
            return Destination(line: target,
                               col: max(0, buffer.lineCharLength(line: target) - 1),
                               kind: .inclusive)
        case .bol:
            return Destination(line: l, col: 0, kind: .exclusive)
        case .fileStart:
            return Destination(line: max(0, count.map { min($0 - 1, last) } ?? 0), col: 0, kind: .linewise)
        case .fileEnd:
            return Destination(line: max(0, count.map { min($0 - 1, last) } ?? last), col: 0, kind: .linewise)
        }
    }

    /// The operator range [cursor … destination] by vim category:
    /// - linewise — whole lines from min to max inclusive;
    /// - charwise — an ordered pair of ends; the inclusive end
    ///   is converted to exclusive form (+1 column);
    /// - adjustment: an exclusive end at (line > 0, col 0) becomes
    ///   the end of the previous line, WITHOUT the terminator
    ///   (vim :h exclusive rule 1). Both behaviors via one rule:
    ///   `dw` on the last word of a line and `db` at BOL preserve
    ///   the line break.
    /// Empty range — nil.
    public static func operatorRange(cursorLine: Int, cursorCol: Int,
                                     destination: Destination,
                                     in buffer: PieceTable) -> OperatorRange? {
        let last = max(0, buffer.lineCount - 1)
        let cl = min(max(0, cursorLine), last)
        if destination.kind == .linewise {
            return .linewise(lower: min(cl, destination.line),
                             upper: max(cl, destination.line))
        }
        var start = (line: cl, col: cursorCol)
        var end: (line: Int, col: Int)
        let exclusive: Bool
        switch destination.kind {
        case .exclusive:
            end = (destination.line, destination.col)
            exclusive = true
        case .inclusive:
            // +1 into exclusive form; clamp — one-past-end `l` (dl there
            // is a no-op) must not produce a column beyond the end of the line
            end = (destination.line,
                   min(destination.col + 1, buffer.lineCharLength(line: destination.line)))
            exclusive = false
        case .linewise:
            return nil
        }
        if (end.line, end.col) < (start.line, start.col) {
            swap(&start, &end)
        }
        if exclusive, end.line > 0, end.col == 0 {
            end = (end.line - 1, buffer.lineCharLength(line: end.line - 1))
        }
        guard (start.line, start.col) < (end.line, end.col) else { return nil }
        return .charwise(startLine: start.line, startCol: start.col,
                         endLine: end.line, endCol: end.col)
    }
}
