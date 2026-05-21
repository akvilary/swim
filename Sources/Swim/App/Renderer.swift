import Foundation

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

    func render(windows: [Window], cursorInfo: (window: Window, cursorLine: Int, cursorCol: Int, scrollY: Int, scrollX: Int, lineNumberWidth: Int, mode: EditorMode)?) {
        ensureScreenSize()

        if needsFullRedraw {
            for i in 0..<prevScreenCells.count { prevScreenCells[i] = nil }
            needsFullRedraw = false
        }

        let screenW = prevScreenW
        let screenH = prevScreenH

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

                        terminal.writeChar(cell.char)

                        prevScreenCells[idx] = cell

                        if cell.char.isWide, screenCol + 1 < screenW {
                            prevScreenCells[screenRow * screenW + screenCol + 1] = window.getCell(row, col + 1)
                        }
                    }
                }
            }
        }

        if let info = cursorInfo, info.mode == .insert {
            let screenRow = info.cursorLine - info.scrollY
            let screenCol = info.cursorCol - info.scrollX
            if screenRow >= 0, screenRow < info.window.height,
               screenCol >= 0, screenCol + info.lineNumberWidth < info.window.width {
                terminal.moveCursor(row: info.window.y + screenRow, col: info.window.x + info.lineNumberWidth + screenCol)
            }
            terminal.setCursorShape(5)
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
        }
    }

}
