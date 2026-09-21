#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Darwin)
@preconcurrency import Darwin
#endif
import Foundation
import Synchronization

/// The credential kind a pending askpass prompt asks for.
enum CredentialKind {
    case login
    case password

    /// Plate/center label: "login" / "password".
    var label: String { self == .login ? "login" : "password" }
    /// The same for narrow terminals: "login" / "pass".
    var narrowLabel: String { self == .login ? "login" : "pass" }

    /// Status-bar mode label replacing COMMAND while the credential is typed.
    var statusLabel: String { self == .login ? "LOGIN" : "PASSWORD" }
    var statusLabelNarrow: String { self == .login ? "LOGIN" : "PASS" }
}

/// A credential prompt surfaced by an `InteractiveShell` session.
struct CredentialPrompt: Sendable {
    let kind: CredentialKind
    let text: String
}

/// A subprocess with a live reader thread — the shape `git pull`/`push`
/// need when the remote asks for credentials. Prompting is routed
/// through a generated askpass helper (GIT_ASKPASS / SSH_ASKPASS):
///
///     #!/bin/sh
///     printf '%s\n' "$1" >&2                        # prompt -> stderr
///     IFS= read -r ans < "$SWIM_CRED_FIFO" || exit 1 # answer channel
///     printf '%s\n' "$ans"                          # -> git (stdout)
///
/// The prompt reaches swim through stderr (inherited by every helper
/// child), but the ANSWER cannot ride the session's stdin: for HTTP(S)
/// remotes git asks credentials inside the git-remote-https transport
/// helper, whose stdin is the protocol pipe to the parent git process —
/// an askpass inheriting it reads protocol junk, and a write to the
/// nobody-reads session stdin hits EPIPE. ssh's askpass gets /dev/null
/// instead of stdin for the same reason. The answer channel is therefore
/// a per-session FIFO named in `SWIM_CRED_FIFO`, opened O_RDWR eagerly:
/// the open never blocks, a written line buffers until the asking
/// helper consumes it, and writes cannot EPIPE while the session holds
/// the fd (it is a reader itself). The password never touches disk.
///
/// Concurrency: the session object is main-thread-confined — it owns
/// the Process and the FIFO descriptor with plain stored properties,
/// enforced by NOT being Sendable. The only cross-thread state is the
/// `Mutex<Mailbox>` (reader -> UI direction: prompt, output, done).
/// The reader thread captures exclusively Sendable values — the mutex
/// value, raw descriptors, the FIFO path — never the session itself,
/// so it always runs to completion no matter the session's lifetime.
/// Cancelling closes the FIFO (every blocked helper read fails, which
/// also releases the descriptors they inherited) and SIGTERMs the
/// process — the operation dies instead of hanging.
final class InteractiveShell {
    /// Reader -> UI state behind a `Mutex`; a separate Sendable object
    /// so the reader thread can hold it without touching the
    /// (non-Sendable, main-thread-confined) session itself.
    private final class Mailbox: Sendable {
        struct State: Sendable {
            var prompt: CredentialPrompt?
            var cancelled = false
            var done = false
            var stdout: [UInt8] = []
            var stderr: [UInt8] = []
        }

        let mutex = Mutex(State())
    }

    private let mailbox = Mailbox()

    // Main-thread-confined state.
    private let process = Process()
    private var fifoFd: Int32 = -1
    private var started = false
    private var ranSuccessfully = false

    var isFinished: Bool { mailbox.mutex.withLock { $0.done } }

    var wasCancelled: Bool { mailbox.mutex.withLock { $0.cancelled } }

    var isAwaitingInput: Bool { mailbox.mutex.withLock { $0.prompt != nil } }

    /// The pending prompt, if the process is blocked on one.
    func currentPrompt() -> CredentialPrompt? {
        mailbox.mutex.withLock { $0.prompt }
    }

    /// Submits the typed credential — one line into the FIFO; the
    /// asking helper consumes it. EINTR-safe partial-write loop; EPIPE
    /// is impossible while the session holds the O_RDWR descriptor.
    func answer(_ text: String) {
        let wasPending = mailbox.mutex.withLock { state -> Bool in
            guard state.prompt != nil else { return false }
            state.prompt = nil
            return true
        }
        guard wasPending, fifoFd >= 0 else { return }
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBufferPointer { ptr in
            var offset = 0
            while offset < bytes.count {
                let n = write(fifoFd, ptr.baseAddress! + offset, bytes.count - offset)
                if n > 0 {
                    offset += n
                } else if errno != EINTR {
                    break
                }
            }
        }
    }

