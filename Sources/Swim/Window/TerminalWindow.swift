import Foundation

class TerminalWindow: Window {
    private enum LineKind {
        case stdout
        case stderr
        case status
    }

    private struct Entry {
        let command: String
        var lines: [(text: String, kind: LineKind)]
    }

    private var entries: [Entry] = []
    private var history: [String] = []
    private var historyIndex = -1
    private var savedLiveInput = ""
    private var inputBuffer = ""
    private var inputCursorPos = 0
    private var scrollOffset = 0
    private(set) var isRunning = false
    var spinnerFrame = 0
    var workingDirectory = ""
    private let runTask = BackgroundTask<Shell.Result>()

    private var flatLines: [(text: String, kind: LineKind, isCommand: Bool)] = []
    private var flatDirty = true

    private static let spinnerChars: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private static let maxOutputLines = 10_000

    func prepare(workingDirectory: String) {
        if !workingDirectory.isEmpty {
            self.workingDirectory = workingDirectory
        }
        dirty = true
    }

    override func poll() {
        guard let result = runTask.consume() else { return }
        isRunning = false

        var lines: [(text: String, kind: LineKind)] = []
        if !result.stdout.isEmpty {
            lines += result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
                .map { (String($0), LineKind.stdout) }
        }
        if !result.stderr.isEmpty {
            lines += result.stderr.split(separator: "\n", omittingEmptySubsequences: false)
                .map { (String($0), LineKind.stderr) }
        }
        if result.exitCode == -1 {
            lines.append(("sh: failed to start", .stderr))
        } else if result.exitCode != 0 {
            lines.append(("[exit \(result.exitCode)]", .status))
        }
        if !lines.isEmpty, !entries.isEmpty {
            entries[entries.count - 1].lines = lines
        }
        let dropped = trim()
        flatDirty = true
        // New output never repositions the view; trim must not shift what
        // is currently on screen.
        scrollOffset = max(0, scrollOffset - dropped)
        dirty = true
        delegate?.requestRender()
        // Any finished command may have touched the repository or the open
        // file (edit, rename, branch switch) — the app state must resync.
        delegate?.terminalCommandFinished()
    }

    override func update() {
        clear(bg: Theme.terminalBg)
        if flatDirty {
            buildFlat()
            flatDirty = false
        }
        clampScroll()

        headerPlate = HeaderPlate(text: " Terminal @ \(dirName()) ")
        drawPlate()

        for row in contentTop..<max(contentTop, height) {
            let lineIdx = scrollOffset + (row - contentTop)
            if lineIdx < flatLines.count {
                let line = flatLines[lineIdx]
                let fg: Color
                if line.isCommand {
                    fg = Theme.blue
                } else {
                    switch line.kind {
                    case .stdout: fg = Theme.fgDark
                    case .stderr: fg = Theme.red
                    case .status: fg = Theme.comment
                    }
                }
                drawLine(String(line.text.prefix(width)), row: row, fg: fg, bg: Theme.terminalBg, bold: line.isCommand)
            } else if lineIdx == flatLines.count {
                drawPromptLine(row: row)
            } else {
                break
            }
        }
    }

    override func handleKey(_ key: Key) -> Bool {
        switch key {
        case .up:
            scrollBy(-1)
        case .down:
            scrollBy(1)
        case .ctrlUp:
            scrollBy(-height)
        case .ctrlDown:
            scrollBy(height)
        case .ctrlLeft:
            if !history.isEmpty { scrollToBottom() }
            browseHistory(-1)
        case .ctrlRight:
            if !history.isEmpty { scrollToBottom() }
            browseHistory(1)
        case .pageUp:
            scrollBy(-height)
        case .pageDown:
            scrollBy(height)
        case .ctrl("d"):
            scrollBy(max(1, height / 2))
        case .ctrl("u"):
            scrollBy(-max(1, height / 2))
        case .char(let c) where c.unicodeScalars.count == 1:
            scrollToBottom()
            let idx = inputBuffer.index(inputBuffer.startIndex, offsetBy: inputCursorPos)
            inputBuffer.insert(c, at: idx)
            inputCursorPos += 1
            dirty = true
        case .backspace:
            scrollToBottom()
            if inputCursorPos > 0 {
                let idx = inputBuffer.index(inputBuffer.startIndex, offsetBy: inputCursorPos - 1)
                inputBuffer.remove(at: idx)
                inputCursorPos -= 1
                dirty = true
            }
        case .delete:
            scrollToBottom()
            if inputCursorPos < inputBuffer.count {
                let idx = inputBuffer.index(inputBuffer.startIndex, offsetBy: inputCursorPos)
                inputBuffer.remove(at: idx)
                dirty = true
            }
        case .left:
            scrollToBottom()
            if inputCursorPos > 0 { inputCursorPos -= 1; dirty = true }
        case .right:
            scrollToBottom()
            if inputCursorPos < inputBuffer.count { inputCursorPos += 1; dirty = true }
        case .home:
            scrollToBottom()
            inputCursorPos = 0; dirty = true
        case .end:
            scrollToBottom()
            inputCursorPos = inputBuffer.count; dirty = true
        case .enter:
            if !atBottom {
                scrollToBottom()
                dirty = true
            } else if !isRunning && !inputBuffer.isEmpty {
                submit()
            }
        case .tab:
            scrollToBottom()
            completePath()
        case .ctrl("l"):
            clearOutput()
        case .escape:
            if !atBottom {
                scrollToBottom()
                dirty = true
            } else if inputBuffer.isEmpty && historyIndex == -1 {
                return false
            } else {
                inputBuffer = ""
                inputCursorPos = 0
                historyIndex = -1
                dirty = true
            }
        default:
            break
        }
        return true
    }

