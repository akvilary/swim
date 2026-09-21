import Foundation

class CommandWindow: Window {
    override var availableModes: [WindowMode] { [.menu, .command] }
    private var title: String = ""
    private var outputLines: [Substring] = []
    private var scrollOffset: Int = 0
    private(set) var isRunning: Bool = false
    var spinnerFrame: Int = 0
    var workingDirectory: String = ""
    private var session: InteractiveShell?
    /// The credential kind being typed in the command line, if any —
    /// git is blocked on an askpass prompt right now.
    private var inputKind: CredentialKind?
    /// The finished run was Esc-cancelled — the done plate says so.
    private var lastRunCancelled = false

    private static let spinnerChars: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    func runCommand(_ label: String, args: [String]) {
        // A previous run may still be blocked on a credential nobody
        // will ever answer — cancel it before starting the new one.
        session?.cancel()
        title = label
        outputLines = []
        scrollOffset = 0
        isRunning = true
        lastRunCancelled = false
        inputKind = nil
        visible = true
        dirty = true

        let workDir = workingDirectory
        let newSession = InteractiveShell()
        session = newSession
        newSession.start(executable: "/usr/bin/git", args: args, workDir: workDir)
    }

    override func poll() {
        guard let session else { return }
        // The process is blocked on a credential prompt — turn it into
        // this window's command line: login first, then password.
        if !session.isFinished, mode != .command, let prompt = session.currentPrompt() {
            inputKind = prompt.kind
            enterCommandMode()
            dirty = true
            delegate?.requestRender()
        }
        guard let result = session.consumeResult() else { return }
        finish(with: result, cancelled: session.wasCancelled)
    }

    private func finish(with result: Shell.Result, cancelled: Bool) {
        session = nil
        if mode == .command { exitCommandMode() }
        inputKind = nil
        lastRunCancelled = cancelled
        outputLines = result.combined.isEmpty && !result.stderr.isEmpty
            ? [Substring(result.stderr)]
            : result.combined.split(separator: "\n", omittingEmptySubsequences: false)
        isRunning = false
        dirty = true
        delegate?.requestRender()
        delegate?.gitCommandFinished(title)
    }

    /// Called when the window is closed while the process still waits
    /// for a credential — the operation is cancelled (killed) instead
    /// of hanging with no one to answer it.
    func cancelPendingCredential() {
        if let session, session.isAwaitingInput { session.cancel() }
    }

    override func executeCommand(_ cmd: String) -> Bool {
        // Enter in the credential command line — one line into the
        // waiting process's stdin; git proceeds (or asks for the
        // password next).
        if inputKind != nil, let session, session.isAwaitingInput {
            inputKind = nil
            session.answer(cmd)
            dirty = true
            return true
        }
        return super.executeCommand(cmd)
    }

    override func handleCommandModeKey(_ key: Key) -> Bool {
        // Esc while typing a credential cancels the whole operation:
        // the process is terminated, not just left without an answer.
        if case .escape = key, let session, session.isAwaitingInput {
            session.cancel()
            inputKind = nil
            dirty = true
        }
        return super.handleCommandModeKey(key)
    }

    /// While a credential is typed, the status-bar COMMAND label reads
    /// LOGIN / PASSWORD (PASS on narrow terminals).
    override func commandModeLabel() -> String? {
        guard let kind = inputKind else { return nil }
        return width >= 45 ? kind.statusLabel : kind.statusLabelNarrow
    }

    /// The password is never shown — asterisks of the same length keep
    /// the caret honest; the login stays visible as usual.
    override func masksCommandLine() -> Bool {
        inputKind == .password
    }

    override func update() {
        clear()

        if isRunning, let kind = inputKind {
            let spinner = Self.spinnerChars[spinnerFrame % Self.spinnerChars.count]
            let label = width >= 20 ? kind.label : kind.narrowLabel
            drawHeader(" \(spinner) \(title) — waiting for \(label) ", fg: Theme.orange)
            let msg = "Type \(label) in the command line (Enter — submit, Esc — cancel)"
            let midRow = height / 2
            let startCol = max(0, (width - msg.count - 2) / 2)
            for (i, c) in msg.enumerated() where startCol + i < width {
                setCell(midRow, startCol + i, Cell.colored(c, fg: Theme.orange, bg: Theme.bgDark))
            }
            return
        }

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
            let header = lastRunCancelled
                ? " \(title) — cancelled (Esc to close) "
                : " \(title) — done (Esc to close) "
            drawHeader(header, fg: lastRunCancelled ? Theme.orange : Theme.green)
            let visibleLines = max(0, height - 1)
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
                let visibleLines = max(0, height - 1)
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
