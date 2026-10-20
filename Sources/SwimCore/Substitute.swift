import Foundation

/// Vim-style `:substitute` — the pure half of the feature: parsing the
/// command line, translating vim's magic-mode regex dialect into ICU
/// terms (Swift's regex engine), and planning the per-match edits over
/// a buffer's lines in the Piece Table's BYTE coordinates. The editor
/// applies the plan (EditorWindow.runSubstitute); everything here is
/// side-effect-free and pinned by Tests/SwimCoreTests.
///
/// Scope (deliberate, documented in ARCHITECTURE.md):
/// - the line scope is the WHOLE buffer by default — `%` is accepted
///   and ignored (a deviation: in vim a bare `:s` works on the
///   current line only); the alternative is the selection marks
///   `'<` / `'>` / `'<,'>` — visual mode's `s` prefills `'<,'>s/`,
///   and a blockwise selection additionally restricts matches to the
///   block's column band (byte windows in `edits`);
/// - flags: `g` (every occurrence in a line; without it — the first
///   one), `i` (ignore case), `c` (confirm each substitution);
/// - a pattern never matches across lines: every line is scanned on
///   its own, so `\n` in the pattern cannot match;
/// - patterns are in vim's DEFAULT magic dialect (`\(…\)` groups,
///   `\|` alternation, bare `( ) { }` are literals) — translated
///   bidirectionally to ICU (see translatePattern);
/// - replacement: `\0`…`\9` and `&` = the whole match, `\r` = a line
///   break (vim's rule — \r is what breaks the line), `\t` = a tab,
///   `\&`/`\\`/`\<separator>` are their literals; an unknown `\x` is
///   the literal x (:h sub-replace-special);
/// - NOT supported, each rejected where the syntax allows it: the
///   magic-mode prefixes `\v` `\m` `\M` `\V` (ICU would silently read
///   them as its own escapes — `\v` is a vertical tab there), and the
///   rest vim itself calls something else (`\zs`, `\{-n,m}` → the ICU
///   compile fails and the editor reports "Invalid pattern"). Also
///   out: `~` (previous replacement), `\u\l\U\L\E` case modifiers,
///   the `\n`→NUL vim quirk, the `I` flag, `\c`/`\C` inline case
///   controls, line ranges/addresses, an empty pattern reusing the
///   last search.
public enum Substitute {

    // MARK: - Command line

    /// A parsed `:s` command: the fields exactly as typed plus the
    /// resolved flags and the line scope.
    public struct Command: Equatable {
        /// Which lines the command covers. `wholeBuffer` is what `%`
        /// (or no prefix) means; the selection* forms come from the
        /// `'<`/`'>` prefixes — visual mode's `s` prefills `'<,'>s/`
        /// and the editor resolves the marks from the selection that
        /// armed the command line (a scope that lives exactly one
        /// command session — see EditorWindow.pendingSubstituteScope).
        public enum Scope: Equatable {
            case wholeBuffer
            case selectionStart     // '< — the selection's first line
            case selectionEnd       // '> — the selection's last line
            case selectionRange     // '<,'> — the selection's lines
        }
        public let pattern: String
        public let replacement: String
        public let global: Bool       // g — every occurrence in a line
        public let ignoreCase: Bool   // i
        public let confirm: Bool      // c — ask before each substitution
        public let scope: Scope
        public init(pattern: String, replacement: String,
                    global: Bool, ignoreCase: Bool, confirm: Bool,
                    scope: Scope = .wholeBuffer) {
            self.pattern = pattern
            self.replacement = replacement
            self.global = global
            self.ignoreCase = ignoreCase
            self.confirm = confirm
            self.scope = scope
        }
    }