    /// The live prompt — the last line of the scrollable buffer.
    private func drawPromptLine(row: Int) {
        var prompt = " > "
        if isRunning {
            let spinner = Self.spinnerChars[spinnerFrame % Self.spinnerChars.count]
            prompt = " \(spinner) > "
        }

        drawLine(prompt, row: row, col: 0, fg: Theme.blue, bg: Theme.terminalBg, bold: true)
        let maxInput = max(0, width - prompt.count - 1)
        let displayText = String(inputBuffer.suffix(maxInput))
        drawLine(displayText, row: row, col: prompt.count, fg: Theme.fg, bg: Theme.terminalBg)
        let cursorCol = prompt.count + min(inputCursorPos, maxInput)
        if cursorCol < width {
            // Same as the editor: invert the existing cell — the character
            // keeps its text color and stays visible under the cursor.
            var cell = getCell(row, cursorCol)
            cell.reverse = true
            setCell(row, cursorCol, cell)
        }
    }

    private func buildFlat() {
        flatLines = []
        for entry in entries {
            flatLines.append((text: " > " + entry.command, kind: .stdout, isCommand: true))
            for line in entry.lines {
                flatLines.append((text: " " + line.text, kind: line.kind, isCommand: false))
            }
        }
    }

    private func ensureFlat() {
        if flatDirty {
            buildFlat()
            flatDirty = false
        }
    }

    private func dirName() -> String {
        workingDirectory.isEmpty
            ? "/"
            : URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    /// Offset at which the prompt line is the last visible row.
    private func standardCeiling() -> Int {
        max(0, flatLines.count + 1 - max(0, contentHeight))
    }

    /// +1 — the prompt line lives at the end of the scrollable content;
    /// the plate row at the top is not scrollable. The ceiling allows
    /// scrolling until the prompt becomes the top row, so a freshly
    /// submitted command can sit at the top with its result below.
    private func maxScroll() -> Int {
        ensureFlat()
        return flatLines.count
    }

    private var atBottom: Bool {
        ensureFlat()
        return scrollOffset >= standardCeiling()
    }

    private func clampScroll() {
        scrollOffset = max(0, min(scrollOffset, maxScroll()))
    }

    private func scrollToBottom() {
        ensureFlat()
        scrollOffset = standardCeiling()
        dirty = true
    }

    private func scrollBy(_ delta: Int) {
        ensureFlat()
        let ceiling = maxScroll()
        let newOffset = max(0, min(min(scrollOffset, ceiling) + delta, ceiling))
        if newOffset != scrollOffset {
            scrollOffset = newOffset
            dirty = true
        }
    }

    private func browseHistory(_ direction: Int) {
        guard !history.isEmpty else { return }
        if historyIndex == -1 {
            guard direction < 0 else { return }
            savedLiveInput = inputBuffer
            historyIndex = history.count - 1
        } else {
            let next = historyIndex + direction
            guard next >= 0 else { return }
            if next >= history.count {
                historyIndex = -1
                inputBuffer = savedLiveInput
                inputCursorPos = inputBuffer.count
                dirty = true
                return
            }
            historyIndex = next
        }
        inputBuffer = history[historyIndex]
        inputCursorPos = inputBuffer.count
        dirty = true
    }

    private func clearOutput() {
        entries = []
        flatDirty = true
        scrollOffset = 0
        dirty = true
    }

    private func submit() {
        let command = inputBuffer
        inputBuffer = ""
        inputCursorPos = 0
        historyIndex = -1
        if history.last != command {
            history.append(command)
        }

        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed == "clear" || trimmed == "cls" {
            clearOutput()
            return
        }
        if trimmed == "exit" || trimmed == "logout" {
            // Echo it so the scrollback shows why the window went away; the
            // window itself is hidden, not destroyed — history survives.
            entries.append(Entry(command: trimmed, lines: []))
            flatDirty = true
            dirty = true
            delegate?.requestClose(self)
            return
        }
        if trimmed == "cd" || trimmed.hasPrefix("cd ") {
            runCd(trimmed)
            return
        }

        entries.append(Entry(command: trimmed, lines: []))
        isRunning = true
        flatDirty = true
        ensureFlat()
        // The submitted command becomes the top visible row — its result
        // is read top-to-bottom. The view returns to the live prompt on
        // the next typed character or a history recall.
        scrollOffset = flatLines.count - 1
        dirty = true

        let workDir = workingDirectory
        runTask.start {
            Shell.run(executable: "/bin/sh", args: ["-c", trimmed], workDir: workDir.isEmpty ? nil : workDir)
        }
    }

    /// `cd` is not a real subprocess: each command runs in its own `/bin/sh`,
    /// so the window tracks the working directory itself.
    private func runCd(_ command: String) {
        var arg = command.count > 3
            ? String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            : ""
        if arg.count >= 2 {
            let first = arg.first, last = arg.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                arg = String(arg.dropFirst().dropLast())
            }
        }
        if arg.isEmpty {
            arg = NSHomeDirectory()
        }
        let expanded = (arg as NSString).expandingTildeInPath
        let combined = expanded.hasPrefix("/")
            ? expanded
            : workingDirectory + "/" + expanded
        let normalized = BufferManager.normalize(combined)

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue {
            entries.append(Entry(command: command, lines: [(text: normalized, kind: .status)]))
            workingDirectory = normalized
        } else {
            entries.append(Entry(command: command, lines: [("cd: not a directory: \(arg)", .stderr)]))
        }
        flatDirty = true
        ensureFlat()
        scrollOffset = flatLines.count - 1
        dirty = true
    }

