import Foundation
#if canImport(Glibc)
@preconcurrency import Glibc
#else
@preconcurrency import Darwin
#endif
import SwimCore

let version = "0.1.19"

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

// The terminal's color capability, process-wide: the theme is RGB,
// and a terminal without truecolor drops or garbles `38;2;...`.
// Degrade once, up front — truecolor → nearest xterm-256 index →
// nearest of the 16 system colors → none at all — so the palette
// survives screen/tmux sessions, 16-color consoles and NO_COLOR
// (no-color.org: present and non-empty — the value is meaningless,
// "0" and "false" included — the user's final word over any
// capability signal).
Color.outputSupport = ColorSupport.detect(
    colorterm: ProcessInfo.processInfo.environment["COLORTERM"],
    term: ProcessInfo.processInfo.environment["TERM"],
    noColor: ProcessInfo.processInfo.environment["NO_COLOR"]
)

// The explorer's icon tier, resolved against that capability: nf is
// the default (the installer ships a pinned Symbols Nerd Font Mono;
// terminals supply the glyphs from their main font or fallback),
// emoji degrades to plain when NO_COLOR forbids color.
IconSet.tier = IconTier.resolve(
    ProcessInfo.processInfo.environment["SWIM_ICONS"],
    support: Color.outputSupport
)

let filePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let app = Application(filePath: filePath)
app.run()
