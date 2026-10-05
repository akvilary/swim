import Foundation
#if canImport(Glibc)
@preconcurrency import Glibc
#else
@preconcurrency import Darwin
#endif

let version = "0.0.59"

if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
    print("swim \(version)")
    exit(0)
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("swim - Vim-like terminal editor")
    print("")
    print("Usage: swim [file]")
    print("")
    print("Options:")
    print("  -v, --version   Print version")
    print("  -h, --help      Print help")
    exit(0)
}

// Pipe-write policy, process-wide: a writer to a child's stdin must see
// an error RETURN (EPIPE), never the SIGPIPE signal — a language server
// or git dying mid-frame would otherwise kill the editor by default
// disposition (probed: exit 141 even through a raw write(2) loop). Nothing
// in Dispatch, Foundation's Process or Pipe installs this ignore on Linux
// (probed: bit stays clear after all three) — when swim appeared to have
// it, the disposition was inherited from the parent shell. Own it here,
// before any pipe exists. Children inherit the ignore: pipelines in the
// embedded terminal see EPIPE returns instead of signal death, the same
// trade every editor on an SIGPIPE-ignoring runtime makes. The fatal
// counterpart of this policy lives in PipeWriter: FileHandle.write
// fatal-errors on any write error, so raw write(2) is the only usable
// shape.
signal(SIGPIPE, SIG_IGN)

let filePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let app = Application(filePath: filePath)
app.run()
