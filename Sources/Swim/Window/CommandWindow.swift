import Foundation

class CommandWindow: Window {
    private var title: String = ""
    private var outputLines: [Substring] = []
    private var scrollOffset: Int = 0
    private(set) var isRunning: Bool = false
    var spinnerFrame: Int = 0
    var workingDirectory: String = ""
    private let cmdTask = BackgroundTask<[Substring]>()

    private static let spinnerChars: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    func runCommand(_ label: String, args: [String]) {
        title = label
        outputLines = []
        scrollOffset = 0
        isRunning = true
        visible = true
        dirty = true

        let workDir = workingDirectory
        cmdTask.start {
            let result = Shell.git(args, workDir: workDir)
            return result.combined.isEmpty && !result.stderr.isEmpty
                ? [Substring(result.stderr)]
                : result.combined.split(separator: "\n", omittingEmptySubsequences: false)
        }
    }

    override func poll() {
        pollResult()
    }

    func pollResult() {
        guard let lines = cmdTask.consume() else { return }
        outputLines = lines
        isRunning = false
        dirty = true
        delegate?.requestRender()
    }

    override func update() {
        clear()

        if isRunning {
            let spinner = Self.spinnerChars[spinnerFrame % Self.spinnerChars.count]
            drawHeader(" \(spinner) \(title) ", fg: Theme.blue)
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
            drawHeader(" \(title) — done (Esc to close) ", fg: Theme.green)
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
            return false
        default: return false
        }
        return true
    }

}
