import Foundation

public struct SyntaxTokenizer {
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

    /// Python 3.10 soft keywords — valid identifiers that act as keywords
    /// only in statement-initial position (`match x:`, `case _:`).
    static let pythonSoftKeywords: Set<String> = ["match", "case"]

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

    static let csharpKeywords: Set<String> = [
        "abstract", "as", "base", "bool", "break", "byte", "case", "catch",
        "char", "checked", "class", "const", "continue", "decimal", "default",
        "delegate", "do", "double", "else", "enum", "event", "explicit",
        "extern", "false", "finally", "fixed", "float", "for", "foreach",
        "goto", "if", "implicit", "in", "int", "interface", "internal", "is",
        "lock", "long", "namespace", "new", "null", "object", "operator",
        "out", "override", "params", "private", "protected", "public",
        "readonly", "ref", "return", "sbyte", "sealed", "short", "sizeof",
        "stackalloc", "static", "string", "struct", "switch", "this",
        "throw", "true", "try", "typeof", "uint", "ulong", "unchecked",
        "unsafe", "ushort", "using", "virtual", "void", "volatile", "while",
        "async", "await", "dynamic", "get", "set", "var", "record",
        "init", "required", "with", "nint", "nuint", "notnull", "unmanaged",
        "file", "allows", "scoped",
    ]

    public static func languageId(for ext: String) -> String {
        switch ext {
        case "swift": return "swift"
        case "c": return "c"
        case "cpp", "cc", "cxx": return "cpp"
        case "h": return "objective-c"
        case "cs", "csx": return "csharp"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        case "ts": return "typescript"
        case "js": return "javascript"
        case "dart": return "dart"
        case "sh", "bash": return "shellscript"
        default: return "plaintext"
        }
    }

    public static func keywords(for ext: String) -> Set<String> {
        switch ext {
        case "swift": return swiftKeywords
        case "c", "h": return cKeywords
        case "cpp", "cxx", "cc", "hpp", "hxx": return cppKeywords
        case "cs", "csx": return csharpKeywords
        case "py", "pyw", "pyi": return pythonKeywords
        case "rs": return rustKeywords
        case "go": return goKeywords
        case "js", "ts", "jsx", "tsx": return jsKeywords
        case "dart": return dartKeywords
        default: return []
        }
    }

    static let opChars: Set<Character> = ["+", "-", "*", "/", "=", "<", ">", "!", "&", "|", "^", "~", "%", "?", ":", "@", "#"]

    /// Boolean/null literals per language — values highlighted with the
    /// number (value) color, distinct from keywords. Python has no `null`,
    /// Swift/Rust have no `null`/`None`, etc.
    static let swiftLiterals: Set<String> = ["true", "false", "nil"]
    static let cLiterals: Set<String> = ["true", "false", "NULL"]
    static let cppLiterals: Set<String> = ["true", "false", "nullptr", "NULL"]
    static let csharpLiterals: Set<String> = ["true", "false", "null"]
    static let pythonLiterals: Set<String> = ["True", "False", "None"]
    static let rustLiterals: Set<String> = ["true", "false"]
    static let goLiterals: Set<String> = ["true", "false", "nil"]
    static let jsLiterals: Set<String> = ["true", "false", "null", "undefined"]
    static let dartLiterals: Set<String> = ["true", "false", "null"]

    public static func valueLiterals(for ext: String) -> Set<String> {
        switch ext {
        case "swift": return swiftLiterals
        case "c", "h": return cLiterals
        case "cpp", "cxx", "cc", "hpp", "hxx": return cppLiterals
        case "cs", "csx": return csharpLiterals
        case "py", "pyw", "pyi": return pythonLiterals
        case "rs": return rustLiterals
        case "go": return goLiterals
        case "js", "ts", "jsx", "tsx": return jsLiterals
        case "dart": return dartLiterals
        default: return []
        }
    }

    /// Multi-line string syntax per language (keyed by file extension — works
    /// for both LSP-backed and builtin highlighting).
    public struct MultilineStringRule: Sendable {
        public let open: String
        public let close: String
        public let escapes: Bool
    }

