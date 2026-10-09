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
    /// A command queued to run in this window right after the current
    /// one SUCCEEDS (the branch picker's menu-mode Ctrl+Enter: switch,
    /// then pull). Dropped on failure or Esc-cancel — the
    /// predecessor's output stays on screen explaining why.
    private var followUp: (label: String, args: [String])?
    /// The shape (user args + ref) of the LAST merge run here — a
    /// conflicted finish offers ours/theirs retries that preserve it.
    private var lastMergeShape: MergeShape?

    private static let spinnerChars: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    func runCommand(_ label: String, args: [String], then chaining: (label: String, args: [String])? = nil) {
        // A previous run may still be blocked on a credential nobody
        // will ever answer — cancel it before starting the new one.
        session?.cancel()
        title = label
        outputLines = []
        scrollOffset = 0
        isRunning = true
        lastRunCancelled = false
        inputKind = nil
        followUp = chaining
        // A new command supersedes an unanswered conflict choice —
        // the conflicted state stays on disk untouched, git's own
        // `git merge --abort` is the way out if that is what happened.
        mergeConflict = nil
        // Remember the merge's shape (user args + the ref after `--`)
        // so a conflicted finish can offer ours/theirs retries that
        // PRESERVE what the user asked for (--no-ff etc.).
        lastMergeShape = args.first == "merge" ? parseMergeShape(args) : nil
        visible = true
        dirty = true

        let workDir = workingDirectory
        let newSession = InteractiveShell()
        session = newSession
        newSession.start(executable: "/usr/bin/git", args: args, workDir: workDir)
    }

    /// The merge invocation's shape: the user's pass-through arguments
    /// and the ref, split at the `--` separator the picker rebuilds
    /// (`git merge <args> -- <name>`). Nil when the shape doesn't hold
    /// (no `--`, no name) — the conflict offer is skipped then.
    private struct MergeShape {
        let userArgs: [String]
        let name: String
    }

    private func parseMergeShape(_ args: [String]) -> MergeShape? {
        // dash >= 1, not > 1: a no-arguments merge is
        // ["merge", "--", name] — the separator sits right after the
        // subcommand and the user-args slice is simply empty.
        guard let dash = args.firstIndex(of: "--"), dash >= 1,
              dash + 1 < args.count else { return nil }
        return MergeShape(userArgs: Array(args[1..<dash]), name: args[dash + 1])
    }

    /// A merge finished with conflicts on disk: the window holds a
    /// one-key choice until the user resolves it (k/o/t) or Esc aborts
    /// the merge. The state is the offer itself — nothing runs until
    /// a key picks.
    private var mergeConflict: MergeShape?

    /// Detects the conflicted state after a failed merge: `ls-files -u`
    /// lists unmerged index entries (empty after --abort, empty on a
    /// clean merge — self-gating against every other finished merge).
    private func detectMergeConflicts() -> Bool {
        let result = Shell.git(["ls-files", "-u"], workDir: workingDirectory)
        return result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        // Report first, chain second: the app (stats, git panel, tab
        // sweep) must reflect the finished command before its
        // follow-up starts rewriting the world again. The follow-up
        // only runs while the window is still open — closing it (Esc,
        // `:q`) abandons the chain instead of resurrecting the window
        // unfocused mid-operation. The predecessor itself may still
        // complete (its process was already running) — pre-existing
        // semantics of closing a running command window.
        delegate?.gitCommandFinished(title)
        if visible, !cancelled, result.exitCode == 0, let next = followUp {
            followUp = nil
            runCommand(next.label, args: next.args)
            return
        }
        followUp = nil
        // A failed merge with unmerged index entries is not just an
        // error to read — offer the resolution choice (the picker's
        // `m` deliberately does not ask the policy blind). Runs only
        // for a real conflict: -X retries cannot conflict and an
        // --abort leaves ls-files -u empty.
        if visible, !cancelled, result.exitCode != 0, let shape = lastMergeShape,
           detectMergeConflicts() {
            mergeConflict = shape
            dirty = true
        }
        delegate?.requestRender()
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

    override func handleKey(_ key: Key) -> Bool {
        // The conflict choice is modal over this window: one key
        // decides, anything else re-prompts (the write-confirm's
        // discipline). k keeps the conflicted state for manual
        // resolution in the editor (commit from the git panel when
        // done); o/t abort and re-merge with -X ours/theirs,
        // PRESERVING the user's own merge arguments (--no-ff etc.);
        // Esc aborts the merge outright.
        if let shape = mergeConflict {
            switch key {
            case .char("k"), .char("K"):
                mergeConflict = nil
                delegate?.reportError("Conflicts left for manual resolution — resolve in the editor, a in the git panel, then c")
                dirty = true
            case .char("o"), .char("O"):
                mergeConflict = nil
                retryMergeResolving("ours", shape: shape)
            case .char("t"), .char("T"):
                mergeConflict = nil
                retryMergeResolving("theirs", shape: shape)
            case .escape:
                mergeConflict = nil
                delegate?.runGitCommand(label: "git merge --abort", args: ["merge", "--abort"])
            default:
                break
            }
            return true
        }
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

    /// The o/t arm: abort the conflicted merge, then re-merge with the
    /// `-X ours/theirs` hunk-level policy — the user's own arguments
    /// ride along, so a `--no-ff` merge stays --no-ff through the
    /// retry. The chain's follow-up contract runs the retry only
    /// after a successful abort.
    private func retryMergeResolving(_ strategy: String, shape: MergeShape) {
        let userArgs = shape.userArgs.joined(separator: " ")
        let argPrefix = userArgs.isEmpty ? "" : userArgs + " "
        delegate?.runGitCommand(
            label: "git merge --abort", args: ["merge", "--abort"],
            then: (
                label: "git merge \(argPrefix)-X \(strategy) \(shape.name)",
                args: ["merge"] + shape.userArgs + ["-X", strategy, "--", shape.name]
            ))
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

        if mergeConflict != nil {
            // The choice is the plate; the merge's own CONFLICT output
            // below explains WHAT conflicted — same rendering as the
            // done branch.
            drawHeader(" Merge conflicts — k: keep & resolve, o: ours, t: theirs, Esc: abort ", fg: Theme.red)
            let visibleLines = max(0, height - 1)
            for i in 0..<visibleLines {
                let lineIdx = scrollOffset + i
                guard lineIdx < outputLines.count else { break }
                let line = outputLines[lineIdx]
                let fg: Color = line.hasPrefix("fatal") || line.hasPrefix("error") ? Theme.red : Theme.fgDark
                drawLine(String(line.prefix(width)), row: i + 1, fg: fg)
            }
        } else if isRunning {
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

}
