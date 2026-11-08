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

    // languageId(for:) moved to LSPServers — the single LSP wiring
    // table (extensions + server key + didOpen languageId); the syntax
    // vocabulary below stays the tokenizer's own concern.

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
        /// `interpolating` — the profile's interpolation gate evaluated
        /// ON for the open string (an f-prefixed python literal, any
        /// swift string, a js template): continuation lines scan for
        /// replacement fields. The content is immutable, so the flag
        /// rides the ladder with the rule index.
        case active(ruleIndex: Int, interpolating: Bool)
    }

    /// When a string occurrence interpolates.
    public enum InterpolationGate: Sendable {
        /// Every string (swift — interpolation is not opt-in).
        case always
        /// Prefix letters switch it on — python f/F, C# $.
        case prefix(Set<Character>)
        /// Prefix letters switch it OFF — dart raw r/R.
        case prefixExcluding(Set<Character>)
        /// Only these quote characters — js backticks; ruby/shell
        /// double quotes (single quotes are literal there).
        case quote(Set<Character>)
    }

    /// String interpolation per language — the sibling of
    /// MultilineStringRule: declarative data, one shared scanner (the
    /// same "embedded code region" model as VS Code's
    /// `string.interpolated` scopes and PyCharm's PSI injection). A
    /// replacement field's expression is tokenized as ordinary code by
    /// a recursive tokenize call; text chunks, spec and doubled
    /// openers stay string-colored; the delimiters are punctuation.
    ///
    /// The field matcher tracks the depth of all three bracket kinds
    /// and skips nested string literals; the field closes where the
    /// running depth first goes negative. The spec-separator rule is
    /// CPython's own (PEP 498: expressions cannot contain ':' outside
    /// of strings or parentheses, brackets or braces) — separators
    /// count only at depth zero.
    public struct InterpolationRule: Sendable {
        /// The field opener: "{", "\\(", "${" or "#{". Multi-character
        /// openers leave lone braces plain text (js/dart/shell/ruby —
        /// `{{ name }}` in an embedded Vue template stays a string).
        public let open: String
        /// Depth-zero separators that start the format spec (":",
        /// python; ":" and "," (alignment), C#). The spec — separators
        /// included — is emitted as one string token.
        public let specSeparators: Set<Character>
        /// A doubled opener is a literal brace ("{{") — python and C#
        /// regular interpolated strings.
        public let doubling: Bool
        /// Interpolation continues on the ladder's continuation lines.
        /// False for C#: its interpolating multi-line forms ($"""/$$""")
        /// have different brace semantics — deferred.
        public let multiline: Bool
        /// Python: a backslash does not swallow a following opener —
        /// CPython keeps the backslash as text and still opens the
        /// field (f"\{x}" interpolates). Elsewhere "\{" / "\$" escapes
        /// the opener into text.
        public let openAfterBackslash: Bool
        public let gate: InterpolationGate
    }

    /// Per-language syntax profile: multi-line string rules, the
    /// single-line comment syntax and soft keywords, resolved in one
    /// place per file extension. Languages without soft keywords keep
    /// the empty default — the tokenizer skips the check entirely.
    ///
    /// `lineComment` is the SINGLE AUTHORITY for the line-comment token:
    /// both the tokenizer's comment branch and the editor's visual `/`
    /// (CommentToggle) read it. Explicit nil — the language has no line
    /// comment, or the extension is not a language this editor knows
    /// (json, markdown, plain text, no extension): the honest "none"
    /// beats a guessed "//" that unknown files used to inherit from
    /// `.default`.
    public struct LanguageSyntax: Sendable {
        public let mlRules: [MultilineStringRule]
        public let lineComment: String?
        /// POSIX shell: "#" comments only where a word begins — `${#arr}`,
        /// `$#`, `x=1#c` are not comments. Python hashes comment anywhere.
        public let lineCommentAtWordStartOnly: Bool
        public var softKeywords: Set<String> = []
        /// String-prefix letters glued to the opening quote (python
        /// f/r/b/u, C# $/@, dart r/R): the prefix belongs to the string
        /// token. Empty — the language has none.
        public var stringPrefixChars: Set<Character> = []
        /// Replacement-field scanning; nil — the language has no
        /// interpolation (rust, go, the C family) or it is deferred
        /// (dart/shell `$ident` shorthands, shell `$(...)`).
        public var interpolation: InterpolationRule? = nil

        public static let `default` = LanguageSyntax(mlRules: [], lineComment: nil, lineCommentAtWordStartOnly: false)
    }

    /// A replacement field must close on its own line, and no real one
    /// approaches this length. The cap bounds the field matcher's scan
    /// so a pathological line of UNMATCHED openers (machine-generated
    /// or adversarial — each bail would otherwise rescan to end of
    /// line, quadratic per draw) stays linear-time. Past the cap the
    /// field is malformed by definition — the opener degrades to text
    /// (INV1): never a crash, never a state change, per-line only.
    static let fieldScanLimit = 512

    /// VS Code parity (TokenizationSupportWithLineLimit): lines at or
    /// beyond this many graphemes are not tokenized at all — plain
    /// text, and the ladder state passes through UNCHANGED (the state
    /// at the beginning of the line is returned, exactly like VS
    /// Code's nullTokenizeEncoded; a multiline string stays open until
    /// its next real delimiter). The render walk is already windowed
    /// by the visible width — this guard leaves tokenization the last
    /// unbounded per-draw cost on a huge line and removes it.
    static let lineTokenizeLimit = 20_000

    /// Merges one line's syntactic (builtin) tokens with its LSP semantic
    /// tokens. LSP wins on overlap — except inside builtin string tokens:
    /// a server token NESTED in a string token is swallowed (strings are
    /// the builtin layer's domain — pyright leaves their coloring to
    /// syntax highlighting; this also dedupes string tokens from servers
    /// that do emit them). Interpolating strings are SEGMENTED (string
    /// chunks + code tokens for the field expressions), so a server's
    /// interpolation tokens now overlap the builtin code tokens and
    /// replace them cleanly; the swallow rule keeps protecting the
    /// string chunks. An LSP token STRADDLING a chunk boundary evicts
    /// the chunk and may leave an uncolored gap — accepted: eviction can
    /// already leave gaps for any token kind (provenance over coverage
    /// — output tokens are never invented); if a real server ever
    /// straddles, the fix belongs in the LSP span conversion, not here.
    /// Returns tokens sorted by startChar with no overlaps.
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
                stringPrefixChars: ["f", "F", "r", "R", "b", "B", "u", "U"],
                interpolation: InterpolationRule(
                    open: "{", specSeparators: [":"], doubling: true,
                    multiline: true, openAfterBackslash: true,
                    gate: .prefix(["f", "F"])))
        case "swift":
            syntax = LanguageSyntax(
                mlRules: [MultilineStringRule(open: "\"\"\"", close: "\"\"\"", escapes: true)],
                lineComment: "//", lineCommentAtWordStartOnly: false,
                interpolation: InterpolationRule(
                    open: "\\(", specSeparators: [], doubling: false,
                    multiline: true, openAfterBackslash: false,
                    gate: .always))
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
            // multiline:false — the interpolating multi-line forms
            // ($""" / $$""") use single-brace fields; deferred.
            syntax = LanguageSyntax(
                mlRules: [
                    MultilineStringRule(open: "\"\"\"", close: "\"\"\"", escapes: true),
                    MultilineStringRule(open: "@\"", close: "\"", escapes: true),
                ],
                lineComment: "//", lineCommentAtWordStartOnly: false,
                stringPrefixChars: ["$", "@"],
                interpolation: InterpolationRule(
                    open: "{", specSeparators: [":", ","], doubling: true,
                    multiline: false, openAfterBackslash: true,
                    gate: .prefix(["$"])))
        case "sh", "bash":
            syntax = LanguageSyntax(
                mlRules: [], lineComment: "#", lineCommentAtWordStartOnly: true,
                interpolation: InterpolationRule(
                    open: "${", specSeparators: [], doubling: false,
                    multiline: false, openAfterBackslash: false,
                    gate: .quote(["\""])))
        case "yaml", "yml", "toml":
            syntax = LanguageSyntax(mlRules: [], lineComment: "#", lineCommentAtWordStartOnly: false)
        case "rb":
            syntax = LanguageSyntax(
                mlRules: [], lineComment: "#", lineCommentAtWordStartOnly: false,
                interpolation: InterpolationRule(
                    open: "#{", specSeparators: [], doubling: false,
                    multiline: false, openAfterBackslash: false,
                    gate: .quote(["\""])))
        case "js", "ts", "jsx", "tsx":
            // Template literals: may span lines (hence the ml rule) and
            // interpolate ${…} inside backticks only.
            syntax = LanguageSyntax(
                mlRules: [MultilineStringRule(open: "`", close: "`", escapes: true)],
                lineComment: "//", lineCommentAtWordStartOnly: false,
                interpolation: InterpolationRule(
                    open: "${", specSeparators: [], doubling: false,
                    multiline: true, openAfterBackslash: false,
                    gate: .quote(["`"])))
        case "dart":
            syntax = LanguageSyntax(
                mlRules: [], lineComment: "//", lineCommentAtWordStartOnly: false,
                stringPrefixChars: ["r", "R"],
                interpolation: InterpolationRule(
                    open: "${", specSeparators: [], doubling: false,
                    multiline: false, openAfterBackslash: false,
                    gate: .prefixExcluding(["r", "R"])))
        // The C family keeps the shared profile shape (no ml rules of
        // their own, "//" comments) — explicit so that "known language"
        // and ".default's unknown file" stay distinguishable: only a
        // listed extension carries a comment token.
        case "c", "h", "cpp", "cc", "cxx", "hpp", "hxx":
            syntax = LanguageSyntax(mlRules: [], lineComment: "//", lineCommentAtWordStartOnly: false)
        default:
            syntax = .default
        }
        // Longest opener first so """ wins over " and @" at the same position
        let sorted = LanguageSyntax(
            mlRules: syntax.mlRules.sorted { $0.open.count > $1.open.count },
            lineComment: syntax.lineComment,
            lineCommentAtWordStartOnly: syntax.lineCommentAtWordStartOnly,
            softKeywords: syntax.softKeywords,
            stringPrefixChars: syntax.stringPrefixChars,
            interpolation: syntax.interpolation)
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

    /// Extends the multi-line-string state ladder to cover line
    /// `through` (entry N — the state AFTER line N; line N is
    /// tokenized starting from states[N - 1]). The pure extend-only
    /// half of the ladder: the editor owns invalidation on edits
    /// (truncating from the edit line down), the preview's content is
    /// immutable so its ladder never invalidates. States come from
    /// tokenize's string scanning — keywords and literals do not
    /// affect them, but tokenize needs them, so they pass through
    /// (token arrays are built and discarded; that is the editor's
    /// own cost profile too, kept for parity). `line` may exceed the
    /// buffer — the walk stops at the last line (callers of the
    /// editor clamp; the preview's Session does not need to).
    /// PERFORMANCE: callers pass the ladder as inout of a STORED
    /// property of a class instance — a direct address, in-place
    /// appends. Routing it through a computed accessor would make
    /// every call copy-in-copy-out the whole array (a regression the
    /// editor has already lived through once).
    public static func extendStringStates(
        _ states: inout [MultilineStringState],
        through line: Int,
        buffer: PieceTable,
        keywords: Set<String>,
        literals: Set<String>,
        syntax: LanguageSyntax
    ) {
        while states.count <= line {
            let idx = states.count
            if idx >= buffer.lineCount { break }
            let initial: MultilineStringState = idx == 0 ? .none : states[idx - 1]
            let endState = tokenize(chars: buffer.getLineChars(idx), lineNum: idx,
                                    keywords: keywords, syntax: syntax,
                                    initialState: initial, literals: literals).endState
            states.append(endState)
        }
    }

    public static func tokenize(chars: [Character], lineNum: Int, keywords: Set<String>,                          syntax: LanguageSyntax = .default,
                          initialState: MultilineStringState = .none,
                          literals: Set<String> = []) -> (tokens: [SemanticToken], endState: MultilineStringState) {
        // The huge-line guard (see lineTokenizeLimit). Placed before
        // everything: zero work, state passthrough.
        if chars.count >= SyntaxTokenizer.lineTokenizeLimit {
            return ([], initialState)
        }
        var tokens = [SemanticToken]()
        let len = chars.count
        var i = 0
        var state = initialState
        // Total field-matching allowance for this line — the
        // deterministic analogue of VS Code's per-call tokenization
        // budget. Each unmatched opener burns up to fieldScanLimit
        // before bailing; a line of machine-junk openers would burn
        // 512×n. The budget stops that early: past it, openers degrade
        // to plain text (INV1) and the worst case is bounded by ~3·n
        // regardless of input. Real lines never approach it — a line's
        // legitimate field content is at most its own length.
        var fieldScanBudget = 2 * len + 4096

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

        // The one quoted-literal skipper: from just past an opening
        // quote to just past its closing quote, escapes honored (even
        // in raw literals — CPython: a raw string cannot end in a
        // backslash). Unterminated (or a trailing backslash) — len:
        // the result never leaves the line. Single authority for both
        // the string terminator and the field matcher's nested-literal
        // skip — the two must never drift apart (`f"{s.replace('a',
        // '}')}"` depends on both agreeing what a literal is).
        func scanQuotedEnd(from: Int, quote: Character) -> Int {
            var k = from
            while k < len {
                if chars[k] == "\\" { k += 2; continue }
                if chars[k] == quote { return k + 1 }
                k += 1
            }
            return len
        }

        // Does this string occurrence interpolate? `prefix` — the
        // prefix letters glued to the opening quote; `quote` — its
        // quote character; `multiline` — the caller's form (single-line
        // strings are unrestricted, ladder forms require rule.multiline).
        func interpolationActive(_ rule: InterpolationRule, prefix: String,
                                 quote: Character, multiline: Bool) -> Bool {
            if multiline && !rule.multiline { return false }
            switch rule.gate {
            case .always: return true
            case .prefix(let set): return prefix.contains { set.contains($0) }
            case .prefixExcluding(let set): return !prefix.contains { set.contains($0) }
            case .quote(let set): return set.contains(quote)
            }
        }

        // Finds the replacement field opened at `from` (just past the
        // opener). Depth runs over all three bracket kinds; nested
        // string literals are skipped whole (a `}` inside `'}'` must
        // not close the field). The field closes where the running
        // depth first goes NEGATIVE. Spec separators count only at
        // depth zero (PEP 498's rule). Nil — unmatched, past
        // fieldScanLimit, or the line's scan budget is spent: the
        // caller degrades the opener to plain text. Whatever happened,
        // the consumed allowance is booked to the budget.
        func matchField(_ rule: InterpolationRule, from: Int) -> (specStart: Int?, closeAt: Int)? {
            let allowance = min(SyntaxTokenizer.fieldScanLimit, fieldScanBudget)
            guard allowance > 0 else { return nil }
            var k = from
            let limit = min(len, from + allowance)
            var depth = 0
            var specStart: Int? = nil
            var result: (specStart: Int?, closeAt: Int)? = nil
            while k < limit {
                let ch = chars[k]
                if ch == "\"" || ch == "'" {
                    k = scanQuotedEnd(from: k + 1, quote: ch)
                    continue
                }
                if ch == "(" || ch == "[" || ch == "{" { depth += 1; k += 1; continue }
                if ch == ")" || ch == "]" || ch == "}" {
                    depth -= 1
                    if depth < 0 {
                        result = (specStart, k)
                        break
                    }
                    k += 1
                    continue
                }
                if depth == 0 && specStart == nil && rule.specSeparators.contains(ch) {
                    specStart = k
                }
                k += 1
            }
            fieldScanBudget -= (k - from)
            return result
        }

        // The interpolated-string body scan — the single shared engine
        // behind every language's InterpolationRule.
        //
        // INV1 — this scan is the SOLE owner of string termination: the
        // close delimiter is checked before anything else each step;
        // the field matcher never decides termination. An unmatched
        // opener degrades to plain text and scanning resumes right
        // after it (self-healing on the next delimiter).
        //
        // INV2 — expression sub-scans run with initialState .none and
        // their endState is DISCARDED: the ladder is driven only by
        // this outer scan, so a pathological field can never corrupt it.
        //
        // Emission: text chunks → string; opener → punctuation;
        // expression → recursive tokenize (ordinary code tokens);
        // spec (separators included) → string; closer → punctuation.
        // Returns the index just past the closing delimiter, or nil
        // when the string runs to end of line (trailing chunk emitted).
        func scanInterpolated(_ rule: InterpolationRule, from: Int,
                              chunkStart: Int, close: String) -> Int? {
            var j = from
            var chunk = chunkStart
            func emitString(_ to: Int) {
                if to > chunk {
                    tokens.append(SemanticToken(line: lineNum, startChar: chunk,
                                                length: to - chunk, type: "string", modifiers: 0))
                }
            }
            while j < len {
                // 1 — close delimiter first: the body scan owns termination.
                if matches(close, at: j) {
                    emitString(j + close.count)
                    return j + close.count
                }
                // 2 — the interpolation trigger, checked BEFORE escape
                //     handling: swift's trigger itself starts with a
                //     backslash and would otherwise be eaten as a pair.
                if matches(rule.open, at: j) {
                    // A doubled opener is a literal brace ("{{").
                    if rule.doubling && matches(rule.open, at: j + rule.open.count) {
                        j += rule.open.count * 2
                        continue
                    }
                    if let field = matchField(rule, from: j + rule.open.count) {
                        let openEnd = j + rule.open.count
                        emitString(j)
                        tokens.append(SemanticToken(line: lineNum, startChar: j,
                                                    length: rule.open.count, type: "interpolation", modifiers: 0))
                        // The expression, as ordinary code (INV2).
                        let exprEnd = field.specStart ?? field.closeAt
                        if exprEnd > openEnd {
                            let inner = tokenize(chars: Array(chars[openEnd..<exprEnd]),
                                                 lineNum: lineNum, keywords: keywords,
                                                 syntax: syntax, initialState: .none,
                                                 literals: literals).tokens
                            for t in inner {
                                tokens.append(SemanticToken(
                                    line: lineNum, startChar: t.startChar + openEnd,
                                    length: t.length, type: t.type, modifiers: 0))
                            }
                        }
                        // The format spec — separators included — stays string.
                        if let sp = field.specStart, field.closeAt > sp {
                            tokens.append(SemanticToken(line: lineNum, startChar: sp,
                                                        length: field.closeAt - sp,
                                                        type: "string", modifiers: 0))
                        }
                        tokens.append(SemanticToken(line: lineNum, startChar: field.closeAt,
                                                    length: 1, type: "interpolation", modifiers: 0))
                        j = field.closeAt + 1
                        chunk = j
                        continue
                    }
                    // INV1 bail: the opener is plain text; resume right after it.
                    j += 1
                    continue
                }
                // 3 — escapes. Python twist: a backslash does not swallow
                //     a following opener (CPython keeps the backslash as
                //     text and still opens the field — f"\{x}").
                if chars[j] == "\\" {
                    if rule.openAfterBackslash && matches(rule.open, at: j + 1) {
                        j += 1
                        continue
                    }
                    j += 2
                    continue
                }
                j += 1
            }
            emitString(len)
            return nil
        }

        // Continuation of a multi-line string opened on a previous line
        if case .active(let ruleIndex, let interpolating) = state {
            let rule = syntax.mlRules[ruleIndex]
            if interpolating, let irule = syntax.interpolation {
                // Same engine, chunk from column 0; INV1/INV2 hold — an
                // unclosed field degrades to text, the ladder is untouched.
                if let after = scanInterpolated(irule, from: 0, chunkStart: 0, close: rule.close) {
                    i = after
                    state = .none
                } else {
                    return (tokens, state)
                }
            } else if let (_, after) = scanClose(rule, from: 0) {
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
            // `first` binds instead of `!` — an (internal-only) profile with
            // an empty lineComment must degrade to "no comments", not trap.
            if let lineComment = syntax.lineComment, let first = lineComment.first,
               chars[i] == first,
               matches(lineComment, at: i),
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

            // String prefixes (python f/r/b/u, C# $/@, dart r/R — any
            // combo): a prefix-only word directly abutting a quote makes
            // the whole literal one string token — `f"x"`, `rb'…'`,
            // `f"""…"""`. Adjacency matters: `f "x"` keeps `f` a plain
            // identifier.
            var prefixEnd = i
            if !syntax.stringPrefixChars.isEmpty, syntax.stringPrefixChars.contains(chars[i]) {
                var p = i + 1
                while p < len, syntax.stringPrefixChars.contains(chars[p]) { p += 1 }
                if p < len, chars[p] == "\"" || chars[p] == "'" { prefixEnd = p }
            }

            // The string's prefix letters (f, $@, r…) — one computation
            // for both gates below.
            let stringPrefix = prefixEnd > i ? String(chars[i..<prefixEnd]) : ""

            // Multi-line string openers (checked before the single-line branch
            // so """ wins over " and @" over "). Rules are per file extension:
            // python files never scan for rust-style " strings and vice versa.
            // The first-character pre-check keeps per-char cost at a compare.
            // The opener normally sits at `prefixEnd` (a prefix glued to it);
            // when the prefix scan swallowed an opener's leading letters
            // (C# `@"`), the rules are retried at `i` — the token starts at
            // the prefix either way.
            var matchedRule: (index: Int, rule: MultilineStringRule, openAt: Int)?
            let c = chars[prefixEnd]
            for (idx, rule) in syntax.mlRules.enumerated()
            where rule.open.first == c && matches(rule.open, at: prefixEnd) {
                matchedRule = (idx, rule, prefixEnd)
                break
            }
            if matchedRule == nil, prefixEnd > i {
                for (idx, rule) in syntax.mlRules.enumerated()
                where rule.open.first == chars[i] && matches(rule.open, at: i) {
                    matchedRule = (idx, rule, i)
                    break
                }
            }
            if let m = matchedRule {
                // The gate sees the prefix letters BEFORE the opener — for
                // an opener matched at `i` (@"…) there are none.
                let gatePrefix = m.openAt == prefixEnd ? stringPrefix : ""
                let activeRule: InterpolationRule? = {
                    guard let r = syntax.interpolation,
                          interpolationActive(r, prefix: gatePrefix,
                                              quote: m.rule.open.last ?? "\"",
                                              multiline: true) else { return nil }
                    return r
                }()
                if let r = activeRule {
                    if let after = scanInterpolated(r, from: m.openAt + m.rule.open.count,
                                                    chunkStart: i, close: m.rule.close) {
                        i = after
                    } else {
                        return (tokens, .active(ruleIndex: m.index, interpolating: true))
                    }
                    continue
                }
                if let (_, after) = scanClose(m.rule, from: m.openAt + m.rule.open.count) {
                    tokens.append(SemanticToken(line: lineNum, startChar: i, length: after - i, type: "string", modifiers: 0))
                    i = after
                } else {
                    tokens.append(SemanticToken(line: lineNum, startChar: i, length: len - i, type: "string", modifiers: 0))
                    return (tokens, .active(ruleIndex: m.index, interpolating: false))
                }
                continue
            }

            if c == "\"" || c == "'" {
                let quote = c
                if let r = syntax.interpolation,
                   interpolationActive(r, prefix: stringPrefix,
                                       quote: quote, multiline: false) {
                    // Emits the whole literal — closing chunk on this
                    // line, trailing chunk at end of line (INV1).
                    i = scanInterpolated(r, from: prefixEnd + 1, chunkStart: i,
                                         close: String(quote)) ?? len
                    continue
                }
                // Escapes are honored even for raw prefixes: a backslash
                // still escapes the quote for termination purposes (a raw
                // literal cannot end in a backslash), matching CPython —
                // the shared scanQuotedEnd (never past the line's end).
                let end = scanQuotedEnd(from: prefixEnd + 1, quote: quote)
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
        // The huge-line guard — a minified one-line JSON is THE giant
        // line case; plain text beats a full pass per draw.
        if chars.count >= lineTokenizeLimit { return [] }
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
