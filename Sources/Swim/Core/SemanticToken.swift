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

struct LSPDefinition {
    let uri: String
    let line: Int
    let charUtf16: Int
}

enum LSPDefinitionResult {
    case found(LSPDefinition)
    case notFound
}
