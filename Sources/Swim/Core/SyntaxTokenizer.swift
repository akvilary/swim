struct SyntaxToken: Equatable {
    let line: Int
    let startChar: Int
    let length: Int
    let type: String
    let modifiers: Int
}

struct SyntaxTokenizer {
    static let swiftKeywords: Set<String> = [
        "import", "class", "struct", "enum", "protocol", "extension",
        "func", "var", "let", "typealias", "associatedtype",
        "if", "else", "switch", "case", "default", "where",
        "for", "in", "while", "repeat", "break", "continue", "fallthrough",
        "return", "throw", "try", "catch", "defer", "guard",
        "init", "deinit", "self", "super", "nil",
        "true", "false",
        "public", "private", "internal", "fileprivate", "open",
        "static", "final", "override", "mutating", "nonmutating",
        "weak", "unowned", "lazy", "optional",
        "inout", "async", "await", "actor", "isolated", "nonisolated",
        "some", "any", "Any", "as", "is",
        "precedencegroup", "operator", "subscript",
        "get", "set", "didSet", "willSet",
        "convenience", "required", "dynamic", "indirect",
        "infix", "prefix", "postfix",
    ]

    static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do",
        "double", "else", "enum", "extern", "float", "for", "goto", "if",
        "int", "long", "register", "return", "short", "signed", "sizeof",
        "static", "struct", "switch", "typedef", "union", "unsigned", "void",
        "volatile", "while",
    ]

    static let pythonKeywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await",
        "break", "class", "continue", "def", "del", "elif", "else", "except",
        "finally", "for", "from", "global", "if", "import", "in", "is",
        "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
        "while", "with", "yield",
    ]

    static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn",
        "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let",
        "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "Self", "static", "struct", "super", "trait", "type",
        "unsafe", "use", "where", "while",
    ]

    static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer",
        "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
        "interface", "map", "package", "range", "return", "select", "struct",
        "switch", "type", "var",
    ]

    static let jsKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const",
        "continue", "debugger", "default", "delete", "do", "else", "export",
        "extends", "false", "finally", "for", "function", "if", "import",
        "in", "instanceof", "let", "new", "null", "of", "return", "static",
        "super", "switch", "this", "throw", "true", "try", "typeof",
        "undefined", "var", "void", "while", "with", "yield",
    ]

    static func keywords(for ext: String) -> Set<String> {
        switch ext {
        case "swift": return swiftKeywords
        case "c", "h": return cKeywords
        case "py": return pythonKeywords
        case "rs": return rustKeywords
        case "go": return goKeywords
        case "js", "ts", "jsx", "tsx": return jsKeywords
        default: return swiftKeywords
        }
    }

    static func tokenize(line: String, lineNum: Int, keywords: Set<String>) -> [SyntaxToken] {
        var tokens = [SyntaxToken]()
        let chars = Array(line)
        let len = chars.count
        var i = 0

        while i < len {
            if chars[i] == "/" && i + 1 < len && chars[i + 1] == "/" {
                tokens.append(SyntaxToken(line: lineNum, startChar: i, length: len - i, type: "comment", modifiers: 0))
                return tokens
            }

            if chars[i] == "/" && i + 1 < len && chars[i + 1] == "*" {
                var end = i + 2
                while end + 1 < len && !(chars[end] == "*" && chars[end + 1] == "/") { end += 1 }
                let commentLen = min(end + 2, len) - i
                tokens.append(SyntaxToken(line: lineNum, startChar: i, length: commentLen, type: "comment", modifiers: 0))
                i += commentLen
                continue
            }

            if chars[i] == "\"" {
                var end = i + 1
                while end < len {
                    if chars[end] == "\\" { end += 2; continue }
                    if chars[end] == "\"" { end += 1; break }
                    end += 1
                }
                tokens.append(SyntaxToken(line: lineNum, startChar: i, length: end - i, type: "string", modifiers: 0))
                i = end
                continue
            }

            if chars[i] == "'" {
                var end = i + 1
                while end < len {
                    if chars[end] == "\\" { end += 2; continue }
                    if chars[end] == "'" { end += 1; break }
                    end += 1
                }
                tokens.append(SyntaxToken(line: lineNum, startChar: i, length: end - i, type: "string", modifiers: 0))
                i = end
                continue
            }

            if chars[i] >= "0" && chars[i] <= "9" {
                var end = i + 1
                while end < len && ((chars[end] >= "0" && chars[end] <= "9") || chars[end] == "." || chars[end] == "x" || chars[end] == "a" || chars[end] == "b" || chars[end] == "c" || chars[end] == "d" || chars[end] == "e" || chars[end] == "f" || chars[end] == "_") { end += 1 }
                tokens.append(SyntaxToken(line: lineNum, startChar: i, length: end - i, type: "number", modifiers: 0))
                i = end
                continue
            }

            if (chars[i] >= "a" && chars[i] <= "z") || (chars[i] >= "A" && chars[i] <= "Z") || chars[i] == "_" {
                var end = i + 1
                while end < len && ((chars[end] >= "a" && chars[end] <= "z") || (chars[end] >= "A" && chars[end] <= "Z") || (chars[end] >= "0" && chars[end] <= "9") || chars[end] == "_") { end += 1 }
                let word = String(chars[i..<end])
                let type: String
                if keywords.contains(word) {
                    type = "keyword"
                } else if word.hasPrefix("//") {
                    type = "comment"
                } else if chars[i] >= "A" && chars[i] <= "Z" && word.count >= 2 {
                    type = "type"
                } else if i > 0 && chars[i - 1] == "." {
                    type = "function"
                } else if end < len && chars[end] == "(" {
                    type = "function"
                } else {
                    type = "variable"
                }
                tokens.append(SyntaxToken(line: lineNum, startChar: i, length: end - i, type: type, modifiers: 0))
                i = end
                continue
            }

            let opChars: Set<Character> = ["+", "-", "*", "/", "=", "<", ">", "!", "&", "|", "^", "~", "%", "?", ":", "@", "#"]
            if opChars.contains(chars[i]) {
                var end = i + 1
                while end < len && opChars.contains(chars[end]) { end += 1 }
                tokens.append(SyntaxToken(line: lineNum, startChar: i, length: end - i, type: "operator", modifiers: 0))
                i = end
                continue
            }

            i += 1
        }

        return tokens
    }

    static func tokenizeVisibleLines(buffer: PieceTable, scrollY: Int, height: Int, fileExt: String) -> [SemanticToken] {
        let kw = keywords(for: fileExt)
        var allTokens = [SemanticToken]()
        for row in 0..<height {
            let lineNum = scrollY + row
            guard lineNum < buffer.lineCount else { break }
            let line = buffer.getLine(lineNum)
            let tokens = tokenize(line: line, lineNum: lineNum, keywords: kw)
            for t in tokens {
                allTokens.append(SemanticToken(line: t.line, startChar: t.startChar, length: t.length, type: t.type, modifiers: t.modifiers))
            }
        }
        return allTokens
    }
}
