import Foundation
import SwimCore

class PreviewWindow: Window {
    /// The content store AND the highlighting engine in one: a
    /// Highlight.Session over the file's immutable snapshot (read
    /// surface only — the PieceTable is sealed inside). Language
    /// routing, viewport-scoped tokenization (visible lines only,
    /// on draw — nothing pre-colored) and the string-state ladder
    /// all live there. Nil — nothing previewed.
    private var session: Highlight.Session?
    private var filePath: String?
    private var highlightLine: Int = -1
    private var scrollY: Int = 0

    /// The preview's color policy — a DIM overview with the lexical
    /// types colored: keywords, strings, numbers, comments (markdown's
    /// vocabulary falls out as markers/fences/lists/quotes almost in
    /// full). Everything else keeps the dim base; the editor's full
    /// map lives in Theme.color(forToken:) — the preview deliberately
    /// takes a subset rather than a second palette.
    private static let tokenColors: [String: Color] = [
        "keyword": Theme.magenta,
        "string": Theme.green,
        "number": Theme.orange,
        "comment": Theme.comment,
    ]

    func loadFile(_ path: String?, highlightLine: Int = -1) {
        if path != filePath {
            filePath = path
            scrollY = 0
            if let path = path,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
               let content = String(data: data, encoding: .utf8) {
                session = Highlight.Session(text: content, fileExt: (path as NSString).pathExtension)
            } else {
                session = nil
            }
        }
        self.highlightLine = highlightLine
        if highlightLine > 0 {
            let visibleH = max(0, height - 1)
            if highlightLine < scrollY + 1 || highlightLine > scrollY + visibleH {
                scrollY = max(0, highlightLine - visibleH / 2 - 1)
            }
        }
        dirty = true
    }

    func resetPreview() {
        session = nil
        filePath = nil
        highlightLine = -1
        scrollY = 0
        dirty = true
    }

    override func update() {
        clear()

        let fileName = filePath.map { ($0 as NSString).lastPathComponent } ?? "Preview"
        drawHeader(" \(fileName) ", fg: Theme.comment, bg: Theme.bgDark)

        guard let session else { return }
        let visibleH = max(0, height - 1)
        let lineCount = session.lineCount
        let lineNumW = max(3, String(max(lineCount, 1)).count + 1)

        // One window-shaped call per draw — markdown's tokenizer is
        // viewport-based; code/JSON loop lines inside the session.
        let tokensByLine = session.tokens(scrollY: scrollY, height: visibleH)

        for row in 0..<visibleH {
            let lineIdx = scrollY + row
            guard lineIdx < lineCount else { break }
            let y = row + 1

            let isHighlight = lineIdx + 1 == highlightLine
            let bg: Color = isHighlight ? Theme.bgHighlight : Theme.bgDark
            let baseFg: Color = Theme.fgDark

            // One row = one cell array through the shared pipeline
            // (Window.textCells / Window.drawCells): the gutter, then
            // the content as token runs — gaps and non-lexical types in
            // the dim base, the subset types in their colors, wide
            // glyphs claiming continuation cells, the window edge the
            // only truncation.
            var cells: [Cell] = []
            let lineNum = String(lineIdx + 1)
            let paddedNum = String(repeating: " ", count: max(0, lineNumW - lineNum.count)) + lineNum + " "
            for c in paddedNum {
                cells.append(Cell.colored(c, fg: Theme.fgGutter, bg: bg))
            }

            let chars = session.getLineChars(lineIdx)
            let tokens = (tokensByLine[lineIdx] ?? []).sorted { $0.startChar < $1.startChar }
            var pos = 0
            for token in tokens where token.length > 0 {
                guard token.startChar >= pos, token.startChar + token.length <= chars.count else { continue }
                if token.startChar > pos {
                    cells += Self.textCells(String(chars[pos..<token.startChar]), fg: baseFg, bg: bg)
                }
                let fg = Self.tokenColors[token.type] ?? baseFg
                cells += Self.textCells(String(chars[token.startChar..<token.startChar + token.length]), fg: fg, bg: bg)
                pos = token.startChar + token.length
            }
            if pos < chars.count {
                cells += Self.textCells(String(chars[pos...]), fg: baseFg, bg: bg)
            }

            drawCells(cells, row: y, offset: 0, fillFg: baseFg, fillBg: bg)
        }
    }

    override func handleKey(_ key: Key) -> Bool {
        switch key {
        case .ctrl("j"), .ctrlDown:
            let visibleH = max(0, height - 1)
            if let session, scrollY + visibleH < session.lineCount {
                scrollY += visibleH
                dirty = true
            }
        case .ctrl("k"), .ctrlUp:
            let visibleH = max(0, height - 1)
            scrollY = max(0, scrollY - visibleH)
            dirty = true
        default: return false
        }
        return true
    }
}
