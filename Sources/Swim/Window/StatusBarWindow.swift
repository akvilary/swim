class StatusBarWindow: Window {
    var modeText: String = "NORMAL"
    var branch: String?
    var branchAdded = 0
    var branchDeleted = 0
    var fileAdded = 0
    var fileDeleted = 0
    var cursorLine: Int = 0
    var cursorCol: Int = 0
    var totalLines: Int = 0
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

        let centerParts: [(text: String, fg: Color)]
        let centerBold: Bool
        if let err = errorMessage {
            centerParts = [(" \(err) ", fg: Theme.red)]
            centerBold = true
        } else if modeText == "COMMAND" {
            let prefix = commandText.hasPrefix("/") ? "" : ":"
            centerParts = [(" \(prefix)\(commandText)", fg: Theme.fg)]
            centerBold = false
        } else if let branch = branch {
            var parts: [(text: String, fg: Color)] = [(" \(branch)", fg: Theme.fgDark)]
            if branchAdded > 0 { parts.append((" +\(branchAdded)", fg: Theme.green)) }
            if branchDeleted > 0 { parts.append((" -\(branchDeleted)", fg: Theme.red)) }
            if branchAdded > 0 || branchDeleted > 0 { parts.append((" ", fg: Theme.fgDark)) }
            centerParts = parts
            centerBold = true
        } else {
            centerParts = []
            centerBold = true
        }
        var ccol = modeLabel.count
        centerLoop: for part in centerParts {
            for c in part.text {
                guard ccol < width else { break centerLoop }
                setCell(0, ccol, Cell.colored(c, fg: part.fg, bg: bgColor, bold: centerBold))
                ccol += 1
            }
        }

        // Right block: groups joined by uniform single spaces, one space
        // padding on each side.
        var rightGroups: [(text: String, fg: Color)] = []
        if !fileType.isEmpty { rightGroups.append((fileType, fg: Theme.fgDark)) }
        if fileAdded > 0 || fileDeleted > 0 {
            if fileAdded > 0 { rightGroups.append(("+\(fileAdded)", fg: Theme.green)) }
            if fileDeleted > 0 { rightGroups.append(("-\(fileDeleted)", fg: Theme.red)) }
        }
        rightGroups.append(("utf-8", fg: Theme.fgDark))
        rightGroups.append(("\(cursorLine + 1):\(cursorCol + 1)", fg: Theme.fgDark))
        rightGroups.append(("\(Int(Double(cursorLine + 1) / Double(max(totalLines, 1)) * 100))%", fg: Theme.fgDark))

        var rightParts: [(text: String, fg: Color)] = [(" ", fg: Theme.fgDark)]
        for (idx, group) in rightGroups.enumerated() {
            if idx > 0 { rightParts.append((" ", fg: Theme.fgDark)) }
            rightParts.append(group)
        }
        rightParts.append((" ", fg: Theme.fgDark))

        // Drawn last: on narrow widths the right block wins the overlap,
        // matching the original status-bar precedence.
        let rightWidth = rightParts.reduce(0) { $0 + $1.text.count }
        var col = max(0, width - rightWidth)
        rightLoop: for part in rightParts {
            for c in part.text {
                guard col < width else { break rightLoop }
                setCell(0, col, Cell.colored(c, fg: part.fg, bg: bgColor))
                col += 1
            }
        }
    }
}
