class TabBarWindow: Window {
    weak var tabsSource: EditorWindow?

    override func update() {
        guard height > 0, let editor = tabsSource else { return }
        let infos = editor.tabInfos()
        guard !infos.isEmpty else { return }

        clear(bg: Theme.bgDark)

        let labels = infos.map { " \($0.modified ? "+" : "")\($0.name) " }
        let activeIdx = infos.firstIndex { $0.active } ?? 0

        // Window of tabs so that the active one is always visible.
        var start = 0
        var end = labels.count
        let totalWidth = labels.reduce(0) { $0 + $1.count }
        if totalWidth > width {
            var used = labels[activeIdx].count
            start = activeIdx
            while start > 0 && used + labels[start - 1].count <= width {
                start -= 1
                used += labels[start].count
            }
            end = activeIdx + 1
            while end < labels.count && used + labels[end].count <= width {
                used += labels[end].count
                end += 1
            }
        }

        var col = 0
        if start > 0 {
            setCell(0, 0, Cell.colored("<", fg: Theme.orange, bg: Theme.bgDark))
            col = 1
        }
        for idx in start..<end {
            let modified = infos[idx].modified
            let active = idx == activeIdx
            let fg = modified ? Theme.yellow : (active ? Theme.fg : Theme.comment)
            let bg = active ? Theme.bgHighlight : Theme.bgDark
            // Modified but inactive: dimmed yellow, so the marker doesn't
            // compete with the active tab.
            let dim = modified && !active
            for c in labels[idx] {
                guard col < width else { break }
                setCell(0, col, Cell.colored(c, fg: fg, bg: bg, bold: active, dim: dim))
                col += 1
            }
        }
        if end < labels.count && col < width {
            setCell(0, width - 1, Cell.colored(">", fg: Theme.orange, bg: Theme.bgDark))
        }
    }
}
