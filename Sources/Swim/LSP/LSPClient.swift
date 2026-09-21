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

    private let tokensLock = NSLock()
    private var _pendingTokens: (uri: String, tokens: [SemanticToken])?
    var pendingTokens: (uri: String, tokens: [SemanticToken])? {
        get {
            tokensLock.lock()
            defer { tokensLock.unlock() }
            return _pendingTokens
        }
        set {
            tokensLock.lock()
            _pendingTokens = newValue
            tokensLock.unlock()
        }
    }
    var hasPendingTokens: Bool { pendingTokens != nil }

    func takePendingTokens() -> (uri: String, tokens: [SemanticToken])? {
        tokensLock.lock()
        defer { tokensLock.unlock() }
        let pending = _pendingTokens
        _pendingTokens = nil
        return pending
    }

    private let definitionLock = NSLock()
    private var _pendingDefinition: LSPDefinitionResult?
    var pendingDefinition: LSPDefinitionResult? {
        get {
            definitionLock.lock()
            defer { definitionLock.unlock() }
            return _pendingDefinition
        }
        set {
            definitionLock.lock()
            _pendingDefinition = newValue
            definitionLock.unlock()
        }
    }
    var hasPendingDefinition: Bool { pendingDefinition != nil }

    func takePendingDefinition() -> LSPDefinitionResult? {
        definitionLock.lock()
        defer { definitionLock.unlock() }
        let pending = _pendingDefinition
        _pendingDefinition = nil
        return pending
    }

    var isReady: Bool { initialized && alive }
    var isAlive: Bool { alive }

    private var pendingDidOpen: (uri: String, languageId: String, text: String)?

    func start(executable: String, arguments: [String] = [], rootUri: String?, initializationOptions: [String: Any]? = nil) {
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
        nonisolated(unsafe) let weakSelf = self
        source.setEventHandler { [weak weakSelf] in
            let data = outputPipe.fileHandleForReading.availableData
            if data.isEmpty { return }
            weakSelf?.handleData(data)
        }
        source.resume()
        readSource = source

        do {
            try process.run()
            self.process = process
            self.alive = true
            sendInitialize(rootUri: rootUri, initializationOptions: initializationOptions)
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

    private func sendInitialize(rootUri: String?, initializationOptions: [String: Any]?) {
        // LSP 3.16: client semanticTokens capabilities require the
        // `requests` object; `full`/`delta` live inside it. Putting them at
        // the top level (server-provider shape) makes sourcekit-lsp 6.2+
        // reject initialize with "missing expected parameter: requests".
        let capabilities: [String: Any] = [
            "textDocument": [
                "semanticTokens": [
                    "requests": [
                        "full": ["delta": true]
                    ] as [String: Any],
                    "tokenTypes": [] as [String],
                    "tokenModifiers": [] as [String],
                    "formats": ["relative"] as [String]
                ] as [String: Any]
            ] as [String: Any]
        ]

        var params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "capabilities": capabilities
        ]
        if let uri = rootUri {
            params["rootUri"] = uri
            // pyright ignores rootUri and requires workspaceFolders; without
            // them it assumes "/" as the workspace root and analyzes nothing.
            let name = (uri as NSString).lastPathComponent
            params["workspaceFolders"] = [["uri": uri, "name": name.isEmpty ? "workspace" : name]]
        }
        if let options = initializationOptions {
            params["initializationOptions"] = options
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

        if let pending = pendingDidOpen {
            pendingDidOpen = nil
            openDocument(uri: pending.uri, languageId: pending.languageId, text: pending.text)
        }
    }

    func openDocument(uri: String, languageId: String, text: String) {
        guard initialized else {
            pendingDidOpen = (uri: uri, languageId: languageId, text: text)
            return
        }
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

    func changeDocument(uri: String, version: Int, changes: [LSPTextChange]) {
        guard initialized else { return }
        let contentChanges: [[String: Any]] = changes.map { change in
            [
                "range": [
                    "start": ["line": change.startLine, "character": change.startChar] as [String: Any],
                    "end": ["line": change.endLine, "character": change.endChar]
                ] as [String: Any],
                "text": change.text
            ] as [String: Any]
        }
        let params: [String: Any] = [
            "textDocument": [
                "uri": uri,
                "version": version
            ] as [String: Any],
            "contentChanges": contentChanges
        ]
        sendNotification(method: "textDocument/didChange", params: params)
    }

    /// Full-sync didChange after an external rewrite (e.g. a git discard
    /// from the panel reloaded the buffer): a contentChange without a
    /// range replaces the whole document, per the LSP spec. Cached
    /// semantic tokens are stale — re-request them.
    func reloadDocument(uri: String, version: Int, text: String) {
        guard initialized else { return }
        let params: [String: Any] = [
            "textDocument": [
                "uri": uri,
                "version": version
            ] as [String: Any],
            "contentChanges": [["text": text] as [String: Any]]
        ]
        sendNotification(method: "textDocument/didChange", params: params)
        requestSemanticTokens(uri: uri)
    }

    func requestSemanticTokens(uri: String) {
        guard initialized else { return }
        let params: [String: Any] = [
            "textDocument": ["uri": uri] as [String: Any]
        ]
        sendRequest(method: "textDocument/semanticTokens/full", params: params) { [weak self] data in
            self?.handleSemanticTokensResponse(data, uri: uri)
        }
    }

    func closeDocument(uri: String) {
        guard initialized else { return }
        let params: [String: Any] = [
            "textDocument": ["uri": uri] as [String: Any]
        ]
        sendNotification(method: "textDocument/didClose", params: params)
    }

    func requestDefinition(uri: String, line: Int, character: Int) {
        guard initialized else { return }
        let params: [String: Any] = [
            "textDocument": ["uri": uri] as [String: Any],
            "position": ["line": line, "character": character] as [String: Any]
        ]
        sendRequest(method: "textDocument/definition", params: params) { [weak self] data in
            self?.handleDefinitionResponse(data)
        }
    }

    /// Handles Location | Location[] | LocationLink[] | null result shapes.
    private func handleDefinitionResponse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            pendingDefinition = .notFound
            return
        }
        guard let result = json["result"], !(result is NSNull) else {
            pendingDefinition = .notFound
            return
        }
        var location = result as? [String: Any]
        if location == nil, let array = result as? [Any] {
            location = array.first as? [String: Any]
        }
        guard let loc = location,
              let uri = (loc["uri"] as? String) ?? (loc["targetUri"] as? String),
              let range = (loc["range"] as? [String: Any])
                  ?? (loc["targetSelectionRange"] as? [String: Any])
                  ?? (loc["targetRange"] as? [String: Any]),
              let start = range["start"] as? [String: Any],
              let line = start["line"] as? Int,
              let character = start["character"] as? Int else {
            pendingDefinition = .notFound
            return
        }
        pendingDefinition = .found(LSPDefinition(uri: uri, line: line, charUtf16: character))
    }

    private func handleSemanticTokensResponse(_ data: Data, uri: String) {
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

        pendingTokens = (uri: uri, tokens: tokens)
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
        let pipe = inputPipe

        queue.async {
            pipe.fileHandleForWriting.write(headerData)
            pipe.fileHandleForWriting.write(data)
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