    /// Evicts the oldest output beyond the cap. Returns how many leading
    /// flat lines were dropped, so the caller can keep the view steady.
    @discardableResult
    private func trim() -> Int {
        var total = entries.reduce(0) { $0 + $1.lines.count }
        var dropped = 0
        while total > Self.maxOutputLines && entries.count > 1 {
            let drop = min(total - Self.maxOutputLines, entries[0].lines.count)
            if drop >= entries[0].lines.count {
                total -= entries[0].lines.count
                dropped += entries[0].lines.count + 1
                entries.removeFirst()
            } else {
                entries[0].lines.removeFirst(drop)
                total -= drop
                dropped += drop
            }
        }
        return dropped
    }

    /// Completes the last token of the input line against directory entries
    /// (single match inserts the name — with `/` for directories; multiple
    /// matches insert their common prefix).
    private func completePath() {
        let tokenStart: String.Index
        if let lastSpace = inputBuffer.lastIndex(of: " ") {
            tokenStart = inputBuffer.index(after: lastSpace)
        } else {
            tokenStart = inputBuffer.startIndex
        }
        let token = String(inputBuffer[tokenStart...])

        let dirPart: String
        let namePart: String
        if let slash = token.lastIndex(of: "/") {
            dirPart = String(token[...slash])
            namePart = String(token[token.index(after: slash)...])
        } else {
            dirPart = ""
            namePart = token
        }

        let base = dirPart.isEmpty
            ? workingDirectory
            : (dirPart.hasPrefix("/")
               ? (dirPart.count > 1 ? String(dirPart.dropLast()) : "/")
               : BufferManager.normalize(workingDirectory + "/" + dirPart))

        let names = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [])
            .filter { $0.hasPrefix(namePart) && (!$0.hasPrefix(".") || namePart.hasPrefix(".")) }
            .sorted()
        guard !names.isEmpty else { return }

        let replacement: String
        if names.count == 1 {
            var completed = names[0]
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: base + "/" + names[0], isDirectory: &isDir), isDir.boolValue {
                completed += "/"
            }
            replacement = completed
        } else {
            replacement = Self.commonPrefix(names)
        }
        guard replacement != namePart || names.count == 1 else { return }

        inputBuffer = String(inputBuffer[..<tokenStart]) + dirPart + replacement
        inputCursorPos = inputBuffer.count
        dirty = true
    }

    private static func commonPrefix(_ names: [String]) -> String {
        guard var prefix = names.first.map({ Array($0) }), !prefix.isEmpty else { return "" }
        for name in names.dropFirst() {
            let chars = Array(name)
            var i = 0
            while i < prefix.count && i < chars.count && prefix[i] == chars[i] {
                i += 1
            }
            prefix.removeLast(prefix.count - i)
            if prefix.isEmpty { break }
        }
        return String(prefix)
    }
}
