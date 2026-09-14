import Foundation

struct CursorRenderInfo {
    let row: Int
    let col: Int
    let shape: Int
    let visible: Bool
}

class Renderer {
    private let terminal: Terminal
    private var prevScreenCells: [Cell?] = []
    private var prevScreenW: Int = 0
    private var prevScreenH: Int = 0
    private var prevEditorScrollY: Int?
    private var prevEditorRect: (x: Int, y: Int, w: Int, h: Int)?
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

    func render(windows: [Window], cursorInfo: CursorRenderInfo?,
                editorScrollY: Int? = nil, editorRect: (x: Int, y: Int, w: Int, h: Int)? = nil) {
        ensureScreenSize()

        if needsFullRedraw {
            for i in 0..<prevScreenCells.count { prevScreenCells[i] = nil }
            prevEditorScrollY = nil
            prevEditorRect = nil
            needsFullRedraw = false
        }

        let screenW = prevScreenW
        let screenH = prevScreenH

        // Vertical editor scroll: shift the terminal's own buffer with a
        // scroll region instead of repainting every row. A full repaint on
        // scroll emits ~screen-size bytes per frame, which can overflow the
        // pty buffer on slow terminals and block the main loop.
        if let scrollY = editorScrollY, let rect = editorRect,
           let prevY = prevEditorScrollY, let prevRect = prevEditorRect,
           prevRect.x == rect.x, prevRect.y == rect.y,
           prevRect.w == rect.w, prevRect.h == rect.h,
           screenH == prevScreenH, screenW == prevScreenW {
            let delta = scrollY - prevY
            if delta != 0 && abs(delta) < rect.h {
                let top = rect.y
                let bottom = rect.y + rect.h - 1
                // DECSTBM scroll region limited to the editor rows
                terminal.writeBuffer(Array("\u{1b}[\(top + 1);\(bottom + 1)r".utf8))
                terminal.moveCursor(row: top, col: 0)
                if delta > 0 {
                    terminal.writeBuffer(Array("\u{1b}[\(delta)S".utf8))
                } else {
                    terminal.writeBuffer(Array("\u{1b}[\(-delta)T".utf8))
                }
                terminal.writeBuffer(Array("\u{1b}[r".utf8))
                // Mirror the shift in the previous-frame buffer so the diff
                // below only redraws the rows that actually appeared.
                shiftPrevCells(regionTop: top, regionBottom: bottom, delta: delta, width: screenW)
            }
        }
        prevEditorScrollY = editorScrollY
        prevEditorRect = editorRect

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
                        terminal.moveCursor(row: screenRow, col: screenCol)

                        if termFG != cell.fg { terminal.setFG(cell.fg); termFG = cell.fg }
                        if termBG != cell.bg { terminal.setBG(cell.bg); termBG = cell.bg }
                        if termBold != cell.bold { terminal.setBold(cell.bold); termBold = cell.bold }
                        if termDim != cell.dim { terminal.setDim(cell.dim); termDim = cell.dim }
                        if termUnderline != cell.underline { terminal.setUnderline(cell.underline); termUnderline = cell.underline }
                        if termReverse != cell.reverse { terminal.setReverse(cell.reverse); termReverse = cell.reverse }

                        terminal.writeChar(cell.char.displayWidth > 0 ? cell.char : " ")

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
            terminal.setCursorShape(info.shape)
            terminal.showCursor(true)
        } else {
            terminal.showCursor(false)
            terminal.setCursorShape(1)
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
            prevEditorScrollY = nil
            prevEditorRect = nil
        }
    }

    /// Shifts prevScreenCells rows inside the region, matching the terminal
    /// scroll: delta > 0 means content moved up (scrolled down), the freed
    /// rows at the bottom are reset so the diff redraws them.
    private func shiftPrevCells(regionTop: Int, regionBottom: Int, delta: Int, width: Int) {
        guard abs(delta) <= regionBottom - regionTop else { return }
        func idx(_ r: Int, _ c: Int) -> Int { r * width + c }
        if delta > 0 {
            for r in regionTop...(regionBottom - delta) {
                for c in 0..<width {
                    prevScreenCells[idx(r, c)] = prevScreenCells[idx(r + delta, c)]
                }
            }
            for r in (regionBottom - delta + 1)...regionBottom {
                for c in 0..<width {
                    prevScreenCells[idx(r, c)] = nil
                }
            }
        } else {
            let d = -delta
            for r in stride(from: regionBottom, through: regionTop + d, by: -1) {
                for c in 0..<width {
                    prevScreenCells[idx(r, c)] = prevScreenCells[idx(r - d, c)]
                }
            }
            for r in regionTop..<(regionTop + d) {
                for c in 0..<width {
                    prevScreenCells[idx(r, c)] = nil
                }
            }
        }
    }

}
