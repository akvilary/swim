import Foundation
import SwimCore

class StatusBarWindow: Window {
    /// The window whose mode and command line are presented — the command
    /// owner while a command is being typed, else the focused window.
    /// Command-mode presentation (buffer + visible caret) is standard for
    /// every window that enters command mode: the status bar pulls it from
    /// the source, no per-window wiring.
    weak var commandSource: Window?

    var branch: String?
    var branchAdded = 0
    var branchDeleted = 0
    var fileAdded = 0
    var fileDeleted = 0
    var cursorLine: Int = 0
    var cursorCol: Int = 0
    var totalLines: Int = 0
    var fileType: String = ""
    /// Command-line caret column inside the status bar while a command is
    /// being typed (nil otherwise) — computed with the center layout; the
    /// real terminal cursor (insert-mode bar) is placed there by the
    /// renderer.
    private(set) var commandCaretScreenCol: Int?

    var errorMessage: String?

    /// Diagnostic of the editor's cursor line (message + LSP severity:
    /// 1 error, 2 warning, 3 info, 4 hint). Shown in the center block
    /// below transient errors and the command line, above branch info.
    var diagnosticMessage: (text: String, severity: Int)?

    override func update() {
        commandCaretScreenCol = nil
        guard height > 0 else { return }

        let source = commandSource
        let modeText = source.map { Self.modeText($0.mode) } ?? "NORMAL"
        let inCommand = source?.mode == .command

        let bgColor = Theme.bgDark

        let modeLabel: String
        let modeBgColor: Color
        if let custom = inCommand ? source?.commandModeLabel() : nil {
            modeLabel = " \(custom) "
            modeBgColor = Theme.orange
        } else {
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
        }

        clear()

        for (i, c) in modeLabel.enumerated() {
            if i < width {
                setCell(0, i, Cell.colored(c, fg: Theme.bgDark, bg: modeBgColor, bold: true))
            }
        }

        // The right block is composed FIRST: it is fixed — always
        // displayed, right-aligned — and the command line's scrolling
        // area is measured against its left edge (the center block
        // below). Groups joined by uniform single spaces, one space
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
        let rightWidth = rightParts.reduce(0) { $0 + $1.text.count }
        // The block is right-aligned but never claims the mode label's
        // territory — the label (always ASCII) owns its cells on every
        // width; on a bar too narrow for both, the block is what clips.
        let rightStart = max(modeLabel.count, width - rightWidth)

        let centerParts: [(text: String, fg: Color)]
        let centerBold: Bool
        if let err = errorMessage {
            centerParts = [(" \(err) ", fg: Theme.red)]
            centerBold = true
        } else if inCommand, let source = source {
            let commandText = source.commandBuffer
            // A credential input is not a ":" command — the label hook
            // doubles as the marker for that repurposed surface.
            let isCredential = source.commandModeLabel() != nil
            let prefix = (commandText.hasPrefix("/") || isCredential) ? "" : ":"
            // Masked input renders asterisks of the same Character count,
            // so the caret math over the real buffer stays exact.
            let display = source.masksCommandLine()
                ? String(repeating: "*", count: commandText.count)
                : commandText
            // The command line scrolls like every other typing surface
            // (the shared InputLine policy) within the space between the
            // mode label and the FIXED right block: the block is always
            // displayed, the typed text scrolls horizontally inside its
            // own area so the newest characters and the caret stay
            // visible. The window is measured in terminal CELLS — wide
            // graphemes (CJK, emoji) occupy two and cannot push the
            // caret under the block; one trailing cell of the area is
            // reserved so the caret always owns a cell of its own.
            let capacity = max(0, rightStart - modeLabel.count - 1 - prefix.count - 1)
            let win = InputLine.window(text: display, caret: source.commandCursorPos, capacity: capacity)
            let visible = display.dropFirst(win.start).prefix(win.visibleCount)
            centerParts = [(" \(prefix)\(visible)", fg: Theme.fg)]
            centerBold = false
            let caret = modeLabel.count + 1 + prefix.count + win.caretOffset
            if caret >= 0, caret < width { commandCaretScreenCol = caret }
        } else if let diag = diagnosticMessage {
            let fg = diag.severity <= 1 ? Theme.red : (diag.severity == 2 ? Theme.orange : Theme.yellow)
            centerParts = [(" \(diag.text) ", fg: fg)]
            centerBold = true
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
                // Wide graphemes claim two cells (a continuation for the
                // renderer); a glyph straddling the row's end is dropped
                // whole — same policy as Window.writeString.
                let w = max(1, c.displayWidth)
                guard ccol + w <= width else { break centerLoop }
                setCell(0, ccol, Cell.colored(c, fg: part.fg, bg: bgColor, bold: centerBold))
                if w == 2 {
                    var cont = Cell.colored(" ", fg: part.fg, bg: bgColor, bold: centerBold)
                    cont.wideContinuation = true
                    setCell(0, ccol + 1, cont)
                }
                ccol += w
            }
        }

        // Drawn last: the fixed right block always wins the overlap over
        // the informational center texts (errors, diagnostics, branch
        // info — display-only, truncation is acceptable). The typed
        // command never reaches it — its scrolling area ends one cell
        // short of the block by construction.
        var col = rightStart
        rightLoop: for part in rightParts {
            for c in part.text {
                let w = max(1, c.displayWidth)
                guard col + w <= width else { break rightLoop }
                setCell(0, col, Cell.colored(c, fg: part.fg, bg: bgColor))
                if w == 2 {
                    var cont = Cell.colored(" ", fg: part.fg, bg: bgColor)
                    cont.wideContinuation = true
                    setCell(0, col + 1, cont)
                }
                col += w
            }
        }
    }

    override func cursorRenderInfo() -> CursorRenderInfo? {
        guard let caret = commandCaretScreenCol else { return nil }
        return .insertCaret(row: y, col: x + caret)
    }

    private static func modeText(_ mode: WindowMode) -> String {
        switch mode {
        case .menu: return "MENU"
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .visual: return "VISUAL"
        case .visualLine: return "VISUAL LINE"
        case .command: return "COMMAND"
        }
    }
}
