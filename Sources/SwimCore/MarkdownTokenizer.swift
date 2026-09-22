import Foundation

/// Markdown highlighting: a document-structure pass, distinct from the
/// per-line code tokenizer — it keeps viewport-scoped state (fenced code
/// blocks span lines) behind an opaque cache instead of per-line states.
public struct MarkdownTokenizer {
    /// Extension routing: files this tokenizer handles.
    public static func isMarkdown(_ ext: String) -> Bool {
        ext == "md" || ext == "markdown" || ext == "mdx"
    }

    /// Viewport cache: remembers where the last render stopped and the
    /// fenced-code-block state as of that line, so a scroll within 200
    /// lines resumes incrementally instead of rescanning from line 0.
    /// Fields are module-internal — the app target can hold and pass the
    /// cache but cannot poke its invariants.
    public struct Cache: Sendable {
        /// Exact buffer identity — a hash could collide between live
        /// buffers (open tabs) and wrongly validate the cache.
        var bufferId: ObjectIdentifier?
        var scrollY: Int = 0
        var inCodeBlock: Bool = false
        var lineCount: Int = 0

        public init() {}
    }

    /// Tokens for the visible viewport only. Toggling of fenced code
    /// blocks is tracked across lines: the pre-scan fast-forwards from
    /// the cached position to `scrollY`, then the render loop keeps the
    /// state moving through the window.
    public static func tokenizeVisible(buffer: PieceTable, scrollY: Int, height: Int, cache: inout Cache) -> [SemanticToken] {
        var allTokens = [SemanticToken]()
        let bufferId = ObjectIdentifier(buffer)
        let lineCount = buffer.lineCount
        var inCodeBlock = false

        let cacheValid = cache.bufferId == bufferId && lineCount == cache.lineCount && scrollY >= cache.scrollY && scrollY <= cache.scrollY + 200
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
            let chars = buffer.getLineChars(lineNum)
            allTokens.append(contentsOf: tokenizeLine(line, lineChars: chars, lineNum: lineNum, inCodeBlock: &inCodeBlock))
        }
        return allTokens
    }

    private static func tokenizeLine(_ line: String, lineChars chars: [Character], lineNum: Int, inCodeBlock: inout Bool) -> [SemanticToken] {
        var tokens = [SemanticToken]()
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
