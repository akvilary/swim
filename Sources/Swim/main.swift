import Foundation

let version = "0.0.1"

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

let filePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let app = Application(filePath: filePath)
app.run()
