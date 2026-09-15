class StatusBarWindow: Window {
    var modeText: String = "NORMAL"
    var fileName: String = "[No Name]"
    var cursorLine: Int = 0
    var cursorCol: Int = 0
    var totalLines: Int = 0
    var modified: Bool = false
    var fileType: String = ""
    var commandText: String = ""
    var errorMessage: String?

    override func update() {
        guard height > 0 else { return }

        let bgColor = Theme.bgDark

        let modeLabel: String
        let modeBgColor: Color
        switch modeText {
        case "NORMAL":
            modeLabel = " NORMAL "
            modeBgColor = Theme.blue
        case "INSERT":
            modeLabel = " INSERT "
            modeBgColor = Theme.green
        case "VISUAL":
            modeLabel = " VISUAL "
            modeBgColor = Theme.magenta
        case "VISUAL LINE":
            modeLabel = " V-LINE "
            modeBgColor = Theme.magenta
        case "COMMAND":
            modeLabel = " COMMAND "
            modeBgColor = Theme.orange
        default:
            modeLabel = " \(modeText) "
            modeBgColor = Theme.blue
        }

        clear()

        for (i, c) in modeLabel.enumerated() {
            if i < width {
                setCell(0, i, Cell.colored(c, fg: Theme.bgDark, bg: modeBgColor, bold: true))
            }
        }

        let rightParts: [String] = [
            fileType.isEmpty ? "" : " \(fileType) ",
            " utf-8 ",
            " \(cursorLine + 1):\(cursorCol + 1) ",
            " \(Int(Double(cursorLine + 1) / Double(max(totalLines, 1)) * 100))% ",
        ]
        let rightText = rightParts.joined()

        let centerText: String
        let centerFg: Color
        if let err = errorMessage {
            centerText = " \(err) "
            centerFg = Theme.red
        } else if modeText == "COMMAND" {
            let prefix = commandText.hasPrefix("/") ? "" : ":"
            centerText = " \(prefix)\(commandText)"
            centerFg = Theme.fg
        } else {
            let modifiedPrefix = modified ? "+ " : ""
            // A path that doesn't fit is truncated from the left — the tail
            // (deepest directories, file name) stays visible.
            var name = fileName
            let avail = width - modeLabel.count - rightText.count - 2
            if modifiedPrefix.count + name.count > avail {
                let keep = max(1, avail - modifiedPrefix.count - 1)
                if keep < name.count {
                    name = "…" + name.suffix(keep)
                }
            }
            centerText = " \(modifiedPrefix)\(name) "
            centerFg = Theme.fgDark
        }
        let centerStart = modeLabel.count
        for (i, c) in centerText.enumerated() {
            let col = centerStart + i
            if col < width {
                setCell(0, col, Cell.colored(c, fg: centerFg, bg: bgColor, bold: modeText != "COMMAND"))
            }
        }

        let rightStart = max(0, width - rightText.count)
        var rc = rightStart
        for part in rightParts {
            for c in part {
                if rc < width {
                    setCell(0, rc, Cell.colored(c, fg: Theme.fgDark, bg: bgColor))
                    rc += 1
                }
            }
        }
    }
}