    public enum MultilineStringState: Equatable, Sendable {
        case none
        case active(ruleIndex: Int)
    }

    /// Per-language syntax profile: multi-line string rules, the
    /// single-line comment syntax and soft keywords, resolved in one
    /// place per file extension. Languages without soft keywords keep
    /// the empty default — the tokenizer skips the check entirely.
    public struct LanguageSyntax: Sendable {
        public let mlRules: [MultilineStringRule]
        public let lineComment: String
        /// POSIX shell: "#" comments only where a word begins — `${#arr}`,
        /// `$#`, `x=1#c` are not comments. Python hashes comment anywhere.
        public let lineCommentAtWordStartOnly: Bool
        public var softKeywords: Set<String> = []
        /// Python f/r/b/u string prefixes: in `f"x"` the prefix belongs to
        /// the string token, not an identifier.
        public var stringPrefixes: Bool = false

        public static let `default` = LanguageSyntax(mlRules: [], lineComment: "//", lineCommentAtWordStartOnly: false)
    }

    /// Letters valid in Python string prefixes (f/r/b/u, any case, any
    /// combination — `fr`, `rb`, …).
    static let stringPrefixChars: Set<Character> = ["f", "F", "r", "R", "b", "B", "u", "U"]

    /// Merges one line's syntactic (builtin) tokens with its LSP semantic
    /// tokens. LSP wins on overlap — except inside builtin string tokens:
    /// servers like pyright leave string coloring to syntax highlighting
    /// yet still emit tokens for f-string interpolation expressions, which
    /// would otherwise evict the string span and leave f-strings uncolored.
    /// An LSP token nested in a string is swallowed by it — but only by a
    /// string that survived the merge: a string evicted by a partially
    /// overlapping LSP token must not take nested tokens with it (that
    /// would leave a coverage hole). Partial overlaps still evict the
    /// builtin token as before. Returns tokens sorted by startChar with
    /// no overlaps.
    public static func mergeWithLSP(builtin: [SemanticToken], lsp: [SemanticToken]) -> [SemanticToken] {
        func overlaps(_ a: SemanticToken, _ b: SemanticToken) -> Bool {
            a.startChar < b.startChar + b.length && b.startChar < a.startChar + a.length
        }
        func nests(_ a: SemanticToken, inside b: SemanticToken) -> Bool {
            a.startChar >= b.startChar && a.startChar + a.length <= b.startChar + b.length
        }
        let surviving = builtin.filter { b in
            !lsp.contains { l in
                overlaps(b, l) && !(b.type == "string" && nests(l, inside: b))
            }
        }
        let survivingStrings = surviving.filter { $0.type == "string" }
        let merged = surviving + lsp.filter { l in
            !survivingStrings.contains { s in nests(l, inside: s) }
        }
        return merged.sorted { $0.startChar < $1.startChar }
    }

    public static func syntax(for fileExt: String) -> LanguageSyntax {
        let syntax: LanguageSyntax
        switch fileExt {
        case "py", "pyw", "pyi":
            syntax = LanguageSyntax(
                mlRules: [
                    MultilineStringRule(open: "\"\"\"", close: "\"\"\"", escapes: true),
                    MultilineStringRule(open: "'''", close: "'''", escapes: true),
                ],
                lineComment: "#", lineCommentAtWordStartOnly: false,
                softKeywords: pythonSoftKeywords,
                stringPrefixes: true)
        case "swift":
            syntax = LanguageSyntax(
                mlRules: [MultilineStringRule(open: "\"\"\"", close: "\"\"\"", escapes: true)],
                lineComment: "//", lineCommentAtWordStartOnly: false)
        case "go":
            syntax = LanguageSyntax(
                mlRules: [MultilineStringRule(open: "`", close: "`", escapes: false)],
                lineComment: "//", lineCommentAtWordStartOnly: false)
        case "rs":
            // Rust "..." literals may legally span lines
            syntax = LanguageSyntax(
                mlRules: [MultilineStringRule(open: "\"", close: "\"", escapes: true)],
                lineComment: "//", lineCommentAtWordStartOnly: false)
        case "cs", "csx":
            syntax = LanguageSyntax(
                mlRules: [
                    MultilineStringRule(open: "\"\"\"", close: "\"\"\"", escapes: true),
                    MultilineStringRule(open: "@\"", close: "\"", escapes: true),
                ],
                lineComment: "//", lineCommentAtWordStartOnly: false)
        case "sh", "bash":
            syntax = LanguageSyntax(mlRules: [], lineComment: "#", lineCommentAtWordStartOnly: true)
        case "yaml", "yml", "toml", "rb":
            syntax = LanguageSyntax(mlRules: [], lineComment: "#", lineCommentAtWordStartOnly: false)
        default:
            syntax = .default
        }
        // Longest opener first so """ wins over " and @" at the same position
        let sorted = LanguageSyntax(
            mlRules: syntax.mlRules.sorted { $0.open.count > $1.open.count },
            lineComment: syntax.lineComment,
            lineCommentAtWordStartOnly: syntax.lineCommentAtWordStartOnly,
            softKeywords: syntax.softKeywords,
            stringPrefixes: syntax.stringPrefixes)
        return sorted
    }

