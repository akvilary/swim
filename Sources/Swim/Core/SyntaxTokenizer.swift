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

    static let cppKeywords: Set<String> = [
        "alignas", "alignof", "and", "and_eq", "asm", "auto", "bitand", "bitor",
        "bool", "break", "case", "catch", "char", "char8_t", "char16_t", "char32_t",
        "class", "compl", "concept", "const", "consteval", "constexpr", "constinit",
        "const_cast", "continue", "co_await", "co_return", "co_yield", "decltype",
        "default", "delete", "do", "double", "dynamic_cast", "else", "enum",
        "explicit", "export", "extern", "false", "float", "for", "friend", "goto",
        "if", "inline", "int", "long", "mutable", "namespace", "new", "noexcept",
        "not", "not_eq", "nullptr", "operator", "or", "or_eq", "private",
        "protected", "public", "register", "reinterpret_cast", "requires", "return",
        "short", "signed", "sizeof", "static", "static_assert", "static_cast",
        "struct", "switch", "template", "this", "thread_local", "throw", "true",
        "try", "typedef", "typeid", "typename", "union", "unsigned", "using",
        "virtual", "void", "volatile", "wchar_t", "while", "xor", "xor_eq",
        "override", "final",
    ]

    static let jsKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const",
        "continue", "debugger", "default", "delete", "do", "else", "export",
        "extends", "false", "finally", "for", "function", "if", "import",
        "in", "instanceof", "let", "new", "null", "of", "return", "static",
        "super", "switch", "this", "throw", "true", "try", "typeof",
        "undefined", "var", "void", "while", "with", "yield",
    ]

    static let dartKeywords: Set<String> = [
        "abstract", "as", "assert", "async", "await", "break", "case",
        "catch", "class", "const", "continue", "covariant", "default",
        "deferred", "do", "dynamic", "else", "enum", "export", "extends",
        "extension", "external", "factory", "false", "final", "finally",
        "for", "Function", "get", "hide", "if", "implements", "import",
        "in", "interface", "is", "late", "library", "mixin", "new", "null",
        "on", "operator", "part", "required", "rethrow", "return", "sealed",
        "set", "show", "static", "super", "switch", "this", "throw", "true",
        "try", "type", "typedef", "var", "void", "while", "with", "yield",
    ]

    static func isMarkdown(_ ext: String) -> Bool {
        ext == "md" || ext == "markdown" || ext == "mdx"
    }

    static func languageId(for ext: String) -> String {
        switch ext {
        case "swift": return "swift"
        case "c": return "c"
        case "cpp", "cc", "cxx": return "cpp"
        case "h": return "objective-c"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        case "ts": return "typescript"
        case "js": return "javascript"
        case "dart": return "dart"
        default: return "plaintext"
        }
    }

    static func keywords(for ext: String) -> Set<String> {
        switch ext {
        case "swift": return swiftKeywords
        case "c", "h": return cKeywords
        case "cpp", "cxx", "cc", "hpp", "hxx": return cppKeywords
        case "py": return pythonKeywords
        case "rs": return rustKeywords
        case "go": return goKeywords
        case "js", "ts", "jsx", "tsx": return jsKeywords
        case "dart": return dartKeywords
        default: return []
        }
    }

    static let opChars: Set<Character> = ["+", "-", "*", "/", "=", "<", ">", "!", "&", "|", "^", "~", "%", "?", ":", "@", "#"]

    static func tokenize(line: String, lineNum: Int, keywords: Set<String>) -> [SemanticToken] {
        var tokens = [SemanticToken]()
        let chars = Array(line)
        let len = chars.count
        var i = 0

        while i < len {
            if chars[i] == "/" && i + 1 < len && chars[i + 1] == "/" {
                tokens.append(SemanticToken(line: lineNum, startChar: i, length: len - i, type: "comment", modifiers: 0))
                return tokens
            }

            if chars[i] == "/" && i + 1 < len && chars[i + 1] == "*" {
                var end = i + 2
                while end + 1 < len && !(chars[end] == "*" && chars[end + 1] == "/") { end += 1 }
                let commentLen = min(end + 2, len) - i
                tokens.append(SemanticToken(line: lineNum, startChar: i, length: commentLen, type: "comment", modifiers: 0))
                i += commentLen
                continue
            }

            if chars[i] == "\"" || chars[i] == "'" {
                let quote = chars[i]
                var end = i + 1
                while end < len {
                    if chars[end] == "\\" { end += 2; continue }
                    if chars[end] == quote { end += 1; break }
                    end += 1
                }
                tokens.append(SemanticToken(line: lineNum, startChar: i, length: end - i, type: "string", modifiers: 0))
                i = end
                continue
            }

            if chars[i] >= "0" && chars[i] <= "9" {
                var end = i + 1
                if end < len && chars[i] == "0" && end < len && (chars[end] == "x" || chars[end] == "X") {
                    end += 1
                    while end < len && ((chars[end] >= "0" && chars[end] <= "9") || (chars[end] >= "a" && chars[end] <= "f") || (chars[end] >= "A" && chars[end] <= "F") || chars[end] == "_") { end += 1 }
                } else {
                    while end < len && ((chars[end] >= "0" && chars[end] <= "9") || chars[end] == "." || chars[end] == "e" || chars[end] == "E" || chars[end] == "_" || ((chars[end] == "+" || chars[end] == "-") && end > 0 && (chars[end - 1] == "e" || chars[end - 1] == "E"))) { end += 1 }
                }
                tokens.append(SemanticToken(line: lineNum, startChar: i, length: end - i, type: "number", modifiers: 0))
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
                } else if chars[i] >= "A" && chars[i] <= "Z" && word.count >= 2 {
                    type = "type"
                } else if i > 0 && chars[i - 1] == "." {
                    type = "function"
                } else if end < len && chars[end] == "(" {
                    type = "function"
                } else {
                    type = "variable"
                }
                tokens.append(SemanticToken(line: lineNum, startChar: i, length: end - i, type: type, modifiers: 0))
                i = end
                continue
            }

            if opChars.contains(chars[i]) {
                var end = i + 1
                while end < len && opChars.contains(chars[end]) { end += 1 }
                tokens.append(SemanticToken(line: lineNum, startChar: i, length: end - i, type: "operator", modifiers: 0))
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
        allTokens.reserveCapacity(height * 4)
        for row in 0..<height {
            let lineNum = scrollY + row
            guard lineNum < buffer.lineCount else { break }
            let line = buffer.getLine(lineNum)
            allTokens.append(contentsOf: tokenize(line: line, lineNum: lineNum, keywords: kw))
        }
        return allTokens
    }

    struct MarkdownCache {
        var bufferId: Int = 0
        var scrollY: Int = 0
        var inCodeBlock: Bool = false
        var lineCount: Int = 0
    }

    static func tokenizeMarkdownVisible(buffer: PieceTable, scrollY: Int, height: Int, cache: inout MarkdownCache) -> [SemanticToken] {
        var allTokens = [SemanticToken]()
        let bufferId = ObjectIdentifier(buffer).hashValue
        let lineCount = buffer.lineCount
        var inCodeBlock = false

        let cacheValid = bufferId == cache.bufferId && lineCount == cache.lineCount && scrollY >= cache.scrollY && scrollY <= cache.scrollY + 200
        var startLine: Int
        if cacheValid {
            startLine = cache.scrollY
            inCodeBlock = cache.inCodeBlock
        } else {
            startLine = 0
            inCodeBlock = false
        }

        for lineNum in startLine..<scrollY {
            guard lineNum < lineCount else { break }
            let line = buffer.getLine(lineNum)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeBlock = !inCodeBlock
            }
        }

        cache.bufferId = bufferId
        cache.scrollY = scrollY
        cache.inCodeBlock = inCodeBlock
        cache.lineCount = lineCount

        allTokens.reserveCapacity(height * 3)
        for row in 0..<height {
            let lineNum = scrollY + row
            guard lineNum < lineCount else { break }
            let line = buffer.getLine(lineNum)
            allTokens.append(contentsOf: tokenizeMarkdownLine(line, lineNum: lineNum, inCodeBlock: &inCodeBlock))
        }
        return allTokens
    }

    private static func tokenizeMarkdownLine(_ line: String, lineNum: Int, inCodeBlock: inout Bool) -> [SemanticToken] {
        var tokens = [SemanticToken]()
        let chars = Array(line)
        let len = chars.count
        var i = 0

        while i < len && chars[i] == " " { i += 1 }

        if inCodeBlock {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeBlock = false
                tokens.append(SemanticToken(line: lineNum, startChar: 0, length: len, type: "string", modifiers: 0))
                return tokens
            }
            tokens.append(SemanticToken(line: lineNum, startChar: 0, length: len, type: "string", modifiers: 0))
            return tokens
        }

        if i < len && chars[i] == "#" {
            var end = i
            while end < len && chars[end] == "#" { end += 1 }
            tokens.append(SemanticToken(line: lineNum, startChar: i, length: end - i, type: "keyword", modifiers: 0))
            if end < len && chars[end] == " " {
                tokens.append(SemanticToken(line: lineNum, startChar: end + 1, length: len - end - 1, type: "type", modifiers: 0))
            }
            return tokens
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            inCodeBlock = true
            tokens.append(SemanticToken(line: lineNum, startChar: 0, length: len, type: "string", modifiers: 0))
            return tokens
        }

        if isHorizontalRule(chars) {
            tokens.append(SemanticToken(line: lineNum, startChar: 0, length: len, type: "comment", modifiers: 0))
            return tokens
        }

        if i < len && chars[i] == ">" {
            var end = i + 1
            if end < len && chars[end] == " " { end += 1 }
            tokens.append(SemanticToken(line: lineNum, startChar: i, length: end - i, type: "comment", modifiers: 0))
            tokens.append(SemanticToken(line: lineNum, startChar: end, length: len - end, type: "comment", modifiers: 0))
            return tokens
        }

        if i < len && (chars[i] == "-" || chars[i] == "*" || chars[i] == "+") {
                let next = i + 1
            if next < len && chars[next] == " " {
                tokens.append(SemanticToken(line: lineNum, startChar: i, length: 1, type: "number", modifiers: 0))
                i = next + 1
            }
        } else if i < len && chars[i] >= "0" && chars[i] <= "9" {
            var numEnd = i + 1
            while numEnd < len && chars[numEnd] >= "0" && chars[numEnd] <= "9" { numEnd += 1 }
            if numEnd < len && (chars[numEnd] == "." || chars[numEnd] == ")") {
                let afterDelim = numEnd + 1
                if afterDelim < len && chars[afterDelim] == " " {
                    tokens.append(SemanticToken(line: lineNum, startChar: i, length: afterDelim - i + 1, type: "number", modifiers: 0))
                    i = afterDelim + 1
                }
            }
        }

        i = 0
        while i < len {
            if chars[i] == "`" {
                var count = 0
                let start = i
                while i < len && chars[i] == "`" { i += 1; count += 1 }
                while i < len {
                    if chars[i] == "`" {
                        var c = 0
                        while i < len && chars[i] == "`" && c < count { i += 1; c += 1 }
                        if c == count { break }
                    } else {
                        i += 1
                    }
                }
                let end = min(i, len)
                tokens.append(SemanticToken(line: lineNum, startChar: start, length: end - start, type: "string", modifiers: 0))
                continue
            }

            if i + 1 < len && chars[i] == "*" && chars[i + 1] == "*" {
                let start = i; i += 2
                while i + 1 < len && !(chars[i] == "*" && chars[i + 1] == "*") { i += 1 }
                if i + 1 < len { i += 2 }
                tokens.append(SemanticToken(line: lineNum, startChar: start, length: i - start, type: "keyword", modifiers: 0))
                continue
            }

            if i + 1 < len && chars[i] == "_" && chars[i + 1] == "_" {
                let start = i; i += 2
                while i + 1 < len && !(chars[i] == "_" && chars[i + 1] == "_") { i += 1 }
                if i + 1 < len { i += 2 }
                tokens.append(SemanticToken(line: lineNum, startChar: start, length: i - start, type: "keyword", modifiers: 0))
                continue
            }

            if chars[i] == "*" && (i == 0 || chars[i - 1] == " ") {
                let start = i; i += 1
                while i < len && chars[i] != "*" && chars[i] != "\n" { i += 1 }
                if i < len && chars[i] == "*" { i += 1 }
                tokens.append(SemanticToken(line: lineNum, startChar: start, length: i - start, type: "variable", modifiers: 0))
                continue
            }

            if chars[i] == "_" && (i == 0 || chars[i - 1] == " ") {
                let start = i; i += 1
                while i < len && chars[i] != "_" && chars[i] != "\n" { i += 1 }
                if i < len && chars[i] == "_" { i += 1 }
                tokens.append(SemanticToken(line: lineNum, startChar: start, length: i - start, type: "variable", modifiers: 0))
                continue
            }

            if chars[i] == "[" {
                let start = i; i += 1
                while i < len && chars[i] != "]" { i += 1 }
                if i < len { i += 1 }
                tokens.append(SemanticToken(line: lineNum, startChar: start, length: i - start, type: "decorator", modifiers: 0))
                if i < len && chars[i] == "(" {
                    let urlStart = i; i += 1
                    while i < len && chars[i] != ")" { i += 1 }
                    if i < len { i += 1 }
                    tokens.append(SemanticToken(line: lineNum, startChar: urlStart, length: i - urlStart, type: "string", modifiers: 0))
                }
                continue
            }

            if chars[i] == "!" && i + 1 < len && chars[i + 1] == "[" {
                let start = i; i += 2
                while i < len && chars[i] != "]" { i += 1 }
                if i < len { i += 1 }
                tokens.append(SemanticToken(line: lineNum, startChar: start, length: i - start, type: "decorator", modifiers: 0))
                if i < len && chars[i] == "(" {
                    let urlStart = i; i += 1
                    while i < len && chars[i] != ")" { i += 1 }
                    if i < len { i += 1 }
                    tokens.append(SemanticToken(line: lineNum, startChar: urlStart, length: i - urlStart, type: "string", modifiers: 0))
                }
                continue
            }

            if chars[i] == "<" && i + 1 < len && (chars[i + 1] == "h" || chars[i + 1] == "H" || chars[i + 1] == "a" || chars[i + 1] == "A") {
                let start = i
                while i < len && chars[i] != ">" { i += 1 }
                if i < len { i += 1 }
                tokens.append(SemanticToken(line: lineNum, startChar: start, length: i - start, type: "string", modifiers: 0))
                continue
            }

            i += 1
        }

        return tokens
    }

    private static func isHorizontalRule(_ chars: [Character]) -> Bool {
        var i = 0
        let len = chars.count
        while i < len && chars[i] == " " { i += 1 }
        guard i < len else { return false }
        let marker = chars[i]
        guard marker == "-" || marker == "*" || marker == "_" else { return false }
        var count = 0
        while i < len {
            if chars[i] == marker { count += 1 }
            else if chars[i] != " " { return false }
            i += 1
        }
        return count >= 3
    }
}
