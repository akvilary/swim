import Foundation

struct Shell {
    struct Result {
        let stdout: String
        let stderr: String
        var combined: String { stdout + stderr }
    }

    @discardableResult
    static func run(executable: String, args: [String] = [], workDir: String? = nil) -> Result {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let workDir { process.currentDirectoryURL = URL(fileURLWithPath: workDir) }
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return Result(stdout: "", stderr: "")
        }
    }

    @discardableResult
    static func git(_ args: [String], workDir: String? = nil) -> Result {
        run(executable: "/usr/bin/git", args: args, workDir: workDir)
    }
}
