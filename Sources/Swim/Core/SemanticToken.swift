struct SemanticToken: Equatable {
    let line: Int
    let startChar: Int
    let length: Int
    let type: String
    let modifiers: Int
}

struct LSPTextChange {
    let startLine: Int
    let startChar: Int
    let endLine: Int
    let endChar: Int
    let text: String
}

/// One entry of a `textDocument/publishDiagnostics` notification, in raw
/// server coordinates (UTF-16); converted to grapheme indices per render
/// like semantic tokens. `unnecessary` is the LSP tag 1 (Unnecessary) —
/// pyright marks unused imports with it.
struct LSPDiagnostic {
    let startLine: Int
    let startChar: Int
    let endLine: Int
    let endChar: Int
    let severity: Int
    let unnecessary: Bool
    let message: String
}

struct LSPDefinition {
    let uri: String
    let line: Int
    let charUtf16: Int
}

enum LSPDefinitionResult {
    case found(LSPDefinition)
    case notFound
}
