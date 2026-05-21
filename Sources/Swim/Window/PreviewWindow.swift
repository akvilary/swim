import Foundation

class PreviewWindow: Window {
    private var lines: [String] = []
    private var filePath: String?
    private var highlightLine: Int = -1
    private var scrollY: Int = 0

    func loadFile(_ path: String?, highlightLine: Int = -1) {
        if path != filePath {
            filePath = path
            scrollY = 0
            if let path = path,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
               let content = String(data: data, encoding: .utf8) {
                lines = content.components(separatedBy: "\n")
            } else {
                lines = []
            }
        }
        self.highlightLine = highlightLine
        if highlightLine > 0 {
            let visibleH = height - 1
            if highlightLine < scrollY + 1 || highlightLine > scrollY + visibleH {
                scrollY = max(0, highlightLine - visibleH / 2 - 1)
            }
        }
        dirty = true
    }

    func resetPreview() {
        filePath = nil
        lines = []
        highlightLine = -1
        scrollY = 0
        dirty = true
    }

    override func update() {
        clear()

        let fileName = filePath.map { ($0 as NSString).lastPathComponent } ?? "Preview"
        drawHeader(" \(fileName) ", fg: Theme.comment, bg: Theme.bgDark)

        let visibleH = height - 1
        let lineNumW = max(3, String(max(lines.count, 1)).count + 1)
        let contentW = max(0, width - lineNumW - 1)

        for row in 0..<visibleH {
            let lineIdx = scrollY + row
            let y = row + 1
            guard lineIdx < lines.count else { break }

            let lineNum = String(lineIdx + 1)
            let paddedNum = String(repeating: " ", count: lineNumW - lineNum.count) + lineNum + " "

            let isHighlight = lineIdx + 1 == highlightLine
            let fg: Color = isHighlight ? Theme.fg : Theme.fgDark
            let bg: Color = isHighlight ? Theme.bgHighlight : Theme.bgDark

            for (i, c) in paddedNum.enumerated() {
                if i < width { setCell(y, i, Cell.colored(c, fg: Theme.fgGutter, bg: bg)) }
            }

            let line = lines[lineIdx]
            let displayLine = String(line.prefix(contentW))
            let offset = lineNumW + 1
            for (i, c) in displayLine.enumerated() {
                let col = offset + i
                if col < width { setCell(y, col, Cell.colored(c, fg: fg, bg: bg)) }
            }
        }
    }

    override func handleKey(_ key: Key) -> Bool {
        switch key {
        case .ctrl("f"):
            let visibleH = height - 1
            if scrollY + visibleH < lines.count {
                scrollY += visibleH
                dirty = true
            }
        case .ctrl("b"):
            let visibleH = height - 1
            scrollY = max(0, scrollY - visibleH)
            dirty = true
        default: return false
        }
        return true
    }
}
