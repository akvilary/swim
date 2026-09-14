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
