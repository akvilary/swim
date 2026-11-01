#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Darwin)
@preconcurrency import Darwin
#endif
import Foundation

private nonisolated(unsafe) var resizePipeWriteFd: Int32 = -1
private nonisolated(unsafe) var termPipeWriteFd: Int32 = -1

private func sigwinchHandler(_: Int32) {
    // errno is thread-local state shared with the interrupted code: a
    // failed write here (EAGAIN on a full pipe) would overwrite the
    // EINTR the interrupted syscall is about to report to readByte or
    // writeBuffer. Save/restore is the async-signal-safety discipline.
    let savedErrno = errno
    var byte: UInt8 = 1
    _ = write(resizePipeWriteFd, &byte, 1)
    errno = savedErrno
}

/// SIGHUP/SIGTERM/SIGINT → one byte into the termination pipe; the run
/// loop's next iteration performs the graceful exit (the same path as
/// `:qa` — LSP servers stopped, terminal restored). Dying by the
/// default disposition instead would leave the user's shell in raw
/// mode (the alt screen still up) and orphan the language servers —
/// sourcekit-lsp demonstrably survives its parent's hard death.
private func terminationHandler(_: Int32) {
    let savedErrno = errno
    var byte: UInt8 = 1
    _ = write(termPipeWriteFd, &byte, 1)
    errno = savedErrno
}

final class Terminal {
    private var originalTermios: termios?
    private(set) var width: Int = 80
    private(set) var height: Int = 24
    private var outputBuffer = [UInt8]()

    private var resizePipeReadFd: Int32 = -1
    private var termPipeReadFd: Int32 = -1

    nonisolated(unsafe) static let shared = Terminal()
    private init() {}

    /// The minimum terminal size swim serves its layout in: 60 columns
    /// (beside the explorer's 22-column floor the editor keeps a
    /// workable 38) and 5 rows (the status bar plus a few content
    /// rows). Startup refuses less (run()); a runtime shrink below this
    /// paints the too-small overlay instead of a degenerate layout.
    static let minimumWidth = 60
    static let minimumHeight = 5

    var isTooSmall: Bool {
        width < Self.minimumWidth || height < Self.minimumHeight
    }

