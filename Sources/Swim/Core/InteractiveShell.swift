#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Darwin)
@preconcurrency import Darwin
#endif
import Foundation

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
struct CredentialPrompt {
    let kind: CredentialKind
    let text: String
}

/// A subprocess with an open stdin and a live reader thread — the shape
/// `git pull`/`push` need when the remote asks for credentials. Prompting
/// is routed through a generated askpass helper (GIT_ASKPASS / SSH_ASKPASS):
///
///     #!/bin/sh
///     printf '%s\n' "$1" >&2      # the prompt — detected in stderr
///     IFS= read -r ans || exit 1  # blocks on the session's stdin pipe
///     printf '%s\n' "$ans"        # the answer git reads from stdout
///
/// Every byte stays in pipes: the password never touches disk, and the
/// raw-mode terminal stays swim's (git's own /dev/tty prompting never
/// engages because askpass takes precedence). The reader thread watches
/// both pipes non-blocking, arms a `CredentialPrompt` when it sees an
/// askpass line, and the UI answers through `answer(_:)`. Cancelling
/// closes stdin (the helper's read fails) and SIGTERMs the process —
/// the operation dies instead of hanging with nobody to answer it.
final class InteractiveShell: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdinPipe: Pipe?
    private var prompt: CredentialPrompt?
    private var cancelled = false
    private var done = false
    private var resultValue: Shell.Result?

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    var isAwaitingInput: Bool {
        lock.lock(); defer { lock.unlock() }
        return prompt != nil
    }

    /// The pending prompt, if the process is blocked on one.
    func currentPrompt() -> CredentialPrompt? {
        lock.lock(); defer { lock.unlock() }
        return prompt
    }

    /// Submits the typed credential — one line into the process stdin.
    func answer(_ text: String) {
        lock.lock()
        let pending = prompt
        prompt = nil
        let pipe = stdinPipe
        lock.unlock()
        guard pending != nil, let pipe else { return }
        try? pipe.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8))
    }

    /// Aborts the operation: closes stdin (the askpass read fails, so
    /// helper children holding inherited descriptors exit too) and
    /// terminates the process itself.
    func cancel() {
        lock.lock()
        cancelled = true
        prompt = nil
        let pipe = stdinPipe
        stdinPipe = nil
        let proc = process
        lock.unlock()
        // Close through the FileHandle itself, not a raw close(fd): the
        // Pipe object stays alive (held by process.standardInput) until
        // the session is discarded, and its deinit closes its fd again —
        // a raw close would free the fd number for reuse, and the later
        // deinit could then close an unrelated descriptor (e.g. the next
        // session's pipe). FileHandle.close() marks the object closed.
        if let pipe { try? pipe.fileHandleForWriting.close() }
        if proc?.isRunning == true { proc?.terminate() }
    }

    /// One-shot final result, `BackgroundTask.consume` semantics.
    func consumeResult() -> Shell.Result? {
        lock.lock(); defer { lock.unlock() }
        guard done else { return nil }
        done = false
        let result = resultValue
        resultValue = nil
        return result
    }

    func start(executable: String, args: [String], workDir: String?) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let workDir { process.currentDirectoryURL = URL(fileURLWithPath: workDir) }
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        var env = ProcessInfo.processInfo.environment
        if let askpass = Self.askpassHelperPath {
            env["GIT_ASKPASS"] = askpass
            env["SSH_ASKPASS"] = askpass
            // OpenSSH >= 8.4: use askpass even though a tty is attached
            // (ours is busy being a TUI). Older ssh ignores the variable.
            env["SSH_ASKPASS_REQUIRE"] = "force"
        }
        process.environment = env

        lock.lock()
        self.process = process
        self.stdinPipe = inPipe
        self.prompt = nil
        self.cancelled = false
        self.done = false
        self.resultValue = nil
        lock.unlock()

        do {
            try process.run()
        } catch {
            lock.lock()
            resultValue = Shell.Result(stdout: "", stderr: error.localizedDescription, exitCode: -1)
            done = true
            lock.unlock()
            return
        }

        let outFd = outPipe.fileHandleForReading.fileDescriptor
        let errFd = errPipe.fileHandleForReading.fileDescriptor
        Self.setNonBlocking(outFd)
        Self.setNonBlocking(errFd)
        Thread { [weak self] in
            self?.readLoop(outFd: outFd, errFd: errFd)
        }.start()
    }

    /// Drains both pipes until EOF, arming prompts seen in stderr; only
    /// then waits for the process and computes the result. Non-blocking
    /// reads on both descriptors in one thread avoid the classic
    /// two-pipe deadlock (a child blocked writing the pipe nobody reads).
    private func readLoop(outFd: Int32, errFd: Int32) {
        guard let process else { return }
        var outBuf = [UInt8]()
        var errBuf = [UInt8]()
        var outEOF = false
        var errEOF = false
        var scanned = 0

        while !(outEOF && errEOF) {
            var progressed = false
            if !outEOF {
                switch Self.readChunk(fd: outFd, into: &outBuf) {
                case .bytes: progressed = true
                case .eof: outEOF = true; progressed = true
                case .again: break
                }
            }
            if !errEOF {
                switch Self.readChunk(fd: errFd, into: &errBuf) {
                case .bytes: progressed = true
                case .eof: errEOF = true; progressed = true
                case .again: break
                }
            }
            if scanned < errBuf.count {
                let before = scanned
                let (found, newScanned) = Self.scanPrompt(in: errBuf, from: scanned)
                scanned = newScanned
                if scanned > before { progressed = true }
                if let found {
                    lock.lock()
                    if prompt == nil { prompt = found }
                    lock.unlock()
                }
            }
            if !progressed { usleep(10000) }
        }

        process.waitUntilExit()
        let result = Shell.Result(
            stdout: String(decoding: outBuf, as: UTF8.self),
            stderr: String(decoding: errBuf, as: UTF8.self),
            exitCode: process.terminationStatus
        )
        lock.lock()
        resultValue = result
        done = true
        lock.unlock()
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
        let script = "#!/bin/sh\nprintf '%s\\n' \"$1\" >&2\nIFS= read -r ans || exit 1\nprintf '%s\\n' \"$ans\"\n"
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