    /// Aborts the operation: closes the FIFO (every helper child blocked
    /// on its read fails — releasing the descriptors they inherited) and
    /// terminates the process itself.
    func cancel() {
        mailbox.mutex.withLock { state in
            state.cancelled = true
            state.prompt = nil
        }
        if fifoFd >= 0 {
            close(fifoFd)
            fifoFd = -1
        }
        if ranSuccessfully, process.isRunning {
            process.terminate()
        }
    }

    /// One-shot final result, `BackgroundTask.consume` semantics. The
    /// reader signals completion after both pipes EOF; the exit status
    /// is reaped here, on the owning thread, through the Process (the
    /// reader must not touch it — non-Sendable — and its internal
    /// helper already owns the waitpid; by now the process is gone and
    /// this returns immediately).
    func consumeResult() -> Shell.Result? {
        guard mailbox.mutex.withLock({ $0.done }) else { return nil }
        if ranSuccessfully { process.waitUntilExit() }
        return mailbox.mutex.withLock { state -> Shell.Result? in
            guard state.done else { return nil }
            state.done = false
            let result = Shell.Result(
                stdout: String(decoding: state.stdout, as: UTF8.self),
                stderr: String(decoding: state.stderr, as: UTF8.self),
                exitCode: ranSuccessfully ? process.terminationStatus : -1
            )
            state.stdout = []
            state.stderr = []
            return result
        }
    }

    func start(executable: String, args: [String], workDir: String?) {
        guard !started else { return }
        started = true

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let workDir { process.currentDirectoryURL = URL(fileURLWithPath: workDir) }
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Not the answer channel (see class docs) — a closed pipe so the
        // child can never swallow swim's tty stdin instead.
        process.standardInput = Pipe()
        var env = ProcessInfo.processInfo.environment
        var fifoPath: String? = nil
        if let askpass = Self.askpassHelperPath {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("swim-cred-\(getpid())-\(UUID().uuidString).fifo").path
            if mkfifo(path, 0o600) == 0 {
                let fd = open(path, O_RDWR)
                if fd >= 0 {
                    fifoFd = fd
                    fifoPath = path
                    env["SWIM_CRED_FIFO"] = path
                }
            }
            env["GIT_ASKPASS"] = askpass
            env["SSH_ASKPASS"] = askpass
            // OpenSSH >= 8.4: use askpass even though a tty is attached
            // (ours is busy being a TUI). Older ssh ignores the variable.
            env["SSH_ASKPASS_REQUIRE"] = "force"
        }
        process.environment = env

        do {
            try process.run()
        } catch {
            ranSuccessfully = false
            mailbox.mutex.withLock { state in
                state.stdout = []
                state.stderr = Array(error.localizedDescription.utf8)
                state.done = true
            }
            return
        }
        ranSuccessfully = true

        let outFd = outPipe.fileHandleForReading.fileDescriptor
        let errFd = errPipe.fileHandleForReading.fileDescriptor
        Self.setNonBlocking(outFd)
        Self.setNonBlocking(errFd)
        // The closure captures Sendable locals only — not self, no vars.
        let box = mailbox
        let fifoPathToSend = fifoPath
        Thread {
            Self.readAndCollect(box: box, outFd: outFd, errFd: errFd, fifoPath: fifoPathToSend)
        }.start()
    }

