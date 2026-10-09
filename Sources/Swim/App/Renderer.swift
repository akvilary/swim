import Foundation
import SwimCore

struct CursorRenderInfo {
    /// DECSCUSR shapes swim uses, as one place's vocabulary: `bar` is
    /// the insert-mode caret of every typing surface (the editor's
    /// insert, the status-bar command line, the query inputs of the
    /// branches picker, search and terminal); `block` is the
    /// navigation default the renderer resets to when no window owns
    /// a cursor. Normal-mode cursors are not terminal cursors at all
    /// — the editor draws its block as an inverted cell highlight.
    enum Shape: Int {
        case block = 1
        case bar = 5
    }

    let row: Int
    let col: Int
    let shape: Shape
    let visible: Bool

    /// The shared insert-mode caret: a steady bar at the screen
    /// position — one definition of "I am typing here", reused by
    /// every typing surface so they all afford the same cursor.
    static func insertCaret(row: Int, col: Int) -> CursorRenderInfo {
        CursorRenderInfo(row: row, col: col, shape: .bar, visible: true)
    }
}

class Renderer {
    private let terminal: Terminal
    private var prevScreenCells: [Cell?] = []
    private var prevScreenW: Int = 0
    private var prevScreenH: Int = 0
    private var termFG: Color = .default
    private var termBG: Color = .default
    private var termBold: Bool = false
    private var termDim: Bool = false
    private var termUnderline: Bool = false
    private var termReverse: Bool = false
    var needsFullRedraw: Bool = true

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    func render(windows: [Window], cursorInfo: CursorRenderInfo?) {
        ensureScreenSize()

        if needsFullRedraw {
            for i in 0..<prevScreenCells.count { prevScreenCells[i] = nil }
            needsFullRedraw = false
        }

        let screenW = prevScreenW
        let screenH = prevScreenH

        // Terminal pen position within this frame: the cursor advances by
        // itself after each written glyph, so a moveCursor is only needed
        // when diffing jumped to a non-adjacent cell (gap, row change,
        // skipped wide continuation). Per-frame locals, deliberately not
        // cross-frame state: the cursor placement at the end of a frame
        // moves the terminal cursor, so any carried position would be
        // stale by construction. This is what keeps a scroll repaint
        // (every editor cell differs) at ~one move per row of bytes
        // instead of a cursor escape per cell — the pty-friendly budget.
        var penRow = -1
        var penCol = -1

        for window in windows {
            guard window.visible else { continue }

            for row in 0..<window.height {
                let screenRow = window.y + row
                if screenRow >= screenH { continue }

                for col in 0..<window.width {
                    let screenCol = window.x + col
                    if screenCol >= screenW { continue }

                    let cell = window.getCell(row, col)

                    if cell.wideContinuation { continue }

                    let idx = screenRow * screenW + screenCol
                    if prevScreenCells[idx] != cell {
                        if penRow != screenRow || penCol != screenCol {
                            terminal.moveCursor(row: screenRow, col: screenCol)
                            penRow = screenRow
                            penCol = screenCol
                        }

                        if termFG != cell.fg { terminal.setFG(cell.fg); termFG = cell.fg }
                        if termBG != cell.bg { terminal.setBG(cell.bg); termBG = cell.bg }
                        if termBold != cell.bold { terminal.setBold(cell.bold); termBold = cell.bold }
                        if termDim != cell.dim { terminal.setDim(cell.dim); termDim = cell.dim }
                        if termUnderline != cell.underline { terminal.setUnderline(cell.underline); termUnderline = cell.underline }
                        if termReverse != cell.reverse { terminal.setReverse(cell.reverse); termReverse = cell.reverse }

                        let glyph = cell.char.displayWidth > 0 ? cell.char : " "
                        terminal.writeChar(glyph)
                        penCol += max(1, glyph.displayWidth)

                        prevScreenCells[idx] = cell

                        if cell.char.displayWidth == 2, screenCol + 1 < screenW {
                            prevScreenCells[screenRow * screenW + screenCol + 1] = window.getCell(row, col + 1)
                        }
                    }
                }
            }
        }

        if let info = cursorInfo, info.visible {
            terminal.moveCursor(row: info.row, col: info.col)
            terminal.setCursorShape(info.shape.rawValue)
            terminal.showCursor(true)
        } else {
            terminal.showCursor(false)
            terminal.setCursorShape(CursorRenderInfo.Shape.block.rawValue)
        }

        terminal.flush()
    }

    private func ensureScreenSize() {
        let w = terminal.width
        let h = terminal.height
        if w != prevScreenW || h != prevScreenH {
            prevScreenCells = Array(repeating: nil, count: w * h)
            prevScreenW = w
            prevScreenH = h
        }
    }
}
