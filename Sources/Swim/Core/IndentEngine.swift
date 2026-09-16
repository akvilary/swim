import Foundation

/// Pure newline-indent planner — no buffer, terminal or window dependencies.
/// Lexical heuristics, the same class of engine as vim `smartindent` or the
/// python pep8-indent `indentexpr`: a closing bracket aligns with the line
/// holding its matching opener (backward bracket-balance scan), never a
/// "one level less" guess. Strings/comments with unbalanced brackets can
/// still confuse it; a treesitter/LSP provider can later replace this
/// behind the same `plan(...)` contract.
enum IndentEngine {
    enum Shape: Equatable {
        /// Plain split: the cursor line gets `cursorIndent`.
        case plain(cursorIndent: Int)
        /// The closer moves to its own line at `bracketIndent`; the cursor
        /// rides that line before the bracket (no fresh line — no more
        /// content is coming).
        case closerOnly(bracketIndent: Int)
        /// The closer moves down AND a fresh line opens for the cursor
        /// between it and the current line (`{|` / `foo(|` — a body or an
        /// argument list is still about to be typed).
        case closerWithBody(cursorIndent: Int, bracketIndent: Int)
    }

    /// - Parameters:
    ///   - before: text of the line left of the cursor
    ///   - after: text of the line right of the cursor
    ///   - fullLine: the whole line (`before + after`)
    ///   - baseIndent: display width of the line's leading whitespace
    ///   - shiftWidth: one standard indent of the language
    ///   - tabWidth: tab stop used to measure leading tabs
    ///   - lineAbove: the n-th line above, nil past the top of the file
    static func plan(before: String,
                     after: String,
                     fullLine: String,
                     baseIndent: Int,
                     shiftWidth: Int,
                     tabWidth: Int,
                     lineAbove: (Int) -> String?) -> Shape {
        let afterTrimmed = after.trimmingCharacters(in: .whitespaces)
        guard afterTrimmed.hasPrefix(")") || afterTrimmed.hasPrefix("}") else {
            let trimmed = fullLine.trimmingCharacters(in: .whitespaces)
            let extra = trimmed.hasSuffix("{") || trimmed.hasSuffix("(") || trimmed.hasSuffix(":")
                ? shiftWidth : 0
            return .plain(cursorIndent: baseIndent + extra)
        }

        let bracketIndent = matchingOpenerIndent(before: before, tabWidth: tabWidth, lineAbove: lineAbove)
            ?? max(baseIndent - shiftWidth, 0)

        let beforeTrimmed = before.trimmingCharacters(in: .whitespaces)
        if beforeTrimmed.hasSuffix("{") || beforeTrimmed.hasSuffix("(") {
            return .closerWithBody(cursorIndent: bracketIndent + shiftWidth,
                                   bracketIndent: bracketIndent)
        }
        return .closerOnly(bracketIndent: bracketIndent)
    }

    /// Walks backwards from the cursor keeping a generic bracket balance
    /// (`(`/`{` open, `)`/`}` close); the first opener that tips the balance
    /// positive matches the closer at the cursor. Returns that line's
    /// indent, or nil when no opener exists above (unbalanced closer).
    private static func matchingOpenerIndent(before: String,
                                             tabWidth: Int,
                                             lineAbove: (Int) -> String?) -> Int? {
        var depth = 0
        var text = before
        var up = 0
        while true {
            for ch in text.reversed() {
                if ch == ")" || ch == "}" {
                    depth -= 1
                } else if ch == "(" || ch == "{" {
                    depth += 1
                    if depth > 0 {
                        return leadingWhitespaceWidth(text, tabWidth: tabWidth)
                    }
                }
            }
            guard let prev = lineAbove(up) else { return nil }
            text = prev
            up += 1
        }
    }

    private static func leadingWhitespaceWidth(_ str: String, tabWidth: Int) -> Int {
        var width = 0
        for c in str {
            if c == " " { width += 1 }
            else if c == "\t" { width += tabWidth }
            else { break }
        }
        return width
    }
}
