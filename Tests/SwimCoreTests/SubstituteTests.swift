import Foundation
import Testing
import SwimCore

/// Substitute — the pure half of vim-style `:s`:
/// command-line parsing (any prefix of "substitute", any vim-legal
/// separator, backslash-escaped fields), the bidirectional magic→ICU
/// pattern translation (vim's `\(` is a group while a bare `(` is a
/// literal — ICU is exactly the other way around), the replacement
/// segments (`\0`…`\9`, `&`, `\r` = a line break), and the edit plan
/// in the Piece Table's BYTE coordinates (ICU matches arrive in
/// UTF-16 — the conversion lives in one place and is pinned here on
/// Cyrillic and empty matches).
@Suite struct SubstituteTests {

    // MARK: - parse

    private func parsed(_ raw: String) -> Substitute.Command? {
        Substitute.parse(raw)
    }

    @Test func parseBasic() {
        let c = parsed("s/a/b/")
        #expect(c == Substitute.Command(pattern: "a", replacement: "b",
                                        global: false, ignoreCase: false, confirm: false))
    }

    @Test func parsePercentIsAcceptedAndIgnored() {
        #expect(parsed("%s/a/b/g")?.global == true)
        #expect(parsed("%s/a/b/g")?.pattern == "a")
        #expect(parsed("s/a/b/g") == parsed("%s/a/b/g"))
    }

    @Test func parseFlags() {
        #expect(parsed("s/a/b/g")?.global == true)
        #expect(parsed("s/a/b/c")?.confirm == true)
        #expect(parsed("s/a/b/i")?.ignoreCase == true)
        #expect(parsed("s/a/b/cg")?.confirm == true && parsed("s/a/b/cg")?.global == true)
        #expect(parsed("s/a/b/gci")?.ignoreCase == true)   // order does not matter
        #expect(parsed("s/a/b/ gc")?.global == true)       // spaces are tolerated
        #expect(parsed("s/a/b")?.global == false)          // flags are optional
    }

    @Test func parseCommandPrefixesAndSeparators() {
        #expect(parsed("su/a/b/") != nil)
        #expect(parsed("substitute/a/b/") != nil)
        #expect(parsed("s,a,b,g")?.global == true)
        #expect(parsed("s#a#b#")?.pattern == "a")
        #expect(parsed("s:a:b:")?.replacement == "b")
    }

    @Test func parseEscapedSeparatorAndOpenFields() {
        #expect(parsed("s/a\\/b/c/")?.pattern == "a\\/b")
        #expect(parsed("s,a\\,b,c,")?.pattern == "a\\,b")
        // `s/a` == `s/a//`: open fields close at the end of the line
        #expect(parsed("s/a")?.replacement == "")
        #expect(parsed("s/a")?.pattern == "a")
        // an empty pattern is legal to parse — the editor rejects it
        #expect(parsed("s//x/")?.pattern == "")
    }

    @Test func parseRejectsForeignCommands() {
        for notSub in ["w", "wq", "e file", "e! f", "/query", "5", "q!", "qa",
                       "sh", "terminal", "s", "sub", "%", "", "%%s/a/b/",
                       "s a b", "s1a1b1", "s/a/b/x", "S/a/b/"] {
            #expect(parsed(notSub) == nil, "expected nil for \(notSub)")
        }
    }

    @Test func parseSelectionMarks() {
        #expect(parsed("'<,'>s/a/b/g")?.scope == .selectionRange)
        #expect(parsed("'<s/a/b/")?.scope == .selectionStart)
        #expect(parsed("'>s/a/b/")?.scope == .selectionEnd)
        #expect(parsed("'<,'>su/a/b/")?.scope == .selectionRange)   // command prefixes too
        #expect(parsed("'<,'>s/a/b/g")?.global == true)             // the rest parses as usual
        // not mark forms — somebody else's command (or a typo)
        for bad in ["'>,'<s/a/b/", "'<,5s/a/b/", "%'<,'>s/a/b/", "'x s/a/b/", "'s/a/b/"] {
            #expect(parsed(bad) == nil, "expected nil for \(bad)")
        }
    }

    // MARK: - pattern translation (vim magic → ICU)

    private func icu(_ vim: String) -> String {
        guard case .success(let s) = Substitute.translatePattern(vim) else {
            Issue.record("expected a successful translation for \(vim)")
            return ""
        }
        return s
    }

    private func failsToTranslate(_ vim: String) -> Bool {
        if case .failure = Substitute.translatePattern(vim) { return true }
        return false
    }

    @Test func escapedMetacharsBecomeBare() {
        #expect(icu("\\(a\\)") == "(a)")
        #expect(icu("a\\|b") == "a|b")
        #expect(icu("ab\\+") == "ab+")
        #expect(icu("x\\?") == "x?")
        #expect(icu("a\\{2,3}") == "a{2,3}")
        #expect(icu("\\d\\+") == "\\d+")
        #expect(icu("\\<word\\>") == "\\bword\\b")
    }

    @Test func bareMetacharsGetEscaped() {
        #expect(icu("(") == "\\(")
        #expect(icu("f(x)? + y") == "f\\(x\\)\\? \\+ y")
        #expect(icu("a{b}") == "a\\{b}")
        // a bare } stays bare: literal in ICU too, and it must close
        // a `\{n,m}` quantifier as-is
        #expect(icu("}") == "}")
    }

    @Test func bracketClassesPassThrough() {
        #expect(icu("[a(b]") == "[a(b]")
        // a bare + after a class is a LITERAL in vim magic (the
        // quantifier is \+) — so the translation escapes it
        #expect(icu("[[:alpha:]]+") == "[[:alpha:]]\\+")
        #expect(icu("[a-z]+") == "[a-z]\\+")
        #expect(icu("[a-z]\\+") == "[a-z]+")     // the vim one-or-more
        #expect(icu("[]a]") == "[]a]")     // a ] right after [ is a member
        #expect(icu("[^]a]") == "[^]a]")   // …also after the leading ^
    }

    @Test func literalBackslashStaysLiteral() {
        // vim `\\(` = a literal backslash + a literal "(" — the ICU
        // reading of the translation is the same two literals
        #expect(icu("\\\\(") == "\\\\\\(")
        #expect(icu("a\\/b") == "a\\/b")
    }

    @Test func magicModePrefixesAreRejected() {
        #expect(failsToTranslate("\\vfoo+"))
        #expect(failsToTranslate("\\m(.*)"))
        #expect(failsToTranslate("\\Mx"))
        #expect(failsToTranslate("\\Vy"))
    }

    // MARK: - replacement translation and expansion

    @Test func replacementSegments() {
        #expect(Substitute.translateReplacement("abc") == [.literal("abc")])
        #expect(Substitute.translateReplacement("\\1") == [.group(1)])
        #expect(Substitute.translateReplacement("\\0") == [.group(0)])
        #expect(Substitute.translateReplacement("&") == [.group(0)])
        #expect(Substitute.translateReplacement("x&y")
                == [.literal("x"), .group(0), .literal("y")])
        #expect(Substitute.translateReplacement("pre\\2post")
                == [.literal("pre"), .group(2), .literal("post")])
    }

    @Test func replacementEscapes() {
        #expect(Substitute.translateReplacement("\\&") == [.literal("&")])
        #expect(Substitute.translateReplacement("\\r") == [.literal("\n")])
        #expect(Substitute.translateReplacement("\\t") == [.literal("\t")])
        #expect(Substitute.translateReplacement("\\\\") == [.literal("\\")])
        #expect(Substitute.translateReplacement("\\/") == [.literal("/")])
        #expect(Substitute.translateReplacement("\\q") == [.literal("q")]) // unknown → the char
    }

    @Test func maxGroupScan() {
        #expect(Substitute.maxGroup(in: []) == 0)
        #expect(Substitute.maxGroup(in: [.literal("x")]) == 0)
        #expect(Substitute.maxGroup(in: [.literal("a"), .group(2), .group(0)]) == 2)
        #expect(Substitute.maxGroup(in: [.group(9)]) == 9)
    }

    @Test func expandGroups() throws {
        let regex = try NSRegularExpression(pattern: "([a-z]+) ([a-z]+)")
        let line = "hello world"
        let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))!
        #expect(Substitute.expand([.group(2), .literal(" "), .group(1)],
                                  line: line, match: match) == "world hello")
        #expect(Substitute.expand([.group(0)], line: line, match: match) == "hello world")
        #expect(Substitute.expand([.group(5)], line: line, match: match) == "")
        #expect(Substitute.expand([.literal("x"), .group(1)], line: line, match: match)
                == "xhello")
    }

    // MARK: - the edit plan

    private func plan(_ vimPattern: String, replacement: String,
                      over lines: [(index: Int, text: String, byteStart: Int)],
                      global: Bool = true,
                      caseInsensitive: Bool = false) -> [Substitute.Edit] {
        guard case .success(let pattern) = Substitute.translatePattern(vimPattern) else {
            Issue.record("bad test pattern")
            return []
        }
        let regex = try! NSRegularExpression(pattern: pattern,
                                             options: caseInsensitive ? [.caseInsensitive] : [])
        let windowed: [(index: Int, text: String, byteStart: Int, byteWindow: Range<Int>?)] =
            lines.map { (index: $0.index, text: $0.text, byteStart: $0.byteStart, byteWindow: nil) }
        return Substitute.edits(lines: windowed, regex: regex,
                                segments: Substitute.translateReplacement(replacement),
                                global: global)
    }

    @Test func byteOffsetsOnCyrillic() {
        // ICU matches arrive in UTF-16; the plan must speak bytes:
        // "привет" is 12 bytes + the space is 1 → "мир" starts at 13
        let edits = plan("мир", replacement: "X", over: [(index: 0, text: "привет мир", byteStart: 0)])
        #expect(edits.count == 1)
        #expect(edits[0].offset == 13)
        #expect(edits[0].length == 6)
        #expect(edits[0].replacement == "X")
        #expect(edits[0].line == 0)
    }

    @Test func globalVsFirstPerLine() {
        let lines = [(index: 0, text: "foo bar", byteStart: 0),
                     (index: 1, text: "bar baz", byteStart: 8)]   // "foo bar\n" is 8 bytes
        // line 1: "bar" at 4; line 2: "bar" AT THE START — 8 + 0
        let g = plan("bar", replacement: "-", over: lines, global: true)
        #expect(g.map(\.offset) == [4, 8])
        let first = plan("bar", replacement: "-", over: lines, global: false)
        #expect(first.map(\.offset) == [4, 8])   // one per line, first occurrence
        let single = plan("bar", replacement: "-", over: [(0, "bar bar", 0)], global: false)
        #expect(single.map(\.offset) == [0])
    }

    @Test func editsAreAscending() {
        let edits = plan("a", replacement: "-", over: [(0, "a a a", 0)])
        #expect(edits.map(\.offset) == [0, 2, 4])
    }

    @Test func terminatorStrippingIsTheCallersContract() {
        // `edits` trusts its caller to pass text WITHOUT the line
        // terminator (EditorWindow strips the full terminator grapheme
        // — "\n", "\r\n" or "\r"). The danger this guard closes, pinned
        // here: ICU's \s matches \r and \n, so on terminator-containing
        // text a trailing \s\+ WOULD plan to eat it (joining lines on
        // CRLF files). If this expectation flips, the editor's strip
        // has a hole.
        let raw = plan("\\s\\+$", replacement: "", over: [(0, "x  \r\n", 0)])
        #expect(raw.count == 1)
        #expect(raw[0].length == 4)   // "  \r\n" — the terminator is swallowed
    }

    // MARK: - byte windows (the blockwise selection's territory)

    private func planWindowed(_ vimPattern: String, replacement: String,
                              text: String, byteStart: Int = 0,
                              window: Range<Int>?) -> [Substitute.Edit] {
        guard case .success(let pattern) = Substitute.translatePattern(vimPattern) else {
            Issue.record("bad test pattern")
            return []
        }
        let regex = try! NSRegularExpression(pattern: pattern)
        return Substitute.edits(
            lines: [(index: 0, text: text, byteStart: byteStart, byteWindow: window)],
            regex: regex,
            segments: Substitute.translateReplacement(replacement),
            global: true)
    }

    @Test func windowKeepsOnlyFullyInsideMatches() {
        // X at bytes 1 and 3; the window [2,4) admits only the second
        let inside = planWindowed("X", replacement: "-", text: "aXbXc", window: 2..<4)
        #expect(inside.map(\.offset) == [3])
        // a partially overlapping match (bytes 0..<2 vs window 1..<3) is skipped
        let partial = planWindowed("aX", replacement: "-", text: "aXbXc", window: 1..<3)
        #expect(partial.isEmpty)
        // a wider window admits both
        let wide = planWindowed("X", replacement: "-", text: "aXbXc", window: 0..<5)
        #expect(wide.map(\.offset) == [1, 3])
        // nil window = the whole line
        let all = planWindowed("X", replacement: "-", text: "aXbXc", window: nil)
        #expect(all.map(\.offset) == [1, 3])
    }

    @Test func windowBoundariesAreClosedForZeroLengthMatches() {
        // zero-length matches sit ON the boundaries — admitted at
        // either edge (a pinned rule, not an accident)
        let edges = planWindowed("x*", replacement: "-", text: "abc", window: 1..<2)
        #expect(edges.map(\.offset) == [1, 2])
    }

    @Test func windowWorksOnCyrillicBytes() {
        // "мир" is bytes 13..<19 of "привет мир"; a window that CUTS
        // into the match by even one byte (left or right) rejects it
        #expect(planWindowed("мир", replacement: "X", text: "привет мир",
                             window: 13..<19).map(\.offset) == [13])
        #expect(planWindowed("мир", replacement: "X", text: "привет мир",
                             window: 14..<19).isEmpty)   // cuts the left edge
        #expect(planWindowed("мир", replacement: "X", text: "привет мир",
                             window: 13..<18).isEmpty)   // cuts the right edge
        #expect(planWindowed("мир", replacement: "X", text: "привет мир",
                             window: 0..<13).isEmpty)
    }

    @Test func zeroLengthMatchesAreKept() {
        let anchor = plan("^", replacement: "$", over: [(0, "abc", 0)], global: true)
        #expect(anchor.count == 1 && anchor[0].length == 0 && anchor[0].offset == 0)
        // an empty line still hosts an empty match — vim replaces there too
        let empty = plan("x*", replacement: "-", over: [(0, "", 0)], global: true)
        #expect(empty.count == 1 && empty[0].length == 0)
        // a no-op substitution (`:s/^//`) still counts as one
        let noop = plan("^", replacement: "", over: [(0, "abc", 0)])
        #expect(noop.count == 1 && noop[0].replacement.isEmpty)
    }

    @Test func ignoreCaseMatchesCaseInsensitively() {
        let edits = plan("SWIM", replacement: "x", over: [(0, "swim Swim", 0)],
                         caseInsensitive: true)
        #expect(edits.count == 2)
    }

    @Test func backReferenceReplacement() {
        let edits = plan("\\(\\w\\+\\) \\(\\w\\+\\)", replacement: "\\2 \\1",
                         over: [(0, "hello world", 0)])
        #expect(edits.count == 1)
        #expect(edits[0].replacement == "world hello")
    }

    @Test func escapedLineBreakInReplacement() {
        let edits = plan(",", replacement: ";\\r", over: [(0, "a,b", 0)])
        #expect(edits.count == 1)
        #expect(edits[0].replacement == ";\n")   // \r is the vim line break
    }

    @Test func escapedSeparatorMatchesLiteralSeparator() {
        let edits = plan("a\\/b", replacement: "X", over: [(0, "x a/b y", 0)])
        #expect(edits.count == 1 && edits[0].offset == 2 && edits[0].length == 3)
    }

    // MARK: - messages

    @Test func reportWordForms() {
        #expect(Substitute.report(substitutions: 1, lines: 1) == "1 substitution on 1 line")
        #expect(Substitute.report(substitutions: 3, lines: 1) == "3 substitutions on 1 line")
        #expect(Substitute.report(substitutions: 1, lines: 2) == "1 substitution on 2 lines")
        #expect(Substitute.report(substitutions: 7, lines: 5) == "7 substitutions on 5 lines")
    }

    @Test func confirmPromptWordForms() {
        #expect(Substitute.confirmPrompt(replacement: "bar") == "replace with bar (y/n/a/q/l)?")
        #expect(Substitute.confirmPrompt(replacement: "") == "replace with  (y/n/a/q/l)?")
    }
}
