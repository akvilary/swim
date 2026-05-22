#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Darwin)
@preconcurrency import Darwin
#endif
import Foundation

private nonisolated(unsafe) var resizePipeWriteFd: Int32 = -1

private func sigwinchHandler(_: Int32) {
    var byte: UInt8 = 1
    _ = write(resizePipeWriteFd, &byte, 1)
}

final class Terminal {
    private var originalTermios: termios?
    private(set) var width: Int = 80
    private(set) var height: Int = 24
    private var outputBuffer = [UInt8]()

    private var resizePipeReadFd: Int32 = -1

    nonisolated(unsafe) static let shared = Terminal()
    private init() {}

    var hasResizeEvent: Bool {
        guard resizePipeReadFd >= 0 else { return false }
        var pfd = pollfd(fd: resizePipeReadFd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, 0)
        return ready > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }

    func consumeResizeEvent() {
        guard resizePipeReadFd >= 0 else { return }
        var buf: UInt8 = 0
        while read(resizePipeReadFd, &buf, 1) == 1 {}
        updateSize()
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

        updateSize()
        writeRaw("\u{1b}[?1049h")
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
    }

    func restore() {
        if let orig = originalTermios {
            var copy = orig
            tcsetattr(STDIN_FILENO, TCSANOW, &copy)
        }
        writeRaw("\u{1b}[?1049l\u{1b}[?25h")
        if resizePipeReadFd >= 0 { close(resizePipeReadFd); resizePipeReadFd = -1 }
        if resizePipeWriteFd >= 0 { close(resizePipeWriteFd); resizePipeWriteFd = -1 }
    }

    private func updateSize() {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
        width = Int(ws.ws_col)
        height = Int(ws.ws_row)
    }

    func readByte() -> UInt8? {
        var byte: UInt8 = 0
        let n = read(STDIN_FILENO, &byte, 1)
        return n == 1 ? byte : nil
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

    func writeChar(_ c: Character) {
        outputBuffer.append(contentsOf: String(c).utf8)
    }

    func flush() {
        guard !outputBuffer.isEmpty else { return }
        writeBuffer(outputBuffer)
        outputBuffer.removeAll(keepingCapacity: true)
    }
}
