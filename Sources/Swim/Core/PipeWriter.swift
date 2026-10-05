import Foundation
#if canImport(Glibc)
@preconcurrency import Glibc
#else
@preconcurrency import Darwin
#endif

/// Whole-buffer write(2) for pipes to child processes — the one writer
/// shape swim uses wherever stdin is fed (LSPClient frames, Shell.run
/// stdin, InteractiveShell's FIFO). FileHandle.write is not usable here:
/// corelibs wraps the syscall in `try!`, so ANY error return — EPIPE
/// first among them, when the child died between the caller's liveness
/// check and the write — fatal-errors the whole editor (probed:
/// Foundation/FileHandle.swift:709, 'try!' expression unexpectedly raised
/// ... Code=32 "Broken pipe", on the main thread and a dispatch queue
/// alike). The loop retries EINTR and stops quietly on any other error:
/// liveness truth belongs to the caller's state machine (the alive flag,
/// the reader's EOF branch, the child's exit), not to the writer — a
/// partial write before the error is simply what made it out. SIGPIPE is
/// ignored process-wide in main.swift, so the error arrives as a return
/// value, not a signal. Children inherit that ignore: pipelines in the
/// embedded terminal see EPIPE returns instead of signal death — the
/// same trade every editor built on an SIGPIPE-ignoring runtime makes.
enum PipeWriter {
    /// Writes as much of `data` as the pipe takes. True when the whole
    /// buffer was delivered; false when a hard error stopped the loop
    /// (EPIPE, EIO, ...) — LSPClient turns that into a dead client, the
    /// one-shot callers (Shell, InteractiveShell) own their own liveness
    /// and ignore it.
    @discardableResult
    static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, UnsafeMutableRawPointer(mutating: base + offset), raw.count - offset)
                if n > 0 {
                    offset += n
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
    }
}
