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

                        if Self.isWideChar(cell.char), screenCol + 1 < screenW {
                            prevScreenCells[screenRow * screenW + screenCol + 1] = window.getCell(row, col + 1)
                        }
                    }
                }
            }
        }

        terminal.flush()

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

    static func isWideChar(_ c: Character) -> Bool {
        let scalars = String(c).unicodeScalars
        guard let scalar = scalars.first else { return false }
        let v = scalar.value
        if v <= 0x7F { return false }
        if v >= 0x1100 {
            if v <= 0x115F { return true }
            if v >= 0x231A && v <= 0x231B { return true }
            if v >= 0x2329 && v <= 0x232A { return true }
            if v >= 0x23E9 && v <= 0x23EC { return true }
            if v == 0x23F0 { return true }
            if v == 0x23F3 { return true }
            if v >= 0x25FD && v <= 0x25FE { return true }
            if v >= 0x2614 && v <= 0x2615 { return true }
            if v >= 0x2648 && v <= 0x2653 { return true }
            if v == 0x267F { return true }
            if v >= 0x2693 && v <= 0x269A { return true }
            if v >= 0x26A1 { return true }
            if v >= 0x26AA && v <= 0x26AB { return true }
            if v >= 0x26BD && v <= 0x26BF { return true }
            if v >= 0x26C4 && v <= 0x26CD { return true }
            if v >= 0x26CF && v <= 0x26E1 { return true }
            if v >= 0x26E8 && v <= 0x26FF { return true }
            if v >= 0x2702 && v <= 0x27B0 { return true }
            if v >= 0x2B1B && v <= 0x2B55 { return true }
            if v >= 0x2E80 && v <= 0x303E { return true }
            if v >= 0x3040 && v <= 0x3247 { return true }
            if v >= 0x3250 && v <= 0x4DBF { return true }
            if v >= 0x4E00 && v <= 0x9FFF { return true }
            if v >= 0xA960 && v <= 0xA97C { return true }
            if v >= 0xAC00 && v <= 0xD7A3 { return true }
            if v >= 0xF900 && v <= 0xFAFF { return true }
            if v >= 0xFE10 && v <= 0xFE19 { return true }
            if v >= 0xFE30 && v <= 0xFE6B { return true }
            if v >= 0xFF01 && v <= 0xFF60 { return true }
            if v >= 0xFFE0 && v <= 0xFFE6 { return true }
            if v >= 0x1F000 && v <= 0x1F02F { return true }
            if v >= 0x1F0A0 && v <= 0x1F0FF { return true }
            if v >= 0x1F100 && v <= 0x1F1AD { return true }
            if v >= 0x1F1E6 && v <= 0x1F6FF { return true }
            if v >= 0x1F700 && v <= 0x1F77F { return true }
            if v >= 0x1F780 && v <= 0x1F7FF { return true }
            if v >= 0x1F800 && v <= 0x1F8FF { return true }
            if v >= 0x1F900 && v <= 0x1F9FF { return true }
            if v >= 0x1FA00 && v <= 0x1FA6F { return true }
            if v >= 0x1FA70 && v <= 0x1FAFF { return true }
            if v >= 0x20000 { return true }
        }
        return false
    }
}
