class StatusBarWindow: Window {
    var modeText: String = "NORMAL"
    var fileName: String = "[No Name]"
    var cursorLine: Int = 0
    var cursorCol: Int = 0
    var totalLines: Int = 0
    var modified: Bool = false
    var fileEncoding: String = "utf-8"
    var fileType: String = ""
    var commandText: String = ""

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
        case "COMMAND":
            modeLabel = " COMMAND "
            modeBgColor = Theme.orange
        default:
            modeLabel = " \(modeText) "
            modeBgColor = Theme.blue
        }

        for i in 0..<width {
            setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: bgColor))
        }

        for (i, c) in modeLabel.enumerated() {
            if i < width {
                setCell(0, i, Cell.colored(c, fg: Theme.bgDark, bg: modeBgColor, bold: true))
            }
        }

        let centerText: String
        let centerFg: Color
        if modeText == "COMMAND" {
            let prefix = commandText.hasPrefix("/") ? "" : ":"
            centerText = " \(prefix)\(commandText)"
            centerFg = Theme.fg
        } else {
            centerText = " \(modified ? "+ " : "")\(fileName) "
            centerFg = Theme.fgDark
        }
        let centerStart = modeLabel.count
        for (i, c) in centerText.enumerated() {
            let col = centerStart + i
            if col < width {
                setCell(0, col, Cell.colored(c, fg: centerFg, bg: bgColor, bold: modeText != "COMMAND"))
            }
        }

        let rightParts: [String] = [
            fileType.isEmpty ? "" : " \(fileType) ",
            " \(fileEncoding) ",
            " \(cursorLine + 1):\(cursorCol + 1) ",
            " \(Int(Double(cursorLine + 1) / Double(max(totalLines, 1)) * 100))% ",
        ]
        let rightText = rightParts.joined()
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