    /// Soft keywords are keywords only in statement-initial position: the
    /// first word on the line, not used as an identifier (`match = 1`,
    /// `match(x)`, `match.attr`, `match, x = ...`), and followed by the
    /// start of a subject/pattern: a name, literal, opening bracket or a
    /// unary/star prefix (augmented assignments rejected by the `=` check).
    /// Only reached for languages whose profile carries soft keywords;
    /// check order is cheapest-most-selective first: the statement-start
    /// scan skips ~all non-line-initial words in a few char compares.
    private static func isSoftKeyword(_ word: String, _ soft: Set<String>,
                                      _ chars: [Character], start: Int, end: Int) -> Bool {
        var j = 0
        while j < start, chars[j] == " " || chars[j] == "\t" { j += 1 }
        guard j == start, soft.contains(word) else { return false }
        if end < chars.count, chars[end] == "(" || chars[end] == "." { return false }
        var k = end
        while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
        guard k < chars.count else { return false }
        let c = chars[k]
        if c == "-" || c == "+" || c == "*" || c == "~" {
            return k + 1 < chars.count && chars[k + 1] != "="
        }
        return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
            || (c >= "0" && c <= "9") || c == "_"
            || c == "(" || c == "[" || c == "{" || c == "\"" || c == "'"
    }