    /// The shared self-pipe read side: a byte is pending. The discipline
    /// both signal pipes share (resize, termination).
    private func pipeHasData(_ fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, 0)
        return ready > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }

    /// Drain a self-pipe dry (non-blocking read loop; safe on the empty
    /// pipe — a full pipe coalesces a signal storm into one reaction).
    private func drainPipe(_ fd: Int32) {
        guard fd >= 0 else { return }
        var buf: UInt8 = 0
        while read(fd, &buf, 1) == 1 {}
    }

    var hasResizeEvent: Bool {
        pipeHasData(resizePipeReadFd)
    }

    func consumeResizeEvent() {
        drainPipe(resizePipeReadFd)
        updateSize()
    }

    /// A termination signal (SIGHUP/SIGTERM/SIGINT) is pending — the
    /// run loop reacts by leaving its `while running` loop through the
    /// graceful tail (same as `:qa`).
    var hasTerminationEvent: Bool {
        pipeHasData(termPipeReadFd)
    }

    func consumeTerminationEvent() {
        drainPipe(termPipeReadFd)
    }

    /// The discipline both signal pipes share: non-blocking (a blocking
    /// self-pipe freezes the editor — the drain loop parks forever on
    /// the empty pipe because the write end lives in this process, and
    /// a blocking write inside a handler could deadlock it) and
    /// CLOEXEC (the pipes stay out of every child — git, LSP, the
    /// embedded shell — which neither needs them nor keeps them alive).
    private func configureSelfPipe(_ fds: [Int32]) {
        for fd in fds {
            let flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
    }

    func setup() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw

        raw.c_iflag &= ~tcflag_t(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON)
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | ISIG | IEXTEN)
        raw.c_cflag |= tcflag_t(CS8)
        raw.c_cc.15 = 0
        raw.c_cc.16 = 0
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)

        var fds: [Int32] = [-1, -1]
        _ = pipe(&fds)
        resizePipeReadFd = fds[0]
        resizePipeWriteFd = fds[1]
        configureSelfPipe(fds)

        var termFds: [Int32] = [-1, -1]
        _ = pipe(&termFds)
        termPipeReadFd = termFds[0]
        termPipeWriteFd = termFds[1]
        configureSelfPipe(termFds)

        updateSize()
        writeRaw("\u{1b}[?1049h")
        // SGR reset on entering: the alternate screen inherits the pen
        // the shell left behind (a prompt color the shell never reset
        // is the common case). Color modes overwrite it with the first
        // frame anyway; mono (NO_COLOR) emits no colors at all, so
        // without this reset an inherited color would own the whole
        // session.
        writeRaw("\u{1b}[0m")
        // Bracketed paste: the terminal wraps pasted text in ESC[200~ …
        // ESC[201~ so it arrives as one chunk instead of a keystroke
        // stream (which auto-indent would mangle line by line).
        writeRaw("\u{1b}[?2004h")
        // Focus reporting: the terminal sends CSI I / CSI O whenever the
        // OS window gains/loses focus — the arrival event drives the
        // external-change sweep (Application.checkTimestamps): the moment
        // the user comes back to swim, buffers resync with whatever an
        // agent or command did meanwhile (vim's FocusGained → checktime).
        // Terminals and tmux sessions without support simply never send
        // the events; the other trigger lanes cover that case.
        writeRaw("\u{1b}[?1004h")
        writeRaw("\u{1b}[2J")
        writeRaw("\u{1b}[H")

        var sa = sigaction()
        #if canImport(Glibc)
        sa.__sigaction_handler = .init(sa_handler: sigwinchHandler)
        #elseif canImport(Darwin)
        sa.__sigaction_u.__sa_handler = sigwinchHandler
        #endif
        sigemptyset(&sa.sa_mask)
        sa.sa_flags = 0
        sigaction(SIGWINCH, &sa, nil)

        // The termination trio rides the same shape (no SA_RESTART —
        // the EINTR wakes the poll/wait so the loop sees the pipe in
        // its next iteration).
        var termSa = sigaction()
        #if canImport(Glibc)
        termSa.__sigaction_handler = .init(sa_handler: terminationHandler)
        #elseif canImport(Darwin)
        termSa.__sigaction_u.__sa_handler = terminationHandler
        #endif
        sigemptyset(&termSa.sa_mask)
        termSa.sa_flags = 0
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            sigaction(sig, &termSa, nil)
        }
    }

    func restore() {
        // The handlers come off before anything else: with them gone, a
        // late SIGWINCH cannot interrupt restore's own writes (an EINTR
        // truncation would leave the terminal stuck in the alt screen)
        // nor touch the pipe descriptors torn down below, and a second
        // termination signal cannot hard-kill the process mid-restore
        // (the default dispositions return; by then the graceful tail
        // is finishing anyway). SIGWINCH's default is to ignore; the
        // termination trio's is to die — the state the process was
        // born with.
        signal(SIGTERM, SIG_DFL)
        signal(SIGHUP, SIG_DFL)
        signal(SIGINT, SIG_DFL)
        signal(SIGWINCH, SIG_DFL)
        if let orig = originalTermios {
            var copy = orig
            tcsetattr(STDIN_FILENO, TCSANOW, &copy)
        }
        // SGR reset on leaving: the alt screen's pen must not leak
        // into the shell — SGR is screen-global in the xterm family,
        // so exiting over a reverse-video selection (routine in mono)
        // or a bold run would restyle the prompt.
        writeRaw("\u{1b}[0m\u{1b}[?1004l\u{1b}[?2004l\u{1b}[?1049l\u{1b}[?25h")
        if resizePipeReadFd >= 0 { close(resizePipeReadFd); resizePipeReadFd = -1 }
        if resizePipeWriteFd >= 0 { close(resizePipeWriteFd); resizePipeWriteFd = -1 }
        if termPipeReadFd >= 0 { close(termPipeReadFd); termPipeReadFd = -1 }
        if termPipeWriteFd >= 0 { close(termPipeWriteFd); termPipeWriteFd = -1 }
    }

    private func updateSize() {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
        width = Int(ws.ws_col)
        height = Int(ws.ws_row)
    }

    func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let n = read(STDIN_FILENO, &byte, 1)
            if n == 1 { return byte }
            // Signals with handlers (SIGWINCH, the termination trio —
            // none use SA_RESTART) interrupt read() with EINTR — a
            // resize or a termination signal arriving during a
            // keystroke or a long bracketed-paste read must not
            // truncate the input; the termination pipe is checked by
            // the run loop between reads. Retry.
            if n == -1 && errno == EINTR { continue }
            return nil
        }
    }

    func bytesAvailable() -> Bool {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, 5)
        return ready > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }

    private func writeRaw(_ str: String) {
        writeBuffer([UInt8](str.utf8))
    }

    func writeBuffer(_ data: [UInt8]) {
        data.withUnsafeBufferPointer { ptr in
            var written = 0
            while written < data.count {
                let n = write(STDOUT_FILENO, ptr.baseAddress! + written, data.count - written)
                if n > 0 { written += n }
                // Every signal with a handler here (SIGWINCH and the
                // termination trio) interrupts write() with EINTR —
                // retry instead of dropping the tail of the frame
                // (readByte does the same for the read side).
                else if n == -1 && errno == EINTR { continue }
                else { break }
            }
        }
    }

    func moveCursor(row: Int, col: Int) {
        outputBuffer.append(contentsOf: "\u{1b}[\(row + 1);\(col + 1)H".utf8)
    }

    func setFG(_ color: Color) {
        outputBuffer.append(contentsOf: color.ansiFG.utf8)
    }

    func setBG(_ color: Color) {
        outputBuffer.append(contentsOf: color.ansiBG.utf8)
    }

    func setBold(_ on: Bool) {
        outputBuffer.append(contentsOf: (on ? "\u{1b}[1m" : "\u{1b}[22m").utf8)
    }

    func setDim(_ on: Bool) {
        outputBuffer.append(contentsOf: (on ? "\u{1b}[2m" : "\u{1b}[22m").utf8)
    }

    func setUnderline(_ on: Bool) {
        outputBuffer.append(contentsOf: (on ? "\u{1b}[4m" : "\u{1b}[24m").utf8)
    }

    func setReverse(_ on: Bool) {
        outputBuffer.append(contentsOf: (on ? "\u{1b}[7m" : "\u{1b}[27m").utf8)
    }

    func showCursor(_ show: Bool) {
        outputBuffer.append(contentsOf: (show ? "\u{1b}[?25h" : "\u{1b}[?25l").utf8)
    }

    func setCursorShape(_ shape: Int) {
        outputBuffer.append(contentsOf: "\u{1b}[\(shape) q".utf8)
    }

    func osc52Copy(_ text: String) {
        let data = Data(text.utf8)
        let encoded = data.base64EncodedString()
        writeRaw("\u{1b}]52;c;\(encoded)\u{07}")
    }

    func resetAttributes() {
        outputBuffer.append(contentsOf: "\u{1b}[0m".utf8)
    }

    /// Whole-string append — one reserve-and-copy of the UTF-8 bytes,
    /// where a writeChar loop would build a tiny String per character.
    /// For direct overlays and one-shot messages; the diff renderer
    /// keeps its per-glyph writeChar.
    func writeString(_ s: String) {
        outputBuffer.append(contentsOf: s.utf8)
    }

    /// Erases the full screen with the CURRENT background — callers
    /// that cannot trust the inherited pen reset the attributes first.
    func eraseScreen() {
        outputBuffer.append(contentsOf: "\u{1b}[2J".utf8)
    }

    func writeChar(_ c: Character) {
        outputBuffer.append(contentsOf: String(c).utf8)
    }

    func flush() {
        guard !outputBuffer.isEmpty else { return }
        writeBuffer(outputBuffer)
        outputBuffer.removeAll(keepingCapacity: true)
    }
}
