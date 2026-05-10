import Foundation

let filePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let app = Application()
app.run(filePath: filePath)
