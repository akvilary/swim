import Foundation

class Window {
    weak var delegate: WindowDelegate?
    var x: Int = 0
    var y: Int = 0
    var width: Int = 0
    var height: Int = 0
    var visible: Bool = false
    var focused: Bool = false
    var dirty: Bool = true

    private var cells: [Cell]

    init(x: Int = 0, y: Int = 0, width: Int = 0, height: Int = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.cells = Array(repeating: .blank, count: width * height)
    }

    func resize(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(1, width)
        self.height = max(1, height)
        self.cells = Array(repeating: .blank, count: self.width * self.height)
        self.dirty = true
    }

    func setCell(_ row: Int, _ col: Int, _ cell: Cell) {
        guard row >= 0 && row < height && col >= 0 && col < width else { return }
        let idx = row * width + col
        if cells[idx] != cell {
            cells[idx] = cell
            dirty = true
        }
    }

    func getCell(_ row: Int, _ col: Int) -> Cell {
        guard row >= 0 && row < height && col >= 0 && col < width else { return .blank }
        return cells[row * width + col]
    }

    func fillRegion(row: Int, col: Int, width w: Int, height h: Int, cell: Cell) {
        let rStart = max(0, row)
        let rEnd = min(row + h, height)
        let cStart = max(0, col)
        let cEnd = min(col + w, width)
        guard rStart < rEnd && cStart < cEnd else { return }

        let fillWidth = cEnd - cStart
        let fillCells = Array(repeating: cell, count: fillWidth)
        for r in rStart..<rEnd {
            let base = r * width + cStart
            cells.replaceSubrange(base..<(base + fillWidth), with: fillCells)
        }
        dirty = true
    }

    func writeString(_ str: String, row: Int, col: Int, fg: Color = .default, bg: Color = .default, bold: Bool = false) {
        var c = col
        for char in str {
            guard c < width && row >= 0 && row < height else { break }
            if char == "\t" {
                let spaces = 4 - (c % 4)
                for _ in 0..<spaces {
                    guard c < width else { break }
                    setCell(row, c, Cell.colored(" ", fg: fg, bg: bg, bold: bold))
                    c += 1
                }
            } else {
                setCell(row, c, Cell.colored(char, fg: fg, bg: bg, bold: bold))
                c += 1
            }
        }
    }

    func drawLine(_ text: String, row: Int, col: Int = 0, fg: Color = Theme.fgDark, bg: Color = Theme.bgDark, bold: Bool = false) {
        guard row >= 0 && row < height else { return }
        writeString(text, row: row, col: col, fg: fg, bg: bg, bold: bold)
    }

    func clear(bg: Color = Theme.bgDark) {
        fillRegion(row: 0, col: 0, width: width, height: height, cell: Cell.colored(" ", fg: Theme.fg, bg: bg))
    }

    func drawHeader(_ text: String, fg: Color, bg: Color = Theme.bgHighlight, bold: Bool = true) {
        for (i, c) in text.enumerated() {
            if i < width { setCell(0, i, Cell.colored(c, fg: fg, bg: bg, bold: bold)) }
        }
        for i in text.count..<width {
            setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: bg))
        }
    }

    func handleKey(_ key: Key) -> Bool { false }

    func update() {}

    func poll() {}

    static func clampedScroll(selectedIndex: Int, scrollOffset: Int, visibleCount: Int) -> Int {
        if selectedIndex < scrollOffset { return selectedIndex }
        if selectedIndex >= scrollOffset + visibleCount { return selectedIndex - visibleCount + 1 }
        return scrollOffset
    }
}
