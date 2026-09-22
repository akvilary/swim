public struct SemanticToken: Equatable, Sendable {
    public let line: Int
    public let startChar: Int
    public let length: Int
    public let type: String
    public let modifiers: Int

    public init(line: Int, startChar: Int, length: Int, type: String, modifiers: Int) {
        self.line = line
        self.startChar = startChar
        self.length = length
        self.type = type
        self.modifiers = modifiers
    }
}

public struct LSPTextChange: Sendable {
    public let startLine: Int
    public let startChar: Int
    public let endLine: Int
    public let endChar: Int
    public let text: String

    public init(startLine: Int, startChar: Int, endLine: Int, endChar: Int, text: String) {
        self.startLine = startLine
        self.startChar = startChar
        self.endLine = endLine
        self.endChar = endChar
        self.text = text
    }
}

/// One entry of a `textDocument/publishDiagnostics` notification, in raw
/// server coordinates (UTF-16); converted to grapheme indices per render
/// like semantic tokens. `unnecessary` is the LSP tag 1 (Unnecessary) —
/// pyright marks unused imports with it.
public struct LSPDiagnostic: Sendable {
    public let startLine: Int
    public let startChar: Int
    public let endLine: Int
    public let endChar: Int
    public let severity: Int
    public let unnecessary: Bool
    public let message: String

    public init(startLine: Int, startChar: Int, endLine: Int, endChar: Int,
                severity: Int, unnecessary: Bool, message: String) {
        self.startLine = startLine
        self.startChar = startChar
        self.endLine = endLine
        self.endChar = endChar
        self.severity = severity
        self.unnecessary = unnecessary
        self.message = message
    }
}

public struct LSPDefinition: Sendable {
    public let uri: String
    public let line: Int
    public let charUtf16: Int

    public init(uri: String, line: Int, charUtf16: Int) {
        self.uri = uri
        self.line = line
        self.charUtf16 = charUtf16
    }
}

public enum LSPDefinitionResult: Sendable {
    case found(LSPDefinition)
    case notFound
}
