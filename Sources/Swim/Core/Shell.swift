import Foundation
import SwimCore

struct Shell {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        var combined: String { stdout + stderr }
    }

    @discardableResult
    static func run(executable: String, args: [String] = [], workDir: String? = nil, stdin: String? = nil) -> Result {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let workDir { process.currentDirectoryURL = URL(fileURLWithPath: workDir) }
        process.standardOutput = outPipe
        process.standardError = errPipe
        // An explicit environment, not silent inheritance: the app
        // locale overrides the user's shell vars — a French desktop
        // must not leak into git's dates and messages (gettext's
        // LANGUAGE outranks even LC_ALL, hence both keys; AppLocale).
        process.environment = AppLocale.current.childEnvironment()
        let inPipe = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }
        do {
            try process.run()
            if let stdin, let inPipe {
                // PipeWriter, not FileHandle.write: a child that fails
                // fast (bad repo, lock conflict) before draining stdin
                // makes the write return EPIPE — fatal through
                // FileHandle.write (see PipeWriter).
                PipeWriter.writeAll(stdin.data(using: .utf8) ?? Data(),
                                    to: inPipe.fileHandleForWriting.fileDescriptor)
                inPipe.fileHandleForWriting.closeFile()
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )
        } catch {
            return Result(stdout: "", stderr: "", exitCode: -1)
        }
    }

    @discardableResult
    static func git(_ args: [String], workDir: String? = nil, stdin: String? = nil) -> Result {
        run(executable: "/usr/bin/git", args: args, workDir: workDir, stdin: stdin)
    }
}