    /// Parses a command line typed after `:` (the colon itself is not
    /// part of `raw`). Returns nil for anything that is not a `:s`
    /// command — the caller then falls through to its other dispatch
    /// branches (`w`, `e`, `/query`, a line number, window
    /// management).
    ///
    ///     "%s/a/b/gc"    → Command(a, b, global, confirm)
    ///     "'<,'>s/a/b/g" → the same, scoped to the selection's lines
    ///     "s,a,b,"       → the same, comma separator
    ///     "su/a/b/"      → any prefix of "substitute" names the command
    ///     "s/a\\/b/c/"   → a literal slash inside a field
    ///     "5", "wq", "/x", "sh" → nil (somebody else's command)
    ///
    /// Total: no input crashes the parser. The only digits it reads
    /// are single `\0`…`\9` back references in the replacement —
    /// there is no numeric accumulation anywhere.
    public static func parse(_ raw: String) -> Command? {
        let chars = Array(raw)
        var i = 0

        func skipSpaces() {
            while i < chars.count, chars[i] == " " { i += 1 }
        }

        skipSpaces()
        // '%' addresses the whole buffer — which is the only built-in
        // range, so it is accepted and ignored. The alternative prefix
        // is the selection marks (visual mode's `s` prefills
        // `'<,'>s/`): only the exact forms `'<`, `'>` and `'<,'>` —
        // numeric/offset addresses are out of scope, and a backwards
        // pair ('>,'<) is simply not one of the forms.
        var scope = Command.Scope.wholeBuffer
        func peekMark() -> Character? {
            guard i + 1 < chars.count, chars[i] == "'" else { return nil }
            let m = chars[i + 1]
            return (m == "<" || m == ">") ? m : nil
        }
        if i < chars.count, chars[i] == "%" {
            i += 1
        } else if let first = peekMark() {
            i += 2
            if first == "<" {
                skipSpaces()
                if i < chars.count, chars[i] == "," {
                    i += 1
                    skipSpaces()
                    guard let second = peekMark(), second == ">" else { return nil }
                    i += 2
                    scope = .selectionRange
                } else {
                    scope = .selectionStart
                }
            } else {
                scope = .selectionEnd
            }
        }
        skipSpaces()

        // The command token: any prefix of "substitute" (vim's
        // command-line rule). A command like `sh` fails here on the
        // separator check below — 'h' is a letter — and stays the
        // shell command.
        let full = Array("substitute")
        var token = 0
        while token < full.count, i + token < chars.count,
              chars[i + token] == full[token] { token += 1 }
        guard token >= 1 else { return nil }
        i += token
        skipSpaces()

        // The separator: any character vim allows — not a letter, a
        // digit, a space, a backslash or a double quote.
        guard i < chars.count else { return nil }   // bare :s (repeat) is not supported
        let sep = chars[i]
        guard !sep.isLetter, !sep.isNumber, sep != " ",
              sep != "\\", sep != "\"" else { return nil }
        i += 1

        // Fields, backslash-escape aware. Everything after the second
        // unescaped separator is the flags field — a separator there
        // is simply an unknown flag character. A command without
        // trailing separators closes each open field at the end
        // (`s/a` == `s/a//`).
        var pattern = ""
        var replacement = ""
        var tail = ""
        var field = 0    // 0 = pattern, 1 = replacement, 2 = flags
        var cur = ""
        while i < chars.count {
            let c = chars[i]
            if field < 2, c == "\\", i + 1 < chars.count {
                cur.append(c); cur.append(chars[i + 1]); i += 2; continue
            }
            if field < 2, c == sep {
                if field == 0 { pattern = cur } else { replacement = cur }
                field += 1; cur = ""; i += 1; continue
            }
            cur.append(c); i += 1
        }
        if field == 0 { pattern = cur } else if field == 1 { replacement = cur }
        else { tail = cur }

        var global = false, ignoreCase = false, confirm = false
        for f in tail where f != " " {
            switch f {
            case "g": global = true
            case "i": ignoreCase = true
            case "c": confirm = true
            default: return nil    // unknown flag — not a :s command
            }
        }
        return Command(pattern: pattern, replacement: replacement,
                       global: global, ignoreCase: ignoreCase,
                       confirm: confirm, scope: scope)
    }

    // MARK: - Pattern translation (vim magic → ICU)

    public enum PatternError: Error, Equatable {
        /// A magic-mode prefix (`\v`, `\m`, `\M`, `\V`). Rejected
        /// explicitly: ICU would silently read them as its own escapes
        /// (`\v` is a vertical tab there) and the pattern would match
        /// something the user never wrote.
        case magicModePrefix(Character)
    }