    /// Drains both pipes until EOF, arming prompts seen in stderr, then
    /// publishes the output. Non-blocking reads on both descriptors in
    /// one thread avoid the classic two-pipe deadlock (a child blocked
    /// writing the pipe nobody reads). Sendable-only parameters: the
    /// thread must not capture the session (non-Sendable) — the loop
    /// then cannot be cut short by the session's deallocation.
    private static func readAndCollect(box: Mailbox, outFd: Int32, errFd: Int32, fifoPath: String?) {
        var outBuf = [UInt8]()
        var errBuf = [UInt8]()
        var outEOF = false
        var errEOF = false
        var scanned = 0

        while !(outEOF && errEOF) {
            var progressed = false
            if !outEOF {
                switch readChunk(fd: outFd, into: &outBuf) {
                case .bytes: progressed = true
                case .eof: outEOF = true; progressed = true
                case .again: break
                }
            }
            if !errEOF {
                switch readChunk(fd: errFd, into: &errBuf) {
                case .bytes: progressed = true
                case .eof: errEOF = true; progressed = true
                case .again: break
                }
            }
            if scanned < errBuf.count {
                let before = scanned
                let (found, newScanned) = scanPrompt(in: errBuf, from: scanned)
                scanned = newScanned
                if scanned > before { progressed = true }
                if let found {
                    box.mutex.withLock { state in
                        if state.prompt == nil { state.prompt = found }
                    }
                }
            }
            if !progressed { usleep(10000) }
        }

        if let fifoPath { unlink(fifoPath) }
        box.mutex.withLock { state in
            state.stdout = outBuf
            state.stderr = errBuf
            state.done = true
        }
    }

    // MARK: - Reader primitives

    private enum ChunkResult { case bytes, eof, again }

    /// One non-blocking read; `.again` covers EAGAIN (pipe empty) and
    /// EINTR alike — the loop simply retries on the next pass.
    private static func readChunk(fd: Int32, into buf: inout [UInt8]) -> ChunkResult {
        var tmp = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &tmp, tmp.count)
        if n > 0 {
            buf.append(contentsOf: tmp[0..<n])
            return .bytes
        }
        return n == 0 ? .eof : .again
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    // MARK: - Prompt detection

    /// Scans complete stderr lines from `from` for an askpass prompt,
    /// stopping at the first match; returns the advanced scan offset (a
    /// line is never matched twice, an incomplete tail waits for more
    /// bytes).
    private static func scanPrompt(in errBuf: [UInt8], from scanned: Int) -> (CredentialPrompt?, Int) {
        var start = scanned
        while let nl = errBuf[start...].firstIndex(of: 0x0A) {
            let line = String(decoding: errBuf[start..<nl], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            start = nl + 1
            if let prompt = classifyPromptLine(line) {
                return (prompt, start)
            }
        }
        return (nil, start)
    }

    /// git askpass prompts: `Username for 'https://…': ` /
    /// `Password for 'https://…': `; ssh (SSH_ASKPASS):
    /// `user@host's password: ` / `Enter passphrase for key '…': `.
    /// Matched by stable ASCII markers. Prefixed lines are excluded:
    /// git's own `fatal: could not read Username for …` (a failed auth
    /// must not rearm a prompt) and the sideband prefixes (`remote:`,
    /// `warning:`, `hint:`) — a remote can print spoofed prompt text
    /// through the transfer output, and only a real askpass echo arrives
    /// unprefixed.
    private static func classifyPromptLine(_ line: String) -> CredentialPrompt? {
        let excludedPrefixes = ["fatal:", "error:", "remote:", "warning:", "hint:"]
        let isExcluded = excludedPrefixes.contains { line.hasPrefix($0) }
        guard !line.isEmpty, !isExcluded else { return nil }
        if line.hasPrefix("Username for ") { return CredentialPrompt(kind: .login, text: line) }
        if line.hasPrefix("Password for ") { return CredentialPrompt(kind: .password, text: line) }
        if line.hasSuffix("password:") { return CredentialPrompt(kind: .password, text: line) }
        if line.hasPrefix("Enter passphrase") { return CredentialPrompt(kind: .password, text: line) }
        return nil
    }

    // MARK: - Askpass helper

    /// One-time askpass helper (see class docs), per-user in the system
    /// temp dir. Nil if the filesystem refused — credential routing then
    /// degrades to git's non-interactive default.
    private static let askpassHelperPath: String? = {
        let script = "#!/bin/sh\nprintf '%s\\n' \"$1\" >&2\n[ -n \"$SWIM_CRED_FIFO\" ] || exit 1\nIFS= read -r ans < \"$SWIM_CRED_FIFO\" || exit 1\nprintf '%s\\n' \"$ans\"\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swim-askpass-\(getuid()).sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            guard chmod(url.path, 0o700) == 0 else { return nil }
            return url.path
        } catch {
            return nil
        }
    }()
}
