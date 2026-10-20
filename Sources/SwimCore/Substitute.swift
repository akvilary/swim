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
///   current line only); the alternatives are the selection marks
///   `'<` / `'>` / `'<,'>` — visual mode's `s` prefills `'<,'>s/`, a
///   blockwise selection additionally restricts matches to the
///   block's column band (byte windows in `edits`) — and an explicit
///   range `:N[,M]`, `:.,$`, `:5,+2`, `:+3` … (addresses as typed;
///   `resolve` maps them to lines against the cursor and buffer);
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

    /// A line address as typed: `[N | . | $][+/-n]…`. The base is
    /// OPTIONAL — a bare +/- offset. For the FIRST address the parser
    /// defaults a missing base to `.` (the current line); for the
    /// SECOND a bare offset means "relative to the RESOLVED first
    /// line" — vim's rule (`:5,+2` is lines 5…7; base inheritance
    /// would instead read the second as current+2 and silently select
    /// the wrong lines — the review round's catch).
    public struct LineAddress: Equatable {
        public enum Base: Equatable {
            case number(Int)   // 1-based, as typed
            case current       // .
            case last          // $
        }
        public let base: Base?
        public let delta: Int
        public init(base: Base?, delta: Int) {
            self.base = base
            self.delta = delta
        }
    }

    /// Resolves an address pair to 0-based lines, clamped to the
    /// buffer. Nil — a backwards range (vim's E493; swim reports it
    /// instead of vim's interactive swap). A missing end — a single
    /// line. A line number past the end clamps to the last line; `:0`
    /// clamps to the first (vim's virtual line-0 is not reproduced).
    public static func resolve(_ start: LineAddress, _ end: LineAddress?,
                               currentLine: Int, lastLine: Int) -> ClosedRange<Int>? {
        func clamp(_ n: Int) -> Int { min(max(0, n), lastLine) }
        func line(_ a: LineAddress, offsetFallback: Int) -> Int {
            let base: Int
            switch a.base {
            case .number(let n): base = n - 1
            case .current: base = currentLine
            case .last: base = lastLine
            case nil: base = offsetFallback   // bare offset — relative to the resolved first
            }
            return clamp(base + a.delta)
        }
        let s = line(start, offsetFallback: currentLine)
        guard let e = end else { return s...s }
        let endLine = line(e, offsetFallback: s)
        guard s <= endLine else { return nil }
        return s...endLine
    }

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
            /// An explicit `:[N|.|$][+/-n][,…]` range — the addresses
            /// as typed; the editor resolves them against the cursor
            /// and the buffer (see `resolve`).
            case addressRange(start: LineAddress, end: LineAddress?)
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
    /// management). The grammar lives in the private `Scan` below —
    /// a cursor over the line whose methods are the productions.
    ///
    ///     "%s/a/b/gc"    → Command(a, b, global, confirm)
    ///     "'<,'>s/a/b/g" → the same, scoped to the selection's lines
    ///     "1,5s/a/b/"    → the same, scoped to lines 1–5
    ///     ".,$s/a/b/"    → current…last; "5,+2s" — the offset is
    ///                      relative to the resolved FIRST line
    ///     "s,a,b,"       → the same, comma separator
    ///     "su/a/b/"      → any prefix of "substitute" names the command
    ///     "s/a\\/b/c/"   → a literal slash inside a field
    ///     "5", "wq", "/x", "sh" → nil (somebody else's command)
    ///
    /// Total: no input crashes the parser. The numeric accumulations
    /// (line numbers and +/- offsets) are capped at 1_000_000, so a
    /// typed 99999999999999999999 cannot trap the Int; everything
    /// else reads only single `\0`…`\9` back references.
    public static func parse(_ raw: String) -> Command? {
        var s = Scan(raw)
        var scope = Command.Scope.wholeBuffer
        switch s.scanPrefix() {
        case .rejected: return nil
        case .scoped(let scanned): scope = scanned
        case .none: break                       // `s/a/b/` — no prefix, the whole buffer
        }
        guard s.scanToken(), let sep = s.scanSeparator() else { return nil }
        let fields = s.scanFields(separator: sep)
        var global = false, ignoreCase = false, confirm = false
        for f in fields.tail where f != " " {
            switch f {
            case "g": global = true
            case "i": ignoreCase = true
            case "c": confirm = true
            default: return nil    // unknown flag — not a :s command
            }
        }
        return Command(pattern: fields.pattern, replacement: fields.replacement,
                       global: global, ignoreCase: ignoreCase,
                       confirm: confirm, scope: scope)
    }

    /// A cursor over the command line — the grammar's only mutable
    /// state, extracted so that `parse` reads like the grammar and
    /// every production has a name: `skipSpaces`, `scanNumber`,
    /// `scanOffsets`, `scanMark`, `scanAddress` are the cursor
    /// primitives; `scanPrefix`, `scanToken`, `scanSeparator`,
    /// `scanFields` are the productions. Private to the file — the
    /// public API never leaks it.
    private struct Scan {
        let chars: [Character]
        var i = 0

        init(_ raw: String) { chars = Array(raw) }

        var atEnd: Bool { i >= chars.count }

        func peek() -> Character? { i < chars.count ? chars[i] : nil }

        mutating func skipSpaces() {
            while peek() == " " { i += 1 }
        }

        // MARK: Cursor primitives

        /// A capped digit run — the cap keeps a typed
        /// 99999999999999999999 from trapping the Int accumulator
        /// (resolve clamps the cap to the buffer anyway).
        mutating func scanNumber() -> Int? {
            var n = 0
            var any = false
            while let c = peek(), c.isASCII, c.isNumber {
                any = true
                n = min(n * 10 + (c.wholeNumberValue ?? 0), 1_000_000)
                i += 1
            }
            return any ? n : nil
        }

        /// A `+n`/`-n` run; a bare sign counts as ±1.
        mutating func scanOffsets() -> Int {
            var delta = 0
            while peek() == "+" || peek() == "-" {
                let sign = chars[i] == "+" ? 1 : -1
                i += 1
                delta += sign * (scanNumber() ?? 1)
            }
            return delta
        }

        /// The selection mark `'<` or `'>`, consumed — nil at anything
        /// else.
        mutating func scanMark() -> Character? {
            guard peek() == "'", i + 1 < chars.count else { return nil }
            let m = chars[i + 1]
            guard m == "<" || m == ">" else { return nil }
            i += 2
            return m
        }

        /// One address — a base (number / `.` / `$`), or none (a bare
        /// offset, or nothing before a leading comma). Out of input
        /// yields the empty shape; the range production rejects it.
        mutating func scanAddress() -> LineAddress {
            guard let c = peek() else { return LineAddress(base: nil, delta: 0) }
            let base: LineAddress.Base?
            if c == "." { base = .current; i += 1 }
            else if c == "$" { base = .last; i += 1 }
            else { base = scanNumber().map { .number($0) } }
            return LineAddress(base: base, delta: scanOffsets())
        }

        // MARK: Grammar productions

        /// The outcome of looking for a range prefix.
        enum Prefix {
            /// No prefix at all — `s/a/b/` is legal without one; the
            /// scope stays the whole buffer.
            case none
            /// The line is not a :s command at all.
            case rejected
            case scoped(Command.Scope)
        }

        /// Whether a character may OPEN an address (entry into the
        /// line-range branch; the leading comma means an
        /// implicit-current first address).
        static func isAddressStart(_ c: Character) -> Bool {
            (c.isASCII && c.isNumber) || c == "." || c == "$"
                || c == "+" || c == "-" || c == ","
        }

        /// `[range]` — `%`, the selection marks, or an explicit line
        /// range; mutually exclusive by first character. A bare
        /// address without the s-token still falls out at the token
        /// (`:5` stays the goto-line branch, `:1,5w` stays unknown).
        mutating func scanPrefix() -> Prefix {
            skipSpaces()
            if peek() == "%" {
                i += 1
                return .scoped(.wholeBuffer)
            }
            if let mark = scanMark() {
                guard mark == "<" else { return .scoped(.selectionEnd) }
                skipSpaces()
                guard peek() == "," else { return .scoped(.selectionStart) }
                i += 1
                skipSpaces()
                guard scanMark() == ">" else { return .rejected }
                return .scoped(.selectionRange)
            }
            guard let c = peek(), Scan.isAddressStart(c) else { return .none }
            // An explicit line range. Strictness below: a comma
            // demands a real second address — at the token or end of
            // input scanAddress yields the empty (nil base, 0 delta)
            // shape; vim's defaults for a missing address are
            // ambiguous, and a half-typed range must not guess
            // (`:5,` and `:,s` are not :s commands).
            let first = scanAddress()
            skipSpaces()
            var second: LineAddress? = nil
            if peek() == "," {
                i += 1
                skipSpaces()
                let scanned = scanAddress()
                guard scanned.base != nil || scanned.delta != 0 else { return .rejected }
                second = scanned
            }
            // The first address gets an explicit base: a bare offset
            // (`:+3s`) or the leading comma means the current line
            let start = first.base == nil
                ? LineAddress(base: .current, delta: first.delta) : first
            return .scoped(.addressRange(start: start, end: second))
        }

        /// `s`…`substitute` — any prefix of the full word names the
        /// command (vim's command-line rule; `:sh` fails the separator
        /// check next and stays the shell command).
        mutating func scanToken() -> Bool {
            skipSpaces()
            let full = Array("substitute")
            var token = 0
            while token < full.count, i + token < chars.count,
                  chars[i + token] == full[token] { token += 1 }
            guard token >= 1 else { return false }
            i += token
            return true
        }

        /// Any character vim allows as the field separator — not a
        /// letter, a digit, a space, a backslash or a double quote.
        /// A missing separator (a bare `:s`, the repeat form) is not
        /// supported.
        mutating func scanSeparator() -> Character? {
            skipSpaces()
            guard let sep = peek(), !sep.isLetter, !sep.isNumber, sep != " ",
                  sep != "\\", sep != "\"" else { return nil }
            i += 1
            return sep
        }

        /// The three fields, backslash-escape aware: pattern and
        /// replacement up to their unescaped separators; everything
        /// after the second separator is the flags tail (a separator
        /// there is simply an unknown flag character). Open fields
        /// close at the end of input — `s/a` == `s/a//`.
        mutating func scanFields(separator: Character)
            -> (pattern: String, replacement: String, tail: String) {
            var closed: [String] = []
            var cur = ""
            while !atEnd {
                let c = chars[i]
                if closed.count < 2, c == "\\", i + 1 < chars.count {
                    cur.append(c); cur.append(chars[i + 1]); i += 2; continue
                }
                if closed.count < 2, c == separator {
                    closed.append(cur); cur = ""; i += 1; continue
                }
                cur.append(c); i += 1
            }
            switch closed.count {
            case 0: return (pattern: cur, replacement: "", tail: "")
            case 1: return (pattern: closed[0], replacement: cur, tail: "")
            default: return (pattern: closed[0], replacement: closed[1], tail: cur)
            }
        }
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
