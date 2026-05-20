import Foundation

private nonisolated(unsafe) var _cmdResult: [Substring]?
private nonisolated(unsafe) var _cmdDone: Bool = false

class CommandWindow: Window {
    private var title: String = ""
    private var outputLines: [Substring] = []
    private var scrollOffset: Int = 0
    private(set) var isRunning: Bool = false
    var spinnerFrame: Int = 0
    var workingDirectory: String = ""

    var onNeedsRender: (() -> Void)?

    private static let spinnerChars: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    func runCommand(_ label: String, args: [String]) {
        title = label
        outputLines = []
        scrollOffset = 0
        isRunning = true
        _cmdResult = nil
        _cmdDone = false
        visible = true
        dirty = true

        let workDir = workingDirectory
        Thread {
            let process = Process()
            let pipe = Pipe()
            let errPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            if !workDir.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: workDir) }
            process.standardOutput = pipe
            process.standardError = errPipe
            do {
                try process.run()
                let outData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let combined = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
                _cmdResult = combined.split(separator: "\n", omittingEmptySubsequences: false)
            } catch {
                _cmdResult = ["error: \(error.localizedDescription)"]
            }
            _cmdDone = true
        }.start()
    }

    func pollResult() {
        guard _cmdDone else { return }
        _cmdDone = false
        if let lines = _cmdResult {
            outputLines = lines
            _cmdResult = nil
        }
        isRunning = false
        dirty = true
        onNeedsRender?()
    }

    override func update() {
        clear()
        fillRegion(row: 0, col: 0, width: width, height: height, cell: Cell.colored(" ", fg: Theme.fg, bg: Theme.bgDark))

        if isRunning {
            let spinner = Self.spinnerChars[spinnerFrame % Self.spinnerChars.count]
            let headerText = " \(spinner) \(title) "
            for (i, c) in headerText.enumerated() {
                if i < width { setCell(0, i, Cell.colored(c, fg: Theme.blue, bg: Theme.bgHighlight, bold: true)) }
            }
            for i in headerText.count..<width {
                setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
            }
            let msg = "Running \(title)..."
            let midRow = height / 2
            let startCol = max(0, (width - msg.count - 2) / 2)
            let fullMsg = "\(spinner) \(msg)"
            for (i, c) in fullMsg.enumerated() {
                if startCol + i < width {
                    setCell(midRow, startCol + i, Cell.colored(c, fg: Theme.blue, bg: Theme.bgDark, bold: true))
                }
            }
        } else {
            let headerText = " \(title) — done (Esc to close) "
            for (i, c) in headerText.enumerated() {
                if i < width { setCell(0, i, Cell.colored(c, fg: Theme.green, bg: Theme.bgHighlight, bold: true)) }
            }
            for i in headerText.count..<width {
                setCell(0, i, Cell.colored(" ", fg: Theme.fgDark, bg: Theme.bgHighlight))
            }
            let visibleLines = height - 1
            for i in 0..<visibleLines {
                let lineIdx = scrollOffset + i
                guard lineIdx < outputLines.count else { break }
                let line = outputLines[lineIdx]
                let fg: Color = line.hasPrefix("fatal") || line.hasPrefix("error") ? Theme.red : Theme.fgDark
                drawLine(String(line.prefix(width)), row: i + 1, fg: fg)
            }
        }
    }

    override func handleKey(_ key: Key) -> Bool {
        switch key {
        case .char("j"), .down:
            if !isRunning {
                let visibleLines = height - 1
                if scrollOffset + visibleLines < outputLines.count {
                    scrollOffset += 1; dirty = true
                }
            }
        case .char("k"), .up:
            if !isRunning {
                if scrollOffset > 0 { scrollOffset -= 1; dirty = true }
            }
        case .escape:
            visible = false; isRunning = false; dirty = true
            onNeedsRender?()
        default: return false
        }
        return true
    }

    private func drawLine(_ text: String, row: Int, col: Int = 0, fg: Color = Theme.fgDark, bg: Color = Theme.bgDark, bold: Bool = false) {
        guard row >= 0 && row < height else { return }
        for (i, c) in text.enumerated() {
            if col + i < width { setCell(row, col + i, Cell.colored(c, fg: fg, bg: bg, bold: bold)) }
        }
    }
}