    /// Translates a vim default-magic pattern into an ICU one — the
    /// two directions of the same historical inversion:
    /// - `\(`, `\)`, `\|`, `\+`, `\?`, `\{` are SPECIAL in vim →
    ///   become bare in ICU;
    /// - bare `(`, `)`, `+`, `?`, `|`, `{` are LITERALS in vim → get
    ///   escaped in ICU (a bare `}` stays bare: it is literal in ICU
    ///   too, and it must close a `\{n,m}` quantifier as-is);
    /// - `\<` and `\>` (word boundaries) → `\b`.
    /// Inside a bracket class `[...]` nothing is translated — the
    /// class syntax is shared with ICU, POSIX `[[:alpha:]]` included;
    /// a `]` right after `[` or `[^` is a member, not the closer.
    public static func translatePattern(_ raw: String) -> Result<String, PatternError> {
        var out = ""
        out.reserveCapacity(raw.count)
        let chars = Array(raw)
        var i = 0
        var inClass = false
        var classMembers = 0    // member chars since the class opened ('^' is not one)
        while i < chars.count {
            let c = chars[i]
            if inClass {
                if c == "\\", i + 1 < chars.count {
                    out.append(c); out.append(chars[i + 1]); classMembers += 1; i += 2; continue
                }
                if c == "]", classMembers > 0 { inClass = false; out.append(c); i += 1; continue }
                out.append(c); classMembers += 1; i += 1; continue
            }
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "(", ")", "|", "+", "?", "{":
                    out.append(n)                    // special in vim → bare in ICU
                case "<", ">":
                    out.append("\\b")                // word boundaries
                case "v", "m", "M", "V":
                    return .failure(.magicModePrefix(n))
                case "\\":
                    out.append("\\\\")               // a literal backslash
                default:
                    out.append(c); out.append(n)     // \d \s \w \1 \. \/ … — same in ICU
                }
                i += 2; continue
            }
            if c == "[" {
                inClass = true; classMembers = 0; out.append(c); i += 1
                if i < chars.count, chars[i] == "^" { out.append("^"); i += 1 }
                continue
            }
            switch c {
            case "(", ")", "+", "?", "|", "{":
                out.append("\\"); out.append(c)      // literal in vim → escaped in ICU
            default:
                out.append(c)
            }
            i += 1
        }
        return .success(out)
    }

    // MARK: - Replacement translation

    /// One piece of a replacement: literal text, or a capture-group
    /// reference (0 = the whole match — what `&` and `\0` mean).
    public enum Segment: Equatable {
        case literal(String)
        case group(Int)
    }

    /// Splits a raw replacement into segments; `expand` turns them
    /// into the final text per match. Kept from vim's replacement
    /// grammar: `\0`…`\9` and `&` = the whole match, `\r` = a LINE
    /// BREAK, `\t` = a tab, `\&`/`\\`/`\<any other>` are their
    /// literals (an unknown `\x` is the literal x — :h
    /// sub-replace-special). Expanding is done here, not through an
    /// ICU template — that is what keeps `&`, `\r` and bare `$`/`~`
    /// behaving exactly like the vim rules above.
    public static func translateReplacement(_ raw: String) -> [Segment] {
        var segments: [Segment] = []
        var literal = ""
        func flush() {
            if !literal.isEmpty { segments.append(.literal(literal)); literal = "" }
        }
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "0"..."9": flush(); segments.append(.group(Int(String(n))!))
                case "&": literal.append("&")
                case "r": literal.append("\n")
                case "t": literal.append("\t")
                case "\\": literal.append("\\")
                default: literal.append(n)     // \/, \q, … — the literal character
                }
                i += 2; continue
            }
            if c == "&" { flush(); segments.append(.group(0)); i += 1; continue }
            literal.append(c); i += 1
        }
        flush()
        return segments
    }

    /// The highest capture-group index a replacement references —
    /// checked against the compiled pattern BEFORE any edit is
    /// applied (vim's E65 "Illegal back reference").
    public static func maxGroup(in segments: [Segment]) -> Int {
        segments.reduce(0) { acc, seg in
            if case .group(let n) = seg { return max(acc, n) } else { return acc }
        }
    }

    /// The replacement text for one match. A reference to a group the
    /// pattern does not have expands to nothing (the editor guards
    /// this with maxGroup beforehand; kept defensive for direct
    /// callers).
    public static func expand(_ segments: [Segment], line: String,
                              match: NSTextCheckingResult) -> String {
        var out = ""
        for seg in segments {
            switch seg {
            case .literal(let s): out += s
            case .group(let g):
                // numberOfRanges counts the whole match at index 0 —
                // the capture groups are the rest
                guard g < match.numberOfRanges,
                      let r = Range(match.range(at: g), in: line) else { continue }
                out += String(line[r])
            }
        }
        return out
    }

    // MARK: - The edit plan

    /// One planned substitution, in the ORIGINAL buffer's byte
    /// coordinates (the Piece Table's currency). `line` is the
    /// 0-based line the match was found on — for the report. Edits
    /// from `edits(...)` are ascending by offset: the plain path
    /// applies them in reverse (an edit never shifts the offsets of
    /// the edits before it), the `c`-flag path walks them forward
    /// with a running byte delta.
    public struct Edit: Equatable {
        public let offset: Int
        public let length: Int
        public let replacement: String
        public let line: Int
        public init(offset: Int, length: Int, replacement: String, line: Int) {
            self.offset = offset
            self.length = length
            self.replacement = replacement
            self.line = line
        }
    }

    /// Plans the edits over whole lines — `text` WITHOUT the line
    /// terminator (so `$` anchors to the line's content end), `byteStart`
    /// = the line's start offset. The terminator strip is the CALLER's
    /// contract and must remove the FULL grapheme: on a CRLF file
    /// `"\r\n"` is one Swift Character, a `hasSuffix("\n")` strip leaks
    /// it in, and ICU's `\s` (which matches `\r` and `\n`) would plan
    /// to swallow it — joining lines. Without `global` only the first
    /// match of a line is taken. Zero-length matches are kept: vim
    /// reports `:s/^//` as a substitution even though no byte moves.
    /// ICU works in UTF-16; the match ranges are converted to bytes
    /// here, in the single place that owns both coordinate systems.
    ///
    /// `byteWindow` (bytes relative to the line start, nil = the whole
    /// line) restricts a line to a column band — the blockwise
    /// selection's territory: a match is kept only when it lies
    /// ENTIRELY inside the window (partially overlapping matches are
    /// skipped — a deterministic rule; a zero-length match is admitted
    /// on either boundary). This is how `'<,'>s` on a Ctrl+V block
    /// substitutes only inside the rectangle.
    public static func edits(lines: [(index: Int, text: String, byteStart: Int,
                                      byteWindow: Range<Int>?)],
                             regex: NSRegularExpression,
                             segments: [Segment],
                             global: Bool) -> [Edit] {
        var result: [Edit] = []
        for entry in lines {
            let found = regex.matches(in: entry.text,
                                      range: NSRange(entry.text.startIndex..., in: entry.text))
            let scan = global ? found[...] : found.prefix(1)
            for m in scan {
                guard let mr = Range(m.range, in: entry.text),
                      let lo = mr.lowerBound.samePosition(in: entry.text.utf8),
                      let hi = mr.upperBound.samePosition(in: entry.text.utf8) else { continue }
                let utf8 = entry.text.utf8
                let relLo = utf8.distance(from: utf8.startIndex, to: lo)
                let relHi = relLo + utf8.distance(from: lo, to: hi)
                if let w = entry.byteWindow {
                    guard relLo >= w.lowerBound, relHi <= w.upperBound else { continue }
                }
                result.append(Edit(
                    offset: entry.byteStart + relLo,
                    length: relHi - relLo,
                    replacement: expand(segments, line: entry.text, match: m),
                    line: entry.index))
            }
        }
        return result
    }

    // MARK: - Messages

    /// The command's summary — vim's wording, singular/plural included.
    public static func report(substitutions: Int, lines: Int) -> String {
        "\(substitutions) \(substitutions == 1 ? "substitution" : "substitutions")"
            + " on \(lines) \(lines == 1 ? "line" : "lines")"
    }

    /// The per-match question of the `c` flag — vim's wording. An
    /// empty replacement shows as an empty gap, exactly like vim.
    public static func confirmPrompt(replacement: String) -> String {
        "replace with \(replacement) (y/n/a/q/l)?"
    }
}
