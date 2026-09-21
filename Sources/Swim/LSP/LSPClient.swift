import Foundation
import SwimCore

/// One language-server process over stdio JSON-RPC.
///
/// Thread model (single-owner confinement):
/// - The serial `queue` owns ALL protocol state: the byte buffer, the
///   pending-response table, the semantic-token legend, `initialized`,
///   the queued pre-init didOpen and the per-document version map.
///   Frames leave as whole `Data` writes on that queue only — FIFO of
///   `Content-Length` frames is guaranteed in both directions.
/// - The main loop never touches that state; it drains three `Locked`
///   mailboxes (tokens, definition, diagnostics) written by the reader
///   and reads `lastSentVersion` from a `Locked` mirror.
/// - Message dictionaries are built and serialized on the calling
///   thread, so only `Data`/`String`/value types cross into `queue`
///   closures; a response can only be parsed after the same serial
///   block that registers its callback and writes its request.
/// - `@unchecked Sendable` is the honest annotation for this discipline:
///   the reference is deliberately shared across threads, the mutable
///   state is not (queue-confined or behind `Locked`). `alive` is the
///   one unlocked cross-thread flag — a word-sized Bool, tear-free on
///   every supported platform.
final class LSPClient: @unchecked Sendable {
    private var process: Process?
    private var inputPipe: Pipe?
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "lsp.client")
    private var alive = false

    // --- Queue-confined protocol state ---
    private var pendingRequests: [Int: (Data) -> Void] = [:]
    private var buffer = Data()
    private var tokenTypes: [String] = []
    private var tokenModifiers: [String] = []
    private var initialized = false
    /// didOpens requested before initialize completed, replayed after.
    /// An array with per-URI dedup (latest text wins): opening a second
    /// file during startup must not swallow the first one's session.
    private var pendingDidOpens: [(uri: String, languageId: String, text: String)] = []
    /// Last document version SENT per URI. Versions are per-document and
    /// only increase, across re-opens — a tab closed and re-opened never
    /// restarts at 0, so a late publishDiagnostics from its previous
    /// incarnation cannot pass the staleness guard.
    private var documentVersions: [String: Int] = [:]

    // --- Cross-thread cells ---
    private let nextIdCell = Locked<Int>(1)
    private let tokensMailbox = Locked<(uri: String, tokens: [SemanticToken])?>(nil)
    private let definitionMailbox = Locked<LSPDefinitionResult?>(nil)
    /// Latest publishDiagnostics per URI. Per-URI coalescing keeps the
    /// newest batch for each file; a burst of publishes for several open
    /// tabs is never dropped.
    private let diagnosticsMailbox = Locked<[String: (version: Int?, diagnostics: [LSPDiagnostic])]>([:])
    /// Main-readable copy of documentVersions for staleness guards.
    private let sentVersions = Locked<[String: Int]>([:])

    init() {}

    func takePendingTokens() -> (uri: String, tokens: [SemanticToken])? {
        tokensMailbox.withLock { slot in
            let pending = slot
            slot = nil
            return pending
        }
    }

    func takePendingDefinition() -> LSPDefinitionResult? {
        definitionMailbox.withLock { slot in
            let pending = slot
            slot = nil
            return pending
        }
    }

    func takePendingDiagnostics() -> [(uri: String, version: Int?, diagnostics: [LSPDiagnostic])] {
        diagnosticsMailbox.withLock { boxes in
            let all = boxes
            boxes.removeAll()
            return all.map { (uri: $0.key, version: $0.value.version, diagnostics: $0.value.diagnostics) }
        }
    }

    /// The last didChange/didOpen version sent for the document — a
    /// publishDiagnostics with a smaller version describes content that
    /// was already superseded and must be dropped.
    func lastSentVersion(for uri: String) -> Int? {
        sentVersions.withLock { $0[uri] }
    }

    var isReady: Bool { initialized && alive }
    var isAlive: Bool { alive }

    func start(executable: String, arguments: [String] = [], rootUri: String?, initializationOptions: [String: Any]? = nil) {
        guard FileManager.default.fileExists(atPath: executable) else { return }
        guard FileManager.default.isExecutableFile(atPath: executable) else { return }

        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let source = DispatchSource.makeReadSource(fileDescriptor: output.fileHandleForReading.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            let data = output.fileHandleForReading.availableData
            if data.isEmpty {
                // EOF: the server exited. Marking dead here is what makes
                // isAlive false — without it a crashed server stays
                // alive-forever, isReady never recovers, and the main
                // loop's dead-client removal never fires. Idempotent with
                // stop(), which sets alive=false before cancelling.
                self?.alive = false
                return
            }
            self?.handleData(data)
        }
        source.resume()
        readSource = source
        inputPipe = input

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
                ] as [String: Any],
                "publishDiagnostics": true
            ] as [String: Any]
        ]

        var params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "capabilities": capabilities,
            // Diagnostics language: pin English regardless of the system
            // locale (a French terminal got French pyright messages).
            "locale": "en"
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

    /// Must run on `queue` (protocol state).
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

        let replay = pendingDidOpens
        pendingDidOpens.removeAll()
        for doc in replay {
            openDocument(uri: doc.uri, languageId: doc.languageId, text: doc.text)
        }
    }

    func openDocument(uri: String, languageId: String, text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.initialized else {
                // Not initialized yet: stash for replay after initialize —
                // decided ON the queue, so a response being processed right
                // now cannot swallow the stash or lose the didOpen. A
                // re-open of the same URI replaces the stashed text.
                self.pendingDidOpens.removeAll { $0.uri == uri }
                self.pendingDidOpens.append((uri: uri, languageId: languageId, text: text))
                return
            }
            let version = self.nextVersion(uri)
            guard let frame = Self.frame(method: "textDocument/didOpen", params: [
                "textDocument": [
                    "uri": uri,
                    "languageId": languageId,
                    "version": version,
                    "text": text
                ] as [String: Any]
            ]) else { return }
            self.write(frame)
            self.requestSemanticTokens(uri: uri)
        }
    }

    func changeDocument(uri: String, changes: [LSPTextChange]) {
        queue.async { [weak self] in
            guard let self, self.initialized else { return }
            let version = self.nextVersion(uri)
            let contentChanges: [[String: Any]] = changes.map { change in
                [
                    "range": [
                        "start": ["line": change.startLine, "character": change.startChar] as [String: Any],
                        "end": ["line": change.endLine, "character": change.endChar]
                    ] as [String: Any],
                    "text": change.text
                ] as [String: Any]
            }
            guard let frame = Self.frame(method: "textDocument/didChange", params: [
                "textDocument": [
                    "uri": uri,
                    "version": version
                ] as [String: Any],
                "contentChanges": contentChanges
            ] as [String: Any]) else { return }
            self.write(frame)
        }
    }

    /// Full-sync didChange after an external rewrite (e.g. a git discard
    /// from the panel reloaded the buffer): a contentChange without a
    /// range replaces the whole document, per the LSP spec. Cached
    /// semantic tokens are stale — re-request them.
    func reloadDocument(uri: String, text: String) {
        queue.async { [weak self] in
            guard let self, self.initialized else { return }
            let version = self.nextVersion(uri)
            guard let frame = Self.frame(method: "textDocument/didChange", params: [
                "textDocument": [
                    "uri": uri,
                    "version": version
                ] as [String: Any],
                "contentChanges": [["text": text] as [String: Any]]
            ] as [String: Any]) else { return }
            self.write(frame)
            self.requestSemanticTokens(uri: uri)
        }
    }

    /// Must run on `queue`. Advances and mirrors the per-document version.
    private func nextVersion(_ uri: String) -> Int {
        let version = (documentVersions[uri] ?? 0) + 1
        documentVersions[uri] = version
        sentVersions.withLock { $0[uri] = version }
        return version
    }

    func requestSemanticTokens(uri: String) {
        sendRequest(method: "textDocument/semanticTokens/full",
                    params: ["textDocument": ["uri": uri] as [String: Any]]) { [weak self] data in
            self?.handleSemanticTokensResponse(data, uri: uri)
        }
    }

    func closeDocument(uri: String) {
        sendNotification(method: "textDocument/didClose",
                         params: ["textDocument": ["uri": uri] as [String: Any]])
    }

    func requestDefinition(uri: String, line: Int, character: Int) {
        sendRequest(method: "textDocument/definition",
                    params: [
                        "textDocument": ["uri": uri] as [String: Any],
                        "position": ["line": line, "character": character] as [String: Any]
                    ]) { [weak self] data in
            self?.handleDefinitionResponse(data)
        }
    }

    /// Handles Location | Location[] | LocationLink[] | null result shapes.
    /// Must run on `queue`.
    private func handleDefinitionResponse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"], !(result is NSNull) else {
            definitionMailbox.withLock { $0 = .notFound }
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
            definitionMailbox.withLock { $0 = .notFound }
            return
        }
        definitionMailbox.withLock { $0 = .found(LSPDefinition(uri: uri, line: line, charUtf16: character)) }
    }

    /// Must run on `queue`.
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

        tokensMailbox.withLock { $0 = (uri: uri, tokens: tokens) }
    }

    /// Serializes one JSON-RPC message with its `Content-Length` frame on
    /// the calling thread — dictionaries never cross into queue closures.
    private static func frame(id: Int? = nil, method: String, params: [String: Any]) -> Data? {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { message["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        var frame = "Content-Length: \(data.count)\r\n\r\n".data(using: .ascii)!
        frame.append(data)
        return frame
    }

    /// Builds and serializes on the caller, registers the callback and
    /// writes on `queue` — one serial block, so the response can only be
    /// parsed after both (the pre-fix code registered from the main
    /// thread, racing the reader's removeValue and risking dictionary
    /// corruption).
    private func sendRequest(method: String, params: [String: Any], callback: @escaping @Sendable (Data) -> Void) {
        let id = nextIdCell.withLock { cell in
            let id = cell
            cell += 1
            return id
        }
        guard let frame = Self.frame(id: id, method: method, params: params) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingRequests[id] = callback
            self.write(frame)
        }
    }

    private func sendNotification(method: String, params: [String: Any]) {
        guard let frame = Self.frame(method: method, params: params) else { return }
        queue.async { [weak self] in
            self?.write(frame)
        }
    }

    /// Must run on `queue`: whole-frame writes keep frames from interleaving.
    private func write(_ frame: Data) {
        guard alive, let inputPipe else { return }
        inputPipe.fileHandleForWriting.write(frame)
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

    /// Must run on `queue`.
    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = json["id"] as? Int {
            if let callback = pendingRequests.removeValue(forKey: id) {
                callback(data)
            }
        }

        if let method = json["method"] as? String, let params = json["params"] as? [String: Any],
           method == "textDocument/publishDiagnostics",
           let uri = params["uri"] as? String {
            let version = params["version"] as? Int
            let decoded = (params["diagnostics"] as? [Any] ?? []).compactMap(Self.decodeDiagnostic)
            diagnosticsMailbox.withLock { $0[uri] = (version, decoded) }
        }
    }

    private static func decodeDiagnostic(_ raw: Any) -> LSPDiagnostic? {
        guard let dict = raw as? [String: Any],
              let range = dict["range"] as? [String: Any],
              let start = range["start"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startChar = start["character"] as? Int,
              let end = range["end"] as? [String: Any],
              let endLine = end["line"] as? Int,
              let endChar = end["character"] as? Int else { return nil }
        return LSPDiagnostic(
            startLine: startLine,
            startChar: startChar,
            endLine: endLine,
            endChar: endChar,
            severity: dict["severity"] as? Int ?? 1,
            unnecessary: (dict["tags"] as? [Int])?.contains(1) ?? false,
            message: dict["message"] as? String ?? ""
        )
    }
}
