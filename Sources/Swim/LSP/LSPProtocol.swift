import Foundation

struct SemanticToken: Equatable {
    let line: Int
    let startChar: Int
    let length: Int
    let type: String
    let modifiers: Int
}

struct LSPPosition: Codable {
    let line: Int
    let character: Int
}

struct LSPRange: Codable {
    let start: LSPPosition
    let end: LSPPosition
}

struct LSPTextDocumentIdentifier: Codable {
    let uri: String
}

struct LSPVersionedTextDocumentIdentifier: Codable {
    let uri: String
    let version: Int
}

struct LSPTextDocumentItem: Codable {
    let uri: String
    let languageId: String
    let version: Int
    let text: String
}

struct LSPTextDocumentContentChangeEvent: Codable {
    let range: LSPRange?
    let rangeLength: Int?
    let text: String
}

enum LSPMessageType: String, Codable {
    case request = "request"
    case response = "response"
    case notification = "notification"
}

struct LSPRequest: Encodable {
    let jsonrpc: String = "2.0"
    let id: Int
    let method: String
    let params: AnyCodable
}

struct LSPNotification: Encodable {
    let jsonrpc: String = "2.0"
    let method: String
    let params: AnyCodable
}

struct LSPResponse<T: Decodable>: Decodable {
    let jsonrpc: String?
    let id: Int?
    let result: T?
    let error: LSPError?
}

struct LSPError: Decodable {
    let code: Int
    let message: String
}

struct LSPInitializeParams: Encodable {
    let processId: Int
    let rootUri: String?
    let capabilities: LSPClientCapabilities
}

struct LSPClientCapabilities: Encodable {
    let textDocument: LSPTextDocumentClientCapabilities
}

struct LSPTextDocumentClientCapabilities: Encodable {
    let semanticTokens: LSPSemanticTokensClientCapabilities?
}

struct LSPSemanticTokensClientCapabilities: Encodable {
    let full: Bool
    let delta: Bool
    let tokenTypes: [String]
    let tokenModifiers: [String]
    let formats: [String]
}

struct LSPInitializeResult: Decodable {
    let capabilities: LSPServerCapabilities
}

struct LSPServerCapabilities: Decodable {
    let semanticTokensProvider: LSPSemanticTokensOptions?
}

struct LSPSemanticTokensOptions: Decodable {
    let full: BoolOrSemanticTokensOptions?
    let legend: LSPSemanticTokensLegend?
}

struct BoolOrSemanticTokensOptions: Decodable {
    let value: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            value = b
        } else {
            value = nil
        }
    }
}

struct LSPSemanticTokensLegend: Decodable {
    let tokenTypes: [String]
    let tokenModifiers: [String]
}

struct LSPSemanticTokens: Decodable {
    let data: [Int]
}

struct LSPOpenParams: Encodable {
    let textDocument: LSPTextDocumentItem
}

struct LSPChangeParams: Encodable {
    let textDocument: LSPVersionedTextDocumentIdentifier
    let contentChanges: [LSPTextDocumentContentChangeEvent]
}

struct LSPSemanticTokensParams: Encodable {
    let textDocument: LSPTextDocumentIdentifier
}

struct AnyCodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? String { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Bool { try container.encode(v) }
        else if let v = value as? [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: v)
            let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
            try container.encode(decoded)
        }
        else if let v = value as? Encodable {
            let data = try JSONEncoder().encode(v)
            let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
            try container.encode(decoded)
        }
    }
}

private struct AnyCodableValue: Encodable, Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode([AnyCodableValue].self) { value = v }
        else if let v = try? container.decode([String: AnyCodableValue].self) { value = v }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? String { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Bool { try container.encode(v) }
        else if let v = value as? Double { try container.encode(v) }
        else if let v = value as? [AnyCodableValue] { try container.encode(v) }
        else if let v = value as? [String: AnyCodableValue] { try container.encode(v) }
    }
}