    public static func tokenize(chars: [Character], lineNum: Int, keywords: Set<String>,
                          syntax: LanguageSyntax = .default,
                          initialState: MultilineStringState = .none,
                          literals: Set<String> = []) -> (tokens: [SemanticToken], endState: MultilineStringState) {
        var tokens = [SemanticToken]()
        let len = chars.count
        var i = 0
        var state = initialState

        func matches(_ seq: String, at pos: Int) -> Bool {
            guard pos + seq.count <= len else { return false }
            for (k, c) in seq.enumerated() where chars[pos + k] != c { return false }
            return true
        }

        // Scans for rule.close starting at `from`; returns (closeStart, afterClose).
        func scanClose(_ rule: MultilineStringRule, from: Int) -> (Int, Int)? {
            var j = from
            while j < len {
                if rule.escapes && chars[j] == "\\" { j += 2; continue }
                if matches(rule.close, at: j) { return (j, j + rule.close.count) }
                j += 1
            }
            return nil
        }

        // Continuation of a multi-line string opened on a previous line
        if case .active(let ruleIndex) = state {
            let rule = syntax.mlRules[ruleIndex]
            if let (_, after) = scanClose(rule, from: 0) {
                // The closing delimiter is part of the string token,
                // matching the single-line string convention.
                tokens.append(SemanticToken(line: lineNum, startChar: 0, length: after, type: "string", modifiers: 0))
                i = after
                state = .none
            } else {
                tokens.append(SemanticToken(line: lineNum, startChar: 0, length: len, type: "string", modifiers: 0))
                return (tokens, state)
            }
        }

        while i < len {
            // Line comment (per language: "//" or "#") wins over everything,
            // including multi-line string openers inside the comment text.
            if !syntax.lineComment.isEmpty, chars[i] == syntax.lineComment.first!,
               matches(syntax.lineComment, at: i),
               !syntax.lineCommentAtWordStartOnly || i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t" {
                tokens.append(SemanticToken(line: lineNum, startChar: i, length: len - i, type: "comment", modifiers: 0))
                return (tokens, .none)
            }

            if chars[i] == "/" && i + 1 < len && chars[i + 1] == "*" {
                var end = i + 2
                while end + 1 < len && !(chars[end] == "*" && chars[end + 1] == "/") { end += 1 }
                let commentLen = min(end + 2, len) - i
                tokens.append(SemanticToken(line: lineNum, startChar: i, length: commentLen, type: "comment", modifiers: 0))
                i += commentLen
                continue
            }

            // Python string prefixes (f/r/b/u, any combo): a prefix-only
            // word directly abutting a quote makes the whole literal one
            // string token — `f"x"`, `rb'…'`, `f"""…"""`. Adjacency
            // matters: `f "x"` keeps `f` a plain identifier.
            var prefixEnd = i
            if syntax.stringPrefixes, stringPrefixChars.contains(chars[i]) {
                var p = i + 1
                while p < len, stringPrefixChars.contains(chars[p]) { p += 1 }
                if p < len, chars[p] == "\"" || chars[p] == "'" { prefixEnd = p }
            }

            // Multi-line string openers (checked before the single-line branch
            // so """ wins over " and @" over "). Rules are per file extension:
            // python files never scan for rust-style " strings and vice versa.
            // The first-character pre-check keeps per-char cost at a compare.
            // With a string prefix the opener sits at `prefixEnd`; the token
            // starts at the prefix either way.
            var matchedRule: (index: Int, rule: MultilineStringRule)?
            let c = chars[prefixEnd]
            for (idx, rule) in syntax.mlRules.enumerated()
            where rule.open.first == c && matches(rule.open, at: prefixEnd) {
                matchedRule = (idx, rule)
                break
            }
            if let m = matchedRule {
                if let (_, after) = scanClose(m.rule, from: prefixEnd + m.rule.open.count) {
                    tokens.append(SemanticToken(line: lineNum, startChar: i, length: after - i, type: "string", modifiers: 0))
                    i = after
                } else {
                    tokens.append(SemanticToken(line: lineNum, startChar: i, length: len - i, type: "string", modifiers: 0))
                    return (tokens, .active(ruleIndex: m.index))
                }
                continue
            }

            if c == "\"" || c == "'" {
                let quote = c
                // Escapes are honored even for raw prefixes: a backslash
                // still escapes the quote for termination purposes (a raw
                // literal cannot end in a backslash), matching CPython.
                var end = prefixEnd + 1
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
                if literals.contains(word) {
                    type = "number"
                } else if keywords.contains(word)
                    || (!syntax.softKeywords.isEmpty
                        && isSoftKeyword(word, syntax.softKeywords, chars, start: i, end: end)) {
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

        return (tokens, .none)
    }

    public static func tokenizeJSON(lineChars chars: [Character], lineNum: Int) -> [SemanticToken] {
        let len = chars.count
        var tokens = [SemanticToken]()
        var i = 0
        var inString = false
        var skipNext = false

        while i < len {
            let char = chars[i]
            let type: String

            if skipNext {
                skipNext = false
                type = "string"
            } else if inString {
                if char == "\\" { skipNext = true }
                else if char == "\"" { inString = false }
                type = "string"
            } else {
                if char == "\"" { inString = true; type = "string" }
                else if char == "{" || char == "}" || char == "[" || char == "]" || char == "," || char == ":" { type = "punctuation" }
                else { type = "number" }
            }

            if let lastIdx = tokens.indices.last,
               tokens[lastIdx].type == type,
               tokens[lastIdx].startChar + tokens[lastIdx].length == i {
                tokens[lastIdx] = SemanticToken(line: lineNum, startChar: tokens[lastIdx].startChar, length: tokens[lastIdx].length + 1, type: type, modifiers: 0)
            } else {
                tokens.append(SemanticToken(line: lineNum, startChar: i, length: 1, type: type, modifiers: 0))
            }

            i += 1
        }

        return tokens
    }
}
