import Foundation

class LSPClient {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var nextId: Int = 1
    private var pendingRequests: [Int: (Data) -> Void] = [:]
    private var tokenTypes: [String] = []
    private var tokenModifiers: [String] = []
    private var initialized = false
    private var buffer = Data()
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "lsp.client")
    private var alive = false

    var onSemanticTokens: (([SemanticToken]) -> Void)?
    var onDiagnostics: ((String, [Any]) -> Void)?

    var pendingTokens: [SemanticToken]?
    var hasPendingTokens: Bool { pendingTokens != nil }

    func start(executable: String, arguments: [String] = [], rootUri: String?) {
        guard FileManager.default.fileExists(atPath: executable) else { return }
        guard FileManager.default.isExecutableFile(atPath: executable) else { return }

        let process = Process()
        inputPipe = Pipe()
        outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        guard let outputPipe = outputPipe else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: outputPipe.fileHandleForReading.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            let data = outputPipe.fileHandleForReading.availableData
            if data.isEmpty { return }
            self?.handleData(data)
        }
        source.resume()
        readSource = source

        do {
            try process.run()
            self.process = process
            self.alive = true
            sendInitialize(rootUri: rootUri)
        } catch {
            self.process = nil
        }
    }

    func stop() {
        alive = false
        readSource?.cancel()
        if let p = process, p.isRunning {
            p.terminate()
        }
    }

    private func sendInitialize(rootUri: String?) {
        let capabilities: [String: Any] = [
            "textDocument": [
                "semanticTokens": [
                    "full": true,
                    "delta": true,
                    "tokenTypes": [] as [String],
                    "tokenModifiers": [] as [String],
                    "formats": ["relative"] as [String]
                ]
            ]
        ]

        var params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "capabilities": capabilities
        ]
        if let uri = rootUri {
            params["rootUri"] = uri
        }

        sendRequest(method: "initialize", params: params) { [weak self] data in
            self?.handleInitializeResponse(data)
        }
    }

    private func handleInitializeResponse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else { return }

        if let capabilities = result["capabilities"] as? [String: Any],
           let semTokensProvider = capabilities["semanticTokensProvider"] as? [String: Any],
           let legend = semTokensProvider["legend"] as? [String: Any] {
            tokenTypes = legend["tokenTypes"] as? [String] ?? []
            tokenModifiers = legend["tokenModifiers"] as? [String] ?? []
        }
        initialized = true

        sendNotification(method: "initialized", params: ["capabilities": [:] as [String: Any]])
    }

    func openDocument(uri: String, languageId: String, text: String) {
        guard initialized else { return }
        let params: [String: Any] = [
            "textDocument": [
                "uri": uri,
                "languageId": languageId,
                "version": 0,
                "text": text
            ] as [String: Any]
        ]
        sendNotification(method: "textDocument/didOpen", params: params)
        requestSemanticTokens(uri: uri)
    }

    func changeDocument(uri: String, version: Int, text: String) {
        guard initialized else { return }
        let params: [String: Any] = [
            "textDocument": [
                "uri": uri,
                "version": version
            ] as [String: Any],
            "contentChanges": [
                ["text": text]
            ] as [[String: Any]]
        ]
        sendNotification(method: "textDocument/didChange", params: params)
    }

    func requestSemanticTokens(uri: String) {
        guard initialized else { return }
        let params: [String: Any] = [
            "textDocument": ["uri": uri] as [String: Any]
        ]
        sendRequest(method: "textDocument/semanticTokens/full", params: params) { [weak self] data in
            self?.handleSemanticTokensResponse(data)
        }
    }

    private func handleSemanticTokensResponse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let tokenData = result["data"] as? [Int] else { return }

        var tokens = [SemanticToken]()
        var line = 0
        var char = 0
        var i = 0

        while i + 4 < tokenData.count {
            let deltaLine = tokenData[i]
            let deltaStart = tokenData[i + 1]
            let length = tokenData[i + 2]
            let tokenType = tokenData[i + 3]
            let tokenMod = tokenData[i + 4]

            if deltaLine > 0 {
                line += deltaLine
                char = deltaStart
            } else {
                char += deltaStart
            }

            let typeName: String
            if tokenType < tokenTypes.count {
                typeName = tokenTypes[tokenType]
            } else {
                typeName = "unknown"
            }

            tokens.append(SemanticToken(
                line: line,
                startChar: char,
                length: length,
                type: typeName,
                modifiers: tokenMod
            ))

            i += 5
        }

        pendingTokens = tokens
    }

    private func sendRequest(method: String, params: [String: Any], callback: @escaping (Data) -> Void) {
        let id = nextId
        nextId += 1
        pendingRequests[id] = callback

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        sendMessage(message)
    }

    private func sendNotification(method: String, params: [String: Any]) {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        sendMessage(message)
    }

    private func sendMessage(_ message: [String: Any]) {
        guard alive, let inputPipe = inputPipe,
              let data = try? JSONSerialization.data(withJSONObject: message) else { return }

        let header = "Content-Length: \(data.count)\r\n\r\n"
        let headerData = header.data(using: .ascii)!

        queue.async { [weak self] in
            guard let self = self, self.alive else { return }
            inputPipe.fileHandleForWriting.write(headerData)
            inputPipe.fileHandleForWriting.write(data)
        }
    }

    private func handleData(_ data: Data) {
        buffer.append(data)
        parseMessages()
    }

    private func parseMessages() {
        while true {
            let separator = Data("\r\n\r\n".utf8)
            guard let headerEnd = buffer.range(of: separator) else { break }

            let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
            guard let header = String(data: headerData, encoding: .ascii) else {
                buffer.removeSubrange(0..<min(headerEnd.upperBound, buffer.count))
                continue
            }

            guard let match = header.range(of: "Content-Length: ") else {
                buffer.removeSubrange(0..<min(headerEnd.upperBound, buffer.count))
                continue
            }

            let rest = header[match.upperBound...]
            let parts = rest.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let lengthStr = parts.first, let length = Int(lengthStr) else {
                buffer.removeSubrange(0..<min(headerEnd.upperBound, buffer.count))
                continue
            }

            let bodyStart = headerEnd.upperBound
            let bodyEnd = bodyStart + length

            guard buffer.count >= bodyEnd else { break }

            let bodyData = buffer.subdata(in: bodyStart..<bodyEnd)
            buffer.removeSubrange(0..<bodyEnd)

            handleMessage(bodyData)
        }
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = json["id"] as? Int {
            if let callback = pendingRequests.removeValue(forKey: id) {
                callback(data)
            }
        }

        if let method = json["method"] as? String, let params = json["params"] as? [String: Any] {
            switch method {
            case "textDocument/publishDiagnostics":
                if let uri = params["uri"] as? String,
                   let diagnostics = params["diagnostics"] as? [Any] {
                    onDiagnostics?(uri, diagnostics)
                }
            default:
                break
            }
        }
    }
}
